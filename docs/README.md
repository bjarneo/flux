# Flux documentation

Flux connects an Omarchy desktop to Flux for Android, Flux for iOS, or Flux for macOS on the same local network.
A paired device can also connect through [Tailscale](tailscale.md) away from that network.

## Start here

1. [Clone and install Flux](install.md).
2. [Install the Android app](android.md), [install the iPhone app](ios.md#install-on-an-iphone), or [build the Mac app](macos.md#build-and-run).
3. [Pair your phone](features.md#pair-a-phone), [pair your iPhone](ios.md#pair-an-iphone), or [pair your Mac](macos.md#pair-a-mac).
4. [Use the CLI](cli.md) or open the window with `flux-cli open`.

## Use Flux

| Guide | Topics |
| --- | --- |
| [Installation](install.md) | Dependencies, Arch package, source install, user-only install, updates, and removal |
| [Android](android.md) | Requirements, `adb`, APK installation, local builds, SDK setup, tests, and screenshots |
| [Android setup and Play Protect](android-setup.md) | Play Protect blocks, installs with `adb`, restricted settings, the service, the network, and permissions |
| [iOS](ios.md) | iPhone app build, installation with Xcode, pairing, features, limits, permissions, and local tests |
| [macOS](macos.md) | Mac app build, pairing, features, permissions, and local tests |
| [CLI](cli.md) | Commands, device selection, JSON state, and notifications from scripts |
| [Everyday use](features.md) | Pair, share, clipboard images, SMS, media, calls, Do Not Disturb, automatic photo transfers, and dictation in text fields |
| [Workflow controls](workflows.md) | Offline outbox, resumable transfers, folder archives, saved snippets, device access, notification rules, automation, agent review, and remote audio |
| [Tailscale](tailscale.md) | Extra addresses, links away from the local network, other VPNs, and connection checks |
| [Camera and streams](camera.md) | Scans, photos, webcam settings, microphone, and screen mirror |
| [Configuration](configuration.md) | TOML settings, data paths, environment variables, and service control |
| [Security](security.md) | What a paired device can do, the settings that limit it, network ports, pairing checks, and unpair |
| [Omarchy integration](omarchy.md) | Shell plugin, bar item, window host, theme, the theme packet for the phone, and desktop integration |
| [Fingerprint approval](approvals.md) | Enrollment on the phone, the iPhone, or the Mac, PAM services, lock screens, timeout, and removal |
| [herdr agents](herdr.md) | Agent status, colored output, notifications, replies, new agents, and terminals on the phone and the Mac |
| [Touchpad and keyboard](remote-input.md) | Remote input from the phone or the Mac, gestures, typing, slides, and the wire format |
| [Remote desktop](remote-desktop.md) | The computer screen on the phone or the Mac, touches, the mouse, the Omarchy panel, dictation, monitors, and the stream format |
| [Troubleshooting](troubleshooting.md) | Service, discovery, plugin, media, Android, and build failures |

## Develop and automate

| Guide | Topics |
| --- | --- |
| [Architecture](architecture.md) | Components, source layout, and network direction |
| [IPC](ipc.md) | Unix socket, request format, responses, and events |
| [Shared QML](qml.md) | Desktop backend contract, icons, themes, and snapshots |
| [Android design system](../DESIGN.md) | Theme roles, the contrast guard, type, the Inbox master and stack, components, and rules |
| [Development](development.md) | Component checks, isolated daemons, and local iteration |
| [Releases](releasing.md) | GitHub workflows, AUR publication, APK signatures, and secrets |
| [Agent skill](agents.md) | Skill installation, scope, and example prompts |
| [Approval security design](approve.md) | Trust anchors, signatures, enrollment, and failure behavior |
| [iOS client plan](ios-plan.md) | Decisions, phases, limits, and checklists for the iPhone app |
| [iOS on the App Store](ios-app-store.md) | Store text, keywords, screenshots, review notes, privacy, and open items for the iPhone app |
| [macOS client plan](macos-plan.md) | Decisions, phases, and checklists for the Mac app |
| [macOS client status](macos-status.md) | Build plan, current state, and what was verified against `fluxd` |
| [Marketing videos](../marketing/README.md) | Video source, phone captures, music timing, render, and mux |
| [Website](../site/README.md) | The page on GitHub Pages, its images, and how to make them again |

Return to the [project README](../README.md).
