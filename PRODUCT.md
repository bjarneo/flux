# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Omarchy users: developers who run Arch Linux with Hyprland and the Omarchy setup. They work keyboard-first, in tiled windows, with a theme that they choose and change.
They often leave the desk while AI coding agents run in herdr terminals on the computer, and they come back to the phone when an agent waits for an answer.
At the desk, they move clipboard text, files, and photos between the phone and the computer.

## Product Purpose

Flux makes the phone and the Omarchy computer work as one.
With the phone, the user answers an agent that waits for input, approves `sudo` and polkit with a fingerprint, sends the clipboard and files, controls media and the desktop, and uses the phone as webcam, microphone, touchpad, and keyboard.
It works on the local network, and through Tailscale away from it.
Success means that the user acts on what needs them in seconds, from the phone, without walking back to the desk.

## Positioning

Flux is built for Omarchy itself, not as a generic phone-to-computer bridge.
It knows herdr agents and their prompts, the omarchy-shell bar and panel, Hyprland workspaces and key bindings, and the user's live Omarchy theme.
Fingerprint approval uses a key that only root on the computer can change, so a phone tap can stand in for a `sudo` password.
The protocol derives from KDE Connect version 8, but Flux speaks only to its own apps.

## Operating Context

- The desktop daemon `fluxd` owns device state and network work. `flux-cli`, a Qt window, and an Omarchy shell plugin talk to it.
- Flux for Android, Flux for iOS, and Flux for macOS are the device apps. Each is native to its OS and shares the protocol.
- Typical scenes: the phone in one hand away from the desk while an agent runs, the lock screen when an approval arrives, and the desk when the user moves clipboard text or files.
- The desktop window follows the active Omarchy theme from `colors.toml`.

## Capabilities and Constraints

- Android: Kotlin and Jetpack Compose, min SDK 29, target SDK 36, shipped as an APK from GitHub releases and through `fluxd`, not through Google Play.
- iOS and macOS: SwiftUI on the shared FluxKit package. This machine has no Swift toolchain, so Swift changes compile first in CI on `master`.
- Pairing compares a 16-character key on both screens. A pairing that the computer starts needs a confirmation on the computer.
- Docs, UI text, and code comments follow ASD-STE100 Simplified Technical English.
- Terminology: computer (not PC), phone, pair, unpair, agent, terminal, pane.

## Brand Commitments

- The name is Flux, and its mark is the square ring in `android/app/src/main/res/drawable/ic_launcher_foreground.xml`.
- Flux looks like the user's Omarchy: it follows the active Omarchy theme, with Tokyo Night as the default.
- The pairing sheet and the fingerprint approval screen stay as they are.

## Evidence on Hand

- Screenshots of the desktop window in `snapshots/` from `make snapshot`, and of the Android app from `android/tools/shot.sh`.
- Feature videos in `marketing/`.
- There are no published user counts, testimonials, reviews, or benchmarks. Do not invent them.

## Product Principles

1. What needs the user comes first: a waiting agent, an approval, or a pair request outranks everything else.
2. Flux looks like the user's own Omarchy setup, not like a separate app.
3. Security moments get proportionate friction: the full key comparison, the fingerprint, and the phone lock before remote control.
4. Plain words: short sentences that name the action and the result.
5. Flux works one-handed and from the lock screen.

## Accessibility & Inclusion

- WCAG 2.2 AA contrast in every theme: 4.5:1 for body text, 3:1 for large text and controls.
- Touch targets of at least 48 by 48 dp.
- Correct TalkBack roles and states, for example switches that announce on and off.
- Layouts that hold at 200% font scale.
