# Install Flux

[Documentation index](README.md)

The desktop targets Omarchy and Arch Linux with a Wayland session and systemd user services.
The Android app requires Android 10 or later.
The macOS app requires macOS 14 or later.

## Requirements

| Component | Requirement |
| --- | --- |
| Go | 1.27.1 or later, as specified in `go.mod` |
| Qt | 6.5 or later with Qt Quick, SVG, and Wayland support |
| Native build | CMake 3.21 or later, Ninja, and a C++20 compiler |
| Desktop services | D-Bus, systemd user services, Avahi, and PipeWire |
| Clipboard | `wl-clipboard` |
| Phone keyboard | `wtype`, which Omarchy installs |
| Remote desktop | `gpu-screen-recorder`, which Omarchy installs |
| Icons | A Nerd Font that provides `ttf-font-nerd` |
| Android install with `adb` | `android-tools`, as in [Android requirements](android.md#requirements) |
| Android build | JDK 21, SDK platform 36, and Build Tools 36.0.0 |
| macOS build | Xcode and XcodeGen on macOS 14 or later |

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
   flux-cli setup
   ```

4. Check the install:

   ```sh
   flux-cli doctor
   flux-cli status --json
   flux-cli open
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
flux-cli setup
flux-cli doctor
```

The workflow does not establish that the package already exists in AUR.
See [release setup](releasing.md) for the first publication.

## Install a release package

Download the `.pkg.tar.zst` package and `SHA256SUMS` from the same GitHub release.
From the download directory, verify and install them:

```sh
sha256sum --check --ignore-missing SHA256SUMS
sudo pacman -U ./omarchy-flux-0.1.0-1-x86_64.pkg.tar.zst
flux-cli setup
```

Replace the example filename with the downloaded version.

## Build and install directly

From the repository root, install the full build and runtime dependencies:

```sh
sudo pacman -Syu --needed base-devel git go cmake ninja \
  qt6-base qt6-declarative qt6-svg qt6-wayland ttf-jetbrains-mono-nerd \
  wl-clipboard pipewire avahi xdg-utils wtype
```

Build before you run the root install:

```sh
make build
sudo make install
flux-cli setup
flux-cli doctor
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
flux-cli setup
flux-cli doctor
```

The binaries go into `~/.local/bin`.
The plugin files go into `~/.local/share/flux/omarchy-plugin`.
The desktop entry and icons go into `~/.local/share`.
If no system service exists, `flux-cli setup` creates a user service for the daemon beside the installed CLI.
An existing system package takes precedence for the service path.
`flux-cli setup` adds the plugin to omarchy-shell.
To skip the plugin, run `flux-cli setup --no-plugin`.

The user-only install omits the root approval helper and webcam system setup.
Use the complete package or root install for those features.

## The command name

The CLI is `flux-cli`.
The `fluxcd` package already owns `/usr/bin/flux`, so Flux does not install a file there.

The Arch package and `sudo make install` add the short name `flux`:

- `/usr/lib/flux/bin/flux` is a link to `/usr/bin/flux-cli`.
- `/etc/profile.d/flux-path.sh` adds `/usr/lib/flux/bin` to the end of `PATH`.

The shell finds `/usr/bin/flux` first.
Without `fluxcd`, `flux` runs Flux.
With `fluxcd`, `flux` runs fluxcd, and `flux-cli` runs Flux.
The short name works after the next login.
`sudo` can reset `PATH`, so use `flux-cli` with `sudo`.

To see which program `flux` runs, use:

```sh
flux-cli doctor
```

`make install-user` adds the link `~/.local/bin/flux` only when no other `flux` command exists.
`~/.local/bin` comes before `/usr/bin` in `PATH`.
If you install `fluxcd` later, remove the link:

```sh
rm ~/.local/bin/flux
```

## What setup changes

| Step | Effect |
| --- | --- |
| Package install or `sudo make install` | Installs the service, udev rule, desktop files, binaries, helper, plugin assets, and the [short name](#the-command-name) `flux`. |
| `dist/post-install.sh` | Reloads udev and enables the user service globally. Loads the optional webcam module when no existing configuration controls it. Restarts a running `fluxd` of an earlier version, which does not restart by itself. |
| `flux-cli setup` | Enables and starts the user service. Copies and enables the shell plugin when the shell is available. |
| `flux-cli setup --dry-run` | Prints the user setup actions without applying them. |
| Each start of `fluxd` | Updates the files of an added plugin to the plugin of the same install. |
| `flux-cli open` | Starts the user service when no `fluxd` answers, except after `flux-cli off`. |

Setup reports missing system parts and their install commands.
Inspect the output because setup can report an error without a nonzero exit code.
Use `flux-cli doctor` to verify the result.

Flux does not add a firewall rule or enable fingerprint approval during installation.

If Avahi is inactive, start it:

```sh
sudo systemctl enable --now avahi-daemon
```

## Update

An update replaces the files on disk.
Flux then moves the running parts to the new version:

| Part | After the update |
| --- | --- |
| `fluxd` | The service restarts into the new binary about 10 seconds after the install. It waits while a file transfer, a stream, or a fingerprint approval runs. |
| Omarchy plugin | `fluxd` copies the new plugin files into `~/.config/omarchy/plugins/flux` when it starts. omarchy-shell then reloads the plugin. |
| Qt window | An open window shows **Flux was updated**. Select **Restart** to open the new version. |
| Phones | The phones connect again about 2 seconds after the restart. |

Only `fluxd.service` restarts by itself.
A `fluxd` that you started by hand logs the new version and keeps running.

To check the versions after an update, run:

```sh
flux-cli version
```

The output names both programs:

```text
flux-cli 0.7.0
fluxd 0.7.0
```

Versions of `fluxd` before this feature do not restart by themselves.
The pacman package and `sudo make install` restart such a `fluxd` at once.
After a user-only install, the output can say `fluxd runs an earlier version`.
Then restart the service once:

```sh
systemctl --user restart fluxd
```

### Update an AUR install

```sh
yay -S omarchy-flux
```

### Update a release package

Download the new `.pkg.tar.zst` package and `SHA256SUMS` from the same GitHub release.
From the download directory, run:

```sh
sha256sum --check --ignore-missing SHA256SUMS
sudo pacman -U ./omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst
```

### Update a checkout package

From the repository root:

```sh
git pull --ff-only
cd dist/arch
makepkg -si
```

### Update a direct source install

From the repository root:

```sh
git pull --ff-only
make build
sudo make install
```

### Update a user-only install

From the repository root:

```sh
git pull --ff-only
make build
make install-user
```

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
flux-cli off
systemctl --user disable --now fluxd
make uninstall-user
make uninstall-plugin
```

The source removal targets leave user configuration and pairing identity in place.
See [configuration paths](configuration.md#data-paths) before you remove user data.

Continue with [Android setup](android.md) and [phone pairing](features.md#pair-a-phone).
To connect a Mac, continue with [Flux for macOS](macos.md).
