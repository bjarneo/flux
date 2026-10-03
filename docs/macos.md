# Flux for macOS

[Documentation index](README.md)

Flux for macOS connects a Mac to an Omarchy computer that runs `fluxd`.
The Mac takes the place of the Android phone: it uses Flux protocol version 8 and pairs, shares, and streams the same way.
The app requires macOS 14 or later.

## Build and run

Install Xcode and XcodeGen:

```sh
brew install xcodegen
```

From the repository root, build the app and run the tests:

```sh
make macos
make test-macos
open macos/build/Build/Products/Debug/Flux.app
```

`make macos` generates `macos/Flux.xcodeproj` from `macos/project.yml` and signs the app ad hoc with the hardened runtime.
The app version is the last release tag, such as `0.7.0`. The app sends it to `fluxd`, and the Flux window on the computer shows it.
The generated project and `macos/build` stay out of Git.
To work in Xcode, run `xcodegen generate` in `macos/` and open `Flux.xcodeproj`.

To build a Release app and install it in `/Applications`, run:

```sh
make install-macos
```

The target runs `scripts/install-macos.sh`.
It quits a running Flux, replaces `/Applications/Flux.app`, and opens the new app.
f.lux also installs as `/Applications/Flux.app`.
If `/Applications/Flux.app` does not have the bundle ID `org.omarchy.flux.mac`, the script stops and changes nothing.
Add `--no-open` when you run the script directly to skip the last step.

