# Architecture

[Documentation index](README.md)

`fluxd` owns device state and network operations.
The CLI and both desktop hosts communicate with it through a local Unix socket.
The native Android app owns the phone services and its side of the connection.
The native iOS and macOS apps take the same role on an iPhone and a Mac.

```text
flux-cli ─────────────┐
Qt app ──────────────┼── Unix socket ── fluxd ── TLS and tunnels ── Android, iOS, or macOS
Omarchy shell plugin ┘
```

## Components

| Component | Path | Responsibility |
| --- | --- | --- |
| CLI | `cmd/flux/` | User commands, desktop setup, diagnostics, and window selection |
| Daemon | `cmd/fluxd/` | Process lifecycle and daemon startup |
| Core | `internal/core/` | Devices, state, IPC methods, and feature handlers |
| Network | `internal/lan/` | Discovery, TLS links, payloads, and reverse tunnels |
| Protocol | `internal/proto/` | Packets, certificates, and identity |
| IPC | `internal/ipc/` | JSON-line Unix socket server and client |
| Configuration | `internal/config/` | TOML settings, data paths, and trust store |
| Desktop services | `internal/desktop/` | Clipboard, notifications, media, audio, and camera integration |
| Updates | `internal/upgrade/`, `internal/plugin/` | The restart of fluxd into a new binary, and the copy of the shell plugin |
| herdr client | `internal/herdr/` | API socket client that reads the [herdr agents](herdr.md) for the phone |
| Approval | `internal/approve/`, `cmd/flux-approve/` | Root trust anchor, PAM setup, and signature verification |
| Shared views | `gui/qml/` | Qt Quick screens and controls for both desktop hosts |
| Qt host | `gui/app/` | Native C++ host, backend adapter, and theme watcher |
| Shell host | `gui/omarchy/` | Omarchy service, bar widget, panel, and backend adapter |
| Android | `android/` | Kotlin app, phone services, Compose screens, and protocol peer |
| macOS | `macos/` | Swift package `FluxKit` with the protocol peer and plugins, and the SwiftUI app |
| iOS | `ios/` | SwiftUI app and share extension on the shared `FluxKit` |
| Distribution | `dist/` | Arch recipe, service, udev rule, install scripts, and desktop files |

## Network direction

Flux uses Flux protocol version 8.
Flux for Android, Flux for iOS, and Flux for macOS are the supported device apps.
The routes are the same for each of them.

| Operation | Route |
| --- | --- |
| Discover the phone | mDNS through Avahi |
| Connect to the phone | Desktop opens the connection |
| Connect to the phone outside the local network | Desktop dials an [extra address](tailscale.md), for example through Tailscale |
| Receive files | Desktop connects to the phone's payload port |
| Send files to the phone | Phone listens for a `flux.tunnel`, then desktop connects |
| Browse the desktop from the phone | SSH inside a `flux.tunnel` |
| Show the desktop on the phone | Phone listens for the stream, then desktop connects |

`fluxd` also listens on all network interfaces:

- TCP on the first free port from 12100 to 12108, for links that a device opens after it gets the UDP identity of `fluxd`.
- UDP on port 12100, for the identity broadcasts of the devices.

