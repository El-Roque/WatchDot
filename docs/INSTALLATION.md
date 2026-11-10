# Installation

## Before starting

You need a Mac with Xcode, a paired iPhone and Apple Watch, and a ChatGPT account with Dot already enabled. WatchDot is installed on the Watch only. The iPhone supplies system connectivity; there is no WatchDot iPhone target to install.

Use a compatible Xcode/watchOS SDK. The checked-in native libraries support Watch devices (`arm64_32`, `arm64`) and Apple Silicon Watch simulators (`arm64`). The project targets watchOS 11 or later; the validated development environment used Xcode 26.6 and watchOS SDK 26.5.

When moving from an earlier personal build, the WatchDot identity and account-storage service are separate. Connect your account again and replace the watch-face shortcut after installation.

## 1. Open the project

Download and extract the entire repository, or clone it with Git. Use a fully downloaded local folder; cloud placeholders must finish downloading before Xcode can read sources and libraries. Open `src/WatchDot.xcodeproj`. Select the **WatchDot** scheme.

The current project has exactly two watchOS targets: **WatchDot** and **WatchDotLauncher**.

## 2. Configure your own signing

In Xcode, add your Apple account under **Xcode → Settings → Apple Accounts**. Enter your Apple credentials directly in Xcode, not in the app or a GitHub issue.

Select the project, then configure **Signing & Capabilities** for each target:

| Target | Team | Example bundle identifier |
| --- | --- | --- |
| WatchDot | Your own development team | `com.yourname.watchdot` |
| WatchDotLauncher | The same team | `com.yourname.watchdot.launcher` |

Keep **Automatically manage signing** enabled. Use identifiers unique to you; the extension identifier must start with the app identifier followed by `.launcher`. The `dev.example.watchdot` default is a template, not an identifier to share between unrelated developers.

For repeatable configuration, copy `src/Config/Signing.local.xcconfig.example` to `src/Config/Signing.local.xcconfig`, then enter your own 10-character development team ID and unique base bundle ID. Both targets inherit these values, and the launcher suffix is automatic. This local file is ignored by Git. If you configure signing directly in Xcode instead, set both targets explicitly. Regenerating the project resets direct Xcode edits; the local configuration file survives regeneration.

A free Personal Team is enough for personal device testing. Apple documents that its provisioning profiles expire after seven days, requiring a rebuild/reinstall. See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account). This repository does not contain a transferable signing certificate, provisioning profile or pre-authorized account.

## 3. Prepare and select the Watch

- Pair the Watch with your iPhone and make sure Xcode can see it.
- Trust the Mac when the devices request it, and enable Developer Mode on the Watch if Xcode requires it. Follow the system's prompts locally.
- For development installation, keep the Watch unlocked and awake, and temporarily enable Wi-Fi on the Watch and iPhone near the Mac. A USB connection to the iPhone may help initial pairing.
- Choose your **actual Watch** as the run destination. A generic watchOS destination only builds the app; it does not install it.
- Build and run the **WatchDot** scheme. Xcode also embeds and signs the face-shortcut extension.

If remote launch times out after installation, open WatchDot manually on the Watch. Do not uninstall it merely to work around a locked or temporarily disconnected device.

## 4. Connect the account

Open WatchDot and choose **Connect account**. The Watch shows a temporary code and the authorization website. In your browser, open `https://auth.openai.com/codex/device`, sign in to the ChatGPT account that has your Dot, and enter the code shown on the Watch.

The code is temporary and the session is stored in this app's Keychain. You do not need an API key or a new paid API account. No microphone or call starts automatically during authorization. Once the account and Dot have been verified, the call action becomes available.

Changing the app's bundle identifier creates a separate installation and Keychain access group. You may need to authorize the account again under that new identity. Updating the same identity preserves the existing app data.

## 5. Try a call

Keep the iPhone nearby with Bluetooth enabled and an Internet connection. Start a call in WatchDot, grant microphone permission when requested, speak and listen, and end it once. During cleanup the app shows a finishing state before returning to the call action.

To check the nearby-iPhone path, turn Wi-Fi off in **Settings** on both devices, disable the Watch's own cellular connection if present, and keep Bluetooth and iPhone cellular data enabled. Do not turn Bluetooth off for this test. Installation and diagnostic transfer may need Wi-Fi to be restored afterward.

Voice access depends on your account's Dot service. A successful build or account login alone does not prove that a call can be established for every account.

## 6. Put WatchDot on the watch face

Open WatchDot once. Return to the face, press and hold it, choose **Edit**, and move to **Complications**. Select a compatible circular or corner position and choose **WatchDot**. Press the crown to save, then tap the icon to open the app.

The shortcut uses the same icon as the app and does not place a call automatically. Faces or positions that require rectangular/inline complications are not supported by this version.

## Troubleshooting

- **Signing/profile errors:** confirm that both targets use your team and matching unique identifiers.
- **Device unavailable or installation timeout:** unlock/wake the Watch, enable Wi-Fi temporarily on both devices, and check Xcode's device connection before retrying. Do not erase devices or account data.
- **Face shortcut missing:** confirm the extension was built and embedded, open the app once, then edit a circular or corner slot.
- **Authentication expired:** use the account-connection action again if automatic renewal cannot recover it. Do not share tokens or passwords.
- **Call fails:** keep the existing diagnostic files before another call. A new call may replace those files. The private server protocol may have changed.

For general device-running instructions, see [Apple's Xcode documentation](https://developer.apple.com/documentation/xcode/building-and-running-an-app).
