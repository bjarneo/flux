---
name: omarchy-flux
description: Use, install, diagnose, develop, and release Omarchy Flux. Use this skill for the flux-cli command, fluxd, Flux for Android, Flux for iOS, Flux for macOS, phone, iPhone, and Mac pairing, connections through Tailscale, file or clipboard transfers, phone notifications, webcam or microphone streams, screen mirror, fingerprint approval, herdr agents on the phone, the Flux Qt app, the Flux Omarchy plugin, AUR packages, and Flux APK workflows. Scope this skill to Flux tasks, not general Android or Omarchy configuration.
---

# Omarchy Flux

Flux connects an Omarchy desktop to Flux for Android, Flux for iOS, or Flux for macOS on the same local network.
A paired device can also connect through Tailscale with an extra address.
The desktop includes the `flux-cli` command, `fluxd`, a Qt app, and an Omarchy shell plugin.
`flux` is a short name for `flux-cli` when no other program uses it.
The `fluxcd` package also installs a `flux` command, so always run `flux-cli`.

## Choose the task

| Task | Reference |
| --- | --- |
| Pair a phone, use the CLI, change settings, or diagnose a connection | [Runtime reference](references/runtime.md) |
| Build, install, test, package, or release Flux | [Build and release reference](references/build-release.md) |
| Change the source | Read the relevant files in the repository and the topic in `docs/README.md`. |
| Change fingerprint approval | Read `docs/approve.md` before you edit the approval code. |

Find the repository from the working directory or ask for its path.
Do not assume that an installed skill lives inside the repository.
Run repository commands from its root unless the reference names another directory.

## Start with the current state

For an installed Flux system, run:

```sh
flux-cli version
flux-cli status --json
flux-cli doctor
```

For source work, run:

```sh
git status --short
git remote -v
```

Preserve existing changes.
Use the configured Git remote for clone and release URLs.
If no remote exists, ask for the repository URL before a remote operation.

`flux-cli setup` prints failures but can still return zero.
Inspect its output and confirm the result with `flux-cli doctor` and `flux-cli status --json`.

## Operate Flux

1. Find the requested phone in `flux-cli status --json`.
2. Select its device ID when more than one phone is present.
3. Run the requested command from the runtime reference.
4. Check the result from the command or the next state event.

Example:

```sh
flux-cli status --json
flux-cli --device "Pixel 8" send "$HOME/Downloads/report.txt"
flux-cli status --json
```

The send command starts a transfer.
Check `transfers` in the state before you report that the file arrived.

Use `flux-cli status --json` for scripts.
Use `flux-cli watch` only when the task needs a continuous event stream.
Stop the watch process when the task ends.

`flux-cli` without arguments opens a window.
Use an explicit command for diagnostics.

## Pair and connect

1. Check that both devices use the same local network.
2. Open Flux for Android.
3. Run `flux-cli discover`.
4. Run `flux-cli pair "Pixel 8"` with the device name from the state.
5. Ask the user to compare the verification key on both devices.
6. Let the user accept the matching request on the phone.
7. Confirm that the device is paired and online.

The desktop discovers phones through Avahi and mDNS.
The desktop opens connections to the phone, including reverse payload tunnels.
A missing connection does not require a new desktop firewall rule by default.
Check the daemon, Avahi, Wi-Fi isolation, and phone state first.

Discovery and pairing need the local network.
To reach a paired phone away from that network, add its Tailscale name as an extra address:

```sh
tailscale status
flux-cli --device "Pixel 8" addresses add pixel-8
flux-cli addresses
```

Use the device name from `flux-cli status --json` and the host name from `tailscale status`.
Read `docs/tailscale.md` for the dial order, limits, and checks.

## Respect the requested operation

SMS, notifications, clipboard transfers, and file transfers affect another device.
Use the destination and content that the user requests.
Keep private keys, notification contents, phone numbers, and signing secrets out of reports unless the task needs them.

