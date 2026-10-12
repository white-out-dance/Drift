"""Spoof engine for the Mac side: teleport, real-road routes, hold/resend,
killswitch, schedules, plus history/bookmarks persistence."""

from __future__ import annotations

import asyncio
import json
import logging
import math
import random
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Optional

from device import Device, DeviceError, friendly

log = logging.getLogger("drift.engine")

DATA_DIR = Path.home() / "Library" / "Application Support" / "Drift"
UA = "Drift-personal/1.0 (local location tool)"

MODES = {
    "walk": {"label": "Walk", "kmh": 5, "osrm": "routed-foot"},
    "bike": {"label": "Bike", "kmh": 16, "osrm": "routed-bike"},
    "drive": {"label": "Drive", "kmh": 50, "osrm": "routed-car"},
}


def _get_json(url: str, timeout: float = 12) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 6371000 * 2 * math.asin(math.sqrt(h))


def sample_path(coords: list[list[float]], mps: float, interval: float = 1.0, variation: float = 0.12) -> list[list[float]]:
    """One point per `interval` seconds along `coords` at ~`mps` metres/second."""
    if len(coords) < 2 or mps <= 0:
        return coords
    out = [coords[0]]
    seg = 0
    cur = list(coords[0])
    while seg < len(coords) - 1:
        step = mps * interval * (1 + random.uniform(-variation, variation))
        while seg < len(coords) - 1:
            nxt = coords[seg + 1]
            remaining = haversine((cur[0], cur[1]), (nxt[0], nxt[1]))
            if step < remaining:
                f = step / remaining
                cur = [cur[0] + (nxt[0] - cur[0]) * f, cur[1] + (nxt[1] - cur[1]) * f]
                out.append(cur)
                break
            step -= remaining
            cur = list(nxt)
            seg += 1
            if seg == len(coords) - 1:
                out.append(cur)
    return out


def search_places(query: str) -> list[dict[str, Any]]:
    q = query.strip()
    parts = [p for p in q.replace(",", " ").split() if p]
    results: list[dict[str, Any]] = []
    if len(parts) == 2:
        try:
            lat, lon = float(parts[0]), float(parts[1])
            if -90 <= lat <= 90 and -180 <= lon <= 180:
                results.append({"name": "Coordinates", "subtitle": f"{lat:.5f}, {lon:.5f}", "lat": lat, "lon": lon})
        except ValueError:
            pass
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
        {"q": q, "format": "jsonv2", "limit": 8, "addressdetails": 0})
    for item in _get_json(url):
        display = item.get("display_name", "")
        name = item.get("name") or display.split(",")[0]
        subtitle = ", ".join(s.strip() for s in display.split(",")[1:4])
        results.append({"name": name, "subtitle": subtitle, "lat": float(item["lat"]), "lon": float(item["lon"])})
    return results


def reverse_place(lat: float, lon: float) -> dict[str, Any]:
    url = "https://nominatim.openstreetmap.org/reverse?" + urllib.parse.urlencode(
        {"lat": lat, "lon": lon, "format": "jsonv2", "zoom": 17})
    try:
        item = _get_json(url)
        display = item.get("display_name", "")
        name = item.get("name") or display.split(",")[0] or "Dropped pin"
        subtitle = ", ".join(s.strip() for s in display.split(",")[1:4])
        return {"name": name, "subtitle": subtitle, "lat": lat, "lon": lon}
    except Exception:
        return {"name": "Dropped pin", "subtitle": "", "lat": lat, "lon": lon}