The default Omarchy firewall blocks inbound traffic to these ports and permits mDNS.
The desktop opens each link itself, so Flux needs no new inbound desktop firewall rule for these routes.
Without such a firewall, each host that reaches the ports can open a link and send a pair request.
See [security](security.md#network-ports) and the [limits below](#limits-for-devices-that-are-not-paired).
Wi-Fi client isolation can still block communication between devices.

A payload server for a device without `flux.tunnel` listens on the first free port from 12070 to 12099 on the local address of the link.
It accepts connections from the address of the link until 1 of them shows the certificate of the device, or for 20 seconds.
A received payload fails when the device sends nothing for 60 seconds.
`fluxd` connects to a payload, tunnel, or stream port of the device from the local address of the link, because the phone accepts only that address.
It connects only to a port from 12070 to 12099.

## Pairing and trust

`fluxd` pins the certificate of each paired device in `~/.local/share/flux/devices.json`.

- The verification key is the first 8 bytes of a SHA-256 hash, as 16 uppercase hex digits. The hash covers the larger SubjectPublicKeyInfo, then the smaller one, then the pair timestamp as decimal text. The apps show the key in 4 groups of 4.
- A pairing is bound to the link and the certificate on which it started. While a pairing is open, or when the device has a trust entry, a new link for the device ID must show that certificate. The provider checks it before the identity exchange, and `onLink` checks it again under the lock.
- Pair packets count only on the current link of the device. `fluxd` pins the certificate from which it computed the key, and only while the link of the pairing is the current link.
- When the user accepts a request of the device, `fluxd` pins the certificate before it sends `pair: true`. The link then reads long lines from the first packet after the answer, and only 1 accept counts for each request. When the answer cannot go out, `fluxd` removes the pin again.
- When the device accepts a request of this computer, the pair state changes to `confirm`, and `fluxd` pins nothing. The user of this computer confirms the key with `pair.accept`, and only then `fluxd` pins the certificate. A reject, the timeout, and a new link send `pair: false`, so that the device removes the pin that it made. When the link of the pairing drops, the next link of the device with the certificate of the pairing gets `pair: false`. A link with another certificate does not get it, and `fluxd` keeps the device in its list until then.
- `pair.accept` and `pair.reject` can name the key that the user compared, and the buttons of the pair notification always name it. `fluxd` then acts only on the pairing with that key. Each path that ends a pairing closes its notification.
- A trust entry with a certificate that does not parse counts as not paired, and it refuses every link.
- An unpair on either side sends `pair: false`, and `fluxd` closes the link. `fluxd` then sends no feature packet to the device.
- The `fingerprint` of a device in the state is the first 8 bytes of the SHA-256 hash of the SubjectPublicKeyInfo of its certificate, as 16 uppercase hex digits.
- A panic in a packet handler drops the packet and writes the stack to the journal. When the handler leaves the daemon lock taken for 2 seconds, `fluxd` stops with an error, and systemd starts it again.

UDP and mDNS never change the address of a paired device.
`fluxd` dials the reported address after the last address, and a link that passes the pin check sets the new address.

## Limits for devices that are not paired

Any host on the network can send identities and open links.
`fluxd` keeps these limits, so that such hosts cannot fill the memory or the desktop.

| Resource | Limit |
| --- | --- |
| Line of a link | 64 KiB until the pairing, then 16 MiB |
| Links of devices that are not paired | 8 in total and 2 for each address. A new link closes the oldest link without a pairing. |
| Link without a pair request | Closed after 2 minutes |
| Incoming connections before the link | 32 in total and 4 for each address |
| Outgoing connections at the same time | 16 to devices without a trust entry or an open pairing. Dials to the other devices do not count. |
| Devices from UDP and mDNS | 64 that are not paired. A new device replaces the device with the oldest report. |
| Pair requests | 1 for each device in 2 seconds, 1 notification for each device, and 4 open requests, 2 of them from 1 address. After a pairing in state `incoming` or `confirm` ends with a pair false, a reject, or a timeout, or an `incoming` request ends with its link, 30 seconds before a new request of the device counts. |
| Ports from discovery | 12100 to 12108 |

A daemon that runs with `-tcp-port` on another port accepts any port from discovery, because its test peers use other ports too.

## App versions

The identity packet names the Flux program and its version in `app` and `appVersion`.
fluxd uses them to offer a new Android app. An earlier app sends neither field.

## Desktop host contract

Keep shared views independent of Quickshell.
Each host provides the same backend methods and state properties.
See the [QML contract](qml.md#backend-contract) and [IPC format](ipc.md).

## Approval boundary

The daemon carries approval messages.
The root helper independently verifies the phone signature against the root-owned public key.
See the [approval design](approve.md) before you change that boundary.
