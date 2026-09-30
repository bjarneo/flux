# macOS client plan

[Documentation index](README.md)

This plan builds Flux for macOS: a native Swift and SwiftUI app that takes the place of the Android phone app toward `fluxd`.
It uses Flux protocol version 8 and offers the Android features that macOS allows.
See [status](macos-status.md) for the details of each check and [Flux for macOS](macos.md) for use.

## Decisions

- [x] The Mac is a device peer that replaces the Android app, not the Omarchy desktop side.
- [x] Native Swift and SwiftUI, macOS 14 or later.
- [x] SwiftNIO and swift-nio-ssl for links, because the protocol reads a plain-text identity and then starts TLS on the same socket.
- [x] swift-certificates and swift-crypto for the self-signed certificate and the verification key.
- [x] XcodeGen project in `macos/project.yml`; the generated project stays out of Git.
- [x] One `FluxPlugin` per feature, composed in `macos/App/Features/Features.swift` with one line per entry.
- [x] Wire formats follow the Android app and the Go handlers exactly.
- [x] The Mac announces only the capabilities it implements.

## Phase 0: Setup

- [x] Fork `bjarneo/flux` to `rogerznts/flux`, with `origin` on the fork and `upstream` on the original.
- [x] Map the Android peer: `protocol`, `net`, `core`, and each feature folder.
- [x] Map the Go peer: `internal/lan`, `internal/proto`, `internal/core`.
- [x] Build a macOS test copy of `fluxd` and `flux-cli` with `go build -overlay`, with no change to the Go sources.
- [x] Run `fluxd -headless` with isolated XDG paths and custom ports as the test peer.

## Phase 1: Foundation

### Protocol

- [x] `JSONValue` that accepts a number or a string for the same field.
- [x] `Packet` with payload fields for a port or a tunnel.
- [x] `Identity`, packet types, device ID rules, and name cleanup.
- [x] RSA 2048 self-signed certificate with CN set to the device ID.
- [x] SubjectPublicKeyInfo taken from the certificate bytes as stored.
- [x] Verification key of 16 characters in 4 groups of 4. The first builds showed 8 characters.
- [x] Unit tests for packets, identity, certificates, and the key.

### Network

- [x] TLS 1.2 with both sides presenting a certificate, and the pin check after the handshake.
- [x] UDP identity broadcasts and a receiver on port 1716.
- [x] TCP listener on ports 1716 to 1764 and a dialer for UDP identities.
- [x] Plain-text identity, then TLS on the same socket, then the identity again inside TLS.
- [x] Links with packet framing and buffering before start.
- [x] Payload server and client on ports 1739 to 1764.
- [x] `flux.tunnel` listener with the pinned certificate.
- [x] Bonjour publish and browse for `_flux._udp`.
- [x] Test variables: `FLUX_DATA_DIR`, `FLUX_UDP_PORT`, `FLUX_PEER_UDP_PORT`, `FLUX_LOOPBACK`.

### Core

- [x] `FluxCore` with devices, links, state snapshots, and toasts.
- [x] Pairing in both directions with timeouts and the timestamp check.
- [x] `TrustStore` with pinned certificates.
- [x] `FluxPlugin` protocol with routing by packet type.
- [x] One shared `Notifier` for UserNotifications.
- [x] `PingPlugin`.

### Foundation checks against fluxd

- [x] The Mac appears online on the computer as `laptop`.
- [x] Pairing from the computer.
- [x] Pairing from the Mac with the same key on both sides.
- [x] Ping in both directions.
- [x] Unpair from the computer.
- [x] Reconnect after a restart with the pinned certificate.

## Phase 2: App shell

- [x] Sidebar with paired and available computers.
- [x] Pairing screens and the pairing request sheet.
- [x] Device dashboard: header with state, IP, battery, and quick actions (Send Files, Send Clipboard, Browse Files, Ping).
- [x] Banners for an open approval request and an offline computer.
- [x] Feature cards in a grid of equal columns, with equal heights per row.
- [x] Collapsible card details, saved per card: webcam image settings and approval details.
- [x] Settings window with General and Features tabs.
- [x] App icon with the Flux mark, dark in the bundle and light in the Dock in light mode.
- [x] **Settings > General > Appearance** (Automatic, Light, Dark) for the windows and the Dock icon.
- [x] Menu bar extra that keeps Flux running after the window closes, with the Flux mark of `dist/flux-symbolic.svg`, dimmed while no computer is connected.
- [x] Pairing request notification with Accept and Reject.
- [x] Pairing through the app UI against `fluxd`.

## Phase 3: Features

Each feature gets its own branch, worktree, and isolated `fluxd`, then merges into `macos-client`.

### Files, text, links, clipboard, and captures

