# Architecture

[Documentation index](README.md)

`fluxd` owns device state and network operations.
The CLI and both desktop hosts communicate with it through a local Unix socket.
The native Android app owns the phone services and its side of the connection.

```text
flux CLI ─────────────┐
Qt app ──────────────┼── Unix socket ── fluxd ── TLS and tunnels ── Android
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
| Approval | `internal/approve/`, `cmd/flux-approve/` | Root trust anchor, PAM setup, and signature verification |
| Shared views | `gui/qml/` | Qt Quick screens and controls for both desktop hosts |
| Qt host | `gui/app/` | Native C++ host, backend adapter, and theme watcher |
| Shell host | `gui/omarchy/` | Omarchy service, bar widget, panel, and backend adapter |
| Android | `android/` | Kotlin app, phone services, Compose screens, and protocol peer |
| Distribution | `dist/` | Arch recipe, service, udev rule, install scripts, and desktop files |

## Network direction

Flux uses KDE Connect protocol version 8 with Flux extensions.
Flux for Android is the supported phone app.

| Operation | Route |
| --- | --- |
| Discover the phone | mDNS through Avahi |
| Connect to the phone | Desktop opens the connection |
| Receive files, icons, or album art | Desktop connects to the phone's payload port |
| Send files to the phone | Phone listens for a `flux.tunnel`, then desktop connects |
| Browse the desktop from the phone | SSH inside a `flux.tunnel` |

The default Omarchy firewall permits mDNS.
Flux needs no new inbound desktop firewall rule for these routes.
Wi-Fi client isolation can still block communication between devices.

## Desktop host contract

Keep shared views independent of Quickshell.
Each host provides the same backend methods and state properties.
See the [QML contract](qml.md#backend-contract) and [IPC format](ipc.md).

## Approval boundary

The daemon carries approval messages.
The root helper independently verifies the phone signature against the root-owned public key.
See the [approval design](approve.md) before you change that boundary.
