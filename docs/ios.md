# Flux for iOS

[Documentation index](README.md)

Flux for iOS connects an iPhone to an Omarchy computer that runs `fluxd`.
The iPhone takes the place of the Android phone: it uses Flux protocol version 8 and pairs, shares, and streams the same way.
It shares the Swift package FluxKit with [Flux for macOS](macos.md) and offers the Android features that iOS allows.
The app requires iOS 17 or later.

## Requirements

- A Mac with Xcode 26 or later. The app uses iOS 26 APIs where they exist.
- XcodeGen:

  ```sh
  brew install xcodegen
  ```

- An iPhone simulator, or an iPhone with iOS 17 or later.

## Build and run in the simulator

From the repository root, build the app and run the tests:

```sh
make ios
make test-ios
```

`make ios` generates `ios/Flux.xcodeproj` from `ios/project.yml` and builds the app for the simulator in `ios/build`.
`make ios` and `make test-ios` set the app version to the last release tag, such as `0.7.0`. The app sends it to `fluxd`.
A build from the Xcode window uses `MARKETING_VERSION` in `ios/project.yml` instead.
`make test-ios` runs the app tests and the FluxKit tests in the booted iPhone simulator, else in the first available one.
Set `IOS_SIMULATOR=<id>` to choose another simulator.
The generated project and `ios/build` stay out of Git.

To install and open the app in the booted simulator:

```sh
xcrun simctl install booted ios/build/Build/Products/Debug-iphonesimulator/Flux.app
xcrun simctl launch booted org.omarchy.flux.ios
```

To work in Xcode, run `xcodegen generate` in `ios/` and open `Flux.xcodeproj`.
The simulator needs no signing.

## Install on an iPhone

The project commits no signing settings.
Install the app from Xcode with your own Apple ID:

1. Run `xcodegen generate` in `ios/` and open `Flux.xcodeproj`.
2. Add your Apple ID in **Xcode > Settings > Accounts**. A free Apple ID works.
3. For the **Flux** and **FluxShare** targets, open **Signing & Capabilities** and select your team.
4. Change the bundle ids when Xcode says they are taken, for example to `com.example.flux.ios` and `com.example.flux.ios.share`.
   The share extension id must start with the app id.
5. Set the App Group when Xcode says `group.org.omarchy.flux` is taken.
   Change `FLUX_APP_GROUP` in `ios/project.yml` to a group id of your team, for example `group.com.example.flux`, and run `xcodegen generate` again.
   It is the only place with the group id. The app and the share extension read it from their Info.plist.
6. Connect the iPhone, select it as the run destination, and select **Run**.
7. On the iPhone, turn on **Settings > Privacy & Security > Developer Mode** when iOS asks, and trust the developer in **Settings > General > VPN & Device Management**.

| Apple ID | Result |
| --- | --- |
| Free | The app runs for 7 days. Run it from Xcode again to renew it. A free team has a small limit of app ids. |
| Paid developer program | The app runs for 1 year. |

The approval notification is time sensitive.
Focus lets it through only with the time-sensitive entitlement, which the project does not set, because a free team may not be able to sign it.
Without it, the notification still shows when no Focus is on.

## Pair an iPhone

1. Connect the iPhone and the computer to the same local network.
2. Open Flux on the iPhone and allow access to the local network.
3. Select the computer under **Available**, then send the pair request.
4. Accept the request on the computer when it shows the same 8-character key.

You can also start from the computer with `flux-cli pair` and accept on the iPhone.
The iPhone appears on the computer as `phone`, with the name from **Settings > This iPhone**.
iOS gives apps only the generic name "iPhone", so set a name there.
Flux keeps its identity key and certificate out of iCloud and computer backups, so pair again after you restore a backup.

The computer connects to the iPhone.
The iPhone publishes `_flux._udp` through Bonjour and listens on TCP ports 1716 to 1764.
It also sends its identity to each computer that it finds through Bonjour.
It sends no UDP broadcasts, because iOS needs a special entitlement for them.

| Problem | Check |
| --- | --- |
| The computer does not see the iPhone | Flux is open on the iPhone. **Settings > Privacy & Security > Local Network** allows Flux. |
| The computer sees the iPhone but cannot connect | The network allows connections between devices. Wi-Fi client isolation blocks them. |
| The link drops away from the computer | Add an extra address. See below. |

The default Omarchy firewall allows mDNS, and `fluxd` opens the connections, so the computer needs no new firewall rule.

