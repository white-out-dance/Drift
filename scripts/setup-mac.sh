#!/bin/zsh
# One-time Mac setup for Drift. Checks Xcode and your Apple ID, and installs the
# Python tools Drift for Mac uses into .venv inside this folder. Safe to re-run.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

ok()   { print -P "%F{green}✓%f $1"; }
warn() { print -P "%F{yellow}!%f $1"; }
fail() { print -P "%F{red}✗%f $1"; exit 1; }

# Xcode (free on the Mac App Store) builds and signs Drift.
DEV=$(xcode-select -p 2>/dev/null || true)
if [[ "$DEV" != *.app/* ]]; then
  if [[ -d /Applications/Xcode.app ]]; then
    fail "Your Mac points at the Command Line Tools, not Xcode. Run this, then run setup again:
    sudo xcode-select -s /Applications/Xcode.app"
  fi
  fail "Xcode isn't installed. Get it free from the Mac App Store, open it once, then run setup again."
fi
xcodebuild -version >/dev/null 2>&1 || fail "Xcode hasn't finished setting up. Open Xcode once (accept the license), then run setup again."
ok "$(xcodebuild -version | head -1)"
xcodebuild -showsdks 2>/dev/null | grep -q iphoneos \
  || fail "Xcode's iOS support isn't downloaded. Open Xcode › Settings › Components, get iOS, then run setup again."
ok "iOS support installed"

# Your Apple ID, signed in to Xcode, is what signs the app.
if defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -q 'teamID = '; then
  ok "Apple ID signed in to Xcode"
else
  warn "No Apple ID in Xcode yet. Open Xcode › Settings › Accounts, click +, choose Apple ID and sign in (free is fine)."
fi

# Python 3.9+ (the one that comes with Xcode is fine).
PY=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 /usr/bin/python3; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then PY="$p"; break; fi
done
[[ -n "$PY" ]] || fail "No Python 3.9 or newer found. Install it from python.org, then run setup again."
ok "Python $("$PY" -c 'import platform; print(platform.python_version())')"

if [[ ! -x .venv/bin/python ]] || ! .venv/bin/python -c 'import sys' 2>/dev/null; then
  rm -rf .venv
  "$PY" -m venv .venv
fi
echo "Installing Drift for Mac's tools (a minute or two the first time)…"
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -r mac/requirements.txt
.venv/bin/python -c 'import pymobiledevice3, fastapi, uvicorn' || fail "The Python tools didn't install correctly (see above)."
ok "Drift for Mac tools installed"

# Downloaded as a ZIP? Let Drift for Mac and Renew Drift open with a double-click.
xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true
chmod +x "Drift for Mac.app/Contents/MacOS/drift" "Renew Drift.command" scripts/*.sh
echo ""
echo "Setup done. Next: plug in your iPhone, double-click “Drift for Mac” in this folder,"
echo "and follow its Setup tab (or see docs/SETUP.md)."