Pairing needs the user's key comparison.
Fingerprint enrollment needs the user's fingerprint and key comparison.
Do not claim that these physical steps succeeded without evidence.

Use `flux-cli commands add` for desktop commands that the phone can run.
`flux-cli run ID` runs a configured command on the desktop, not on the phone.
Do not expand a command's permissions beyond the user's request.

## Install locally

Prefer the Arch package for a complete install on Omarchy.
It includes the Qt app, CLI, daemon, plugin assets, PAM helper, desktop entry, icons, and system files.

From the repository root:

```sh
make build
sudo make install
flux-cli setup
flux-cli doctor
```

The root install performs system setup.
Run `flux-cli setup` as the desktop user.
Use `docs/install.md` for dependencies, the pacman package, and the user-only install.

To install the latest release, run `flux-cli update`.
It asks for the sudo password, so run it in a terminal that the user sees.
After an update, `fluxd.service` restarts into the new binary when no transfer or stream runs.
Confirm the running version:

```sh
flux-cli version
```

`fluxd` checks GitHub once a day for a new release.
`check_updates = false` in `config.toml` turns the check off.

Use `docs/install.md` for the update command of each install method.

For a preview without installation:

```sh
make build
./bin/flux-cli setup --dry-run
```

## Develop the correct component

| Component | Source |
| --- | --- |
| CLI | `cmd/flux/` |
| Daemon entry point | `cmd/fluxd/` |
| Device state and IPC methods | `internal/core/` |
| Network and protocol | `internal/lan/`, `internal/proto/` |
| Configuration and trust | `internal/config/` |
| Desktop integration | `internal/desktop/` |
| Shared Qt views | `gui/qml/` |
| Qt host | `gui/app/` |
| Omarchy shell host | `gui/omarchy/` |
| Android app | `android/app/src/main/java/org/omarchy/flux/` |
| macOS app | `macos/Sources/FluxKit/`, `macos/App/` |
| iOS app | `ios/App/`, `ios/ShareExtension/`, and the shared `macos/Sources/FluxKit/` |
| Fingerprint approval | `internal/approve/`, `cmd/flux-approve/`, Android `core/Approve*` |
| herdr agents | `internal/herdr/`, `internal/core/herdr.go`, Android `core/Herdr.kt` |
| Package and system install | `dist/`, `Makefile` |

Keep network state in `fluxd`.
The CLI and both desktop hosts use its Unix socket.
Keep shared QML free of Quickshell imports.
Update both host adapters when you change their shared backend contract.
Test wire changes on the Go, Kotlin, and Swift implementations.

Use the existing tests for the component you change.
Run these checks for a complete build change:

```sh
make build test vet
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease --no-daemon
```

On a Mac with Xcode and XcodeGen, run `make test-macos macos` and `make ios test-ios` from the repository root.
Use `docs/macos.md` for the macOS app and `docs/ios.md` for the iOS app.

Use `docs/development.md` for isolated daemon tests and UI snapshots.
Do not run a second development daemon against the user's active socket or trust store.

## Release

Read the build and release reference before you change workflows or prepare a tag.
The workflows support stable tags in `vMAJOR.MINOR.PATCH` form.
The release workflow checks out that tag for both desktop and Android builds.

Keep one Android release key across releases.
The workflow requires signing secrets and refuses a debug-signed APK.
The AUR recipe includes a source checksum and the install hook.
The AUR job uses the tested recipe only after the GitHub release succeeds.

Do not create a tag, push, publish, or change repository secrets unless the user requests that action.
For preparation work, report the required setup and the commands without running the remote action.

## Report the result

Include:

- The completed operation or changed files.
- The selected device or release tag when relevant.
- The checks that passed.
- Any check that failed or could not run.
- The next required user action, such as a phone prompt or a release secret.

Distinguish a successful local build from a published release.
Distinguish a queued transfer from a completed transfer.
