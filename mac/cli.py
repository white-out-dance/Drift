#!/usr/bin/env python3
"""Drift setup from the command line, for you or an AI assistant (Claude Code).

Run with the project's Python after scripts/setup-mac.sh:

  .venv/bin/python mac/cli.py status          # every setup step: done or not, and what's next
  .venv/bin/python mac/cli.py status --json   # same, machine-readable
  .venv/bin/python mac/cli.py devmode         # make the Developer Mode switch appear on the iPhone
  .venv/bin/python mac/cli.py launch          # open Drift on the iPhone (shows if it still needs Trust)
  .venv/bin/python mac/cli.py pairing         # make the pairing file and copy it into Drift
  .venv/bin/python mac/cli.py push-pairing    # copy the existing pairing file into Drift again
  .venv/bin/python mac/cli.py mount           # mount Apple's developer image now (optional)
  .venv/bin/python mac/cli.py spoof LAT LON [--hold 60]   # test over USB, then restore real GPS
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import subprocess
import sys
from contextlib import suppress
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pymobiledevice3.lockdown import create_using_usbmux  # noqa: E402
from pymobiledevice3.services.house_arrest import HouseArrestService  # noqa: E402
from pymobiledevice3.services.installation_proxy import InstallationProxyService  # noqa: E402
from pymobiledevice3.usbmux import list_devices  # noqa: E402

from device import Device, friendly  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PAIRING_OUT = Path.home() / "Desktop" / "Drift-pairing.plist"
LOCALDEVVPN_URL = "https://apps.apple.com/app/localdevvpn/id6755608044"

logging.basicConfig(level=logging.WARNING, format="%(message)s")
logging.getLogger("pymobiledevice3").setLevel(logging.ERROR)


def run(cmd: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ---------- status ----------

def mac_checks() -> list[dict[str, Any]]:
    checks = []
    dev = run(["xcode-select", "-p"]).stdout.strip()
    xcode_ok = ".app/" in dev and run(["xcodebuild", "-version"]).returncode == 0
    checks.append({
        "id": "xcode", "ok": xcode_ok, "who": "you",
        "detail": dev or "not installed",
        "next": ("Install Xcode from the Mac App Store and open it once (accept the license)."
                 if not Path("/Applications/Xcode.app").exists() or ".app/" in dev else
                 "In the Terminal app run: sudo xcode-select -s /Applications/Xcode.app"),
    })
    sdk_ok = xcode_ok and "iphoneos" in run(["xcodebuild", "-showsdks"]).stdout
    checks.append({
        "id": "ios_sdk", "ok": sdk_ok, "who": "claude",
        "detail": "installed" if sdk_ok else "missing",
        "next": "Run: xcodebuild -downloadPlatform iOS   (large download)",
    })
    teams = run(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"]).stdout
    checks.append({
        "id": "apple_id", "ok": "teamID" in teams, "who": "you",
        "detail": "signed in" if "teamID" in teams else "not signed in",
        "next": "Open Xcode › Settings › Accounts, click +, choose Apple ID and sign in (free is fine).",
    })
    return checks


async def phone_checks() -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []

    def add(id_: str, ok: bool, who: str, detail: str, next_: str) -> None:
        checks.append({"id": id_, "ok": ok, "who": who, "detail": detail, "next": next_})

    try:
        devices = await list_devices()
    except Exception as exc:
        devices = []
        add("iphone_connected", False, "you", friendly(exc), "Plug the iPhone in with a cable and unlock it.")
        return checks
    usb = [d for d in devices if d.connection_type == "USB"]
    chosen = (usb or devices or [None])[0]
    if chosen is None:
        add("iphone_connected", False, "you", "no iPhone found",
            "Plug the iPhone into the Mac with a cable and unlock it.")
        return checks
    udid = chosen.serial
    # Setup steps need the cable; over Wi-Fi we can still report the rest.
    add("iphone_connected", bool(usb), "you", udid if usb else f"{udid} (Wi-Fi only)",
        "Plug the iPhone into the Mac with a cable and unlock it.")

    try:
        lockdown = await create_using_usbmux(serial=udid, autopair=True, connection_type=chosen.connection_type)
    except Exception as exc:
        add("trusted", False, "you", friendly(exc),
            "Unlock the iPhone. If it asks “Trust This Computer?”, tap Trust and enter the passcode.")
        return checks
    try:
        add("trusted", True, "you", f"{lockdown.display_name or ''} iOS {lockdown.product_version}".strip(), "")

        dev_mode = None
        with suppress(Exception):
            dev_mode = await lockdown.get_developer_mode_status()
        add("developer_mode", bool(dev_mode), "both", "on" if dev_mode else "off",
            "Claude runs `mac/cli.py devmode`. Then on the iPhone: Settings › Privacy & Security › Developer Mode › "
            "On › Restart. After it restarts, unlock it and tap Turn On, then enter the passcode.")

        apps = await InstallationProxyService(lockdown=lockdown).get_apps(application_type="User")
        drift = await Device._find_drift(Device(), lockdown)
        add("drift_installed", bool(drift), "claude", drift or "not installed",
            "Run: ./scripts/install-iphone.sh   (keep the iPhone unlocked; first build takes a few minutes)")

        vpn = next((bid for bid, app in apps.items()
                    if "localdevvpn" in str(app.get("CFBundleDisplayName") or app.get("CFBundleName") or "").lower()), None)
        add("localdevvpn_installed", bool(vpn), "you", vpn or "not installed",
            f"On the iPhone install LocalDevVPN (free) from the App Store: {LOCALDEVVPN_URL} . "
            "Open it, allow it to add a VPN configuration, then tap Connect.")

        has_pairing = False
        if drift:
            with suppress(Exception):
                async with await HouseArrestService.create(lockdown, drift, documents_only=True) as afc:
                    has_pairing = "pairingFile.plist" in await afc.listdir("/Documents")
        add("pairing_file", has_pairing, "claude", "in Drift" if has_pairing else "missing",
            "Run: .venv/bin/python mac/cli.py pairing   (iPhone unlocked)")
    finally:
        await lockdown.close()
    return checks


async def status(as_json: bool) -> int:
    checks = mac_checks()
    if all(c["ok"] for c in checks):
        checks += await phone_checks()
    pending = next((c for c in checks if not c["ok"]), None)
    if as_json:
        print(json.dumps({"checks": checks, "next": pending, "done": pending is None}, indent=2))
        return 0
    for c in checks:
        print(f"{'✓' if c['ok'] else '✗'} {c['id']:<22} {c['detail']}")
    print()
    if pending:
        who = {"you": "You", "claude": "Claude/Mac", "both": "Claude, then you"}[pending["who"]]
        print(f"NEXT ({who}): {pending['next']}")
    else:
        print("All set. Test it: .venv/bin/python mac/cli.py spoof 48.8584 2.2945 --hold 60  "
              "(Apple Maps should show the Eiffel Tower), then follow docs/SETUP.md step 7 on the phone.")
    return 0


# ---------- actions ----------

def saved_bundle_id() -> Optional[str]:
    with suppress(OSError):
        return (ROOT / ".bundle-id").read_text().strip() or None
    return None


async def find_drift_bundle() -> Optional[str]:
    bundle = saved_bundle_id()
    if bundle:
        return bundle
    udid = await Device().pick_udid()
    lockdown = await create_using_usbmux(serial=udid, autopair=True)
    try:
        return await Device._find_drift(Device(), lockdown)
    finally:
        await lockdown.close()


async def launch() -> int:
    device = Device()
    udid = await device.pick_udid()
    bundle = await find_drift_bundle()
    if not bundle:
        print("Drift isn't installed yet. Run ./scripts/install-iphone.sh first.")
        return 1
    result = run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid,
                  "--terminate-existing", bundle], timeout=120)
    out = (result.stdout + result.stderr)
    if result.returncode == 0:
        print("Drift opened on the iPhone. It's installed and trusted.")
        return 0
    if "explicitly trusted" in out or "untrusted" in out.lower() or "invalid code signature" in out:
        print("NEXT (You): On the iPhone go to Settings › General › VPN & Device Management, "
              "tap your Apple ID under Developer App, then tap Trust. Then run this again.")
    elif "Locked" in out or "unlocked" in out:
        print("NEXT (You): Unlock the iPhone, then run this again.")
    elif "Developer Mode" in out or "developer mode" in out:
        print("NEXT: Developer Mode is off. Run `mac/cli.py devmode` and turn it on in Settings › Privacy & Security.")
    else:
        print("Couldn't open Drift:\n" + out.strip()[-800:])
    return 1


async def pairing() -> int:
    device = Device()
    made = await device.create_pairing_file(PAIRING_OUT)
    print(f"Pairing file saved to {PAIRING_OUT} (keep it private).")
    try:
        bundle = await device.push_pairing_file(PAIRING_OUT.read_bytes())
        print(f"Copied into Drift ({bundle}).")
    except Exception as exc:
        print(f"Couldn't copy it into Drift: {friendly(exc)}")
        return 1
    return 0 if made else 1


async def push_pairing() -> int:
    if not PAIRING_OUT.exists():
        print("No pairing file yet. Run `mac/cli.py pairing`.")
        return 1
    bundle = await Device().push_pairing_file(PAIRING_OUT.read_bytes())
    print(f"Copied into Drift ({bundle}).")
    return 0


async def spoof(lat: float, lon: float, hold: int) -> int:
    device = Device()
    try:
        await device.set_location(lat, lon, progress=lambda m: print(m))
        print(f"iPhone location set to {lat}, {lon}. Check Apple Maps. Restoring real GPS in {hold} s (Ctrl-C to restore now)…")
        with suppress(asyncio.CancelledError, KeyboardInterrupt):
            await asyncio.sleep(hold)
    finally:
        with suppress(Exception):
            await device.clear_location()
        print("Real location restored.")
    return 0


async def clear() -> int:
    await Device().clear_location()
    print("Real location restored.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Drift setup from the command line.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("status", help="show every setup step and what's next")
    st.add_argument("--json", action="store_true")
    sub.add_parser("devmode", help="make the Developer Mode switch appear on the iPhone")
    sub.add_parser("launch", help="open Drift on the iPhone")
    sub.add_parser("pairing", help="make the pairing file and copy it into Drift")
    sub.add_parser("push-pairing", help="copy the existing pairing file into Drift")
    sub.add_parser("mount", help="mount the developer image now")
    sp = sub.add_parser("spoof", help="set the location over USB, then restore it")
    sp.add_argument("lat", type=float)
    sp.add_argument("lon", type=float)
    sp.add_argument("--hold", type=int, default=60, help="seconds before restoring real GPS")
    sub.add_parser("clear", help="restore the real location")
    args = parser.parse_args()

    async def go() -> int:
        if args.cmd == "status":
            return await status(args.json)
        if args.cmd == "devmode":
            print(await Device().reveal_developer_mode())
            return 0
        if args.cmd == "mount":
            print(await Device().mount_image())
            return 0
        return await {"launch": launch, "pairing": pairing, "push-pairing": push_pairing, "clear": clear}[args.cmd]() \
            if args.cmd != "spoof" else await spoof(args.lat, args.lon, args.hold)

    try:
        return asyncio.run(go())
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"Error: {friendly(exc)}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
