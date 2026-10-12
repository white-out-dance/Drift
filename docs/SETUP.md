# Setting up Drift

This takes about 30 minutes, once. After that, Drift runs on your iPhone without the Mac, and you only come back to the Mac once a week for a one-minute renewal.

**You need:** a Mac, your iPhone with its cable, and an Apple ID (a free one is fine).

**Have Claude Code?** Let it do this for you. See the [README](../README.md#set-it-up-with-claude-code-easiest). The steps below are the manual version.

**Prefer the command line?** After step 4, `.venv/bin/python mac/cli.py status` shows which steps are done and what's next. Run it with `--help` to see the setup commands.

---

## 1. Install Xcode (on the Mac)

1. Open the **Mac App Store**, search for **Xcode**, and click **Get**. It's a large download.
2. Open Xcode once. Accept the license, and if it asks which platforms you want, make sure **iOS** is ticked.
   - If you skipped that: **Xcode › Settings › Components**, then click **Get** next to iOS.

## 2. Sign in to Xcode with your Apple ID

1. **Xcode › Settings › Accounts**.
2. Click **+**, choose **Apple ID**, and sign in.
3. You'll see a **Personal Team** under your name. That's what signs Drift.

Your Apple ID only goes into Xcode, which is Apple's own app. Every few months Apple signs you out. If renewing ever says Xcode isn't signed in, repeat this step.

## 3. Download Drift

**Option A, Terminal (recommended):**

```bash
cd ~/Desktop
git clone https://github.com/white-out-dance/Drift.git
```

If macOS offers to install developer tools, click **Install**, then run the command again.

**Option B, ZIP:** on the GitHub page click **Code › Download ZIP**, then double-click the ZIP to unzip it. You can rename the folder to `Drift` and move it wherever you like.

## 4. Run the setup script

1. Open **Terminal**.
2. Type `cd ` (with a space after it), drag the Drift folder into the Terminal window, and press **Return**.
3. Run:

```bash
zsh scripts/setup-mac.sh
```

The script checks Xcode and your Apple ID, then installs the tools Drift for Mac needs. If it reports a problem, fix that and run it again until it says **Setup done**.

## 5. Connect the iPhone

1. Plug the iPhone into the Mac and unlock it.
2. If it asks **Trust This Computer?**, tap **Trust** and enter your passcode.

## 6. Follow the Setup tab in Drift for Mac

Double-click **Drift for Mac** in the Drift folder. It opens in your web browser. Click the **Setup** tab and work down the list:

1. **Plug in your iPhone.** The tab shows it once it's connected.
2. **Turn on Developer Mode.**
   1. Click **Show Developer Mode switch**.
   2. On the iPhone, go to **Settings › Privacy & Security › Developer Mode**, turn it on, and tap **Restart**.
   3. After the restart, tap **Turn On** and enter your passcode.
3. **Install Drift.** Click **Install Drift**. The first build takes a few minutes. (Double-clicking **Renew Drift** in the folder does exactly the same thing.)
4. **Trust it on the iPhone.** Go to **Settings › General › VPN & Device Management**, tap your Apple ID, then tap **Trust**.
5. **Get LocalDevVPN.** Install it free from the App Store.
   1. Open it and allow it to add a VPN configuration.
   2. Tap **Connect**.

   It only loops a connection back to your phone; your internet traffic doesn't go through it.
6. **Pairing file.** Keep the iPhone unlocked and the cable in, then click **Make pairing file**. It's copied into Drift automatically.
   - A copy named `Drift-pairing.plist` is saved to your Desktop as a backup. **Keep it private.** Anyone with it can reach your phone's developer services.
7. **Unplug and go.**

## 7. Your first spoof

1. Turn on **LocalDevVPN**.
2. Open **Drift** and allow location access. When you first spoof, also allow Live Activities so you get the Lock Screen card.
3. Search for a place or tap the map, then tap **Spoof**.
4. Open Apple Maps to check that you're there.
5. Back in Drift, tap **Stop** to return to your real location.

If Drift shows an error card, the code (like **D03**) and its fix are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Every week: renew

Free Apple IDs sign apps for 7 days. When that runs out, the Drift icon stays on the phone but won't open. Drift reminds you before that happens.

To renew:
1. Plug in the iPhone (or be on the same Wi-Fi) and unlock it.
2. Double-click **Renew Drift** in the Drift folder.

It takes about a minute and keeps everything. If you miss the date, renew the same way; nothing is lost.

## Good to know

- **Free Apple IDs allow 3 sideloaded apps per phone.** Drift uses 2 of them (the app plus its Lock Screen card).
- **Each Apple ID needs its own app ID.** The first install picks one from your team and saves it in a hidden `.bundle-id` file in the folder, so renewals update the same app. Don't delete that file.
- **On cellular only (no Wi-Fi), iOS won't let Drift start its connection.** Drift shows a card: switch Cellular Data off for a few seconds (or join Wi-Fi), and once Drift connects you can switch data back on.
- **After restarting the iPhone, Drift needs internet once.** It re-sets up Apple's developer image by itself.
- **Real location stuck?** Open Drift and tap **Stop**. Restarting the iPhone always clears it too.
- **New iOS version or reset phone?** If Drift says the pairing was rejected (D06), make a new pairing file (step 6.6).
