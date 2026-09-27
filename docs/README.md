# Flux documentation

Flux connects an Omarchy desktop to Flux for Android or Flux for macOS on the same local network.
A paired device can also connect through [Tailscale](tailscale.md) away from that network.

## Start here

1. [Clone and install Flux](install.md).
2. [Install the Android app](android.md) or [build the Mac app](macos.md#build-and-run).
3. [Pair your phone](features.md#pair-a-phone) or [pair your Mac](macos.md#pair-a-mac).
4. [Use the CLI](cli.md) or open the window with `flux-cli open`.

## Use Flux

| Guide | Topics |
| --- | --- |
| [Installation](install.md) | Dependencies, Arch package, source install, user-only install, updates, and removal |
| [Android](android.md) | APK installation, local builds, SDK setup, tests, and screenshots |
| [macOS](macos.md) | Mac app build, pairing, features, permissions, and local tests |
| [CLI](cli.md) | Commands, device selection, JSON state, and notifications from scripts |
| [Everyday use](features.md) | Pair, share, clipboard images, SMS, media, calls, Do Not Disturb, and automatic photo transfers |
| [Tailscale](tailscale.md) | Extra addresses, links away from the local network, other VPNs, and connection checks |
| [Camera and streams](camera.md) | Scans, photos, webcam settings, microphone, and screen mirror |
| [Configuration](configuration.md) | TOML settings, data paths, environment variables, and service control |
| [Omarchy integration](omarchy.md) | Shell plugin, bar item, window host, theme, and desktop integration |
| [Fingerprint approval](approvals.md) | Enrollment, PAM services, timeout, and removal |
| [herdr agents](herdr.md) | Agent status, colored output, notifications, and replies on the phone |
| [Touchpad and keyboard](remote-input.md) | Remote input from the phone, gestures, typing, slides, and the wire format |
| [Troubleshooting](troubleshooting.md) | Service, discovery, plugin, media, Android, and build failures |

## Develop and automate

| Guide | Topics |
| --- | --- |
| [Architecture](architecture.md) | Components, source layout, and network direction |
| [IPC](ipc.md) | Unix socket, request format, responses, and events |
| [Shared QML](qml.md) | Desktop backend contract, icons, themes, and snapshots |
| [Development](development.md) | Component checks, isolated daemons, and local iteration |
| [Releases](releasing.md) | GitHub workflows, AUR publication, APK signatures, and secrets |
| [Agent skill](agents.md) | Skill installation, scope, and example prompts |
| [Approval security design](approve.md) | Trust anchors, signatures, enrollment, and failure behavior |
| [macOS client plan](macos-plan.md) | Decisions, phases, and checklists for the Mac app |
| [macOS client status](macos-status.md) | Build plan, current state, and what was verified against `fluxd` |
| [Marketing videos](../marketing/README.md) | Video source, phone captures, music timing, render, and mux |

Return to the [project README](../README.md).