The `macos` job in `.github/workflows/build.yml` runs `swift test` and builds a universal Release app for each push to `master` and each release.
Pull requests run no build.
Each release attaches the same build as `flux-macos-VERSION.zip`.
The window on the computer shows an update notice only for the Android app.
To find a newer Mac app, check `https://github.com/bjarneo/flux/releases`.
For a build of a branch, download the `macos-app` artifact from the run to get `flux-macos.zip`.
The app is signed ad hoc and not notarized, so Gatekeeper blocks the first start.
To open it, remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine Flux.app
```

The app runs with the hardened runtime.
macOS then loads no library that another program injects, so no other program can use the camera, microphone, and Photos access of Flux.
`macos/project.yml` gives the entitlements for the camera, the microphone, and the Photos library, and XcodeGen writes them to `macos/App/Flux.entitlements`.
When a feature starts to use another protected resource, add its entitlement there, or macOS refuses the access without a prompt.
To check a build, run:

```sh
codesign -dv Flux.app 2>&1 | grep flags
```

The output shows `flags=0x10002(adhoc,runtime)`.

Flux keeps running in the menu bar after the window closes.
Quit it from the menu bar panel.

To start Flux when you log in, turn on **Settings > General > Open at login**.
Flux then opens its window at each login.
When you close the window, Flux keeps running in the menu bar.
macOS can ask you to allow Flux in **System Settings > General > Login Items**.
While macOS waits for this, the setting shows **Open Login Items…**.
When the setting shows an error, add Flux with **+** in **System Settings > General > Login Items**.
Without this setting, the clipboard does not sync after a restart until you open Flux.

The app icon uses the Flux mark from the desktop and Android icons.
The theme sets the light or dark mode of the windows and the Dock icon, see [Theme](#theme).
Finder and Launchpad keep the dark bundle icon.
To change the icons, edit and run `swift macos/tools/render-icon.swift`.

## Pair a Mac

1. Connect the Mac and the computer to the same local network.
2. Open Flux on the Mac and allow access to the local network.
3. Open **Computers** in the sidebar, select the computer under **Available**, then **Pair…**, then **Send request**.
4. Accept the request on the computer when it shows the same 16-character key, such as `5EE6 825F 974E D59A`.

Compare all 16 characters.
Earlier versions of Flux show only 8 characters, so update Flux on all devices before you pair.

You can also start from the computer with `flux-cli pair` and accept on the Mac.
A request from the computer does not change the page that the window shows.
The Inbox shows the request, and a notification shows the key.
To see the key, select **Compare the key** in the Inbox, or select the notification.
Compare the key, then select **Accept**.
Return does not accept a request.
After the Mac accepts, the computer asks you to confirm the key.
Select **Confirm** in the Flux window or in the notification, or type `y` at the `flux-cli pair` prompt.
The computer pins the Mac only after this step, and each step waits at most 30 seconds.
Flux shows 1 request at a time.
When a request ends without a pairing, for example after a reject or a timeout, Flux ends new requests from the same computer or address for 30 seconds.
To pair in that time, start the pairing on the Mac.
A pairing is bound to its link.
When the computer connects again while a pairing runs, the pairing stops, so pair again.
A request from the computer that stops this way also starts the wait of 30 seconds.
The Mac announces itself with UDP broadcasts on port 1716 and as `_flux._udp` through Bonjour, like the phone.
It appears on the computer as `laptop` when it has a battery and `desktop` otherwise.

The Mac is a remote for Omarchy computers.
It connects and pairs only with a computer that runs `fluxd`.
It ignores phones, tablets, and other Macs, and it removes old pairings with them when it starts.

Flux searches the network for 10 seconds when it starts.
It does not search all the time.
If **Computers** shows **No computers found**, select **Search again**.
After the search ends, the Mac still connects to a paired computer when that computer announces itself.
A computer that is not paired finds the Mac through Bonjour, and `fluxd` then connects to the Mac.

## Features

| Feature | Mac behavior |
| --- | --- |
| Files, text, and links | Send from **Send**, a drop on **Send** or the Dock icon, **Open With**, or **Services > Send to Flux**. Received files go to `~/Downloads` or the folder in Settings, with the quarantine mark of a download, so Gatekeeper checks them when you open them. Flux refuses a file that leaves less than 256 MB free. A received file or link shows in a notification, and it opens only after a click. Flux never opens a received file by itself. |
| Clipboard | Syncs text both ways by itself, also while the window is closed. A copy while no computer is connected goes out when a computer connects. Password manager entries are not synced automatically. Images do not sync to or from the Mac. See [Clipboard](#clipboard). |
| Screenshots and photos | **Send new screenshots** watches the macOS screenshot folder. **Send new photos** sends new photos from the Photos library and needs full Photos access. 1 scan sends at most 50 images. The rest go with the next scan, for example after the next new image or the next connect. |
| Media | Controls the computer's players. The computer does not control the players on the Mac. |
| Commands | Lists and runs the commands configured on the computer. |
| Browse | Opens the computer's shared folders read-only through SSH inside a `flux.tunnel`, and downloads files. |
| Webcam | Streams a Mac camera, including Continuity Camera, to the computer as a virtual webcam in H.264. Zoom is digital, and exposure is a software gain, because macOS gives apps no camera zoom or exposure control. **Also send the microphone** starts the microphone with the webcam. `flux-cli webcam start` asks the Mac to start it. See [Start a stream from the computer](#start-a-stream-from-the-computer). |
| Screen mirror | Streams a display to a window on the computer in H.264, with the long side at most 1080 pixels. |
| Camera modes | Text, QR, Photo, Document, and Signature, like the phone. Text, QR, Document, and Signature also read an opened, pasted, or dropped image or a screen region. To read an image, select **From Image**, then **Open Image…**, **Screen Region…**, or **Paste Image**. In Signature, **From Image** shows with the **Paper** source. Signature also accepts a drawn signature with the **Draw** source. |
| Microphone | Streams the Mac microphone as 48 kHz mono audio. `flux-cli mic start` asks the Mac to start it. See [Start a stream from the computer](#start-a-stream-from-the-computer). |
| Notifications | Shows notifications from `flux-cli notify`. Each computer can show 10 notifications at once, then 1 more each second. Only the first notification of a burst makes a sound. Each computer keeps at most 20 notifications in Notification Center, and a new one removes the oldest. Received links count toward these limits. |
| Battery | A Mac with a battery reports it. The scope menu and **Computers** show the battery of each computer. |
| Do Not Disturb | See [Focus](#focus). |
| Fingerprint approval | Approves `sudo` and polkit with Touch ID. The Inbox shows each request, and **Review** opens the prompt. The setup is on the page of each computer in **Computers**. See [approval](#approval). |
| Touchpad and keyboard | The trackpad, the mouse, and the keyboard of the Mac control the pointer and the keys of the Omarchy computer. The computer does not control the Mac. The computer needs `remote_input = true`. The Mac asks for Touch ID or its password before the touchpad opens. Control and Option together give the pointer back to the Mac. See [Touchpad and keyboard](remote-input.md#use-a-mac). |
| Remote desktop | Shows the screen of the Omarchy computer in a window. The mouse over the video, the keys, the Omarchy panel, and dictation control the computer. The computer does not control the Mac. The computer needs `remote_desktop = true`, and `remote_input = true` for control. The Mac asks for Touch ID or its password before the window opens. See [Remote desktop](remote-desktop.md#use-a-mac). |
| herdr agents | Shows the coding agents that herdr runs on the computer, their output in color, and notifications. Answers them after Touch ID or the password when the computer allows replies, with dictation on the Mac. See [herdr agents](herdr.md#use-a-mac). |
| Dictation | Each text field has a mic key: the agent replies, the touchpad and the remote desktop, **Text or link** in **Share**, the scanned text, the shortcut search, and the language search. Search fields get the words in place of the search. Other fields get them at the cursor or at the end of the text. All fields use the same language. See [Dictate on a Mac](herdr.md#dictate-on-a-mac). |
| Clear and expand | The agent replies, **Text or link** in **Share**, the scanned text, the shortcut search, and the language search have a clear key while they have text. The agent replies and **Text or link** also have an expand key that opens a larger editor with **Send**. The type field of the touchpad and the remote desktop has a clear key and the draft editor, see [Type on the Mac](remote-input.md#type-on-the-mac). |

The Mac cannot mirror notifications from other apps, report calls, or send SMS, because macOS gives apps no access to them.
Flux does not advertise those capabilities.

## Start a stream from the computer

The computer can ask the Mac to start the webcam or the microphone.
The Mac never turns on its camera or its microphone without a click on the Mac.
The request only asks, also while Flux is the active app.

```sh
flux-cli webcam start
flux-cli --device MacBook mic start
```

The computer sends `flux.stream.request` with `{"kind": "webcam"}` or `{"kind": "mic"}`.
The Mac lists `flux.stream.request` in its incoming packet types, because it can stream both kinds.

| Flux | What the Mac shows |
| --- | --- |
| The active app | A prompt window over the other windows. The prompt has the title `omarchy asks for the webcam` or `omarchy asks for the mic`. It has the buttons **Not now** and **Start webcam** or **Start the mic**. |
| Not the active app | A notification with the text `Tap to start the webcam.` or `Tap to start the mic.` under the same title. The **Start webcam** or **Start the mic** action, or a click on the notification, starts the stream. |

The prompt and the notification name the computer that asks.
When a request waits and Flux becomes the active app, the prompt window shows the request.
The prompt window shows the newest request first.

- **Start webcam** and **Start the mic** are not the default button, so Return does not start a stream.
- Escape and **Not now** end the request and start nothing.
- The close button of the prompt window ends each open request and starts nothing.

A click on start opens a window with the **Webcam and screen mirror** page or the **Microphone** page of that computer.
The stream starts at once with the saved settings, the same as **Start** on that page.

Each request follows these rules:

- A request ends after 60 seconds, and its notification goes away.
- When a stream of that kind already runs to that computer, the request does nothing.
- The Mac ignores a request of the same kind from the same computer that comes less than 3 seconds after the last request. An ignored request also counts as the last request.
- An unpair ends the requests of the computer. A link that only drops keeps them.

## Inbox and navigation

The window has a sidebar with 4 destinations: **Inbox**, **Send**, **Control**, and **Computers**.
The Inbox row counts the items of all computers that need you.
To open a destination from the keyboard, press Command-1 to Command-4, or use the **Go** menu.

The scope menu in the toolbar shows **All computers** or 1 paired computer, with a link dot and a battery dot for each computer.
The scope filters the Inbox, Send, and Control, and it picks the theme of the **Computer** setting.
A click on a paired computer in **Computers** also sets the scope, and a second click sets **All computers** again.
A new pairing sets the scope to the new computer and opens the Inbox.
Each start of Flux begins with **All computers**.

The Inbox shows what happens on the computers in scope, as a Hyprland master layout:

- The item that comes first takes the master tile, in the active border of the theme. An agent that waits for input comes first, then an approval, then a pair request. What plays now, the last clip, the transfers, and the other agents follow.
- The other items wait in the stack. A click on a stack tile moves it to the master tile.
- **Later**, Command-], or **Show the next item** in the context menu moves the master item to the end of the stack. A new item that needs you takes the master tile back.
- In a detail column of 600 pt or more, the master tile takes 60% of the width on the left, and the status line and the stack fill the column on the right. A narrower column shows the master tile above a stack of 2 columns.
- A finished transfer, the last clip, and a paused player stay for 30 minutes.

The master tile of an agent that waits shows its question with the numbered choices.
The tile reads the output of the agent when it shows and when its window comes to the front.
Choices show only for an output that came after that read.
The question keeps the lines nearest the choices, because they hold the command that a choice approves, and the tile never cuts them.
Each answer asks for Touch ID or the password first, see [Touch ID lock](#touch-id-lock).
After an answer, the choices stay off until a new output comes.
When the computer does not allow replies, set `herdr_control = true` on it.
**Reply** and **Open** open the agent in the agents window.

The master tile of an approval shows the request, and **Review** opens the Touch ID prompt.
It never approves by itself.
The master tile of a pair request opens the pairing page with **Compare the key**.
It never pairs by itself.

**Send** holds the tools that send to the computer in scope: the clipboard, files, text and links, the clipboard sync, the files of the computer, and the camera modes.
**Control** holds the tools that act on the computer in scope: the remote desktop with the Omarchy panel, the touchpad and keyboard, the commands, the media, the microphone, the webcam and screen mirror, and the agents.
When more than 1 computer can take a tool, Flux asks which one.
The cards of the features open on a page of their own from **Send** and **Control**.
The agents, browse, camera, remote desktop, and touchpad windows stay separate windows.

**Computers** shows this Mac, the paired computers, and the computers to pair.
The arrow on a paired computer opens its page, with the Touch ID approval and **Unpair**.

The menu bar extra shows the Flux mark and the count of the items that need you.
Its panel shows the master item of all computers with its one-tap choices, then the next 3 items, a menu for each online computer, **Open Flux**, **Settings…**, and **Quit Flux**.
A click on a next item shows it first in the Inbox of the window.

## Theme

Flux follows the active Omarchy theme of the computer, as Flux for Android does.
`fluxd` sends the theme in a `flux.theme` packet when the Mac connects and when the theme changes.
Flux saves the theme of each computer, so the next start draws it at once.

To change the theme, open **Settings > General > Theme**. The choices are:

- **Computer**, the default: the theme of the computer in scope. In the scope of all computers, Flux uses the theme that changed most recently. Without a theme from the computer in scope, Flux uses Tokyo Night when macOS is dark and Tokyo Night Day when macOS is light. The line under the choices names the theme and the computer that sent it.
- **System**: Tokyo Night when macOS is dark and Tokyo Night Day when macOS is light.
- **Light**: Tokyo Night Day.
- **Dark**: Tokyo Night.

The theme sets the light or dark mode of all Flux windows and the Dock icon.
The old **Appearance** setting becomes **Computer** for Automatic, and stays **Light** or **Dark**.
A contrast guard maps the theme to the colors of the app, see [Flux for Android](android.md#theme).
The window, the menu bar panel, the Settings window, and the feature windows take the theme background and the theme accent.
The cards of the features and the agent output keep their own colors.
The pairing view keeps its layout. It shows on the theme background of the window, and takes the theme accent and the light or dark mode.
The pair request sheet and the Touch ID prompt keep their layout and their own background, and take only the theme accent and the light or dark mode.
The theme engine is in `macos/Sources/FluxKit/Theme`.

## Clipboard

Each copy on the Mac reaches the clipboard of the Omarchy computer without a click.
Keep **Sync clipboard** on in **Settings > Features**, and keep `auto_clipboard = true` on the computer.
Both are on by default.

- While a paired computer is connected, Flux checks the clipboard every 0.5 seconds and sends each new copy.
- While no computer is connected, Flux reads only the change count every 2 seconds. It keeps the time of a new copy and does not read the copy. A copy from the last 0.5 seconds before the last link drops also keeps its time.
- When a computer connects, the Mac and the computer compare the times of their last copies. The newer copy goes on both clipboards.
- Flux skips the copies that password managers mark as concealed, transient, or generated.
- Text that a computer put on the clipboard does not go back to that computer. This is also true when the computer connects again.

The time of a copy can be up to 2 seconds late, and both clocks must be correct.
When the clock of the Mac differs from the clock of the computer, 2 copies close in time can win in the wrong order.

On macOS 15.4 and later, macOS can ask before an app reads the clipboard, or deny the read.
When macOS asks or denies, **Sync clipboard** shows a warning with **Open Privacy Settings**.
To sync without a question, choose **Allow** for Flux in **System Settings > Privacy & Security > Paste from Other Apps**.

## Touch ID lock

The touchpad, the remote desktop, and the agent replies ask for Touch ID or the Mac password.
The unlock stays valid for 5 minutes.
It ends earlier when the Mac sleeps, its screens sleep, the screen locks, or another user takes the session.

The remote desktop stops while the Mac sleeps or is locked and while its window is in the Dock.
It does not start again in that time, also not when the link to the computer comes back.

## Focus

macOS has no public API that reads or sets the Focus state for an ad hoc signed app.
Flux uses two public paths instead:

- To report Focus, add the **Flux** filter to each Focus that should silence the computers in **System Settings > Focus**, and turn on **Do Not Disturb on computers**.
- To follow the computer, create two shortcuts with the **Set Focus** action and select them in **Settings > Features**. Flux runs them with `/usr/bin/shortcuts`.

A Focus without the Flux filter is not reported.
Without shortcuts, the Mac ignores Do Not Disturb changes from the computer.

## Approval

The Mac keeps the approval key in the Secure Enclave.
Each signature needs Touch ID, and a new fingerprint invalidates the key.
An ad hoc signed app has no keychain access group, so Flux stores the key blob that the Secure Enclave wrapped in `~/Library/Application Support/Flux/approve/` with mode `0600`.
Only this Mac's Secure Enclave can use the blob, and only after Touch ID.
The Mac shows requests only while it is unlocked.
See the [approval design](approve.md) and [fingerprint approval](approvals.md) for the computer side.

## Pairing data

Flux keeps the identity of the Mac in `~/Library/Application Support/Flux/identity/`.
The private key file has mode `0600`, but each program that runs as your user can read it.
A program with the key and the certificate can act as this Mac from another host.
To replace the identity after such a program ran, quit Flux, remove the `identity` folder, start Flux, and pair again.
When the key or the certificate exists but does not read, Flux does not start, and it keeps the files.
Flux makes a new identity only when a file is missing.

The paired computers are in `~/Library/Application Support/Flux/trusted.json`.
An entry that does not read is not paired, and Flux keeps a copy of the file in `trusted.json.bad`.
A link that shows another certificate than the pinned one is refused, also while a pairing runs.
Links of computers that are not paired read at most 64 KiB for each packet, close after 2 minutes without a pairing, and at most 8 of them stay open.

## Permissions

macOS asks for each permission on first use:

| Permission | Used by |
| --- | --- |
| Local network | Discovery and links |
| Notifications | Pairing requests, received files, notifications, approval, herdr agents |
| Camera | Webcam and camera modes |
| Microphone | Microphone, dictation in the text fields |
| Speech Recognition | Dictation in the text fields |
| Screen & System Audio Recording | Screen mirror, and **Screen Region…** in the camera modes, which runs `/usr/sbin/screencapture -i` |
| Photos | Send new photos |
| Downloads folder | Received files |
| Paste from Other Apps | Clipboard sync, on macOS 15.4 and later when macOS asks before clipboard reads. See [Clipboard](#clipboard). |

## Test against a computer on the same Mac

`fluxd` does not build for macOS as is.
For local protocol tests, build a copy with a Go overlay that replaces the Linux-only peer credential check and process death signal, then run it headless as in [development](development.md#isolated-daemon).
Point the app at it with these variables:

```sh
FLUX_DATA_DIR=/tmp/flux-mac FLUX_UDP_PORT=28731 FLUX_PEER_UDP_PORT=28716 FLUX_LOOPBACK=1 \
  macos/build/Build/Products/Debug/Flux.app/Contents/MacOS/Flux
