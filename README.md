# Flux

Connect your Omarchy desktop and Android phone over your local network.
Share files and clipboard text, read phone notifications, control media, and use your phone as a camera or microphone.

Flux includes a CLI, a background daemon, a native Qt window, an Omarchy shell plugin, and a native Android app.
The desktop opens the network connections, so the default Omarchy firewall needs no new inbound rule.

https://github.com/user-attachments/assets/fcd223a6-af92-485f-a8af-4165906afa30


**[Install locally](docs/install.md)** · **[Set up Android](docs/android.md)** · **[Read the docs](docs/README.md)** · **[Use with agents](docs/agents.md)**

## What you can do

| Task | Guide |
| --- | --- |
| Send files, clipboard text, and links between devices | [Everyday use](docs/features.md) |
| Read notifications, send SMS, control media, and run desktop commands from your phone | [CLI reference](docs/cli.md) |
| Sync Do Not Disturb and pause media during calls | [Phone integration](docs/features.md#calls) |
| Scan text, send photos, and use the phone as a webcam or microphone | [Camera and streams](docs/camera.md) |
| Show the phone screen in a desktop window | [Screen mirror](docs/camera.md#screen-mirror) |
| Approve sudo with the phone's fingerprint sensor | [Fingerprint approval](docs/approvals.md) |

Flux for Android requires Android 10 or later.
Flux for Android is the supported phone app.

## Clone and install

On Omarchy or Arch Linux, install the build tools:

```sh
sudo pacman -Syu --needed base-devel git go cmake ninja
```

Replace `OWNER` with the GitHub owner of this repository:

```sh
git clone https://github.com/OWNER/omarchy-flux.git
cd omarchy-flux/dist/arch
makepkg -si
flux setup
flux doctor
flux open
```

The package includes the Qt app, CLI, daemon, shell plugin, approval helper, desktop entry, icons, and system files.
Run `flux setup` as your desktop user after installation.

The [install guide](docs/install.md) covers dependencies, source builds, user-only installation, updates, and removal.

## Connect your phone

1. [Install Flux for Android](docs/android.md).
2. Connect the phone and desktop to the same local network.
3. Open the desktop window with `flux open`.
4. Select **+ Pair new device**.
5. Compare the 8-character verification key on both screens.
6. Accept the matching request on the phone.

You can also start the pair request from a terminal:

```sh
flux pair "Pixel 8"
```

## Use it from your terminal

```sh
flux status
flux send "$HOME/Downloads/report.txt"
flux clip
flux url https://omarchy.org
flux ring
flux media play-pause
flux notify --run -- make test
```

To select one of multiple connected phones, add `--device`:

```sh
flux --device "Pixel 8" send "$HOME/Downloads/report.txt"
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

See [development](docs/development.md) for local checks and [releases](docs/releasing.md) for keys, secrets, tags, and artifacts.

## Documentation

- [Install and update](docs/install.md)
- [Android build and setup](docs/android.md)
- [CLI reference](docs/cli.md)
- [Configuration and data paths](docs/configuration.md)
- [Everyday use](docs/features.md)
- [Camera, microphone, and screen](docs/camera.md)
- [Omarchy shell integration](docs/omarchy.md)
- [Troubleshoot Flux](docs/troubleshooting.md)
- [Architecture and IPC](docs/architecture.md)
- [Agent skill](docs/agents.md)

The [documentation index](docs/README.md) lists all topics.
