# Flux

Flux connects an Omarchy computer to your phone on the same network. Share
files and the clipboard, read phone notifications, control media, send text
messages, run desktop commands from the phone, and use the phone camera as
a scanner or a webcam.

Flux for Android, in `android/`, is the phone app.

Flux needs no open port. `fluxd` finds phones with mDNS, which the default
Omarchy firewall allows, and it opens every connection itself.

## Parts

| Part | Path | Job |
| --- | --- | --- |
| `fluxd` | `cmd/fluxd` | The daemon. It owns the network links and all device state. |
| `flux` | `cmd/flux` | The CLI. `flux open` opens the window. |
| Shared views | `gui/qml` | The 8 screens in Qt Quick, used by both front ends |
| `flux` plugin | `gui/omarchy` | The window and a bar item inside `omarchy-shell` |
| `flux-gui` | `gui/app` | The same window as a Qt6 C++ app |
| Flux for Android | `android/` | A native Kotlin app for the phone |

## Install

Flux needs no manual system setup. The install does the system part as
root, and `flux setup` does the part for your user.

### Arch package

To build and install the package from this checkout, run:

```sh
cd dist/arch
makepkg -si
flux setup
```

`makepkg` needs Go 1.27, CMake, and Ninja. Omarchy installs the other
dependencies, including the Nerd Font that the window uses for its icons.

### From source

```sh
make
sudo make install
flux setup
```

### What the install does

| Part | Runs as | What it does |
| --- | --- | --- |
| `post-install.sh` | root, from pacman or `sudo make install` | Reloads udev and applies the rule for `/dev/v4l2loopback`. Loads `v4l2loopback` with no devices when nothing else configures it, and keeps existing camera settings. Enables `fluxd.service` for all users. |
| `flux setup` | your user | Enables and starts `fluxd.service`. Copies the `omarchy-shell` plugin to `~/.config/omarchy/plugins/flux`, rescans, and adds the bar item. Reports each missing system part with the command that adds it. |

The install opens no firewall port, because Flux needs none. Run
`flux setup --dry-run` to see the steps first, and `flux doctor` to check
the setup later.

To remove Flux, run `sudo pacman -R omarchy-flux` or `sudo make uninstall`.
Both undo the system part.

### The phone

Build Flux for Android and install it over USB:

```sh
make android
adb install android/app/build/outputs/apk/debug/app-debug.apk
```

## Pair a phone

1. Install Flux for Android on the phone.
2. Connect the phone to the same Wi-Fi network as the computer.
3. Open the window with `flux open`, and press `+ Pair new device`.
4. Select the phone, and compare the 8-character key on both screens.
5. Accept the request on the phone.

To pair from a terminal, run `flux pair "Pixel 8"`.

## CLI

```sh
flux status                 # this computer and the known devices
flux ring                   # ring the phone
flux send ~/report.pdf      # send files
flux clip                   # send the clipboard
flux url https://omarchy.org
flux sms +4712345678 "On my way"
flux media play-pause
flux notifications
flux commands add "Lock screen" omarchy-system-lock   # a command for the phone
flux commands               # list the commands, with their IDs
flux commands remove ID
flux watch                  # print each state change as JSON
```

When 2 or more paired devices are connected, add `--device NAME`.

## Routes through a closed firewall

| Need | Route |
| --- | --- |
| Find a phone | mDNS through Avahi |
| Link to the phone | `fluxd` connects to the phone |
| Files, icons, and album art from the phone | `fluxd` connects to the payload port of the phone |
| Files to the phone | A `flux.tunnel`: the phone listens, and `fluxd` connects |
| Browse PC from the phone | SSH inside a `flux.tunnel` |

## Omarchy integration

- `dist/hyprland.lua` floats the window and binds `SUPER + ALT + P` to
  `flux open`.
- `dist/omarchy-menu.jsonc` adds Flux to the Trigger menu. Merge it into
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
- The window reads `~/.local/state/omarchy/current/theme/colors.toml` and
  changes color when you change the theme. Flux for Android follows the
  system theme of the phone.

## Configuration

`fluxd` writes `~/.config/flux/config.toml` on the first start. Send `SIGHUP`
to reload it, or run `systemctl --user reload fluxd`.

```toml
name = "omarchy-framework"   # the name that the phone shows
download_dir = "~/Downloads"
scan_dir = "~/Documents/flux/scanned"   # scanned text and PDFs from the phone
photo_dir = "~/Pictures/flux"             # photos from the phone camera
auto_clipboard = true        # sync the clipboard in both directions
notifications = true         # show phone notifications on this computer
share_home = true            # let Flux for Android browse the home folder, read-only

# Commands that the phone can run. A new config has none. Add them in the
# Phone commands tab of the window, or with `flux commands add`.
[[commands]]
id = "lock"
name = "Lock screen"
command = "omarchy-system-lock"
```

## Files

