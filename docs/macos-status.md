# macOS client: plan, status, and verification

[Documentation index](README.md)

This page records how Flux for macOS was built, what state it is in, and what was and was not verified against `fluxd`.
For build, use, and permissions, see [Flux for macOS](macos.md).

## Goal

A native Mac app, in Swift and SwiftUI, that takes the place of the Android phone app toward `fluxd`.
It speaks KDE Connect protocol version 8 with the Flux extensions and offers the Android features that macOS allows.
The Mac is a device peer, not a replacement for the Omarchy desktop side.

## Plan as executed

### 1. Fork and scope

1. Forked `bjarneo/flux` to `rogerznts/flux`. `origin` points to the fork and `upstream` to the original.
2. Chose the device role: the Mac replaces the Android app, not the desktop.
3. Chose the stack: native Swift and SwiftUI.
4. Read the Android protocol peer (`android/.../protocol`, `net`, `core`) and the Go side (`internal/lan`, `internal/proto`, `internal/core`) to fix the contract.

### 2. Test peer on the Mac

`fluxd` does not build for macOS as is. Two Linux-only calls block it: `SO_PEERCRED` in `internal/approve/client.go` and `Pdeathsig` in `internal/core/stream.go`.
A `go build -overlay` replaced both files at build time only, with no change to the Go sources.
The resulting headless daemon (`fluxd -headless -udp-port … -tcp-port …`) served as the desktop peer for every test.

### 3. Foundation (`FluxKit`)

| Layer | Content |
| --- | --- |
| Protocol | `JSONValue`, `Packet`, `Identity`, packet types, RSA 2048 self-signed certificate in the KDE Connect format, SubjectPublicKeyInfo extraction, and the 8-character verification key |
| Network | TLS 1.2 with SwiftNIO and swift-nio-ssl, UDP identity broadcasts, the TCP listener and dialer, the plain-text identity then TLS upgrade on the same socket, links, payload servers and clients, `flux.tunnel`, and Bonjour `_kdeconnect._udp` |
| Core | `FluxCore`, `Device` with pairing, `TrustStore` with pinned certificates, the `FluxPlugin` protocol, and one shared `Notifier` for UserNotifications |

SwiftNIO was chosen because the protocol reads a plain-text identity line and then starts TLS on the same socket.
Network.framework cannot upgrade a connection that way.

