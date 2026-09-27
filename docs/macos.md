# Flux for macOS

[Documentation index](README.md)

Flux for macOS connects a Mac to an Omarchy computer that runs `fluxd`.
The Mac takes the place of the Android phone: it uses KDE Connect protocol version 8 with Flux extensions and pairs, shares, and streams the same way.
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

`make macos` generates `macos/Flux.xcodeproj` from `macos/project.yml` and signs the app ad hoc.
The generated project and `macos/build` stay out of Git.
To work in Xcode, run `xcodegen generate` in `macos/` and open `Flux.xcodeproj`.

To build a Release app and install it in `/Applications`, run:

```sh
make install-macos
```

The target runs `scripts/install-macos.sh`.
It quits a running Flux, replaces `/Applications/Flux.app`, and opens the new app.
Add `--no-open` when you run the script directly to skip the last step.

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
4. Accept the request on the computer when it shows the same 8-character key.

You can also start from the computer with `flux-cli pair` and accept on the Mac.
The Mac announces itself with UDP broadcasts on port 1716 and as `_kdeconnect._udp` through Bonjour, like the phone.
It appears on the computer as `laptop` when it has a battery and `desktop` otherwise.

## Features

| Feature | Mac behavior |
| --- | --- |
| Files, text, and links | Send from the device page, a drop on the window or Dock icon, **Open With**, or **Services > Send to Flux**. Received files go to `~/Downloads` or the folder in Settings. |
| Clipboard | Syncs both ways while a paired computer is connected. Password manager entries are not synced automatically. |
| Screenshots and photos | **Send new screenshots** watches the macOS screenshot folder. **Send new photos** sends new photos from the Photos library and needs full Photos access. |
| Media | Controls the computer's players. The computer does not control the players on the Mac. |
| Commands | Lists and runs the commands configured on the computer. |
| Browse | Opens the computer's shared folders read-only through SSH inside a `flux.tunnel`, and downloads files. |
| Webcam | Streams a Mac camera, including Continuity Camera, to the computer as a virtual webcam in H.264. Zoom is digital, and exposure is a software gain, because macOS gives apps no camera zoom or exposure control. **Also send the microphone** starts the microphone with the webcam. |
| Screen mirror | Streams a display to a window on the computer in H.264, with the long side at most 1080 pixels. |
| Camera modes | Text, QR, Photo, Document, and Signature, like the phone. Text, QR, and Document also read an opened, pasted, or dropped image or a screen region. Signature also accepts a drawn signature. |
| Microphone | Streams the Mac microphone as 48 kHz mono audio. |
| Notifications | Shows notifications from `flux-cli notify`. |
| Battery | A Mac with a battery reports it. The page shows the computer's battery. |
| Do Not Disturb | See [Focus](#focus). |
| Fingerprint approval | Approves `sudo` and polkit with Touch ID. See [approval](#approval). |

The Mac cannot mirror notifications from other apps, report calls, or send SMS, because macOS gives apps no access to them.
Flux does not advertise those capabilities.

The Mac app does not show [herdr agents](herdr.md) yet.
It does not advertise `flux.herdr`, so `fluxd` sends it no agent state.

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

## Permissions

macOS asks for each permission on first use:

| Permission | Used by |
| --- | --- |
| Local network | Discovery and links |
| Notifications | Pairing requests, received files, notifications, approval |
| Camera | Webcam and camera modes |
| Microphone | Microphone |
| Screen & System Audio Recording | Screen mirror |
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
| `FLUX_DATA_DIR` | Identity, trust store, and settings in a separate directory and defaults domain |
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