| Path | Content |
| --- | --- |
| `~/.config/flux/config.toml` | Settings and commands |
| `~/.local/share/flux/certificate.pem`, `privateKey.pem` | The identity of this computer |
| `~/.local/share/flux/devices.json` | Paired devices and their pinned certificates |
| `~/Documents/flux/scanned/` | Scanned text and PDFs from the phone, 1 file per scan |
| `~/Pictures/flux/` | Photos from the phone camera |
| `~/.cache/flux/` | Notification icons and album art |
| `$XDG_RUNTIME_DIR/flux/fluxd.sock` | The IPC socket |

## Phone as webcam

Flux for Android can stream its camera to this computer. Video apps then
see a camera named "Flux Camera". The webcam needs 2 optional packages.
After you install them, run the system setup again, so it loads the module:

```sh
sudo pacman -S ffmpeg v4l2loopback-dkms
sudo sh /usr/share/flux/post-install.sh
```

On the phone, open Camera, select Webcam, and press Start.

```sh
flux webcam                                # the state and the settings
flux webcam set aspect=1:1 brightness=0.2  # change a setting
flux webcam reset                          # the neutral settings
flux webcam stop
```

To change the settings in the window, open the PHONE CAMERA card on the
Overview page and press Settings. On the phone, press Settings in the
Webcam mode. The settings open below the preview, so the preview shows
each change. A change to `aspect` or `resolution` restarts the stream. The
other settings change the image while it streams.

| Key | Values | Default |
| --- | --- | --- |
| `aspect` | `16:9`, `4:3`, `1:1`, `9:16` | `16:9` |
| `resolution` | `720`, `1080`. The short side of the frame, in pixels | `720` |
| `camera` | `back`, `front` | `back` |
| `mirror` | `true`, `false` | `false` |
| `zoom` | `1` to the maximum zoom of the camera | `1` |
| `exposure` | The EV range of the camera | `0` |
| `whiteBalance` | `auto`, `daylight`, `cloudy`, `shade`, `incandescent`, `fluorescent`, `twilight` | `auto` |
| `brightness` | `-1` to `1` | `0` |
| `contrast` | `0` to `2` | `1` |
| `saturation` | `0` to `2` | `1` |
| `warmth` | `-1` to `1`. A higher value makes the image warmer | `0` |

`flux webcam reset` sets the defaults again and keeps `aspect`,
`resolution`, and `camera`. The phone limits each value to what its camera
supports, and saves the settings for the next stream.

## Do Not Disturb sync

When you turn on Do Not Disturb on the computer, the phone turns it on too.
When you turn it off on the phone, the computer turns it off. Each side
sends its state only after a change, so the start of `fluxd` changes
nothing.

On the phone, turn on **Sync Do Not Disturb** on the device page. Android
asks for Do Not Disturb access the first time. On the computer, the sync
is on by default. To turn it off, set this key in `config.toml`:

```toml
sync_dnd = false
```

`fluxd` uses the notification service of the Omarchy shell. It reads
`~/.local/state/omarchy/notifications.json` every 2 seconds and sets the
state with `omarchy-shell notifications setDnd on`. With no Omarchy shell,
`fluxd` uses the `do-not-disturb` mode of mako. The log of `fluxd` names the
service at start.

## New screenshots and photos

Flux for Android can send each new screenshot and each new camera photo to
the computer by itself. On the phone, turn on **Send new screenshots** or
**Send new photos** on the device page. Both are off by default. Android
asks for access to photos the first time. Allow access to all photos,
because access to selected photos does not show new images.

| Phone folder | Kind | Folder on the computer |
| --- | --- | --- |
| `Pictures/Screenshots`, `DCIM/Screenshots` | Screenshot | `<photo_dir>/screenshots` |
| `DCIM/Camera` | Photo | `<photo_dir>` |

An image goes out once, to every connected computer, when the phone has
written it completely. Images from before the switch turned on stay on the
phone. An image that no computer took goes out when a computer connects.
The computer shows a notification with Open for each image.

## Open the window

`flux open [page]` opens the plugin when `omarchy-shell` runs and the plugin
is enabled. Otherwise it starts `flux-gui`. To choose one, set `FLUX_GUI` or
`gui` in `config.toml`:

```sh
FLUX_GUI=app flux open files
FLUX_GUI=plugin flux open media
```

## Development

The wire protocol builds on KDE Connect protocol version 8, with Flux
extensions. Flux for Android is the only supported phone app.


```sh
make test          # unit tests and a 2-daemon end-to-end test
make dev           # run fluxd from the checkout
make open          # build, then open the window from the checkout
make snapshot      # render every screen into snapshots/
make android       # build the Android app
```

To load the shared views from disk while you edit them, run
`FLUX_QML_DIR=$PWD/gui/qml gui/app/build/flux-gui`.

`fluxd -headless -udp-port 28716 -tcp-port 28720` runs without desktop
integration and keeps discovery on loopback. The end-to-end test in
`internal/e2e` uses this mode.

