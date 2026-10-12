# Drift: setup playbook for Claude Code

You're helping someone install Drift on **their own iPhone**, which is plugged into this Mac. Do everything you can yourself. For anything only they can do (taps on the phone, signing in to Xcode, App Store downloads, `sudo`), give short numbered steps, wait for them to say they're done, then check again. Assume they aren't technical: one step at a time, plain words.

## Rules

- **Never ask for, read or type their Apple ID password or 2FA codes.** They sign in to Xcode themselves. Xcode is the only thing that signs Drift.
- Don't install SideStore, AltStore, iloader, Sideloadly or any other tool that asks for an Apple ID.
- Don't run `sudo`. If a sudo command is needed, give it to them to run in the Terminal app.
- `~/Desktop/Drift-pairing.plist` is private: anyone with it can reach their phone's developer services. Never print it, upload it or commit it.
- Don't commit or push to this repository, and don't edit its files to work around a problem. Tell the user what failed instead.
- Never erase or reset the phone, and never use "Clear Trusted Computers".

## The loop

1. If `.venv/` is missing, run `zsh scripts/setup-mac.sh`. Each ✗ line names what's missing on the Mac. Handle it using the table below and re-run until it prints **Setup done**.
2. Run `.venv/bin/python mac/cli.py status`. It lists every step and ends with `NEXT (who): …`. Add `--json` if you want it machine-readable.
3. Do that step (table below). If it's the user's step, tell them exactly what to do and wait.
4. Repeat from step 2 until status says **All set**, then do **Finish**.

## Steps

| Status id | Who | What to do |
| --- | --- | --- |
| `xcode` | user | If `/Applications/Xcode.app` is missing, run `open "macappstore://apps.apple.com/app/id497799835"`. Ask them to click **Get**, wait for it to finish, open Xcode once and accept the license. If Xcode is installed but the Mac points at the Command Line Tools, they run `sudo xcode-select -s /Applications/Xcode.app` in Terminal. |
| `ios_sdk` | you | Run `xcodebuild -downloadPlatform iOS`. It's several GB, so warn them it takes a while. |
| `apple_id` | user | Run `open -a Xcode`. They go to **Xcode › Settings › Accounts › + › Apple ID** and sign in (a free account is fine). |
| `iphone_connected` | user | Plug the iPhone in with a USB cable and unlock it. |
| `trusted` | user | On the iPhone, tap **Trust** on "Trust This Computer?" and enter the passcode. Running status again re-shows the prompt. |
| `developer_mode` | both | You run `.venv/bin/python mac/cli.py devmode`. They go to **Settings › Privacy & Security › Developer Mode**, turn it **On** and tap **Restart**. After the restart they unlock, tap **Turn On** and enter the passcode. Wait a minute, then check status again. |
| `drift_installed` | you | Run `./scripts/install-iphone.sh` (2–5 minutes the first time; keep the phone unlocked). Then run `.venv/bin/python mac/cli.py launch`. If it says to trust the app, they go to **Settings › General › VPN & Device Management**, tap their Apple ID and tap **Trust**. Repeat `launch` until Drift opens. |
| `localdevvpn_installed` | user | On the iPhone, install **LocalDevVPN** (free) from the App Store: https://apps.apple.com/app/localdevvpn/id6755608044. Open it, allow it to add a VPN configuration (passcode), then tap **Connect**. |
| `pairing_file` | you | Run `.venv/bin/python mac/cli.py pairing` with the phone unlocked. |

## When `install-iphone.sh` fails

- **"Xcode isn't signed in"**: do the `apple_id` step, then retry.
- **"bundle identifier isn't available"**: retry with `BUNDLE_ID=com.<something-unique>.drift ./scripts/install-iphone.sh` (letters, digits and dots only). It's remembered in `.bundle-id`.
- **"maximum number of apps for free development profiles"**: free Apple IDs allow 3 sideloaded apps per phone, and Drift needs 2 (the app plus its Lock Screen extension). Ask which sideloaded app they want to delete. They delete it, then you retry.
- **Developer Mode or "Locked"**: see the steps above.
- **Anything else**: read the end of `ios/build-signed/last-build.log` and check `docs/TROUBLESHOOTING.md`.

## Finish

1. **USB test:** run `.venv/bin/python mac/cli.py spoof 48.8584 2.2945 --hold 60` and ask them to open Apple Maps. They should be at the Eiffel Tower, and their real location returns after 60 seconds.
2. **Phone-only test.** Give them these steps:
   1. Open **LocalDevVPN** and tap **Connect**.
   2. Open **Drift**, allow location, and allow Live Activities when asked.
   3. Search for a place, tap **Spoof**, and check Maps.
   4. Tap **Stop**.

   If Drift shows an error card, its code (D01–D99) is explained in `docs/TROUBLESHOOTING.md`.
3. **Explain renewal:** free Apple IDs sign apps for 7 days. Once a week they plug in and double-click **Renew Drift** in this folder, or ask Claude Code to run `./scripts/install-iphone.sh`. Drift reminds them before it expires. Suggest dragging **Renew Drift** to the Dock.
