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
flux notify "Backup done"   # a notification on the phone
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
pause_media_on_call = true   # pause the players on this computer during a phone call

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

## Notifications to the phone

To show a notification on the phone, run `flux notify`. The phone shows it
in the "From computers" channel, with the name of this computer:

```sh
flux notify "Backup done" "412 files, 2.1 GB"
```

To get a notification when a long command ends, run the command through
`flux notify --run`. Flux runs it in the terminal, then sends "finished" or
"failed" with the exit code and the time that it took. `flux` exits with
the exit code of the command, so the command still works in scripts:

```sh
flux notify --run -- make -j8
flux notify --run -- rsync -a ~/Photos nas:/backup
```

Ctrl+C stops the command, and the phone still gets the result. Use
`--device NAME` before `--` when more than 1 phone is connected.

## Calls

To see phone calls on this computer, turn on **Call alerts** on the device
screen of Flux for Android. The phone asks for phone access. The call log
gives the number, and the contacts give the name. You can refuse both.
Then the notification shows "Unknown caller".

While the phone rings or has a call, fluxd pauses the players on this
computer that play. When the call ends, fluxd plays only those players
again. A player that you start again during the call stays as it is. A
missed call gives a notification. To keep the players on, set
`pause_media_on_call = false` in `config.toml`.

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

## Phone as microphone

Flux for Android can stream its microphone to this computer. Apps then
see an input named "Flux Microphone". fluxd plays the audio with
`pw-cat`, which PipeWire includes, so the microphone needs no extra
package.

On the phone, open Microphone and press Start. The stream stops when
you leave the screen. To send the microphone with the webcam, turn on
Also send the microphone in the Webcam settings.

```sh
flux mic           # the state
flux mic stop
```

The source exists only while the phone streams. It goes away when the
stream stops or fluxd stops.

## Phone screen in a window

Flux for Android can show its screen in a window on this computer. The
window only shows the screen. It does not control the phone. The mirror
needs `mpv` or `ffplay`:

```sh
sudo pacman -S mpv
```

On the phone, press Mirror screen and allow the capture. To stop, close
the window, press Stop in the phone notification, or run:

```sh
flux screen        # the state
flux screen stop
```

The window has the app id `flux-screen`. `dist/hyprland.lua` has a rule
that makes it float.

## Approve with fingerprint

Flux for Android can approve `sudo` and polkit with your fingerprint. The
phone signs each request with a key in its secure hardware. The computer
checks the signature with a key file that only root can change. If the
phone does not answer, PAM asks for the password as usual. The security
design is in `docs/approve.md`.

The feature is off until you add it to a PAM file. The phone needs a
fingerprint in its settings. To turn it on for `sudo`:

1. Open Flux on the phone, and check that the computer is connected.
2. From your own user, enroll the phone:

   ```sh
   sudo flux approve enroll
   ```

3. On the phone, press Enroll and touch the fingerprint sensor.
4. Compare the key code on the phone with the key code in the terminal.
   Type `y` only when the codes are the same.
5. Open a root shell in a second terminal. Keep it open until the test
   works.
6. Add this line at the top of `/etc/pam.d/sudo`, above
   `auth include system-auth`:

   ```text
   auth sufficient pam_exec.so quiet stdout /usr/lib/flux/flux-approve
   ```

7. In a new terminal, run `sudo -k` and then `sudo true`. The terminal
   shows `Approve on <phone>, or wait for the password prompt.`, and the
   phone shows the request.

If you change a PAM file, keep the root shell open until `sudo` works. A
wrong line can stop `sudo` for all users.

Approve a request only right after you typed the command. The phone shows
the service, the user, the host, the terminal, and the time.

To use it for polkit, copy the vendor file and add the same line at the
top of the copy:

```sh
sudo cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
sudoedit /etc/pam.d/polkit-1
```

hyprlock reads `/etc/pam.d/hyprlock`, and it takes the same line. The
Omarchy lock screen uses its own PAM services, and Flux does not change
them. Do not add the line to `sshd` or `login`. The helper refuses `sshd`.

```sh
flux approve              # the enrolled phone and the PAM files that use it
sudo flux approve remove  # delete the key file, so that no phone can approve
```

`approve_timeout` in `config.toml` sets how long `sudo` waits for the
phone, from 5 to 120 seconds. The default is 20 seconds. If no phone is
connected, the helper stops at once, and `sudo` asks for the password.

| Path | Content |
| --- | --- |
| `/etc/flux/approve/<user>.pub` | The public key of the phone. Root owns it. |
| `/usr/lib/flux/flux-approve` | The PAM helper |

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

