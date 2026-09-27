# Flux

Connect your Omarchy desktop to an Android phone or a Mac over your local network, or through Tailscale when you are away.
Share files, clipboard text, and clipboard images, read phone notifications, control media, and use your phone as a camera or microphone.

Flux includes a CLI, a background daemon, a native Qt window, an Omarchy shell plugin, a native Android app, and a native macOS app.
The desktop opens the network connections, so the default Omarchy firewall needs no new inbound rule.


https://github.com/user-attachments/assets/4b8445fe-6734-4100-b200-92f57e1b353a


**[Install locally](docs/install.md)** · **[Set up Android](docs/android.md)** · **[Set up macOS](docs/macos.md)** · **[Read the docs](docs/README.md)** · **[Use with agents](docs/agents.md)**

## What you can do

| Task | Guide |
| --- | --- |
| Send files, clipboard text and images, and links between devices | [Everyday use](docs/features.md) |
| Read notifications, send SMS, control media, and run desktop commands from your phone | [CLI reference](docs/cli.md) |
| Sync Do Not Disturb and pause media during calls | [Phone integration](docs/features.md#calls) |
| Scan text, send photos, and use the phone as a webcam or microphone | [Camera and streams](docs/camera.md) |
| Show the phone screen in a desktop window | [Screen mirror](docs/camera.md#screen-mirror) |
| Use the phone as a touchpad and keyboard | [Touchpad and keyboard](docs/remote-input.md) |
| Approve sudo with the phone's fingerprint sensor | [Fingerprint approval](docs/approvals.md) |
| Reach your phone away from home through Tailscale | [Connect through Tailscale](docs/tailscale.md) |
| See herdr coding agents on the phone, read their output, and answer them | [herdr agents](docs/herdr.md) |

Flux for Android requires Android 10 or later.
Flux for Android is the supported phone app.

Flux for macOS requires macOS 14 or later.
It connects a Mac in the place of a phone and offers the features that macOS allows.
See [Flux for macOS](docs/macos.md) for the feature list.

## Clone and install

On Omarchy or Arch Linux, install the build tools:

```sh
sudo pacman -Syu --needed base-devel git go cmake ninja
```

Clone this repository and setup:

```sh
git clone https://github.com/bjarneo/flux.git
cd flux/dist/arch
makepkg -si
flux-cli setup
flux-cli doctor
flux-cli open
```

The package includes the Qt app, CLI, daemon, shell plugin, approval helper, desktop entry, icons, and system files.
Run `flux-cli setup` as your desktop user after installation.
The short name `flux` also works when no other program, such as `fluxcd`, uses that name.

The [install guide](docs/install.md) covers dependencies, source builds, user-only installation, updates, and removal.

## Connect your phone

1. [Install Flux for Android](docs/android.md).
2. Connect the phone and desktop to the same local network.
3. Open the desktop window with `flux-cli open`.
4. Select **+ Pair new device**.
5. Compare the 8-character verification key on both screens.
6. Accept the matching request on the phone.

You can also start the pair request from a terminal:

```sh
flux-cli pair "Pixel 8"
```

To connect a Mac, build the app and follow [Pair a Mac](docs/macos.md#pair-a-mac).

## Use it from your terminal

```sh
flux-cli status
flux-cli send "$HOME/Downloads/report.txt"
flux-cli clip
flux-cli url https://omarchy.org
flux-cli ring
flux-cli notify --run -- make test
```

To select one of multiple connected phones, add `--device`:

```sh
flux-cli --device "Pixel 8" send "$HOME/Downloads/report.txt"
```

See the [CLI reference](docs/cli.md) for commands and script examples.

## Build and release

```sh
make build test vet
make android
```

GitHub Actions builds the complete Arch package and Android APKs for pull requests and the `main` branch.
Stable version tags produce a signed APK, an Arch package, an AUR recipe, and checksums.
The optional AUR job publishes the tested recipe after the GitHub release succeeds.

On a Mac with Xcode and XcodeGen, test, build, and install the macOS app:

```sh
make test-macos macos
make install-macos
```

GitHub Actions does not build the macOS app.

See [development](docs/development.md) for local checks and [releases](docs/releasing.md) for keys, secrets, tags, and artifacts.

## Documentation

- [Install and update](docs/install.md)
- [Android build and setup](docs/android.md)
- [macOS build and setup](docs/macos.md)
- [CLI reference](docs/cli.md)
- [Configuration and data paths](docs/configuration.md)
- [Everyday use](docs/features.md)
- [Camera, microphone, and screen](docs/camera.md)
- [Omarchy shell integration](docs/omarchy.md)
- [Troubleshoot Flux](docs/troubleshooting.md)
- [Architecture and IPC](docs/architecture.md)
- [Agent skill](docs/agents.md)

The [documentation index](docs/README.md) lists all topics.