```

| Variable | Effect |
| --- | --- |
| `FLUX_DATA_DIR` | Identity, trust store, and settings in a separate directory and defaults domain. Each launch with the same directory uses the same domain. |
| `FLUX_UDP_PORT` | UDP port that receives identity broadcasts |
| `FLUX_PEER_UDP_PORT` | UDP port of the computer that the Mac announces itself to |
| `FLUX_LOOPBACK=1` | Announce only to 127.0.0.1 and skip Bonjour |

Headless `fluxd` has no clipboard, notification, media, or stream backends.
Check its side with `flux-cli status --json`, `flux-cli watch`, and its log.

To read the Mac logs:

```sh
log stream --predicate 'subsystem == "org.omarchy.flux"'
```

## Layout

| Path | Content |
| --- | --- |
| `macos/Sources/FluxKit/Protocol` | Packets, identity, certificates, and the verification key |
| `macos/Sources/FluxKit/Net` | UDP discovery, Bonjour, TCP links, TLS, payload transfers, and tunnels |
| `macos/Sources/FluxKit/Core` | Devices, pairing, trust store, the plugin protocol, and notifications |
| `macos/Sources/FluxKit/Plugins` | One folder per feature |
| `macos/Sources/FluxKit/Theme` | The theme packet, the contrast guard, and the palettes |
| `macos/Sources/FluxKit/Inbox` | The items of the Inbox, their order, and their texts |
| `macos/App` | The SwiftUI app; `App/Features/Features.swift` lists the plugins and their views |
| `macos/App/Theme` | The colors of the theme in SwiftUI and the shared components |
| `macos/App/Shell` | The destinations, the sidebar, the Go menu, the scope menu, and the pages of the features |
| `macos/App/Inbox` | The Inbox: the master tile, the stack, and the empty Inbox |
| `macos/App/Destinations` | Send, Control, and Computers |
| `macos/Tests/FluxKitTests` | Protocol and feature tests |
| `macos/project.yml` | XcodeGen project with the Info.plist keys |

To add a feature, write a `FluxPlugin` in `Plugins/<Feature>/`, add its views in `App/Features/<Feature>/`, and add one line to each list in `Features.swift`.
