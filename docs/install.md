# Install Flux

[Documentation index](README.md)

The desktop targets Omarchy and Arch Linux with a Wayland session and systemd user services.
The Android app requires Android 10 or later.

## Requirements

| Component | Requirement |
| --- | --- |
| Go | 1.27.1 or later, as specified in `go.mod` |
| Qt | 6.5 or later with Qt Quick, SVG, and Wayland support |
| Native build | CMake 3.21 or later, Ninja, and a C++20 compiler |
| Desktop services | D-Bus, systemd user services, Avahi, and PipeWire |
| Clipboard | `wl-clipboard` |
| Icons | A Nerd Font that provides `ttf-font-nerd` |
| Android build | JDK 21, SDK platform 36, and Build Tools 36.0.0 |

## Clone the repository

```sh
git clone https://github.com/bjarneo/flux.git
cd flux
```

## Install the Arch package from your checkout

This method gives pacman ownership of all desktop files.

1. Install the build tools:

   ```sh
   sudo pacman -Syu --needed base-devel git go cmake ninja
   ```

2. Build and install the package as a regular user:

   ```sh
   cd dist/arch
   makepkg -si
   ```

3. Set up Flux for your desktop user:

   ```sh
   flux setup
   ```

4. Check the install:

   ```sh
   flux doctor
   flux status --json
   flux open
   ```

`makepkg -s` installs missing package dependencies.
Select a Nerd Font provider if pacman asks for one.
The package builds the CLI, daemon, approval helper, Qt app, and shell plugin assets.

The package recipe supports `x86_64` and `aarch64` source builds.
GitHub Actions currently produces an `x86_64` binary package.

## Install from AUR

After the maintainer publishes `omarchy-flux` to AUR, install it with:

```sh
yay -S omarchy-flux
flux setup
flux doctor
```

The workflow does not establish that the package already exists in AUR.
See [release setup](releasing.md) for the first publication.

## Install a release package

Download the `.pkg.tar.zst` package and `SHA256SUMS` from the same GitHub release.
From the download directory, verify and install them:

```sh
sha256sum --check --ignore-missing SHA256SUMS
sudo pacman -U ./omarchy-flux-0.1.0-1-x86_64.pkg.tar.zst
flux setup
```

Replace the example filename with the downloaded version.

## Build and install directly

From the repository root, install the full build and runtime dependencies:

```sh
sudo pacman -Syu --needed base-devel git go cmake ninja \
  qt6-base qt6-declarative qt6-svg qt6-wayland ttf-jetbrains-mono-nerd \
  wl-clipboard pipewire sound-theme-freedesktop avahi xdg-utils
```

Build before you run the root install:

```sh
make build
sudo make install
flux setup
flux doctor
```

`make install` copies the existing build outputs.
Root does not need Go on its `PATH`.
This method installs into `/usr` and does not register a pacman package.

## Install for your user

From the repository root:

```sh
make build
make install-user
export PATH="$HOME/.local/bin:$PATH"
flux setup --no-plugin
flux doctor
```

The binaries go into `~/.local/bin`.
The desktop entry and icons go into `~/.local/share`.
If no system service exists, `flux setup` creates a user service for the daemon beside the installed CLI.
An existing system package takes precedence for the service path.

To add the Omarchy plugin from the checkout:

```sh
make install-plugin
omarchy-shell shell rescanPlugins
omarchy plugin enable flux --section right
```

The user-only install omits the root approval helper and webcam system setup.
Use the complete package or root install for those features.

## What setup changes

| Step | Effect |
| --- | --- |
| Package install or `sudo make install` | Installs the service, udev rule, desktop files, binaries, helper, and plugin assets. |
| `dist/post-install.sh` | Reloads udev and enables the user service globally. Loads the optional webcam module when no existing configuration controls it. |
| `flux setup` | Enables and starts the user service. Copies and enables the shell plugin when the shell is available. |
| `flux setup --dry-run` | Prints the user setup actions without applying them. |

Setup reports missing system parts and their install commands.
Inspect the output because setup can report an error without a nonzero exit code.
Use `flux doctor` to verify the result.

Flux does not add a firewall rule or enable fingerprint approval during installation.

If Avahi is inactive, start it:

```sh
sudo systemctl enable --now avahi-daemon
```

## Update

For a checkout package, update and rebuild from the repository root:

```sh
git pull --ff-only
cd dist/arch
makepkg -si
flux setup
systemctl --user restart fluxd
```

`flux setup` refreshes the user's plugin copy.
Close and reopen the Qt window after an update.

## Remove

For a pacman-managed install:

```sh
sudo pacman -R omarchy-flux
```

For a direct source install, run from the checkout:

```sh
sudo make uninstall
```

For a user-only install, stop the service before you remove the binaries:

```sh
flux off
systemctl --user disable --now fluxd
make uninstall-user
make uninstall-plugin
```

The source removal targets leave user configuration and pairing identity in place.
See [configuration paths](configuration.md#data-paths) before you remove user data.

Continue with [Android setup](android.md) and [phone pairing](features.md#pair-a-phone).
