# Configuration

[Documentation index](README.md)

`fluxd` creates `~/.config/flux/config.toml` on its first start.
After an edit, reload the service:

```sh
systemctl --user reload fluxd
```

## Settings

```toml
name = "omarchy-desktop"
download_dir = "~/Downloads"
scan_dir = "~/Documents/flux/scanned"
photo_dir = "~/Pictures/flux"
auto_clipboard = true
notifications = true
share_home = true
pause_media_on_call = true
sync_dnd = true
herdr = true
herdr_control = false
herdr_terminals = false
remote_input = false
remote_desktop = false
check_updates = true
gui = ""
approve_timeout = 20

[[commands]]
id = "lock"
name = "Lock screen"
command = "omarchy-system-lock"
```

| Key | Effect |
| --- | --- |
| `name` | The desktop name shown on the phone. An empty name uses the host name. |
| `download_dir` | Destination for received files. Defaults to the XDG Downloads directory, then `~/Downloads`. |
| `scan_dir` | Destination for scanned text and documents. Defaults to `flux/scanned` inside the XDG Documents directory. |
| `photo_dir` | Destination for camera photos. Defaults to `flux` inside the XDG Pictures directory. Screenshots and signatures use its `screenshots` and `signatures` folders. |
| `auto_clipboard` | Sync clipboard text and images in both directions. Defaults to `true`. |
| `notifications` | Show phone notifications on the desktop. Defaults to `true`. |
| `share_home` | Let the phone browse the desktop home folder read-only. Defaults to `true`. |
| `pause_media_on_call` | Pause desktop media during calls. Defaults to `true`. |
| `sync_dnd` | Sync Do Not Disturb. Defaults to `true`. |
| `herdr` | Show the [herdr agents](herdr.md) of this computer on the phone. Defaults to `true`. |
| `herdr_control` | Let the phone send keys and prompts to the herdr agents, start agents, and close them. Defaults to `false`. See [Answer an agent](herdr.md#answer-an-agent). |
| `herdr_terminals` | Let the phone open herdr terminals, read them, and type commands in them. Needs `herdr_control`. Defaults to `false`. See [Use terminals](herdr.md#use-terminals). |
| `remote_input` | Let the phone or the Mac move the pointer and type on this computer. Defaults to `false`. See [Touchpad and keyboard](remote-input.md). |
| `remote_desktop` | Let the phone or the Mac show the screen of this computer. Defaults to `false`. The touches and the mouse on the screen also need `remote_input`. See [Remote desktop](remote-desktop.md). |
| `check_updates` | Ask GitHub once a day for the latest release. Defaults to `true`. See [release check](#release-check). |
| `gui` | Use `app`, `plugin`, or an empty value for automatic host selection. |
| `approve_timeout` | Wait 5 to 120 seconds for approval. Zero or an omitted value uses 20 seconds. |
| `commands` | Desktop commands available to the phone. A new configuration has no commands. |

The destination paths expand `~`.
Use the [CLI](cli.md#desktop-commands) or the Phone commands page to add commands without editing TOML.

## Data paths

| Path | Content |
| --- | --- |
| `~/.config/flux/config.toml` | Settings and commands |
| `~/.config/flux/off` | Marker that disables automatic daemon start |
| `~/.local/share/flux/certificate.pem` | Desktop identity certificate |
| `~/.local/share/flux/privateKey.pem` | Desktop identity private key |
| `~/.local/share/flux/devices.json` | Paired devices, pinned certificates, and [extra addresses](tailscale.md) |
| `~/Documents/flux/scanned/` | Scanned text and documents by default |
| `~/Pictures/flux/` | Camera photos by default |
| `~/Pictures/flux/screenshots/` | Automatically received screenshots by default |
| `~/Pictures/flux/signatures/` | Signatures from the camera by default |
| `~/.cache/flux/` | Notification icons and album art |
| `~/.cache/flux/release.json` | The last answer of the [release check](#release-check) |
| `~/.cache/flux/update/` | The package that `flux-cli update` downloads, until pacman installs it |
| `$XDG_RUNTIME_DIR/flux/fluxd.sock` | Local IPC socket |
| `/etc/flux/approve/<user>.pub` | Root-owned phone approval public key |
| `/etc/flux/approve/pam-backup/` | Original PAM files from approval setup |

The config and data paths honor `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.
Keep the identity private key private.
Its replacement changes the desktop identity and requires new pairing.

## Environment variables

| Variable | Use |
| --- | --- |
| `FLUX_SOCKET` | Override the local IPC socket path. |
| `FLUX_GUI` | Select `app` or `plugin` for `flux-cli open`. |
| `FLUX_QML_DIR` | Load shared views from disk in the Qt host during development. |
| `FLUX_THEME_FILE` | Select a theme file for the snapshot harness. |
| `FLUX_SNAPSHOT` | Select the output directory for the QML snapshot harness. |
| `FLUX_SNAPSHOT_ONLY` | Filter snapshot names by text. |
| `HERDR_SOCKET_PATH` | Select the herdr session that `fluxd` follows. See [herdr agents](herdr.md#use-another-herdr-session). |
| `FLUX_RELEASES_URL` | Replace the GitHub API address of the release check. Tests use it. |
| `FLUX_RELEASE_DELAY` | Change the wait before the first release check, such as `0s`. Tests use it. |
| `FLUX_BINARY_POLL` | Change the interval of the check for a new `fluxd` binary, such as `100ms`. Tests use it. |

Without `XDG_RUNTIME_DIR`, the daemon uses `flux-<uid>` inside the system temporary directory.
See [development](development.md) for an isolated test environment.

## Release check

`fluxd` asks GitHub once a day for the latest Flux release.
When a newer release exists, the window shows **Flux 0.7.0 is available**, and `flux-cli version` prints it.
The update itself starts only when you select **Update** or run `flux-cli update`.

The check sends 1 HTTPS `GET` request to `api.github.com`.
The request has the Flux version in its `User-Agent` header and no other data.
GitHub sees the IP address of the computer.

The check needs no network to work correctly:

- The first check runs 30 seconds after `fluxd` starts, so it does not slow the login.
- Without a network, the check fails at once, and `fluxd` works as before.
- `fluxd` tries again after 1 hour, or at the next network change.
- `fluxd` keeps the last answer in `~/.cache/flux/release.json`. A known update stays visible without a network.
- `flux-cli doctor` shows the error of the last failed check.

To turn the check off, set `check_updates = false` in `~/.config/flux/config.toml`, then reload the service:

```sh
systemctl --user reload fluxd
```

When the check is off, `fluxd` sends no request, and the window shows no update notice.
`flux-cli update` still asks GitHub when you run it.

## Turn Flux off or on

```sh
flux-cli off
flux-cli on
```

`flux-cli off` stops the daemon and creates the off marker.
`flux-cli on` removes the marker and starts the daemon.
On Android, use **Turn off Flux** in the device-list menu or **Turn off** in its notification.
The phone stays off after a restart until you select **Turn on Flux** in the app.

## Choose the Android theme

To change the colors of the Android app:

1. Open the menu on the device list.
2. Select **System**, **Light**, or **Dark**.

**System** is the default and follows the dark theme setting of the phone.
**Light** uses the Tokyo Night Day colors.
**Dark** uses the Tokyo Night colors.