The foundation was checked against `fluxd` before any feature work: see [Foundation](#foundation).

### 4. App shell

A SwiftUI app generated with XcodeGen (`macos/project.yml`): sidebar of computers, pairing screens and sheet, device page, settings window, menu bar extra, and toasts.
`App/Features/Features.swift` holds the composition points, and each feature adds one line per list.

### 5. Features in parallel

Each feature was built by a separate agent in its own git worktree and branch, against its own isolated headless `fluxd` on separate ports.
The integrator merged each branch into `macos-client`, resolved the composition file, and rebuilt.

| Order | Branch | Feature |
| --- | --- | --- |
| 1 | `macos-mic` | Microphone (`flux.mic`) |
| 2 | `macos-system` | Notifications, find my device, battery, Do Not Disturb |
| 3 | `macos-browse` | Browse the computer over SFTP in a tunnel |
| 4 | `macos-share` | Files, text, links, clipboard, screenshots, and photos |
| 5 | `macos-approve` | Fingerprint approval with Touch ID |
| 6 | `macos-media` | Media control in both directions and desktop commands |
| 7 | `macos-stream` | Webcam and screen mirror, then **Also send the microphone** |
| 8 | `macos-camera` | Camera modes, started after Share because it uses the Share API |

### 6. Integration

1. Merged every branch and ran `swift test` and the Xcode build after each merge.
2. Ran one smoke client that registers the same plugin list as the app against a clean `fluxd`.
3. Wrote [Flux for macOS](macos.md) and updated the index, [architecture](architecture.md), and [development](development.md). Added `make macos` and `make test-macos`.
4. Removed the worktrees, feature branches, test daemons, throwaway clients, test defaults domains, and test data.

## Current state

- Branch `macos-client`, local only, not pushed.
- 160 `FluxKitTests` pass. The app builds with no errors and no warnings in `macos/App` or `macos/Sources`.
- The app is signed ad hoc, not sandboxed, and has no hardened runtime. It targets macOS 14 and later.
- Dependencies: swift-nio 2.103, swift-nio-ssl 2.37, swift-certificates 1.21, swift-crypto 3.15, swift-asn1, and Citadel 0.12.0 for SSH and SFTP. Citadel requires swift-crypto below 4.

### Capabilities the Mac announces

| Direction | Packet types |
| --- | --- |
| Incoming | `kdeconnect.ping`, `kdeconnect.battery`, `kdeconnect.battery.request`, `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`, `kdeconnect.share.request`, `kdeconnect.share.request.update`, `kdeconnect.notification`, `kdeconnect.runcommand`, `kdeconnect.mpris`, `kdeconnect.mpris.request`, `kdeconnect.sftp`, `flux.webcam`, `flux.screen`, `flux.mic`, `flux.dnd`, `flux.approve` |
| Outgoing | `kdeconnect.ping`, `kdeconnect.battery`, `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`, `kdeconnect.share.request`, `kdeconnect.share.request.update`, `kdeconnect.runcommand.request`, `kdeconnect.mpris`, `kdeconnect.mpris.request`, `kdeconnect.sftp.request`, `flux.tunnel`, `flux.webcam`, `flux.screen`, `flux.mic`, `flux.dnd`, `flux.approve` |

A Mac without an internal battery announces `kdeconnect.battery` as incoming only.
`fluxd` decides whether to use tunnels from the peer's outgoing `flux.tunnel` (`Link.CanTunnel`), so the Mac does not list it as incoming.

### Not possible on macOS

| Android feature | Reason |
| --- | --- |
| Mirror phone notifications (`kdeconnect.notification` outgoing, `.request`, `.reply`, `.action`) | macOS gives apps no access to other apps' notifications |
| Call alerts (`kdeconnect.telephony`) | A Mac has no telephony |
| Read and set Do Not Disturb directly | No public Focus API for an ad hoc signed app. The Mac reads Focus through a Focus filter and sets it by running user-chosen Shortcuts |
| Control any media app | MediaRemote is private. Only Apple Music and Spotify are controlled, through Apple Events |
| Camera zoom, exposure, and white balance presets | No macOS API. Zoom is digital, and exposure is a software gain |

The Android app does not send SMS either. `fluxd` supports SMS for other KDE Connect phones.

## Verified against fluxd

Unless noted, the peer was the headless `fluxd` described above, driven with the `flux` CLI, `flux status --json`, `flux watch`, and the daemon log.

### Foundation

| Check | Result |
| --- | --- |
| Discovery and link | The Mac announced itself over UDP. `fluxd` connected, ran the TLS handshake, and listed the Mac online as `laptop` |
| Pairing from the computer | `flux pair` showed a request on the Mac. Accepting it paired both sides |
| Pairing from the Mac | Both sides showed the same key, `B6922FF4`, which confirms the Swift SubjectPublicKeyInfo and hash match Go. `flux accept` paired both sides |
| Pairing in the app UI | **Pair…**, **Send request**, `flux accept`, then the app showed **Connected** and the toast "Paired with roger" |
| Ping | Both directions |
| Unpair | `flux unpair` reached the Mac, which dropped the trust |
| Reconnect | After a restart, the paired Mac reconnected with its pinned certificate and no new prompt |

### Features

| Feature | What was checked |
| --- | --- |
| Files | `flux send` of a 3 MB file arrived over `flux.tunnel` with an identical sha256. Mac to computer arrived in `fluxd`'s download folder |
| Text and links | Both directions |
| Clipboard | `flux clip` reached the Mac pasteboard. A Mac pasteboard change appeared in `fluxd`'s clipboard history |
| Screenshots | A new screenshot in a watched folder was sent once |
| Notifications | `flux notify` and `flux notify --run` produced Mac notifications, including the exit code. The app delivered a banner |
| Battery | `flux status --json` showed the Mac battery, and `battery.request` was answered |
| Do Not Disturb | With a non-headless `fluxd` and a fake `makoctl`: a Mac change made `fluxd` switch the mako mode. A change on the computer made the Mac run the configured shortcut command. The guard stopped echoes |
| Media, computer to Mac | `flux media play-pause --device <mac>` toggled Apple Music, and the new state appeared in `flux status --json` |
| Media, Mac to computer | Request packets and parsing checked in the log and in unit tests. Headless `fluxd` has no MPRIS players |
| Commands | `flux commands add`, then running it from the Mac created the file on the computer side, from the smoke client and from the app UI |
| Browse | Listed the home roots, opened subfolders, downloaded files with identical sha256, and showed the `share_home` disabled error. A link drop closed the session, and it reopened after reconnect. The app opened the files window |
| Microphone | Headless `fluxd` refuses the microphone, and the Mac showed its error. With a copy of `fluxd` without the headless check and a fake `pw-cat`, real audio arrived: 48 kHz, mono, s16le, 96 kB/s, RMS −36 dBFS. `flux mic stop`, a stop from the Mac, input switching, and a killed daemon all stopped capture |
| Webcam | Headless `fluxd` reported the missing v4l2loopback module, and the Mac showed it. A throwaway Go peer that uses the repo's `lan` code received real camera H.264: Main profile, level 4.1, no B-frames, SPS and PPS before each IDR, valid in `ffprobe`. Aspect changes from the Mac and from the computer restarted the stream at the new size. Config changes and stops worked |
| Screen mirror | Mirrored to a real Omarchy computer by hand, with Screen & System Audio Recording allowed for Flux. The Mac screen showed in a window on the computer and worked well |
| Fingerprint approval | With a copy of the repo's `internal/approve` code, the Go verifier accepted a Touch ID enrollment and approvals for sudo and polkit from the real app. Deny, timeout, the computer's cancel, and Remove Key worked |
| Camera modes | From generated images: Text and QR arrived as Android sends them, and Photo, Document, and Signature files landed in `fluxd`'s photo and scan folders with Android's names and fields. One real camera capture in the app |
| All plugins together | One client with the full plugin list announced the capabilities above. In the same session it paired, received the 3 MB file with an identical sha256, got ping and notify, and ran a desktop command |

## Not verified yet

| Item | Why | How to verify |
| --- | --- | --- |
| **Also send the microphone** with the webcam | Each ad hoc rebuild loses the camera and microphone grants, so it was not run end to end | Start the webcam with the option on and check that `flux.mic` starts and stops with it |
| Send new photos | Needs full Photos access and a new photo in the personal library | Turn it on, add a photo, and check the computer's photo folder |
| Spotify control | Spotify is not installed | Install Spotify and repeat the Apple Music check |
| Media section with real players | Headless `fluxd` on macOS has no MPRIS players | Pair with a real Omarchy computer that plays media |
| Direct SFTP route (ip and port) | `fluxd` always answers with a tunnel | Only reachable with a peer that offers a direct address |
| Menu bar items | The automation tool cannot open a `MenuBarExtra` menu | Open the menu bar item by hand and try each entry |
| Settings window | The shell-launched app could not take keyboard focus | Open **Settings** and change each option |
| Focus filter in System Settings | Adding the Flux filter and toggling a real Focus was not completed | Add **Flux** under **Focus > Focus filters** and toggle the Focus |
| Notification actions | System banners were not clicked | Click Accept, Open, Stop, and Approve in the banners |
| Battery change events | The battery stayed at a constant level during tests | Unplug the charger and watch `flux status --json` |
| Camera Screen Region and denied-camera screen | Needs a manual selection and a revoked permission | Use **Screen Region** and revoke camera access |
| Microphone and webcam timeouts when the computer never connects | Not exercised | Block the computer's connection and wait 10 seconds |
| A real Omarchy computer over Wi-Fi | Every test used a loopback daemon on the Mac | Pair with an Omarchy computer on the same network, including Bonjour discovery and UDP broadcasts |
| Approval with the real root helper and PAM | Needs root on Linux | Run `sudo flux approve setup` and `enroll` on an Omarchy computer, then `sudo true` |
