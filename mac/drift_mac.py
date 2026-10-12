"""Drift for Mac: local web app at http://127.0.0.1:8765

- One-time setup for the phone-only app (Developer Mode, install, pairing file)
- Spoof the iPhone's location over USB, with routes, bookmarks, history,
  schedules and a killswitch.

Nothing here leaves your Mac except map tiles, place search (OpenStreetMap
Nominatim) and road routing (routing.openstreetmap.de).
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import subprocess
import sys
import time
import webbrowser
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import uvicorn
from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse

sys.path.insert(0, str(Path(__file__).parent))
from device import Device, friendly  # noqa: E402
from engine import DATA_DIR, Engine, Library, plan_route, reverse_place, search_places  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
WEB = Path(__file__).resolve().parent / "web"
PORT = int(os.environ.get("DRIFT_PORT", "8765"))
PAIRING_OUT = Path.home() / "Desktop" / "Drift-pairing.plist"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logging.getLogger("pymobiledevice3").setLevel(logging.WARNING)
log = logging.getLogger("drift")

device = Device()
library = Library()
engine = Engine(device, library)


class Job:
    """A long-running shell step (install / build) whose output the UI polls."""

    def __init__(self) -> None:
        self.running = False
        self.lines: list[str] = []
        self.ok: Optional[bool] = None
        self.title = ""

    def snapshot(self) -> dict[str, Any]:
        return {"running": self.running, "lines": self.lines[-200:], "ok": self.ok, "title": self.title}

    async def run(self, title: str, cmd: list[str]) -> None:
        if self.running:
            raise HTTPException(409, "Another setup step is still running.")
        self.running, self.ok, self.lines, self.title = True, None, [], title
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(ROOT))
            assert proc.stdout
            async for raw in proc.stdout:
                self.lines.append(raw.decode(errors="replace").rstrip())
            self.ok = (await proc.wait()) == 0
        except Exception as exc:
            self.lines.append(f"ERROR: {exc}")
            self.ok = False
        finally:
            self.running = False


job = Job()


@asynccontextmanager
async def lifespan(app: FastAPI):
    engine.start()
    yield
    await device.reset()


app = FastAPI(lifespan=lifespan)


def ok(**extra: Any) -> JSONResponse:
    return JSONResponse({"ok": True, **extra})


def fail(exc: BaseException) -> JSONResponse:
    log.exception("request failed")
    return JSONResponse({"ok": False, "error": friendly(exc)}, status_code=400)


@app.get("/")
async def index():
    return FileResponse(WEB / "index.html", headers={"Cache-Control": "no-store"})


@app.get("/api/state")
async def state():
    return engine.snapshot()


@app.get("/api/device")
async def device_status():
    return await device.status()


@app.post("/api/clear-error")
async def clear_error():
    engine.error = None
    return ok()


# ---------- spoofing ----------

@app.post("/api/teleport")
async def teleport(place: dict = Body(...)):
    asyncio.create_task(engine.teleport(place))
    return ok()


@app.post("/api/route/plan")
async def route_plan(body: dict = Body(...)):
    try:
        route = await asyncio.to_thread(plan_route, body["start"], body["end"], body.get("mode", "walk"), body.get("via"))
        return ok(route=route)
    except Exception as exc:
        return fail(exc)


@app.post("/api/route/start")
async def route_start(body: dict = Body(...)):
    route = body["route"]
    kmh = float(body.get("kmh") or library.kmh(route.get("mode", "walk")))
    asyncio.create_task(engine.start_route(route, kmh, bool(body.get("loop"))))
    return ok()


@app.post("/api/pause")
async def pause():
    engine.toggle_pause()
    return ok()


@app.post("/api/stop")
async def stop():
    await engine.stop()
    return ok()


@app.post("/api/killswitch")
async def killswitch(body: dict = Body(...)):
    if body.get("off"):
        engine.disarm_killswitch()
    else:
        engine.extend_killswitch(int(body.get("minutes", 15)))
    return ok()


# ---------- library ----------

@app.post("/api/bookmark")
async def bookmark(place: dict = Body(...)):
    return ok(bookmarked=library.toggle_bookmark(place))


@app.post("/api/library/delete")
async def library_delete(body: dict = Body(...)):
    kind, item_id = body.get("kind"), body.get("id")
    if kind == "history":
        library.history = [h for h in library.history if h.get("id") != item_id] if item_id else []
    elif kind == "bookmarks":
        library.bookmarks = [b for b in library.bookmarks if b.get("id") != item_id]
    library.save()
    return ok()


@app.post("/api/preset")
async def preset(body: dict = Body(...)):
    key = body.get("key")
    if key not in ("home", "work"):
        raise HTTPException(400, "Unknown preset")
    library.presets[key] = body.get("place")
    library.save()
    return ok(presets=library.presets)


@app.get("/api/library/export")
async def library_export():
    data = {"history": library.history, "bookmarks": library.bookmarks, "presets": library.presets}
    return JSONResponse(data, headers={"Content-Disposition": 'attachment; filename="drift-places.json"'})


@app.post("/api/library/import")
async def library_import(body: dict = Body(...)):
    def merge(existing: list, incoming: list) -> list:
        out = list(existing)
        for p in incoming or []:
            if isinstance(p, dict) and "lat" in p and "lon" in p and not any(Library._near(p, e) for e in out):
                out.append(p)
        return out
    library.bookmarks = merge(library.bookmarks, body.get("bookmarks", []))
    library.history = merge(library.history, body.get("history", []))[:60]
    for k, v in (body.get("presets") or {}).items():
        if k in library.presets and v and not library.presets.get(k):
            library.presets[k] = v
    library.save()
    return ok()


@app.post("/api/settings")
async def settings(body: dict = Body(...)):
    allowed = {"killswitchMinutes", "jitter", "walkKmh", "bikeKmh", "driveKmh"}
    library.settings.update({k: v for k, v in body.items() if k in allowed})
    library.save()
    return ok(settings=library.settings)


@app.post("/api/schedule")
async def schedule(body: dict = Body(...)):
    fire_at = float(body["fireAt"])
    if fire_at < time.time() - 5:
        raise HTTPException(400, "Pick a time in the future.")
    return ok(job=engine.schedule(fire_at, body["action"]))


@app.post("/api/schedule/cancel")
async def schedule_cancel(body: dict = Body(...)):
    engine.cancel_job(body["id"])
    return ok()


@app.get("/api/search")
async def search(q: str):
    try:
        return ok(results=await asyncio.to_thread(search_places, q))
    except Exception as exc:
        return fail(exc)


@app.get("/api/reverse")
async def reverse(lat: float, lon: float):
    return ok(place=await asyncio.to_thread(reverse_place, lat, lon))


# ---------- one-time setup ----------

@app.post("/api/setup/devmode")
async def setup_devmode():
    try:
        return ok(message=await device.reveal_developer_mode())
    except Exception as exc:
        return fail(exc)


@app.post("/api/setup/mount")
async def setup_mount():
    try:
        return ok(message=await device.mount_image())
    except Exception as exc:
        return fail(exc)


@app.post("/api/setup/pairing")
async def setup_pairing():
    try:
        made = await device.create_pairing_file(PAIRING_OUT)
        message = f"Pairing file saved to {PAIRING_OUT.name} on your Desktop."
        pushed = None
        try:
            pushed = await device.push_pairing_file(PAIRING_OUT.read_bytes())
            message += " It was also copied straight into Drift on your iPhone, so you're set."
        except Exception as exc:
            message += f" Couldn't copy it into Drift automatically ({friendly(exc)}). AirDrop the file to your iPhone and choose Drift."
        return ok(message=message, pushed=pushed, **made)
    except Exception as exc:
        return fail(exc)


@app.post("/api/setup/push-pairing")
async def setup_push_pairing():
    try:
        if not PAIRING_OUT.exists():
            raise FileNotFoundError("Make the pairing file first.")
        bundle = await device.push_pairing_file(PAIRING_OUT.read_bytes())
        return ok(message=f"Copied into Drift ({bundle}).")
    except Exception as exc:
        return fail(exc)


@app.post("/api/setup/install")
async def setup_install():
    await device.reset()
    udid = None
    try:
        udid = await device.pick_udid()
    except Exception:
        pass
    cmd = ["/bin/zsh", str(ROOT / "scripts" / "install-iphone.sh")] + ([udid] if udid else [])
    asyncio.create_task(job.run("Install Drift on iPhone", cmd))
    return ok()


@app.get("/api/setup/job")
async def setup_job():
    return job.snapshot()


@app.post("/api/reveal")
async def reveal(body: dict = Body(...)):
    path = Path(body.get("path") or PAIRING_OUT)
    if path.exists():
        subprocess.Popen(["open", "-R", str(path)])
    return ok()


@app.post("/api/quit")
async def quit_app():
    async def _bye():
        await asyncio.sleep(0.3)
        if engine.active:
            try:
                await engine.stop()
            except Exception:
                pass
        await device.reset()
        os.kill(os.getpid(), signal.SIGTERM)
    asyncio.create_task(_bye())
    return ok()


def already_running() -> bool:
    import urllib.request
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/state", timeout=1):
            return True
    except Exception:
        return False


def main() -> None:
    url = f"http://127.0.0.1:{PORT}/"
    if already_running():
        webbrowser.open(url)
        return
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if "--no-browser" not in sys.argv:
        asyncio.get_event_loop_policy()
        import threading
        threading.Timer(1.2, lambda: webbrowser.open(url)).start()
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