- [x] Receive files over a tunnel, with unique names and no overwrite.
- [x] Send files, text, and links with Android's fields.
- [x] Capture and scan sends for the camera modes.
- [x] Clipboard sync in both directions with Android's timestamp and echo rules.
- [x] Drop zone, **Open With**, Dock drop, and **Services > Send to Flux**.
- [x] Send new screenshots from the macOS screenshot folder.
- [x] Send new photos from the Photos library.
- [x] Checked: files both ways with identical sha256, text and links both ways, clipboard both ways, one screenshot sent once.
- [ ] Checked: send new photos with a real new photo.
- [ ] Checked: Services menu, Dock drop, and menu bar items in the app.

### Notifications, battery, and Do Not Disturb

- [x] Show notifications from `flux-cli notify`, with replace and cancel.
- [x] Report the Mac battery and show the computer's battery.
- [x] Report Focus through a Focus filter and follow the computer through user-chosen Shortcuts.
- [x] Checked: notifications, battery in `flux-cli status`, Do Not Disturb both ways with a fake `makoctl`.
- [ ] Checked: the Flux Focus filter in System Settings with a real Focus toggle.
- [ ] Checked: battery change events on unplug.
- [ ] Checked: notification actions clicked in banners.

### Media and commands

- [x] Control the computer's players with Android's requests and state merging.
- [x] Let the computer control Apple Music and Spotify through Apple Events.
- [x] List and run desktop commands.
- [x] Checked: `flux-cli media play-pause` toggled Apple Music, and commands ran from the Mac.
- [ ] Checked: Spotify control.
- [ ] Checked: the Media section with real players on a computer.

### Browse

- [x] Request the SFTP offer and connect through a tunnel with a loopback bridge.
- [x] Read-only browsing, downloads with progress, and a window per computer.
- [x] Checked: listing, subfolders, downloads with identical sha256, the `share_home` error, and reconnect.

### Microphone

- [x] Stream 48 kHz mono s16le over a pinned payload connection.
- [x] Input picker, level meter, and stops on every end path.
- [x] Checked: real audio at the computer, `flux-cli mic stop`, stop from the Mac, and a killed daemon.
- [ ] Checked: the 10-second timeout when the computer never connects.

### Webcam and screen mirror

- [x] Webcam in H.264 with Android's start, config, and stop packets.
- [x] Screen mirror in H.264 with ScreenCaptureKit.
- [x] **Also send the microphone** starts and stops the microphone with the webcam.
- [x] Continuity Camera through `NSCameraUseContinuityCameraDeviceType`.
- [x] Checked: real camera H.264 valid in `ffprobe`, aspect changes from both sides, config changes, and stops.
- [x] Checked: screen mirror with real pixels on an Omarchy computer.
- [ ] Checked: **Also send the microphone** end to end.
- [ ] Checked: the webcam timeout when the computer never connects.

### Fingerprint approval

- [x] `flux.approve` messages byte for byte as the Go verifier expects.
- [x] Secure Enclave key that needs Touch ID for every signature.
- [x] Prompt window with countdown, and notification with Approve and Deny.
- [x] Checked: enrollment and sudo and polkit approvals accepted by the Go verifier, plus deny, timeout, cancel, and Remove Key.
- [ ] Checked: approval with the real root helper and PAM on an Omarchy computer.

### Camera modes

- [x] Text, QR, Photo, Document, and Signature with Android's names and fields.
- [x] Vision for text, codes, and document edges.
- [x] Image input from files, paste, drop, and a screen region.
- [x] Drawn signatures.
- [x] Checked: every mode's output at `fluxd`, and one real camera capture.
- [ ] Checked: Screen Region and the denied-camera screen.

## Phase 4: Integration

- [x] Merge every feature branch into `macos-client`.
- [x] `swift test` passes: 160 tests.
- [x] The app builds with no errors and no warnings in `macos/App` and `macos/Sources`.
- [x] One client with the full plugin list against a clean `fluxd`: pairing, a 3 MB file, ping, notify, and a desktop command.
- [x] `make macos` and `make test-macos`.
- [x] Remove worktrees, feature branches, test daemons, and test data.
- [ ] Checked: menu bar items in the running app.
- [ ] Checked: every option in the Settings window.
- [ ] Checked: a real Omarchy computer on the same Wi-Fi, with Bonjour discovery and UDP broadcasts.

## Phase 5: Documentation

- [x] [Flux for macOS](macos.md): build, pairing, features, Focus, approval, permissions, local tests, and layout.
- [x] Index, [architecture](architecture.md), and [development](development.md) updated.
- [x] [Status](macos-status.md): plan, current state, and verification.

## Next

- [x] Push `macos-client` to the fork.
- [ ] Run the unchecked checks above.
