#!/bin/zsh
# Builds Drift for iPhone, signs it with the free Apple ID signed in to Xcode,
# and installs it on the connected iPhone. Re-run every 7 days (free Apple IDs
# only sign for a week); it keeps your places and settings.
#
#   ./scripts/install-iphone.sh            # first connected iPhone
#   ./scripts/install-iphone.sh <UDID>     # a specific one
#   BUILD_ONLY=1 ./scripts/install-iphone.sh   # build and sign, don't install
#   BUNDLE_ID=com.you.drift ./scripts/install-iphone.sh   # pick the app ID yourself
set -euo pipefail

ROOT="${0:A:h:h}"
IOS="$ROOT/ios"
# Each Apple ID needs its own app ID (Apple won't sign one another account
# registered). The first run picks one from your team ID and saves it here, so
# renewals update the same app instead of installing a second copy.
BUNDLE_FILE="$ROOT/.bundle-id"

UDID="${1:-}"
if [[ -z "$UDID" && -x "$ROOT/.venv/bin/python3" ]]; then
  UDID=$("$ROOT/.venv/bin/python3" - <<'EOF'
import asyncio
from pymobiledevice3.usbmux import list_devices
devs = asyncio.run(list_devices())
usb = [d for d in devs if d.connection_type == "USB"] or devs
print(usb[0].serial if usb else "")
EOF
)
fi
if [[ -z "$UDID" ]]; then
  # Not on USB: try a phone Xcode already knows over Wi-Fi (same network).
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  UDID=$(/usr/bin/python3 - "$JSON" <<'EOF2'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    c, h = d.get("connectionProperties", {}), d.get("hardwareProperties", {})
    if h.get("platform") == "iOS" and c.get("pairingState") == "paired" and c.get("transportType") in ("wired", "localNetwork"):
        print(h.get("udid", ""))
        break
EOF2
)
  rm -f "$JSON"
fi
if [[ -z "$UDID" ]]; then
  echo "ERROR: No iPhone found. Plug it in with a cable, unlock it and tap Trust."
  exit 1
fi
echo "iPhone: $UDID"

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -m1 -E 'teamID = ' | sed -E 's/.*teamID = "?([A-Z0-9]+)"?;.*/\1/' || true)
fi
if [[ -z "$TEAM" ]]; then
  echo "ERROR: No Apple ID team found in Xcode."
  echo "Open Xcode › Settings › Accounts, click +, sign in with your Apple ID (free is fine), then run this again."
  exit 1
fi
echo "Signing team: $TEAM"

if [[ -z "${BUNDLE_ID:-}" ]]; then
  if [[ -s "$BUNDLE_FILE" ]]; then
    BUNDLE_ID=$(<"$BUNDLE_FILE")
  else
    BUNDLE_ID="com.${TEAM:l}.drift"
  fi
fi
echo "App ID: $BUNDLE_ID"

cd "$IOS"
# The Xcode project is checked in; XcodeGen (optional) keeps it in sync with project.yml.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
elif ! [[ -d Drift.xcodeproj ]]; then
  echo "ERROR: ios/Drift.xcodeproj is missing. Install XcodeGen (brew install xcodegen) or re-download the project."
  exit 1
fi

# Free Apple ID signatures last 7 days and Xcode reuses the cached one until it
# expires, so renewing early wouldn't move the date. Drop Drift's cached profile
# so every renewal gets a fresh 7 days.
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [[ -d "$dir" ]] || continue
  for f in "$dir"/*.mobileprovision(N); do
    appid=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    [[ "$appid" == *".$BUNDLE_ID" || "$appid" == *".$BUNDLE_ID".* ]] && rm -f "$f"
  done
done

# A changed profile must be sealed into a freshly signed app, not an incremental one.
rm -rf "$IOS/build-signed/Build/Products/Release-iphoneos/Drift.app"
mkdir -p "$IOS/build-signed"

echo "Building Drift (this takes a minute the first time)…"
xcodebuild -project Drift.xcodeproj -scheme Drift -configuration Release \
  -destination "id=$UDID" -derivedDataPath build-signed \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" DRIFT_BUNDLE_ID="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  build 2>&1 | tee "$IOS/build-signed/last-build.log" | grep -E "error:|warning: .*[Pp]rovision|BUILD (SUCCEEDED|FAILED)|Signing" || true

if grep -q "No Accounts" "$IOS/build-signed/last-build.log" 2>/dev/null; then
  echo ""
  echo "ERROR: Xcode isn't signed in to your Apple ID anymore (Apple signs you out every so often)."
  echo "Fix: open Xcode › Settings › Accounts, click + › Apple ID, sign in, close Xcode, then run Renew Drift again."
  exit 1
fi

APP="$IOS/build-signed/Build/Products/Release-iphoneos/Drift.app"
if [[ ! -d "$APP" ]] || ! codesign -v "$APP" 2>/dev/null; then
  echo "ERROR: Build or signing failed (see above)."
  echo "If it says the bundle identifier isn't available, pick another one, e.g.:"
  echo "  BUNDLE_ID=com.yourname.drift ./scripts/install-iphone.sh"
  exit 1
fi
echo "$BUNDLE_ID" > "$BUNDLE_FILE"

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  echo "Built and signed: $APP"
  exit 0
fi

echo "Installing on iPhone…"
xcrun devicectl device install app --device "$UDID" "$APP"
EXPIRY=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)
echo ""
echo "DONE. Drift is renewed${EXPIRY:+ until $EXPIRY (UTC)}."
echo "First install only: on the iPhone go to Settings › General › VPN & Device Management › your Apple ID › Trust,"
echo "and turn on Settings › Privacy & Security › Developer Mode if it isn't on yet."
