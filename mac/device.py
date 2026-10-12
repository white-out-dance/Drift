"""iPhone access for Drift's Mac side, built on pymobiledevice3.

Everything here runs without root: iOS 17.4+ is reached through pymobiledevice3's
in-process userspace tunnel instead of a kernel utun.
"""

from __future__ import annotations

import asyncio
import logging
import plistlib
import uuid
from contextlib import suppress
from pathlib import Path
from typing import Any, Optional

from pymobiledevice3.exceptions import (
    AlreadyMountedError,
    AppNotInstalledError,
    DeveloperModeIsNotEnabledError,
    RemotePairingCompletedError,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.usbmux import list_devices

log = logging.getLogger("drift.device")

# Written by scripts/install-iphone.sh: the app ID Drift was installed under.
BUNDLE_ID_FILE = Path(__file__).resolve().parent.parent / ".bundle-id"
PAIRING_HOST_NAME = "Drift iPhone"


class DeviceError(Exception):
    """An error with a message that is fine to show the user as-is."""


def friendly(exc: BaseException) -> str:
    if isinstance(exc, DeviceError):
        return str(exc)
    name = type(exc).__name__
    text = str(exc) or name
    hints = {
        "NoDeviceConnectedError": "No iPhone found. Plug it in with a cable and unlock it.",
        "PasswordRequiredError": "Unlock your iPhone, then try again.",
        "PairingDialogResponsePendingError": "Tap Trust on your iPhone, then try again.",
        "UserDeniedPairingError": "The iPhone said Don't Trust. Unplug, plug back in and tap Trust.",
        "DeveloperModeIsNotEnabledError": "Developer Mode is off. Use 'Show Developer Mode toggle', then turn it on in Settings › Privacy & Security.",
        "ConnectionTerminatedError": "The iPhone disconnected. Check the cable and that it's unlocked.",
    }
    return hints.get(name, f"{text} ({name})")


class RemotePairingFileMaker(RemotePairingLockdownService):
    """RemotePairing pair-setup over USB lockdown, saved in the format idevice
    (and so Drift for iPhone, StikDebug, SideStore) reads: public_key /
    private_key / identifier. No Trust prompt, since USB is already trusted."""

    def __init__(self, service, udid: str, identifier: str, record: Optional[dict[str, Any]] = None):
        super().__init__(service, udid)
        self.identifier = identifier
        self._record = record
        self.saved: Optional[dict[str, Any]] = None

    @property
    def pair_record(self) -> Optional[dict[str, Any]]:  # type: ignore[override]
        return self._record

    def save_pair_record(self) -> None:
        self.saved = {
            "public_key": self.ed25519_private_key.public_key().public_bytes_raw(),
            "private_key": self.ed25519_private_key.private_bytes_raw(),
            "identifier": self.identifier,
        }
        if self.peer_alt_irk is not None:
            self.saved["alt_irk"] = self.peer_alt_irk


class Device:
    def __init__(self) -> None:
        self.lock = asyncio.Lock()
        self.udid: Optional[str] = None
        self._tunnel: Optional[UserspaceRsdTunnel] = None
        self._rsd = None
        self._dvt: Optional[DvtProvider] = None
        self._loc: Optional[LocationSimulation] = None

    # ---------- discovery ----------

    async def pick_udid(self) -> str:
        devices = await list_devices()
        usb = [d for d in devices if d.connection_type == "USB"]
        chosen = (usb or devices)
        if not chosen:
            raise DeviceError("No iPhone found. Plug it in with a cable and unlock it.")
        if self.udid and any(d.serial == self.udid for d in chosen):
            return self.udid
        if self.udid and self.udid not in [d.serial for d in chosen]:
            await self.reset()
        self.udid = chosen[0].serial
        return self.udid

    async def status(self) -> dict[str, Any]:
        try:
            devices = await list_devices()
        except Exception as exc:  # usbmuxd hiccup
            return {"connected": False, "error": friendly(exc)}
        if not devices:
            if self._loc is not None:
                await self.reset()
            return {"connected": False}
        udid = await self.pick_udid()
        info: dict[str, Any] = {"connected": True, "udid": udid,
                                "connection": next(d.connection_type for d in devices if d.serial == udid)}
        try:
            lockdown = await create_using_usbmux(serial=udid, autopair=True)
            try:
                values = lockdown.all_values
                info.update({
                    "name": values.get("DeviceName"),
                    "model": lockdown.display_name or values.get("ProductType"),
                    "ios": lockdown.product_version,
                })
                with suppress(Exception):
                    info["developerMode"] = await lockdown.get_developer_mode_status()
                with suppress(Exception):
                    info["driftBundle"] = await self._find_drift(lockdown)
            finally:
                await lockdown.close()
            info["paired"] = True
        except Exception as exc:
            info["paired"] = False
            info["error"] = friendly(exc)
        info["spoofSession"] = self._loc is not None
        return info

    async def _find_drift(self, lockdown) -> Optional[str]:
        apps = await InstallationProxyService(lockdown=lockdown).get_apps(application_type="User")
        with suppress(OSError):
            saved = BUNDLE_ID_FILE.read_text().strip()
            if saved in apps:
                return saved
        for bundle_id, app in apps.items():
            if app.get("CFBundleExecutable") == "Drift" and app.get("CFBundleName") == "Drift":
                return bundle_id
        return None

    # ---------- spoofing (USB / network via userspace tunnel) ----------

    async def _ensure_location(self, progress=None) -> None:
        if self._loc is not None:
            return
        udid = await self.pick_udid()
        if progress:
            progress("Opening tunnel to iPhone…")
        tunnel = UserspaceRsdTunnel(serial=udid)
        rsd = await tunnel.aopen()
        try:
            if progress:
                progress("Checking developer image…")
            try:
                await auto_mount(rsd)
            except AlreadyMountedError:
                pass
            except DeveloperModeIsNotEnabledError:
                raise DeviceError("Developer Mode is off. Use 'Show Developer Mode toggle', then turn it on in Settings › Privacy & Security.")
            dvt = DvtProvider(rsd)
            await dvt.__aenter__()
            loc = LocationSimulation(dvt)
            await loc.__aenter__()
        except BaseException:
            await tunnel.aclose()
            raise
        self._tunnel, self._rsd, self._dvt, self._loc = tunnel, rsd, dvt, loc

    async def set_location(self, lat: float, lon: float, progress=None) -> None:
        async with self.lock:
            for attempt in range(2):
                try:
                    await self._ensure_location(progress)
                    assert self._loc is not None
                    await self._loc.set(lat, lon)
                    return
                except DeviceError:
                    raise
                except Exception as exc:
                    log.warning("set_location attempt %d failed: %r", attempt, exc)
                    await self._reset_locked()
                    if attempt == 1:
                        raise DeviceError(friendly(exc)) from exc

    async def clear_location(self) -> None:
        async with self.lock:
            try:
                if self._loc is None:
                    await self._ensure_location()
                assert self._loc is not None
                await self._loc.clear()
            finally:
                await self._reset_locked()

    async def reset(self) -> None:
        async with self.lock:
            await self._reset_locked()

    async def _reset_locked(self) -> None:
        loc, dvt, tunnel = self._loc, self._dvt, self._tunnel
        self._loc = self._dvt = self._tunnel = self._rsd = None
        for closer in (
            (lambda: loc.__aexit__(None, None, None)) if loc else None,
            (lambda: dvt.__aexit__(None, None, None)) if dvt else None,
            tunnel.aclose if tunnel else None,
        ):
            if closer is None:
                continue
            with suppress(Exception):
                await asyncio.wait_for(closer(), timeout=5)

    @property
    def session_open(self) -> bool:
        return self._loc is not None

    # ---------- one-time setup ----------

    async def reveal_developer_mode(self) -> str:
        udid = await self.pick_udid()
        lockdown = await create_using_usbmux(serial=udid, autopair=True)
        try:
            if await lockdown.get_developer_mode_status():
                return "Developer Mode is already on."
            # Only reveal the switch; flipping it (and the restart) stays on the phone, under your control.
            await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
            return ("Done. On your iPhone open Settings › Privacy & Security › Developer Mode, turn it on, "
                    "tap Restart, then after it boots tap Turn On and enter your passcode.")
        finally:
            await lockdown.close()

    async def mount_image(self) -> str:
        async with self.lock:
            await self._reset_locked()
            udid = await self.pick_udid()
            async with UserspaceRsdTunnel(serial=udid) as rsd:
                try:
                    await auto_mount(rsd)
                    return "Developer image mounted."
                except AlreadyMountedError:
                    return "Developer image was already mounted."
                except DeveloperModeIsNotEnabledError:
                    raise DeviceError("Developer Mode is off. Turn it on first.")

    async def create_pairing_file(self, out_path: Path) -> dict[str, Any]:
        """Make a RemotePairing file for the phone-only app, verify it, save it."""
        async with self.lock:
            await self._reset_locked()
            udid = await self.pick_udid()
            identifier = str(uuid.uuid4()).upper()

            lockdown = await create_using_usbmux(serial=udid, autopair=True)
            try:
                service = await lockdown.start_lockdown_service(RemotePairingLockdownService.SERVICE_NAME)
                maker = RemotePairingFileMaker(service, udid, identifier)
                try:
                    await maker.connect(autopair=True)
                except RemotePairingCompletedError:
                    pass
                finally:
                    with suppress(Exception):
                        await maker.close()
                if not maker.saved:
                    raise DeviceError("The iPhone didn't accept the pairing. Unlock it and try again.")
                record = maker.saved

                # Prove the device now recognises this record.
                service = await lockdown.start_lockdown_service(RemotePairingLockdownService.SERVICE_NAME)
                checker = RemotePairingFileMaker(service, udid, identifier, record=record)
                try:
                    await checker._attempt_pair_verify()
                    verified = await checker._validate_pairing()
                finally:
                    with suppress(Exception):
                        await checker.close()
                if not verified:
                    raise DeviceError("Pairing was created but the iPhone didn't verify it. Try again with the phone unlocked.")
            finally:
                await lockdown.close()

            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_bytes(plistlib.dumps(record, fmt=plistlib.FMT_XML))
            out_path.chmod(0o600)
            return {"path": str(out_path), "identifier": identifier, "udid": udid}

    async def push_pairing_file(self, data: bytes) -> str:
        udid = await self.pick_udid()
        lockdown = await create_using_usbmux(serial=udid, autopair=True)
        try:
            bundle = await self._find_drift(lockdown)
            if not bundle:
                raise DeviceError("Drift isn't installed on the iPhone yet. Install it first, then send the pairing file.")
            try:
                afc = await HouseArrestService.create(lockdown, bundle, documents_only=True)
            except AppNotInstalledError:
                raise DeviceError("Drift isn't installed on the iPhone yet.")
            except Exception:
                afc = await HouseArrestService.create(lockdown, bundle, documents_only=False)
            async with afc:
                with suppress(Exception):
                    await afc.makedirs("/Documents")
                await afc.set_file_contents("/Documents/pairingFile.plist", data)
            return bundle
        finally:
            await lockdown.close()
