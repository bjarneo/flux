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

The package does not start `fluxd` for the accounts on the computer.
Each desktop user who wants Flux runs `flux-cli setup` once.
So another account does not announce this computer on the network.

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

Download the `.pkg.tar.zst` package, `SHA256SUMS`, and `SHA256SUMS.sig` from the same GitHub release.
[Check the release](#check-a-release), then install the package from the download directory:

```sh
sudo pacman -U ./omarchy-flux-0.1.0-1-x86_64.pkg.tar.zst
flux-cli setup
```

Replace the example filename with the downloaded version.

## Check a release

The checksum in `SHA256SUMS` finds a damaged download.
It does not show who made the release, because the same release gives the file and its checksum.
The signature in `SHA256SUMS.sig` shows that the Flux release workflow made `SHA256SUMS`.

To check the signature, you need the public release key: the value of `PublicKey` in [`internal/release/sign.go`](../internal/release/sign.go).
While that value is empty, the releases have no key to check.
From the download directory, replace `KEY` with the public key and run:

```sh
printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' KEY > flux-release.pem
base64 -d SHA256SUMS.sig > SHA256SUMS.sig.bin
openssl pkeyutl -verify -pubin -inkey flux-release.pem -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig.bin
```

OpenSSL prints `Signature Verified Successfully`.
Then check the downloads against `SHA256SUMS`:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

Android installs an update only with the certificate of the installed app.
For a first install of `flux-android-VERSION.apk`, compare its certificate with the Flux release certificate:

```sh
apksigner verify --print-certs flux-android-0.1.0.apk
```

The line `Signer #1 certificate SHA-256 digest` must show:

```text
a9af3fb3886f2c7cf4e2c9d93824aed23314d4e4fb36a364373064aa11700884
```

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
If no system service exists, `flux-cli setup` writes `~/.config/systemd/user/fluxd.service` for the daemon beside the installed CLI.
systemd uses this user unit before the unit of a package.
After you install the package, run `flux-cli setup` again. It removes the user unit that it wrote.
`flux-cli doctor` reports a user unit that hides the unit of the package.
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
| `dist/post-install.sh` | Reloads udev. Loads the optional webcam module when no existing configuration controls it. Restarts a running `fluxd` of an earlier version, which does not restart by itself. It does not enable the user service for the accounts on the computer. |
| `flux-cli setup` | Enables and starts the user service for the user who runs it. Removes a user unit that an earlier `flux-cli setup` of a checkout wrote, when a package unit exists. Copies and enables the shell plugin when the shell is available. |
| `flux-cli setup --dry-run` | Prints the user setup actions without applying them. |
| Each start of `fluxd` | Updates the files of an added plugin to the plugin of the same install. |
| `flux-cli open` | Starts the user service when no `fluxd` answers, except after `flux-cli off`. |

Setup reports missing system parts and their install commands.
It returns 1 when the service step or the plugin step fails.
A missing system part does not change the exit code, so read the output.
Use `flux-cli doctor` to verify the result.

An earlier package enabled `fluxd` for every account on the computer, and an upgrade keeps that.
To start `fluxd` only for the users who ran `flux-cli setup`, remove the global link once:

```sh
sudo systemctl --global disable fluxd.service
```

Then run `flux-cli setup` as each desktop user who wants Flux.

Flux does not add a firewall rule or enable fingerprint approval during installation.
`fluxd` needs no inbound firewall rule. See [network ports](security.md#network-ports).

If Avahi is inactive, start it:

```sh
sudo systemctl enable --now avahi-daemon
```

## Update

An update replaces the files on disk.
Flux then moves the running parts to the new version:

| Part | After the update |
| --- | --- |
| `fluxd` | The service restarts into the new binary about 10 seconds after the install. It waits while a file transfer, a stream, or the remote desktop runs. It also waits for a Browse PC session, the send of the Android app, and a fingerprint approval. |
| Omarchy plugin | `fluxd` copies the new plugin files into `~/.config/omarchy/plugins/flux` when it starts. omarchy-shell then reloads the plugin. |
| Qt window | An open window shows **Flux was updated**. Select **Restart** to open the new version. |
| Phones | The phones connect again about 2 seconds after the restart. |

Only `fluxd.service` restarts by itself.
A `fluxd` that you started by hand logs the new version and keeps running.

### Update with flux-cli

To install the latest release, run:

```sh
flux-cli update
```

For a pacman package, `flux-cli update` does these steps:

1. It downloads `SHA256SUMS` and checks `SHA256SUMS.sig` with the public release key.
2. It downloads the release package into `~/.cache/flux/update`, which only your user can read, and checks it against `SHA256SUMS`.
3. `sudo` copies the package into a new folder that only root can read, checks the copy again, and runs `pacman -U` on the copy.

A `flux-cli` without a public release key skips the signature check in step 1 and says so.
When `SHA256SUMS` or the signature is missing or does not match, `flux-cli update` stops and installs nothing.
An upload of the release can be incomplete for a short time, so try again later.
When the release has no package for your architecture, `flux-cli update` runs `yay -S omarchy-flux`.
`flux-cli update` uses only the files at `https://github.com/bjarneo/flux/releases/download/TAG/`.
When GitHub gives a file of the release at another address, `flux-cli update` stops and does not run `yay`.
For a source install, it prints the commands for your checkout.

When a newer release exists, the window shows **Flux 0.7.0 is available**.
**Update** opens a terminal that runs `flux-cli update`.
**Later** hides the notice until the window opens again.
The daily [release check](configuration.md#release-check) finds the release.
To turn the check off, set `check_updates = false`.

### Check the versions

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

Download the new `.pkg.tar.zst` package, `SHA256SUMS`, and `SHA256SUMS.sig` from the same GitHub release.
[Check the release](#check-a-release), then install the package from the download directory:

```sh
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

Give the same `PREFIX` as for the install.
Only an install with `PREFIX=/usr` removes the fingerprint approval from the PAM files, because the PAM line names `/usr/lib/flux/flux-approve`.

For a user-only install, stop the service before you remove the binaries:

```sh
flux-cli off
systemctl --user disable --now fluxd
make uninstall-user
make uninstall-plugin
```

`make uninstall-user` also removes the `~/.config/systemd/user/fluxd.service` unit that `flux-cli setup` wrote for this install.
Without that step, the old unit hides the unit of a package that you install later.

The source removal targets leave user configuration and pairing identity in place.
See [configuration paths](configuration.md#data-paths) before you remove user data.

Continue with [Android setup](android.md) and [phone pairing](features.md#pair-a-phone).
To connect a Mac, continue with [Flux for macOS](macos.md).
