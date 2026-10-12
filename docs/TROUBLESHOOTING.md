# Troubleshooting

## Error codes in the iPhone app

When something fails, Drift shows a card with a code, the fix, and usually a one-tap button. The card's small **Details** line has the raw error, which helps if you need to ask for help.

| Code | What it means | Fix |
| --- | --- | --- |
| **D01** | No pairing file | Drift for Mac › Setup › **Make pairing file** (cable in). |
| **D02** | Pairing file is damaged | Make a new one: Drift for Mac › Setup › **Make pairing file**. |
| **D03** | LocalDevVPN is off | Tap **Turn on LocalDevVPN**. Drift finishes the spoof once it's connected. |
| **D04** | Blocked on cellular | Switch Cellular Data off for a few seconds (or join Wi-Fi), then switch it back on once Drift says Connected. |
| **D05** | iPhone isn't answering | In LocalDevVPN tap Disconnect, then Connect. Tap **Try again**. Still failing? Restart the iPhone. |
| **D06** | Pairing was rejected | Usually after an iOS update or reset. Make a new pairing file in Drift for Mac, then try again. |
| **D07** | Connection timed out | Reconnect LocalDevVPN and tap **Try again**. If it keeps happening, restart the iPhone. |
| **D08** | Couldn't connect | Check that LocalDevVPN says Connected, then tap **Try again**. |
| **D09** | Developer services unavailable | Check that Developer Mode is on. In Drift tap the gear › **Mount developer image now**, then try again. |
| **D10** | Developer image failed | Make sure you're online (Wi-Fi is best) and try again. With the cable in, Drift for Mac › Setup › **Mount developer image now** also works. |
| **D11** | Needs internet once | After a restart Drift has to fetch Apple's developer image. Join Wi-Fi (allowed even in Airplane Mode) and try again. |
| **D12** | Developer Mode is off | Go to Settings › Privacy & Security › Developer Mode and turn it on. The phone restarts; then tap Turn On. |
| **D20** | Connection dropped (orange chip while spoofing) | Drift keeps retrying. Tap the chip to see the likely cause and its fix. |
| **D21** | Couldn't restore real location | Turn on LocalDevVPN and tap **Stop** again, or restart the iPhone (that always clears it). |
| **D99** | Something else | Tap **Try again**. If it repeats, screenshot the card with its Details line. |

## Installing and renewing

**"No iPhone found"**
Plug the iPhone in with a cable, unlock it, and tap **Trust** if asked.

**"Xcode isn't signed in to your Apple ID anymore"**
Go to **Xcode › Settings › Accounts**, click **+**, choose **Apple ID** and sign in. Close Xcode, then renew again.

**"The bundle identifier isn't available"**
Someone else's Apple ID already uses that app ID. Pick your own (letters, numbers, dots):

```bash
BUNDLE_ID=com.yourname.drift ./scripts/install-iphone.sh
```

It's remembered for later renewals.

**"The maximum number of apps for free development profiles has been reached"**
Free Apple IDs allow 3 sideloaded apps per phone, and Drift uses 2. Delete another sideloaded app, then install again.

**"Unable to launch … the device was not, or could not be, unlocked"**
Unlock the iPhone and run it again.

**Tapping Drift says "Untrusted Developer"**
Go to **Settings › General › VPN & Device Management**, tap your Apple ID, then tap **Trust**.

**Drift's icon is there but it won't open**
The 7 days ran out. Renew it (double-click **Renew Drift**). Your places and settings are kept.

**Setup says your Mac points at the Command Line Tools**
Run this in Terminal (it asks for your Mac password), then run setup again:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

**Drift for Mac says it isn't set up yet**
Run `zsh scripts/setup-mac.sh` from the Drift folder first.

**macOS won't open Drift for Mac or Renew Drift ("can't be opened")**
Run `zsh scripts/setup-mac.sh` once. It clears the download flag macOS puts on ZIP files. Or go to **System Settings › Privacy & Security** and click **Open Anyway**.

## My real location is stuck

Open Drift and tap **Stop**. If Drift can't reach the phone, turn on LocalDevVPN and tap Stop again. Restarting the iPhone always brings your real location back.
