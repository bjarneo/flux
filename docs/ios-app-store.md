# Flux for iOS on the App Store

[Documentation index](README.md)

This page holds the App Store text, the review notes, and the open items for [Flux for iOS](ios.md).
The app is not on the App Store yet.
[TestFlight](releasing.md#testflight) covers the upload of a build.

## App facts

| Item | Value | Source |
| --- | --- | --- |
| Name on the home screen | Flux | `CFBundleDisplayName` in `ios/project.yml` |
| App bundle ID | `org.omarchy.flux.ios` | `PRODUCT_BUNDLE_IDENTIFIER` of the `Flux` target |
| Share extension bundle ID | `org.omarchy.flux.ios.share` | `PRODUCT_BUNDLE_IDENTIFIER` of the `FluxShare` target |
| App Group | `group.org.omarchy.flux` | `FLUX_APP_GROUP` |
| Version | `0.1.0`, build `1` | `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` of both targets |
| Category | Utilities | `LSApplicationCategoryType` |
| Devices | iPhone with iOS 17 or later | `TARGETED_DEVICE_FAMILY` and `deploymentTarget` |
| Entitlements | `com.apple.security.application-groups` in the app and in the share extension, and no other | `entitlements` of both targets |
| Background modes | `audio` only | `UIBackgroundModes` |
| Privacy manifests | `ios/App/PrivacyInfo.xcprivacy` and `ios/ShareExtension/PrivacyInfo.xcprivacy` | [Privacy manifests](ios.md#privacy-manifests) |

## Store text

### Name and subtitle

- Name: Flux
- Subtitle: Connect to Omarchy computers

### Description

```text
Flux connects your iPhone to your Omarchy computer on the same local network. The computer runs fluxd, the Flux service for Omarchy.

- Send files, photos, text, and links to the computer, also from the share sheet of other apps.
- Receive files from the computer in the Files app.
- Share the clipboard with the computer while Flux is open, or send a copy with a shortcut while Flux stays closed.
- Control the music and video players of the computer.
- Run the commands that you set up on the computer.
- Browse the shared folders of the computer and save files to the Files app.
- Scan text, QR codes, documents, and signatures, and send photos to the computer.
- Use the iPhone as a webcam or as a microphone for the computer.
- Use the iPhone as a touchpad and keyboard, or show the screen of the computer on the iPhone.
- Follow the coding agents on the computer, answer them, and start new ones.
- Approve sudo on the computer with Face ID or Touch ID.
- Dictate into each text field of the app.

Flux pairs only after you compare the same 16-character key on the iPhone and on the computer. Each link uses TLS with the certificate from the pairing. Flux has no account, no server, and no analytics.

What iOS does not allow:

- iOS suspends Flux soon after it leaves the screen. Flux connects again when you open it. Only the microphone stream continues in the background.
- iOS gives apps no access to the notifications of other apps, to text messages, or to calls. Flux does not send them to the computer.
- The clipboard syncs only while Flux is on the screen. A shortcut with Get Clipboard and Send Text to Computer sends 1 copy per run.
- New screenshots and photos go to the computer when you open Flux.
- The webcam stops when Flux leaves the screen.
- Flux does not show the screen of the iPhone on the computer.

Flux needs an Omarchy computer with Flux installed. It does not connect to other computers.
```

### Keywords

```text
omarchy,computer,file transfer,clipboard,webcam,microphone,remote desktop,touchpad,keyboard,scanner
```

The list has 99 characters. App Store Connect accepts up to 100.
Do not add the names of other products, companies, or apps.

### Screenshots

Take the screenshots from the [demo mode](ios.md#demo-mode), which shows only sample names and addresses:

```sh
xcrun simctl launch --terminate-running-process booted org.omarchy.flux.ios -FLUX_DEMO 1
xcrun simctl io booted screenshot computers.png
```

Use a simulator with the display size that App Store Connect asks for, for example an iPhone 17 Pro Max for the 6.9-inch display.

The render tests also save screens, for example the demo computers, the approval sheet, and agent output:

```sh
mkdir -p "$PWD/screens"
TEST_RUNNER_FLUX_SCREENS="$PWD/screens" make test-ios
```

The folder must exist and have an absolute path.
The render tests draw screens of 402 × 874 points, the size of an iPhone 17 Pro.
Check their pixel size against the sizes that App Store Connect accepts before you upload them.

## App Review

### Test without an Omarchy computer

Flux needs a paired Omarchy computer for its features, and App Review has none.
The [demo mode](ios.md#demo-mode) shows 2 sample computers and their feature screens without a network.
It starts with the launch argument `-FLUX_DEMO 1`, which Xcode and the simulator can pass.
App Review installs the build from App Store Connect and cannot add a launch argument.
So give App Review 1 of these, and name it in the review notes:

- A screen recording of the pairing and the main features with a real computer, as an attachment in **App Review Information**.
- A build with a way to set the `FLUX_DEMO` user default without a launch argument, for example a switch in a settings bundle. The app reads the demo flag through `UserDefaults.standard`, so the switch needs no other code change.

### Review notes

Paste this text into **Notes** in **App Review Information**, and complete the first paragraph:

```text
Flux connects the iPhone to the user's own Omarchy computer on the same local network. The computer runs fluxd, the Flux service for Omarchy. Flux has no account, no server of its own, and no analytics. It sends data only to computers that the user paired. The media screen loads album art from the web address that a player on the computer reports. [Name the screen recording or the demo switch here.]

Pairing: the iPhone publishes the Bonjour service _flux._udp and listens on TCP ports 12100 to 12108. The computer connects to it. The user compares a 16-character key in 4 groups of 4 on both devices before the pairing. The key is the first 8 bytes of a SHA-256 hash of both public keys and the pairing time.

Encryption: each device makes a self-signed RSA 2048 certificate with its device ID as the common name, O=Omarchy, and OU=Flux. The links use TLS 1.2 through swift-nio-ssl. After the pairing, each side accepts only the certificate that it pinned, because the devices have no public certificate authority. The file browser uses SSH and SFTP through the Citadel library inside a TLS tunnel with the same certificates. Sudo approval signs with a P-256 key in the Secure Enclave through CryptoKit, and each signature needs Face ID or Touch ID. The links use sockets, not URL loading, and the app sets no App Transport Security exception.

Background mode: the app claims only the audio mode. It keeps the microphone stream to the computer running while the iPhone is locked or Flux is in the background, like a voice recorder. Without a microphone stream, Flux closes its links when its background time ends. The Send Text to Computer action for Shortcuts runs in the background without this mode: it opens the links for at most 20 seconds, sends the text that Shortcuts gives it, and closes the links.

Remote control: the touchpad, keyboard, remote desktop, terminal, and agent screens send input to programs on the user's own computer, like an SSH client. The app asks for Face ID, Touch ID, or the passcode before these screens send input, and an unlock lasts 5 minutes. The app runs no downloaded code.

Permissions: Local Network finds and connects to the computers. Camera scans text, codes, and pages, takes photos, and streams as a webcam. Microphone streams audio to the computer and records dictation. Speech Recognition turns dictation into text. Photos sends new screenshots and photos when the user turns that on. Face ID confirms input to the computer and approves sudo. Notifications show pairing requests, received files, notifications from the computer, approvals, agent alerts, and stream requests.

Stream requests: a paired computer can ask Flux to start the webcam or the microphone. Flux shows a prompt or a notification. It starts the stream only after the user taps Start webcam or Start the mic.
```

### Permission texts

The `info.properties` section of `ios/project.yml` holds these texts.
The `ios` job in `build.yml` checks that the built app has each of them.

| Key | Use |
| --- | --- |
| `NSLocalNetworkUsageDescription` | Discovery and links |
| `NSBonjourServices` | The service `_flux._udp` |
| `NSCameraUsageDescription` | Camera modes and the webcam |
| `NSMicrophoneUsageDescription` | The microphone stream and dictation |
| `NSSpeechRecognitionUsageDescription` | Dictation |
| `NSPhotoLibraryUsageDescription` | New screenshots and photos, the photo picker |
| `NSFaceIDUsageDescription` | The Face ID lock and sudo approval |

### Risks for App Review

- The `audio` background mode must serve only the microphone stream. Flux must not keep links open in the background without it.
- The store text must not promise what iOS does not allow. Keep the limits in the description.
- Self-signed TLS with pinned certificates is the trust model of Flux on each platform. The review notes explain it.
- Each new permission needs a clear text in `info.properties` and a line in the review notes.
- App Review can run the iPhone app on an iPad. Check the app in an iPad simulator before submission.

## Privacy

The app collects no data for the developer. It sends data only to the computers that the user paired.
The media screen also loads album art from the web address that a player on the computer reports.
The planned answer for **App Privacy** in App Store Connect is **Data Not Collected**.
Confirm the answer against the code of the release before each submission.
The [privacy manifests](ios.md#privacy-manifests) declare no tracking and no collected data.

## Open items

| Item | Next step |
| --- | --- |
| Support URL | Choose a page for support questions. App Store Connect requires it. |
| Privacy policy URL | Publish a privacy policy. App Store Connect requires it for each app. |
| App name | Check that the name Flux is free on the App Store. The home screen name stays `CFBundleDisplayName`. |
| App Review access | Add a screen recording or a demo switch. See [Test without an Omarchy computer](#test-without-an-omarchy-computer). |
| Export compliance | Answer the encryption questions for TLS, SSH, RSA, and ECDSA. The `Info.plist` does not set `ITSAppUsesNonExemptEncryption`, so App Store Connect asks for each build. |
| Time-sensitive notifications | Decide if the paid team signs the time-sensitive entitlement for approval notifications. See [Flux for iOS](ios.md#install-on-an-iphone). |
