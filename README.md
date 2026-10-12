# Drift

Change your iPhone's GPS location from the iPhone itself. Pick a place and tap **Spoof**, or have it walk, bike or drive a real route. Tap **Stop** and your real location comes back.

It's free and needs no jailbreak. You build it yourself with Xcode and a free Apple ID. Your Apple ID only ever goes into Apple's own Xcode, never into a third-party app.

## What you need

- An iPhone on iOS 17.4 or newer (tested up to iOS 27)
- A Mac with Xcode (free on the Mac App Store)
- An Apple ID (a free one is fine)
- A USB cable for the first setup
- About 30 minutes once, then about a minute a week to renew

## Set it up with Claude Code (easiest)

Plug your iPhone into your Mac with a cable, open **Claude Code**, and paste:

> Set up Drift on my iPhone: clone https://github.com/white-out-dance/Drift into ~/Drift and follow its CLAUDE.md.

Claude does the Mac side (building, signing, installing, the pairing file) and tells you exactly what to tap on your phone. You sign in to Xcode yourself; Claude never sees your Apple ID password. Say yes when Claude asks to run commands.

## Set it up by hand

Follow **[docs/SETUP.md](docs/SETUP.md)**. In short:

1. Install Xcode and sign in to it with your Apple ID (Xcode › Settings › Accounts).
2. Download this project, then in Terminal run `zsh scripts/setup-mac.sh` from its folder.
3. Plug in your iPhone, double-click **Drift for Mac** in the folder and follow its **Setup** tab.

## Using it

1. Turn on **LocalDevVPN** (free on the App Store; setup covers it).
2. Open **Drift**, search for a place or tap the map, then tap **Spoof**.
3. Tap **Stop** to get your real GPS back.

Also in the app:
- **Routes:** walk, bike or drive on real roads, with speed and loop options.
- **Places:** bookmarks and history.
- **Timing:** scheduled spoofs and a killswitch timer.
- **Lock Screen card:** a Lock Screen and Dynamic Island card with a Stop button.

If something goes wrong, Drift shows a card with an error code (like **D03**), what happened and how to fix it. All codes are in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

## Every 7 days: renew

Apps signed with a free Apple ID stop opening after 7 days. Drift reminds you 2 days, 1 day and 3 hours before, and **Setup › Keeping Drift installed** shows the exact date.

To renew:
1. Plug the iPhone into your Mac (or be on the same Wi-Fi) and keep it unlocked.
2. Double-click **Renew Drift** in the Drift folder.

It takes about a minute and keeps your places and settings. Drag **Renew Drift** to your Dock so it's one click away.

## Spoofing from the Mac (optional)

Drift for Mac has its own map. With the cable in, it can spoof straight from the Mac, with no LocalDevVPN needed.

## How it works

iOS has a location simulation service for developers. Drift reaches that service from the iPhone itself:
- **LocalDevVPN** loops a connection back to the phone. It doesn't route your internet traffic.
- **The pairing file** is made once on the Mac and proves to the phone that Drift is allowed in.
- **Developer Mode** has to stay on, because location simulation is a developer feature.

## Project layout

| Path | What it is |
| --- | --- |
| `ios/` | The iPhone app (SwiftUI) and its Lock Screen extension |
| `mac/` | Drift for Mac: setup helper and USB spoofing (Python, runs locally in your browser) |
| `scripts/setup-mac.sh` | One-time Mac setup |
| `mac/cli.py` | Setup from the command line: `status` shows each step and what's next |
| `CLAUDE.md` | Step-by-step playbook Claude Code follows to set Drift up for you |
| `scripts/install-iphone.sh` | Builds, signs and installs Drift. Same as **Renew Drift** |
| `Drift for Mac.app` | Opens Drift for Mac |
| `Renew Drift.command` | Double-click to install or renew |

## Credits and license

- [idevice](https://github.com/jkcoxson/idevice) (MIT): the iPhone-side connection library. `ios/Drift/idevice` holds its prebuilt static library and header.
- [StikDebug](https://github.com/StikDebug/StikDebug) (AGPL-3.0): the connection and keep-alive approach is adapted from it.
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) (GPL-3.0): used by Drift for Mac.

Drift is licensed under the **AGPL-3.0** (see [LICENSE](LICENSE)).

Use it responsibly. Some apps and games ban location spoofing, and changing your location can affect Find My, maps, and location-based reminders until you tap Stop.
