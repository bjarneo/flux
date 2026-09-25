# Runtime reference

## Service and window

```sh
flux setup --dry-run
flux setup
flux setup --no-plugin
flux doctor
flux status --json
systemctl --user status fluxd
journalctl --user -u fluxd -n 100 --no-pager
flux off
flux on
flux open files
FLUX_GUI=app flux open files
FLUX_GUI=plugin flux open media
```

`flux off` writes an off marker that also prevents the next login from starting the daemon.
`flux on` removes the marker and starts the daemon.
Prefer these commands when the user asks to turn Flux off or on.

Pages: `overview`, `clipboard`, `files`, `notifications`, `media`, `messages`, `browse`, and `commands`.

## Devices and transfers

```sh
flux discover
flux pair "Pixel 8"
flux accept "Pixel 8"
flux reject "Pixel 8"
flux unpair "Pixel 8"
flux --device "Pixel 8" ring
flux --device "Pixel 8" ping "Connection check"
flux --device "Pixel 8" send "$HOME/Downloads/report.txt"
flux --device "Pixel 8" clip
flux --device "Pixel 8" clip "Text from the desktop"
flux --device "Pixel 8" url https://omarchy.org
```

Replace the example device with a name or ID from `flux status --json`.
Names match without case.
Use the ID when devices have the same name.
Compare the key before the user accepts a pair request.

## Notifications, media, and commands

```sh
flux --device "Pixel 8" notifications
flux --device "Pixel 8" notify "Build complete" "All tests passed"
flux --device "Pixel 8" notify --run -- make test
flux --device "Pixel 8" media play-pause
flux commands
flux commands add "Lock screen" omarchy-system-lock
flux commands remove COMMAND_ID
flux run COMMAND_ID
```

Media actions: `play-pause`, `play`, `pause`, `next`, `previous`, and `stop`.
Put `--device` before `--` with `notify --run`.
The process exits with the wrapped command's exit code.

For SMS, use the recipient and message from the user:

```sh
flux --device "$DEVICE" sms "$RECIPIENT" "$MESSAGE"
```

`flux commands` manages desktop commands that a paired phone can request.
The command ID comes from the list or the add result.

## Camera, microphone, and screen

Start capture on the phone.
The CLI reports state, changes webcam settings, and stops streams.

```sh
flux webcam
flux webcam set aspect=1:1 brightness=0.2
flux webcam reset
flux webcam stop
flux mic
flux mic stop
flux screen
flux screen stop
```

The webcam needs `ffmpeg` and `v4l2loopback-dkms` with the matching kernel headers.
The microphone needs PipeWire and `pw-cat`.
The screen mirror needs `mpv` or `ffplay`.
The screen mirror does not provide phone input control.

## Configuration

Settings live in `~/.config/flux/config.toml`, with XDG overrides supported.
Reload after an edit:

```sh
systemctl --user reload fluxd
```

Key settings:

| Key | Default behavior |
| --- | --- |
| `auto_clipboard` | Sync clipboard text in both directions |
| `notifications` | Show phone notifications on the desktop |
| `share_home` | Share the desktop home folder read-only |
| `pause_media_on_call` | Pause desktop media during a phone call |
| `sync_dnd` | Sync Do Not Disturb |
| `gui` | Select the enabled plugin, otherwise the Qt app |
| `approve_timeout` | Wait 20 seconds for fingerprint approval |

`download_dir`, `scan_dir`, and `photo_dir` select destination folders.
The identity and paired-device certificates live in `~/.local/share/flux/`.
The socket is `$XDG_RUNTIME_DIR/flux/fluxd.sock`, with `FLUX_SOCKET` as an override.
Without `XDG_RUNTIME_DIR`, Flux uses a user-specific directory in the system temporary directory.

Do not delete the identity or trust store to diagnose a routine connection failure.
Their removal changes pairing identity.

## Fingerprint approval

Read `docs/approvals.md` for setup and `docs/approve.md` for the security design.
The root helper validates a phone signature against `/etc/flux/approve/<user>.pub`.
The daemon carries approval messages but does not establish trust by itself.

```sh
flux approve
sudo flux approve setup
sudo flux approve enable polkit-1 hyprlock
sudo flux approve disable
sudo flux approve remove
```

Use root commands only for the requested setup or removal.
Keep the password fallback.
Do not change `sshd` or `login` PAM services.

## Connection diagnosis

1. Inspect `flux doctor` and `flux status --json`.
2. Inspect the user service and its logs.
3. Check `systemctl status avahi-daemon`.
4. Check that Flux runs on the phone.
5. Check that the network allows communication between clients.
6. Run `flux discover` and inspect the state again.

If the plugin fails, test the Qt host with `FLUX_GUI=app flux open`.
If that succeeds, inspect the plugin install and shell logs.
