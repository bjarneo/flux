# Flux

Flux connects an Omarchy computer to your phone on the same network. Share
files and the clipboard, read phone notifications, control media, send text
messages, run desktop commands from the phone, and use the phone as a
touchpad.

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

## Install from source

Flux needs Go 1.27, CMake, Ninja, Qt 6, `wl-clipboard`, `pipewire`, and
`avahi`. Omarchy installs all of them except Go, CMake, and Ninja.

1. Build and install:

   ```sh
   make
   sudo make install
   ```

2. Load the `uinput` module and apply the udev rule, so the phone touchpad
   works without root:

   ```sh
   sudo modprobe uinput
   sudo udevadm control --reload && sudo udevadm trigger /dev/uinput
   ```

3. Optional: add the plugin to `omarchy-shell` for your user:

   ```sh
   make install-plugin
   omarchy plugin enable flux
   ```

4. Start the daemon:

   ```sh
   systemctl --user enable --now fluxd
   ```

5. Check the setup:

   ```sh
   flux doctor
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
scan_dir = "~/Documents/flux/scanned"   # text that the phone camera scans
auto_clipboard = true        # sync the clipboard in both directions
notifications = true         # show phone notifications on this computer
receive_input = true         # let the phone move the pointer and type
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
| `~/Documents/flux/scanned/` | Text that the phone camera scanned, 1 file per scan |
| `~/.cache/flux/` | Notification icons and album art |
| `$XDG_RUNTIME_DIR/flux/fluxd.sock` | The IPC socket |

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