To reach the iPhone away from the local network, add its Tailscale name as an extra address on the computer, as for a phone in [Tailscale](tailscale.md#add-the-phone):

```sh
flux-cli --device "Snorre's iPhone" addresses add snorres-iphone
```

Flux must still be open on the iPhone. See [limits](#limits-of-ios).

## Features

| Feature | iPhone behavior |
| --- | --- |
| Files, text, and links | Send from the Files picker, the photo picker, the Share field, or the share sheet of any app. Received files go to the Flux folder in the Files app and open with Quick Look. Links open in the browser of the computer, and text goes on its clipboard. |
| Share sheet | **Flux** in the share sheet of other apps queues files, photos, text, and links for a computer. Flux sends them when it opens and connects. See [limits](#limits-of-ios). |
| Clipboard | Text and images both ways while **Sync clipboard** is on and Flux is on the screen. The **Clipboard** quick action sends it at once. |
| Screenshots and photos | **Send new screenshots** and **Send new photos** send new items from the Photos library when Flux opens. |
| Media | Controls the players of the computer. The computer does not control the players on the iPhone. |
| Commands | Lists and runs the commands configured on the computer. |
| Browse | Opens the shared folders of the computer read-only through SSH inside a `flux.tunnel`, and saves files to the Files app. |
| Camera modes | Text, QR, Photo, Document, and Signature, like the Android app, from the camera, a picked photo, or a pasted image. |
| Webcam | Streams the front or back camera to the computer as a virtual webcam in H.264. **Also send the microphone** starts the microphone with it. It stops when Flux leaves the screen. |
| Microphone | Streams the microphone as 48 kHz mono audio. It keeps streaming in the background and while the iPhone is locked. |
| Notifications | Shows notifications from `flux-cli notify`. |
| Battery | Reports the battery of the iPhone. The device screen shows the battery of the computer. |
| Ring | `flux-cli ring` rings the iPhone. |
| Do Not Disturb | Reports the Focus through a Focus filter. The iPhone does not follow the computer. See [Focus](#focus). |
| Fingerprint approval | Approves `sudo` and polkit with Face ID or Touch ID and a key in the Secure Enclave. See [fingerprint approval](approvals.md). |
| Touchpad and keyboard | The touchpad gestures of the Android app, a key panel, a type field with dictation, and the keys of a hardware keyboard. The computer needs `remote_input = true`. See [Touchpad and keyboard](remote-input.md). |
| Remote desktop | Shows the screen of the computer, with touches, keys, the Omarchy panel, dictation, and a monitor picker. The computer needs `remote_desktop = true`, and `remote_input = true` for control. See [Remote desktop](remote-desktop.md). |
| herdr agents | Shows the agents that herdr runs, their output in color fitted to the phone screen, and notifications for needs input and finished. Answers them, starts agents, and runs terminals when the computer allows it. See [herdr agents](herdr.md). |
| Dictation | Each text field has a mic key: the agent replies, the touchpad, the remote desktop, **Text or link** in **Share**, the scanned text, the shortcut search, the folder search and the task of a new agent, and the terminal command. Searches get the words in place of the search. Other fields get them at the end of the text. The iPhone dictates in its own languages. |
| Face ID lock | Replies, new agents, terminals, the touchpad, and the remote desktop ask for Face ID, Touch ID, or the passcode. It stays valid for 5 minutes. |

Flux for iOS does not advertise notifications of other apps, SMS, calls, or the screen mirror.

## Limits of iOS

| Limit | Effect |
| --- | --- |
| iOS suspends Flux soon after it leaves the screen | The link closes, and Flux connects again when it opens. Approvals, agent alerts, notifications, and clipboard changes reach the iPhone only while Flux runs. The microphone stream keeps running in the background. |
| Other apps' notifications, text messages, and calls | iOS gives apps no access to them. Flux does not advertise `notification.request`, `sms.*`, or `telephony`. |
| Clipboard | iOS asks before each read of text that another app copied. Flux reads the clipboard only while it is on the screen, and when a computer connects only after the clipboard changed. |
| Screenshots and photos | They go to the computer when Flux opens, not in the background. |
| Share sheet | The share extension runs apart from the app and cannot open Flux or hold a link. It queues the items in the App Group. Flux sends them when it opens and connects, and keeps failed items with the reason on the **Share** screen. The queue holds up to 200 items and 1 GB, and an item that failed 5 times or waited 7 days goes, with a notification. Folders do not go. |
| Focus | Flux cannot read or set the Focus. It reports the Focus through the Focus filter and ignores Do Not Disturb from the computer. |
| Camera | iOS gives the camera only to the app on the screen, so the webcam stops when Flux leaves it. |
| Volume keys | iOS gives apps no public way to take the volume keys, so they do not change slides. |
| Screen mirror | iOS does not mirror the screen to a computer. See below. |

### Screen mirror

The iPhone does not announce `flux.screen`, and the app has no Screen Mirror tile.
A broadcast upload extension would have to encode the screen and hold a TLS listener in about 50 MB of memory, and that could not be checked in the simulator.
The broadcast also runs apart from the app.
When the user leaves Flux to show another app, iOS suspends Flux and its link closes, and `fluxd` ends a mirror when the link that started it drops.
Keeping the mirror alive needs a change to `fluxd` and the identity key in a second process.
See [Phase 9 of the plan](ios-plan.md#phase-9-screen-mirror) for the details.

## Focus

To silence the computers with a Focus:

1. In **Settings > Focus**, open a Focus, then **Add Filter**, then **Flux**.
2. Turn on **Silence computers with Focus** in Flux.

A Focus without the Flux filter is not reported.

## Permissions

iOS asks for each permission on first use:

| Permission | Used by |
| --- | --- |
| Local Network | Discovery and links |
| Notifications | Pairing requests, received files, notifications, approval, herdr agents, sent share sheet items |
| Camera | Camera modes and the webcam |
| Microphone | The microphone stream and dictation |
| Speech Recognition | Dictation in the text fields |
| Photos | Send new screenshots and photos, the photo picker |
| Face ID | The Face ID lock and fingerprint approval |
| Paste from other apps | Clipboard sync. iOS asks at each read unless you choose **Allow** in **Settings > Apps > Flux > Paste from Other Apps**. |

## Privacy manifests

The app has `ios/App/PrivacyInfo.xcprivacy`, and the share extension has `ios/ShareExtension/PrivacyInfo.xcprivacy`.
Both declare no tracking, no tracking domains, and no collected data.
They declare these required-reason APIs:

| Target | API category | Reason | Use |
| --- | --- | --- | --- |
| Flux | User defaults | `CA92.1` | The settings of the app and of FluxKit, which only the app reads |
| Flux | File timestamp | `C617.1` | The creation date of the share queue folders in the App Group, and the attributes of the files that Flux sends and receives in its container |
| Flux | System boot time | `35F9.1` | The time between events in the app: touches, the Face ID unlock, media positions, dictation, and agent tasks |
| FluxShare | User defaults | `1C8F.1` | The last computer of the share extension, in the App Group |

When code starts to use another required-reason API, add its category and reason to the manifest of each target that runs the code.
FluxKit runs only in the app. The code in `ios/Shared` runs in the app and in the share extension.
`options.fileTypes` in `ios/project.yml` puts each manifest into the bundle of its target.

## Demo mode

The demo shows sample computers without a network, for App Review and screenshots.
The app shows `omarchy`, a connected laptop, and `workstation`, a desktop that is not reachable.
It starts no discovery, listener, or link, and the actions on the sample computers reach no computer.
The paired computers and the share queue stay as they are, and **Flux is on** in **Settings** does not change.

To start the demo in the booted simulator:

```sh
xcrun simctl launch --terminate-running-process booted org.omarchy.flux.ios -FLUX_DEMO 1
```

In Xcode, add `-FLUX_DEMO 1` in **Product > Scheme > Edit Scheme > Run > Arguments Passed On Launch**.
The app reads the argument as the `FLUX_DEMO` user default.
Start the app without the argument to leave the demo.
`ios/App/DemoMode.swift` holds the sample computers.
[Flux for iOS on the App Store](ios-app-store.md#test-without-an-omarchy-computer) explains what App Review can use.

## Local tests

```sh
make test-ios
```

The FluxKit tests run on the iPhone simulator and on macOS with `make test-macos`.
The app tests cover the app logic: pairing, share queue, camera, keys, approval, dictation fields, the layout of agent output, and the demo.
Some tests render screens.
With `TEST_RUNNER_FLUX_SCREENS=<folder>`, they save them as PNG files in that folder.
The demo tests save `demo-01-computers.png` and `demo-02-computer.png`.

The simulator has no camera, no battery, no Secure Enclave key that needs Face ID, and no broadcast.
Check camera capture, the webcam, the microphone, and approval on an iPhone.

To read the logs of the app in the simulator:

```sh
xcrun simctl spawn booted log stream --predicate 'subsystem == "org.omarchy.flux"'
```

## Layout

| Path | Content |
| --- | --- |
| `ios/App` | The SwiftUI app; `App/Features/Features.swift` lists the plugins and their tiles |
| `ios/Shared` | The share queue and the App Group, for the app and the share extension |
| `ios/ShareExtension` | The share extension |
| `ios/Tests` | App tests |
| `ios/project.yml` | XcodeGen project with the Info.plist keys and `FLUX_APP_GROUP` |
| `macos/Sources/FluxKit` | The shared protocol peer and plugins, with `#if os(iOS)` where iOS differs |
| `macos/Tests/FluxKitTests` | Protocol and feature tests for both apps |

To add a feature, write a `FluxPlugin` in `macos/Sources/FluxKit/Plugins/<Feature>/`, add its views in `ios/App/Features/<Feature>/`, and add one line to each list in `Features.swift`.