def plan_route(start: dict, end: dict, mode: str, via: Optional[list[dict]] = None) -> dict[str, Any]:
    """Road route start -> via... -> end (OSRM); straight lines if routing fails."""
    stops = [start] + list(via or []) + [end]
    profile = MODES.get(mode, MODES["walk"])["osrm"]
    path = ";".join(f"{p['lon']},{p['lat']}" for p in stops)
    url = f"https://routing.openstreetmap.de/{profile}/route/v1/driving/{path}?overview=full&geometries=geojson"
    try:
        data = _get_json(url, timeout=20)
        route = data["routes"][0]
        coords = [[c[1], c[0]] for c in route["geometry"]["coordinates"]]
        coords = [[start["lat"], start["lon"]]] + coords + [[end["lat"], end["lon"]]]
        return {"start": start, "end": end, "via": list(via or []), "mode": mode, "coords": coords,
                "distance": route["distance"], "followsRoads": True}
    except Exception as exc:
        log.info("routing failed, straight line: %r", exc)
        coords = [[p["lat"], p["lon"]] for p in stops]
        dist = sum(haversine(tuple(coords[i]), tuple(coords[i + 1])) for i in range(len(coords) - 1))
        return {"start": start, "end": end, "via": list(via or []), "mode": mode, "coords": coords,
                "distance": dist, "followsRoads": False}


class Library:
    def __init__(self) -> None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        self.path = DATA_DIR / "library.json"
        self.history: list[dict] = []
        self.bookmarks: list[dict] = []
        self.jobs: list[dict] = []
        self.presets: dict[str, Optional[dict]] = {"home": None, "work": None}
        self.settings: dict[str, Any] = {"killswitchMinutes": 0, "jitter": False,
                                         "walkKmh": 5, "bikeKmh": 16, "driveKmh": 50}
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                self.history = data.get("history", [])
                self.bookmarks = data.get("bookmarks", [])
                self.jobs = data.get("jobs", [])
                self.presets.update(data.get("presets", {}))
                self.settings.update(data.get("settings", {}))
            except Exception:
                log.exception("library unreadable; starting fresh")

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"history": self.history, "bookmarks": self.bookmarks,
                                   "jobs": self.jobs, "presets": self.presets,
                                   "settings": self.settings}, indent=1))
        tmp.replace(self.path)

    @staticmethod
    def _near(a: dict, b: dict, meters: float = 25) -> bool:
        return haversine((a["lat"], a["lon"]), (b["lat"], b["lon"])) < meters

    def record(self, place: dict) -> None:
        entry = {**place, "id": str(uuid.uuid4()), "date": time.time()}
        self.history = [h for h in self.history if not self._near(h, entry)]
        self.history.insert(0, entry)
        del self.history[60:]
        self.save()

    def toggle_bookmark(self, place: dict) -> bool:
        if any(self._near(b, place) for b in self.bookmarks):
            self.bookmarks = [b for b in self.bookmarks if not self._near(b, place)]
            self.save()
            return False
        self.bookmarks.insert(0, {**place, "id": str(uuid.uuid4()), "date": time.time()})
        self.save()
        return True

    def kmh(self, mode: str) -> float:
        return float(self.settings.get(f"{mode}Kmh") or MODES[mode]["kmh"])


