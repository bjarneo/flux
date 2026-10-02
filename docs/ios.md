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

## Install a release with a sideload tool

Each release attaches `flux-ios-VERSION.ipa`. The app in it has no signature.
A sideload tool such as AltStore, SideStore, or Sideloadly signs it with your Apple ID and installs it.
The limits of a free Apple ID in the table above also apply.
The window on the computer shows an update notice only for the Android app.
To find a newer iPhone app, check `https://github.com/bjarneo/flux/releases`.

The share extension needs the App Group `group.org.omarchy.flux`.
When the sideload tool cannot give the app this group, the share extension cannot queue files for the app.
To use the share extension with your own team, build the app from Xcode as described above.

## Pair an iPhone

1. Connect the iPhone and the computer to the same local network.
2. Open Flux on the iPhone and allow access to the local network.
3. Open **Computers** and select the computer under **Available**. Before the first pairing, the **Inbox** also lists the computers on the network. Then send the pair request.
4. Accept the request on the computer when it shows the same 16-character key, such as `5EE6 825F 974E D59A`.

Compare all 16 characters.
Earlier versions of Flux show only 8 characters, so update Flux on all devices before you pair.

You can also start from the computer with `flux-cli pair` and accept on the iPhone.
While Flux is on the screen, a sheet shows the request.
A swipe down on the sheet rejects it.
While Flux is in the background, a notification shows the request and the key.
**Accept** in the notification needs an unlocked iPhone and opens Flux.
**Reject** also works on the lock screen.
Flux shows 1 request at a time.
When a request ends without a pairing, for example after a reject or a timeout, Flux ends new requests from the same computer or address for 30 seconds.
To pair in that time, start the pairing on the iPhone.
After the iPhone accepts, the computer asks you to confirm the key.
Select **Confirm** in the Flux window or in the notification, or type `y` at the `flux-cli pair` prompt.
The computer pins the iPhone only after this step, and each step waits at most 30 seconds.
A pairing is bound to its link.
When the computer connects again while a pairing runs, the pairing stops, so pair again.
A request from the computer that stops this way also starts the wait of 30 seconds.
Flux asks for permission to show notifications when you pair the first computer.
The iPhone appears on the computer as `phone`, with the name from **Computers > Settings > This iPhone**.
iOS gives apps only the generic name "iPhone", so set a name there.
Flux keeps its identity key and certificate out of iCloud and computer backups, so pair again after you restore a backup.

The computer connects to the iPhone.
The iPhone publishes `_flux._udp` through Bonjour and listens on TCP ports 1716 to 1764.
It also sends its identity to each computer that it finds through Bonjour.
It sends no UDP broadcasts, because iOS needs a special entitlement for them.

| Problem | Check |
| --- | --- |
| The computer does not see the iPhone | Flux is open on the iPhone. **Settings > Privacy & Security > Local Network** allows Flux. While it does not, **Computers** shows **Local Network is off**. After you allow it, return to Flux, and Flux searches again. |
| The computer sees the iPhone but cannot connect | The network allows connections between devices. Wi-Fi client isolation blocks them. |
| The link drops away from the computer | Add an extra address. See below. |

The default Omarchy firewall allows mDNS, and `fluxd` opens the connections, so the computer needs no new firewall rule.

