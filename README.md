# Flux

Connect your Omarchy desktop to an Android phone, an iPhone, or a Mac over your local network, or through Tailscale when you are away.
Share files, clipboard text, and clipboard images, read phone notifications, control media, and use your phone as a camera or microphone.

Flux includes a CLI, a background daemon, a native Qt window, an Omarchy shell plugin, a native Android app, a native iOS app, and a native macOS app.
`fluxd` listens on 1 TCP port from 12100 to 12108 and on UDP port 12100, and it also opens the connections to the devices itself.
So Flux works with the default Omarchy firewall, which blocks inbound traffic, and needs no new inbound rule.
See [security](docs/security.md) for what a paired device can do and which settings limit it.


https://github.com/user-attachments/assets/4b8445fe-6734-4100-b200-92f57e1b353a


**[Install locally](docs/install.md)** · **[Set up Android](docs/android.md)** · **[Set up iOS](docs/ios.md)** · **[Set up macOS](docs/macos.md)** · **[Read the docs](docs/README.md)** · **[Use with agents](docs/agents.md)**

## What you can do

| Task | Guide |
| --- | --- |
| Send files, clipboard text and images, and links between devices | [Everyday use](docs/features.md) |
| Queue files offline, send folder archives, and save clipboard snippets | [Workflow controls](docs/workflows.md) |
| Set device access, notification rules, and local automation | [Workflow controls](docs/workflows.md#per-device-access) |
| Read notifications, send SMS, control media, and run desktop commands from your phone | [CLI reference](docs/cli.md) |
| Sync Do Not Disturb and pause media during calls | [Phone integration](docs/features.md#calls) |
| Scan text, send photos, and use the phone as a webcam or microphone | [Camera and streams](docs/camera.md) |
| Show the phone screen in a desktop window | [Screen mirror](docs/camera.md#screen-mirror) |
| Use the phone or the Mac as a touchpad and keyboard | [Touchpad and keyboard](docs/remote-input.md) |
| Show and control the computer screen on the phone or the Mac | [Remote desktop](docs/remote-desktop.md) |
| Approve sudo with the phone's fingerprint sensor | [Fingerprint approval](docs/approvals.md) |
| Reach your phone away from home through Tailscale | [Connect through Tailscale](docs/tailscale.md) |
| See herdr coding agents on the phone or the Mac, read their output, and answer them | [herdr agents](docs/herdr.md) |
| Update Flux on the computer and send the new app to the phone | [Update](docs/install.md#update) |

Flux for Android requires Android 10 or later.
Flux for Android is the supported phone app.

Flux for iOS requires iOS 17 or later.
It connects an iPhone in the place of the Android phone and offers the features that iOS allows.
Install it with Xcode. See [Flux for iOS](docs/ios.md) for the feature list and the limits of iOS.

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
Flux checks for a new release once a day. To install it, run `flux-cli update`.

## Connect your phone

1. [Install Flux for Android](docs/android.md).
2. Connect the phone and desktop to the same local network.
3. Open the desktop window with `flux-cli open`.
4. Select **+ Pair new device**.
5. Compare the 16-character verification key on both screens, for example `5EE6 825F 974E D59A`.
6. Accept the matching request on the phone.
7. Select **Confirm** in the Flux window or in the notification on the desktop. The desktop pins the phone only after this step.

Each step waits at most 30 seconds.
Compare all 16 characters.
Earlier Flux apps show only 8 characters, so update Flux on each phone, iPhone, and Mac before you pair.

You can also start the pair request from a terminal:

```sh
flux-cli pair "Pixel 8"
```

After the phone accepts, `flux-cli pair` asks whether the phone shows the same key.
Type `y` to confirm.

To connect an iPhone, install the app with Xcode and follow [Pair an iPhone](docs/ios.md#pair-an-iphone).
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

GitHub Actions builds the complete Arch package, the Android APKs, and the macOS and iOS apps for each push to the `master` branch.
Pull requests run no build.
Stable version tags produce a signed APK, an Arch package, an AUR recipe, an ad hoc signed macOS app, an unsigned iOS app for sideload tools, and checksums.
The optional AUR job publishes the tested recipe after the GitHub release succeeds.

On a Mac with Xcode and XcodeGen, test, build, and install the macOS app:

```sh
make test-macos macos
make install-macos
```

To build the iOS app and run its tests in a simulator:

```sh
make ios test-ios
```

GitHub Actions also tests FluxKit, builds the macOS and iOS apps, and runs the iOS tests in a simulator.

See [development](docs/development.md) for local checks and [releases](docs/releasing.md) for keys, secrets, tags, and artifacts.

## Documentation

- [Install and update](docs/install.md)
- [Android build and setup](docs/android.md)
- [iOS build and setup](docs/ios.md)
- [macOS build and setup](docs/macos.md)
- [CLI reference](docs/cli.md)
- [Configuration and data paths](docs/configuration.md)
- [Security and paired devices](docs/security.md)
- [Everyday use](docs/features.md)
- [Camera, microphone, and screen](docs/camera.md)
- [Omarchy shell integration](docs/omarchy.md)
- [Troubleshoot Flux](docs/troubleshooting.md)
- [Architecture and IPC](docs/architecture.md)
- [Agent skill](docs/agents.md)

The [documentation index](docs/README.md) lists all topics.