class Engine:
    def __init__(self, device: Device, library: Library) -> None:
        self.device = device
        self.library = library
        self.status = "idle"   # idle | working | holding | moving | paused
        self.message = ""
        self.place: Optional[dict] = None
        self.route: Optional[dict] = None
        self.current: Optional[list[float]] = None
        self.progress = 0.0
        self.remaining = 0
        self.killswitch_deadline: Optional[float] = None
        self.warning: Optional[str] = None
        self.error: Optional[str] = None
        self._hold_task: Optional[asyncio.Task] = None
        self._route_task: Optional[asyncio.Task] = None
        self._ticker: Optional[asyncio.Task] = None
        self._paused = False
        self._busy = False
        self.started_at: Optional[float] = None
        self.route_started_at: Optional[float] = None

    def start(self) -> None:
        self._ticker = asyncio.create_task(self._tick_loop())

    def snapshot(self) -> dict[str, Any]:
        return {
            "status": self.status, "message": self.message, "place": self.place,
            "route": self.route, "current": self.current, "progress": self.progress,
            "remaining": self.remaining, "killswitchDeadline": self.killswitch_deadline,
            "warning": self.warning, "error": self.error,
            "history": self.library.history, "bookmarks": self.library.bookmarks,
            "jobs": self.library.jobs, "settings": self.library.settings, "now": time.time(),
            "presets": self.library.presets, "startedAt": self.started_at, "routeStartedAt": self.route_started_at,
        }

    @property
    def active(self) -> bool:
        return self.status in ("holding", "moving", "paused")

    def _progress(self, msg: str) -> None:
        self.message = msg

    # ----- actions -----

    async def teleport(self, place: dict) -> None:
        if self._busy:
            return
        self._busy = True
        was_active = self.active
        self._cancel_route()
        self._cancel_hold()
        prev = (self.status, self.place, self.current)
        self.status, self.message, self.error = "working", "Connecting…", None
        try:
            await self.device.set_location(place["lat"], place["lon"], progress=self._progress)
            self.status, self.place, self.route = "holding", place, None
            self.current = [place["lat"], place["lon"]]
            self.route_started_at = None
            if not was_active or self.started_at is None:
                self.started_at = time.time()
            self.library.record(place)
            self._arm_killswitch(was_active)
            self._start_hold(self.current)
        except Exception as exc:
            self.error = friendly(exc)
            self.status, self.place, self.current = prev if was_active else ("idle", None, None)
            if was_active and self.current:
                self._start_hold(self.current)
        finally:
            self._busy = False

    async def start_route(self, route: dict, kmh: float, loop: bool) -> None:
        if self._busy or not route.get("coords"):
            return
        self._busy = True
        was_active = self.active
        self._cancel_route()
        self._cancel_hold()
        self.status, self.message, self.error = "working", "Connecting…", None
        try:
            first = route["coords"][0]
            await self.device.set_location(first[0], first[1], progress=self._progress)
            self.current = list(first)
            self.library.record(route["start"])
            self._arm_killswitch(was_active)
            self.route, self.place, self.status, self._paused = route, None, "moving", False
            self.route_started_at = time.time()
            if not was_active or self.started_at is None:
                self.started_at = time.time()
            self._route_task = asyncio.create_task(self._play(route, kmh / 3.6, loop))
        except Exception as exc:
            self.error = friendly(exc)
            self.status, self.current = "idle", None
        finally:
            self._busy = False

    def toggle_pause(self) -> None:
        if self.status == "moving":
            self._paused, self.status = True, "paused"
            if self.current:
                self._start_hold(self.current)
        elif self.status == "paused":
            self._cancel_hold()
            self._paused, self.status = False, "moving"

    async def stop(self) -> None:
        self._cancel_route()
        self._cancel_hold()
        self.killswitch_deadline = None
        self.warning = None
        self.status, self.message = "working", "Restoring real location…"
        try:
            await self.device.clear_location()
        except Exception as exc:
            self.error = f"Stopped, but couldn't reach the iPhone to reset GPS ({friendly(exc)}). Plug it back in and press Stop again, or restart the phone."
        self.status, self.place, self.route, self.current = "idle", None, None, None
        self.progress, self.remaining = 0.0, 0
        self.started_at = self.route_started_at = None

    def extend_killswitch(self, minutes: int) -> None:
        if self.killswitch_deadline:
            self.killswitch_deadline += minutes * 60

    def disarm_killswitch(self) -> None:
        self.killswitch_deadline = None

    def schedule(self, fire_at: float, action: dict) -> dict:
        job = {"id": str(uuid.uuid4()), "fireAt": fire_at, "action": action}
        self.library.jobs.append(job)
        self.library.jobs.sort(key=lambda j: j["fireAt"])
        self.library.save()
        return job

    def cancel_job(self, job_id: str) -> None:
        self.library.jobs = [j for j in self.library.jobs if j["id"] != job_id]
        self.library.save()

    # ----- internals -----

    def _arm_killswitch(self, was_active: bool) -> None:
        minutes = int(self.library.settings.get("killswitchMinutes") or 0)
        if minutes <= 0:
            self.killswitch_deadline = None
        elif not was_active or self.killswitch_deadline is None:
            self.killswitch_deadline = time.time() + minutes * 60

    def _jitter(self, c: list[float]) -> list[float]:
        if not self.library.settings.get("jitter"):
            return c
        m, b = random.uniform(0, 3), random.uniform(0, 2 * math.pi)
        dlat = m * math.cos(b) / 111320
        dlon = m * math.sin(b) / (111320 * max(math.cos(math.radians(c[0])), 0.01))
        return [c[0] + dlat, c[1] + dlon]

    def _start_hold(self, coord: list[float]) -> None:
        self._cancel_hold()
        self._hold_task = asyncio.create_task(self._hold(list(coord)))

    def _cancel_hold(self) -> None:
        if self._hold_task:
            self._hold_task.cancel()
            self._hold_task = None

    def _cancel_route(self) -> None:
        if self._route_task:
            self._route_task.cancel()
            self._route_task = None
        self._paused = False
        self.progress, self.remaining = 0.0, 0

    async def _hold(self, coord: list[float]) -> None:
        failures = 0
        while True:
            await asyncio.sleep(4)
            p = self._jitter(coord)
            try:
                await self.device.set_location(p[0], p[1])
                failures, self.warning = 0, None
            except asyncio.CancelledError:
                raise
            except Exception:
                failures += 1
                if failures >= 2:
                    self.warning = "Lost the iPhone — retrying. Check the cable and keep it unlocked."

    async def _play(self, route: dict, mps: float, loop: bool) -> None:
        path = list(route["coords"])
        while True:
            samples = sample_path(path, mps)
            i, failures = 1, 0
            while i < len(samples):
                if self._paused:
                    await asyncio.sleep(0.5)
                    continue
                await asyncio.sleep(1)
                if self._paused:
                    continue
                pt = samples[i]
                try:
                    await self.device.set_location(pt[0], pt[1])
                    failures, self.warning = 0, None
                    self.current = pt
                    self.progress = i / max(len(samples) - 1, 1)
                    self.remaining = len(samples) - 1 - i
                    i += 1
                except asyncio.CancelledError:
                    raise
                except Exception:
                    failures += 1
                    if failures >= 2:
                        self.warning = "Lost the iPhone — retrying. Check the cable and keep it unlocked."
            if not loop:
                break
            path.reverse()
        end = route["end"]
        self.route_started_at = None
        self.status, self.place, self.route = "holding", end, None
        self.current = [end["lat"], end["lon"]]
        self.library.record(end)
        self._route_task = None
        self._start_hold(self.current)

    async def _tick_loop(self) -> None:
        while True:
            await asyncio.sleep(1)
            try:
                now = time.time()
                if self.killswitch_deadline and now >= self.killswitch_deadline and self.active:
                    self.killswitch_deadline = None
                    self.error = "Killswitch: spoofing stopped and your real location is back."
                    await self.stop()
                    continue
                due = next((j for j in self.library.jobs if j["fireAt"] <= now), None)
                if due and not self._busy:
                    self.cancel_job(due["id"])
                    asyncio.create_task(self._run_job(due))
            except Exception:
                log.exception("tick failed")

    async def _run_job(self, job: dict) -> None:
        action = job["action"]
        if action.get("kind") == "teleport":
            await self.teleport(action["place"])
        elif action.get("kind") == "route":
            route = await asyncio.to_thread(plan_route, action["start"], action["end"], action["mode"], action.get("via"))
            await self.start_route(route, float(action.get("kmh") or self.library.kmh(action["mode"])),
                                   bool(action.get("loop")))
