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
Pull requests skip it, because macOS runners use GitHub minutes at a high rate.
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
Quit it from the menu bar item.

The app icon uses the Flux mark from the desktop and Android icons.
**Settings > General > Appearance** sets the windows and the Dock icon: Automatic follows macOS, or choose Light or Dark.
Finder and Launchpad keep the dark bundle icon.
To change the icons, edit and run `swift macos/tools/render-icon.swift`.

## Pair a Mac

1. Connect the Mac and the computer to the same local network.
2. Open Flux on the Mac and allow access to the local network.
3. Select the computer in the sidebar, then **Pair…**, then **Send request**.
4. Accept the request on the computer when it shows the same 16-character key, such as `5EE6 825F 974E D59A`.

Compare all 16 characters.
Earlier versions of Flux show only 8 characters, so update Flux on all devices before you pair.

You can also start from the computer with `flux-cli pair` and accept on the Mac.
A request from the computer does not change the page that the window shows.
The sidebar marks the computer, and a notification shows the key.
Select the computer, compare the key, and select **Accept**.
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
If the sidebar shows **No computer found**, select **Search again**.
After the search ends, the Mac still connects to a paired computer when that computer announces itself.
A computer that is not paired finds the Mac through Bonjour, and `fluxd` then connects to the Mac.

## Features

| Feature | Mac behavior |
| --- | --- |
| Files, text, and links | Send from the device page, a drop on the window or Dock icon, **Open With**, or **Services > Send to Flux**. Received files go to `~/Downloads` or the folder in Settings, with the quarantine mark of a download, so Gatekeeper checks them when you open them. Flux refuses a file that leaves less than 256 MB free. A received file or link shows in a notification, and it opens only after a click. Flux never opens a received file by itself. |
| Clipboard | Syncs text both ways while a paired computer is connected. Password manager entries are not synced automatically. Images do not sync to or from the Mac. |
| Screenshots and photos | **Send new screenshots** watches the macOS screenshot folder. **Send new photos** sends new photos from the Photos library and needs full Photos access. 1 scan sends at most 50 images. The rest go with the next scan, for example after the next new image or the next connect. |
| Media | Controls the computer's players. The computer does not control the players on the Mac. |
| Commands | Lists and runs the commands configured on the computer. |
| Browse | Opens the computer's shared folders read-only through SSH inside a `flux.tunnel`, and downloads files. |
| Webcam | Streams a Mac camera, including Continuity Camera, to the computer as a virtual webcam in H.264. Zoom is digital, and exposure is a software gain, because macOS gives apps no camera zoom or exposure control. **Also send the microphone** starts the microphone with the webcam. |
| Screen mirror | Streams a display to a window on the computer in H.264, with the long side at most 1080 pixels. |
| Camera modes | Text, QR, Photo, Document, and Signature, like the phone. Text, QR, Document, and Signature also read an opened, pasted, or dropped image or a screen region. To read an image, select **From Image**, then **Open Image…**, **Screen Region…**, or **Paste Image**. In Signature, **From Image** shows with the **Paper** source. Signature also accepts a drawn signature with the **Draw** source. |
| Microphone | Streams the Mac microphone as 48 kHz mono audio. |
| Notifications | Shows notifications from `flux-cli notify`. Each computer can show 10 notifications at once, then 1 more each second. Only the first notification of a burst makes a sound. Each computer keeps at most 20 notifications in Notification Center, and a new one removes the oldest. Received links count toward these limits. |
| Battery | A Mac with a battery reports it. The page shows the computer's battery. |
| Do Not Disturb | See [Focus](#focus). |
| Fingerprint approval | Approves `sudo` and polkit with Touch ID. See [approval](#approval). |
| Touchpad and keyboard | The trackpad, the mouse, and the keyboard of the Mac control the pointer and the keys of the Omarchy computer. The computer does not control the Mac. The computer needs `remote_input = true`. The Mac asks for Touch ID or its password before the touchpad opens. Control and Option together give the pointer back to the Mac. See [Touchpad and keyboard](remote-input.md#use-a-mac). |
| Remote desktop | Shows the screen of the Omarchy computer in a window. The mouse over the video, the keys, the Omarchy panel, and dictation control the computer. The computer does not control the Mac. The computer needs `remote_desktop = true`, and `remote_input = true` for control. The Mac asks for Touch ID or its password before the window opens. See [Remote desktop](remote-desktop.md#use-a-mac). |
| herdr agents | Shows the coding agents that herdr runs on the computer, their output in color, and notifications. Answers them after Touch ID or the password when the computer allows replies, with dictation on the Mac. See [herdr agents](herdr.md#use-a-mac). |
| Dictation | Each text field has a mic key: the agent replies, the touchpad and the remote desktop, **Text or link** in **Share**, the scanned text, the shortcut search, and the language search. Search fields get the words in place of the search. Other fields get them at the cursor or at the end of the text. All fields use the same language. See [Dictate on a Mac](herdr.md#dictate-on-a-mac). |

The Mac cannot mirror notifications from other apps, report calls, or send SMS, because macOS gives apps no access to them.
Flux does not advertise those capabilities.

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
| `macos/App` | The SwiftUI app; `App/Features/Features.swift` lists the plugins and their views |
| `macos/Tests/FluxKitTests` | Protocol and feature tests |
| `macos/project.yml` | XcodeGen project with the Info.plist keys |

To add a feature, write a `FluxPlugin` in `Plugins/<Feature>/`, add its views in `App/Features/<Feature>/`, and add one line to each list in `Features.swift`.