To reach the iPhone away from the local network, add its Tailscale name as an extra address on the computer, as for a phone in [Tailscale](tailscale.md#add-the-phone):

```sh
flux-cli --device "Snorre's iPhone" addresses add snorres-iphone
```

Flux must still be open on the iPhone. See [limits](#limits-of-ios).

## Inbox and navigation

Flux has 4 tabs: **Inbox**, **Send**, **Control**, and **Computers**.
Each tab has its own navigation stack, so the system back button and the edge swipe work.
A tap on the open tab goes back to its root.
The **Inbox** tab has a badge with the number of items that need you on all computers, from 1 to 9, then `9+`.

The scope chip sits in the navigation bar of each tab root.
It shows **All computers** or 1 computer, with a link dot and a battery dot for each computer.
A tap opens the menu of scopes.
The scope filters the **Inbox**, **Send**, and **Control**, and it picks the theme of the computer.
A tap on a paired computer in **Computers** also sets the scope, and a second tap shows all computers again.
A new pairing sets the scope to the new computer and opens the **Inbox**.
A new start of Flux begins with all computers.

The **Inbox** shows what happens on the computers in scope, in this order:

1. Agents that wait for input, approvals, and pair requests. These items need you.
2. What plays now, the last clip, and the transfers.
3. Agents that are done, then agents that work.

The first item takes the master tile with its whole action, framed in the active border of the Omarchy theme.
The other items wait in the stack under it, 2 tiles in each row.
A tile of an item that needs you has a red border.
A tap on a stack tile moves it to the master tile.
To move the master item to the end of the stack, swipe the master tile to the side, or tap **Later**.
VoiceOver users can select the action **Show the next item** on the master tile.
A new item that needs you takes the master tile back.
A finished transfer, the last clip, and a paused player stay for 30 minutes.

An agent that waits shows its question and the numbered choices in the master tile.
The tile reads the output of the agent when it shows, and only an output that comes after that read shows choices.
The question keeps the lines nearest the choices, because they hold the command that a choice approves, and the tile never cuts them.
Each answer asks for Face ID, Touch ID, or the passcode first.
After an answer, the choices stay off until the agent shows a new output.
**Reply** and **Open** open the full output of the agent.
**Review** on an approval opens the approval sheet, and **Compare the key** on a pair request opens the pairing sheet. Neither approves or pairs by itself.

In a window of 600 points or wider, such as an iPhone in landscape, the **Inbox** splits.
The master tile takes 60% of the width at full height, and its choices sit directly under the question.
The status line and the stack fill a column on the right.

**Send** holds the tools that send to the computer in scope: **Send clipboard**, **Send files**, **Send photos**, **Text and links**, **Get files**, and the camera modes.
**Control** holds the tools that act on the computer in scope: the Omarchy panel, the touchpad, the remote desktop, the commands, the media, the microphone, the webcam, and the herdr agents.
With all computers in scope and more than 1 computer online, a tool asks which computer to use.
**Computers** holds this iPhone, the paired computers, the computers to pair, **Settings**, the theme, and **Turn off Flux**.
The chevron of a paired computer opens its page with the address, the approval setup, and **Unpair**.

## Theme

Flux follows the active Omarchy theme of the computer.
`fluxd` sends the theme in a `flux.theme` packet when the iPhone connects and when the theme changes.
Flux saves the theme of each computer, so the next start draws it at once.

To change the theme, open **Computers** and select a choice under **Theme**. The choices are:

- **Computer**, the default: the theme of the computer in scope. In the scope of all computers, Flux uses the theme that changed most recently. A reconnect does not change the theme. Without a theme from the computer in scope, Flux uses Tokyo Night on a dark iPhone and Tokyo Night Day on a light iPhone. The choice shows the theme name and the computer that sent it.
- **System**: Tokyo Night on a dark iPhone and Tokyo Night Day on a light iPhone.
- **Light**: Tokyo Night Day.
- **Dark**: Tokyo Night.

The setting keeps the key of the earlier **Appearance** setting. **Automatic** becomes **Computer**, and **Light** and **Dark** stay.
The light or dark mode of the theme also applies to the sheets, the alerts, and the keyboard.
A contrast guard maps the theme to the colors of the app, as in [Flux for Android](android.md#theme).
The master tile takes the gradient of `hyprland_active_border`.
The feature screens take the background, the accent, and the light or dark mode of the theme.
The agent output keeps its terminal colors.
The theme engine is in `macos/Sources/FluxKit/Theme`, and the colors of the app are in `ios/App/Theme`.

## Features

| Feature | iPhone behavior |
| --- | --- |
| Files, text, and links | Send from the Files picker, the photo picker, the Share field, or the share sheet of any app. An `http` or `https` link with a host opens in the browser of the computer. Text and each other link go on its clipboard. Text has a limit of 1 MB. Received files go to the Flux folder in the Files app. A received file or link shows in a notification, and it opens only after a tap on the notification or on the transfer. |
| Share sheet | **Flux** in the share sheet of other apps queues files, photos, text, and links for a computer. A text file, such as a `.txt` or `.md` file, goes as a file with its name. **Cancel** stops the share. Flux sends the items when it opens and connects. See [limits](#limits-of-ios). |
| Clipboard | Text and images both ways while **Sync clipboard** is on and Flux is on the screen. When Flux opens, a new copy from another app goes out once. **Send clipboard** in **Send** and in the **Inbox** sends it at once. To send without opening Flux, see [Send the clipboard without opening Flux](#send-the-clipboard-without-opening-flux). |
| Screenshots and photos | **Send new screenshots** and **Send new photos** send new items from the Photos library when Flux opens. An item goes only when its original is on this iPhone and it was taken at most 1 day before its switch turned on. Photos that only iCloud has, for example from your other devices or from a Shared Library, stay home. PhotoKit does not tell which device took a photo, so with **Download and Keep Originals** in iCloud Photos, new photos from those sources can go too. 1 scan sends at most 50 items. The rest go with the next scan, for example when Flux opens again. |
| Media | Controls the players of the computer. The computer does not control the players on the iPhone. |
| Commands | Lists and runs the commands configured on the computer. |
| Browse | Opens the shared folders of the computer read-only through SSH inside a `flux.tunnel`, and saves files to the Files app. |
| Camera modes | Text, QR, Photo, Document, and Signature, like the Android app, from the camera, a picked photo, or a pasted image. A document has at most 30 pages. |
| Webcam | Streams the front or back camera to the computer as a virtual webcam in H.264. **Also send the microphone** starts the microphone with it. It stops when Flux leaves the screen. The screen of the iPhone stays on while the webcam or the remote desktop streams and while the touchpad shows. |
| Microphone | Streams the microphone as 48 kHz mono audio. It keeps streaming in the background and while the iPhone is locked. |
| Notifications | Shows notifications from `flux-cli notify`. Each computer can show 10 notifications at once, then 1 more each second. Only the first notification of a burst makes a sound. Each computer keeps at most 20 notifications in Notification Center, and a new one removes the oldest. Received links count toward these limits. |
| Battery | Reports the battery of the iPhone. The scope chip, **Computers**, and the page of the computer show the battery of the computer. |
| Ring | `flux-cli ring` rings the iPhone. |
| Do Not Disturb | Reports the Focus through a Focus filter. The iPhone does not follow the computer. See [Focus](#focus). |
| Fingerprint approval | Approves `sudo` and polkit with Face ID or Touch ID and a key in the Secure Enclave. Set it up on the page of the computer in **Computers**. See [fingerprint approval](approvals.md). |
| Touchpad and keyboard | The touchpad gestures of the Android app, a key panel, a type field with dictation, and the keys of a hardware keyboard. The computer needs `remote_input = true`. See [Touchpad and keyboard](remote-input.md). |
| Remote desktop | Shows the screen of the computer, with touches, keys, the Omarchy panel, dictation, and a monitor picker. The computer needs `remote_desktop = true`, and `remote_input = true` for control. See [Remote desktop](remote-desktop.md). |
| herdr agents | Shows the agents that herdr runs, their output in color fitted to the phone screen, and notifications for needs input and finished. Answers them, starts agents, and runs terminals when the computer allows it. See [herdr agents](herdr.md). |
| Dictation | Each text field has a mic key: the agent replies, the touchpad, the remote desktop, **Text or link** in **Send > Text and links**, the scanned text, the shortcut search, the folder search and the task of a new agent, and the terminal command. Searches get the words in place of the search. Other fields get them at the end of the text. The iPhone dictates in its own languages. |
| Face ID lock | Replies, new agents, terminals, the touchpad, the remote desktop, and the Omarchy panel ask for Face ID, Touch ID, or the passcode. The unlock stays valid for 5 minutes, and it ends when the iPhone locks. An open touchpad, remote desktop, or Omarchy panel asks again when Flux returns after the unlock ended. |

Flux for iOS does not advertise notifications of other apps, SMS, calls, or the screen mirror.

## Limits of iOS

| Limit | Effect |
| --- | --- |
| iOS suspends Flux soon after it leaves the screen | The link closes, and Flux connects again when it opens. Approvals, agent alerts, notifications, and clipboard changes reach the iPhone only while Flux runs. The microphone stream keeps running in the background. |
| Other apps' notifications, text messages, and calls | iOS gives apps no access to them. Flux does not advertise `notification.request`, `sms.*`, or `telephony`. |
| Clipboard | iOS gives apps no event for a new copy, and it asks before each read of text that another app copied. Flux reads the clipboard only while it is on the screen. When Flux opens and when a computer connects, it reads only after the clipboard changed. A shortcut with **Send Text to Computer** sends a copy while Flux stays closed. Text and images from a computer stay on the iPhone and do not go to Universal Clipboard. |
| Screenshots and photos | They go to the computer when Flux opens, not in the background. |
| Share sheet | The share extension runs apart from the app and cannot open Flux or hold a link. It queues the items in the App Group. Flux sends them when it opens and connects, and keeps failed items with the reason on the **Share** screen, under **Send > Text and links**. The queue holds up to 200 items and 1 GB, and an item that failed 5 times or waited 7 days goes, with a notification. The extension checks the size of each file before the copy, and the size of each text before it decodes the text. Send a file larger than 1 GB from the **Share** screen of Flux. A text or link has a limit of 1 MB. Folders do not go. |
| Focus | Flux cannot read or set the Focus. It reports the Focus through the Focus filter and ignores Do Not Disturb from the computer. A change while Flux has no link goes to each computer that was paired at the change, when that computer connects. |
| Camera | iOS gives the camera only to the app on the screen, so the webcam stops when Flux leaves it. |
| Volume keys | iOS gives apps no public way to take the volume keys, so they do not change slides. |
| Screen mirror | iOS does not mirror the screen to a computer. See below. |

### Screen mirror

The iPhone does not announce `flux.screen`, and **Control** has no screen mirror tool.
A broadcast upload extension would have to encode the screen and hold a TLS listener in about 50 MB of memory, and that could not be checked in the simulator.
The broadcast also runs apart from the app.
When the user leaves Flux to show another app, iOS suspends Flux and its link closes, and `fluxd` ends a mirror when the link that started it drops.
Keeping the mirror alive needs a change to `fluxd` and the identity key in a second process.
See [Phase 9 of the plan](ios-plan.md#phase-9-screen-mirror) for the details.

## Send the clipboard without opening Flux

iOS lets only the app on the screen read the clipboard.
The **Send Text to Computer** action sends text while Flux stays closed.
The Shortcuts app reads the clipboard and gives the text to the action.
After the setup, each copy needs 1 gesture, for example a double tap on the back of the iPhone.

To make the shortcut:

1. Open **Shortcuts** and make a new shortcut.
2. Add the **Get Clipboard** action.
3. Add **Flux > Send Text to Computer**. It takes the clipboard as its text.
4. Choose 1 way to run the shortcut:
   - **Settings > Accessibility > Touch > Back Tap**, then **Double Tap**, then the shortcut.
   - **Settings > Action Button**, then **Shortcut**, then the shortcut. This needs an iPhone with the Action button.
   - Control Center, then **+**, then **Add a Control**, then **Shortcut**, then the shortcut. This needs iOS 18 or later.
5. Run the shortcut once. Answer each question from Shortcuts with **Always Allow**.

**Send without opening Flux** in the settings of Flux opens the Flux page in Shortcuts and shows these places.

The action runs in the background and needs an unlocked iPhone.
With no paired computer, it stops at once and shows **No computer is paired**.
It starts the links and waits for the paired computers.
The wait ends when each paired computer is connected, 2 seconds after the first computer connects, or after 20 seconds.
The action sends the text as `flux.clipboard` to each computer that is connected at that time.
It then closes the links again, unless Flux is on the screen.
The computer puts the text on its clipboard while `auto_clipboard` is on, which is the default.
While only the action keeps Flux running, the items of the share queue and new screenshots and photos do not go.
The links close when the action ends and would stop their transfers.
They go when Flux opens.

A link usually takes 0.5 to 3 seconds.
When the computer misses the Bonjour service of the iPhone, it connects only at its next check, which runs every 30 seconds.
This worst case takes up to 30 seconds, but iOS ends an action after about 30 seconds.
The action waits at most 20 seconds and then shows **No computer connected**.
Run the shortcut again.
Away from the local network, a link through Tailscale also waits for this check.

**Warning:** When you copy a password, do not run the shortcut.
The action cannot see the marks that password managers put on a copied password.
The password goes to the computer and into its clipboard history.
The clipboard sync in the app skips copies with these marks.

The action sends text only.
Turn on **Skip unchanged text** in the action when an automation runs it often.
The action then does not send the text that Flux sent last or that a computer put on the clipboard.
Flux compares keyed digests of these texts and does not keep the texts.
The key stays in the Keychain of the iPhone and does not go into a backup.
A copy that the action sent does not go out again when Flux opens.

To send with Siri or Spotlight, say or search **Send clipboard with Flux**.
This App Shortcut opens Flux, because iOS lets only the app on the screen read the clipboard.
It sends text or an image to each connected computer.

While **Send the clipboard when Flux opens** is on, Flux sends a new copy from another app once when it opens.
The setting is on by default.
With no computer connected, the first computer that connects gets the copy.
Flux cannot know when you made the copy, so the copy counts as new and replaces the clipboard of the computer.
iOS asks before Flux reads the copy.
To skip the question, choose **Allow** in **Settings > Apps > Flux > Paste from Other Apps**.
**Paste from Other Apps** in the settings of Flux opens the Flux page in the Settings app.

## Focus

To silence the computers with a Focus:

1. In **Settings > Focus**, open a Focus, then **Add Filter**, then **Flux**.
2. Turn on **Silence computers with Focus** in Flux.

A Focus without the Flux filter is not reported.
iOS runs the filter also while Flux is in the background or not open, when Flux has no link.
Flux keeps such a change for each computer that is paired at the time of the change.
Each of these computers gets the change when it connects.
Only a change goes out.
A computer that connects gets no state that it already has.
A computer that you pair after the change does not get it.
A computer that you unpair and pair again also does not get it.

## Permissions

iOS asks for each permission on first use.
Flux asks for notifications when you pair the first computer, not at the first start.

| Permission | Used by |
| --- | --- |
| Local Network | Discovery and links |
| Notifications | Pairing requests, received files and links, notifications, approval, herdr agents, sent share sheet items |
| Camera | Camera modes and the webcam |
| Microphone | The microphone stream and dictation |
| Speech Recognition | Dictation in the text fields |
| Photos | Send new screenshots and photos, the photo picker |
| Face ID | The Face ID lock and fingerprint approval |
| Paste from other apps | Clipboard sync and the send when Flux opens. iOS asks at each read unless you choose **Allow** in **Settings > Apps > Flux > Paste from Other Apps**. **Send Text to Computer** needs no permission, because Shortcuts reads the clipboard. |

## Privacy manifests

The app has `ios/App/PrivacyInfo.xcprivacy`, and the share extension has `ios/ShareExtension/PrivacyInfo.xcprivacy`.
Both declare no tracking, no tracking domains, and no collected data.
They declare these required-reason APIs:

| Target | API category | Reason | Use |
| --- | --- | --- | --- |
| Flux | User defaults | `CA92.1` | The settings of the app and of FluxKit, which only the app reads |
| Flux | File timestamp | `C617.1` | The creation date of the share queue folders in the App Group, and the attributes of the files that Flux sends and receives in its container |
| Flux | System boot time | `35F9.1` | The time between events in the app: touches, media positions, dictation, and agent tasks |
| FluxShare | User defaults | `1C8F.1` | The last computer of the share extension, in the App Group |

When code starts to use another required-reason API, add its category and reason to the manifest of each target that runs the code.
FluxKit runs only in the app. The code in `ios/Shared` runs in the app and in the share extension.
`options.fileTypes` in `ios/project.yml` puts each manifest into the bundle of its target.

## Demo mode

The demo shows sample computers without a network, for App Review and screenshots.
The app shows `omarchy`, a connected laptop, and `workstation`, a desktop that is not reachable.
It starts no discovery, listener, or link, and the actions on the sample computers reach no computer.
The **Inbox** shows sample items on the laptop: an agent that waits with its question and choices, an approval, a player, a clip, a received file, and an agent that is done.
**Review**, the choices, and the player buttons show a message and send nothing.
The paired computers and the share queue stay as they are, and **Flux is on** in **Settings** does not change.

To start the demo in the booted simulator:

```sh
xcrun simctl launch --terminate-running-process booted org.omarchy.flux.ios -FLUX_DEMO 1
```

In Xcode, add `-FLUX_DEMO 1` in **Product > Scheme > Edit Scheme > Run > Arguments Passed On Launch**.
The app reads the argument as the `FLUX_DEMO` user default.
Start the app without the argument to leave the demo.
`ios/App/DemoMode.swift` holds the sample computers and the sample items.

To give the laptop a sample Omarchy theme, add `-FLUX_THEME` and the name of a theme in `SampleThemes`, such as `neon`:

```sh
xcrun simctl launch --terminate-running-process booted org.omarchy.flux.ios -FLUX_DEMO 1 -FLUX_THEME neon
```

The names are `neon`, `tokyo-night`, `tokyo-night-day`, `catppuccin-latte`, `cotton-candy`, `futurism`, and `low-contrast`.
The theme applies when the scope is all computers or the laptop.
[Flux for iOS on the App Store](ios-app-store.md#test-without-an-omarchy-computer) explains what App Review can use.

## Local tests

```sh
make test-ios
```

The FluxKit tests run on the iPhone simulator and on macOS with `make test-macos`.
The app tests cover the app logic: pairing, share queue, clipboard actions, camera, keys, approval, dictation fields, the layout of agent output, and the demo.
Some tests render screens.
With `TEST_RUNNER_FLUX_SCREENS=<folder>`, they save them as PNG files in that folder.
The demo tests save `demo-01-inbox.png`, `demo-02-send.png`, `demo-03-control.png`, and `demo-04-computers.png`.
The theme tests save the demo Inbox in each sample theme as `demo-inbox-<theme>.png`, for example `demo-inbox-neon.png`.

The simulator has no camera, no battery, no Secure Enclave key that needs Face ID, and no broadcast.
Check camera capture, the webcam, the microphone, and approval on an iPhone.

To read the logs of the app in the simulator:

```sh
xcrun simctl spawn booted log stream --predicate 'subsystem == "org.omarchy.flux"'
```

## Layout

| Path | Content |
| --- | --- |
| `ios/App` | The SwiftUI app. `App/Features/Features.swift` lists the plugins and the feature screens. |
| `ios/App/Theme` | The colors of the theme in the environment, and the shared tiles, buttons, and rows |
| `ios/App/Shell` | The scope chip, the computer picker of the tools, and the routes of the tabs |
| `ios/App/Inbox` | The Inbox: the master tile, the stack, the empty states, and the notices |
| `ios/App/Destinations` | Send, Control, and the page of a computer |
| `ios/Shared` | The share queue and the App Group, for the app and the share extension |
| `ios/ShareExtension` | The share extension |
| `ios/Tests` | App tests |
| `ios/project.yml` | XcodeGen project with the Info.plist keys and `FLUX_APP_GROUP` |
| `macos/Sources/FluxKit` | The shared protocol peer and plugins, with `#if os(iOS)` where iOS differs |
| `macos/Tests/FluxKitTests` | Protocol and feature tests for both apps |

To add a feature, write a `FluxPlugin` in `macos/Sources/FluxKit/Plugins/<Feature>/`, add its views in `ios/App/Features/<Feature>/`, and add one line to each list in `Features.swift`.
