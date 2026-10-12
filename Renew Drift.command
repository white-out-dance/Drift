#!/bin/zsh
# Double-click to install or renew Drift on your iPhone. Free Apple IDs sign apps
# for 7 days, so do this once a week. Plug the iPhone in (or be on the same
# Wi-Fi) and keep it unlocked.
cd "${0:A:h}" || exit 1
./scripts/install-iphone.sh
echo ""
read -k 1 "?Press any key to close…"
