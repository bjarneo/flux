# Runtime reference

## Command name

The CLI is `flux-cli`.
The package adds the short name `flux` at the end of `PATH`, so another `flux` command comes first.
The `fluxcd` package installs `/usr/bin/flux`.
With `fluxcd`, `flux` runs fluxcd and prints errors about Kubernetes.
Run `flux-cli` in commands, scripts, and reports.
`flux-cli doctor` prints which program `flux` runs.
Read `docs/install.md#the-command-name` for the files.

## Service and window

```sh
flux-cli setup --dry-run
flux-cli setup
flux-cli setup --no-plugin
flux-cli doctor
flux-cli status --json
systemctl --user status fluxd
journalctl --user -u fluxd -n 100 --no-pager
flux-cli off
flux-cli on
flux-cli open files
FLUX_GUI=app flux-cli open files
FLUX_GUI=plugin flux-cli open notifications
```

`flux-cli off` writes an off marker that also prevents the next login from starting the daemon.
`flux-cli on` removes the marker and starts the daemon.
Prefer these commands when the user asks to turn Flux off or on.

Pages: `overview`, `clipboard`, `files`, `notifications`, `messages`, `browse`, and `commands`.

## Devices and transfers

```sh
flux-cli discover
flux-cli pair "Pixel 8"
flux-cli accept "Pixel 8"
flux-cli reject "Pixel 8"
flux-cli unpair "Pixel 8"
flux-cli --device "Pixel 8" ring
flux-cli --device "Pixel 8" ping "Connection check"
flux-cli --device "Pixel 8" send "$HOME/Downloads/report.txt"
flux-cli --device "Pixel 8" clip
flux-cli --device "Pixel 8" clip "Text from the desktop"
flux-cli --device "Pixel 8" url https://omarchy.org
```

Replace the example device with a name or ID from `flux-cli status --json`.
Names match without case.
Use the ID when devices have the same name.
Compare the key before the user accepts a pair request.

## Extra addresses and Tailscale

```sh
tailscale status
flux-cli addresses
flux-cli --device "Pixel 8" addresses add pixel-8
flux-cli --device "Pixel 8" addresses remove pixel-8
```

An extra address is a host name or an IP address without a port, for example the Tailscale name of the phone.
`fluxd` dials the last address first, then the extra addresses. It dials 2 seconds after a link drops and every 30 seconds while the paired device is offline.
Each device in `flux-cli status --json` has an `addresses` list.
`flux-cli doctor` reports an extra host name that does not resolve.
The addresses are in `~/.local/share/flux/devices.json`. Change them with the CLI, not by hand, while `fluxd` runs.

Flux cannot discover or pair a device through Tailscale.
Pair on the local network first.
Read `docs/tailscale.md` for the limits and the troubleshooting steps.

## Notifications and commands

```sh
flux-cli --device "Pixel 8" notifications
flux-cli --device "Pixel 8" notifications clear
flux-cli --device "Pixel 8" notify "Build complete" "All tests passed"
flux-cli --device "Pixel 8" notify --run -- make test
flux-cli commands
flux-cli commands add "Lock screen" omarchy-system-lock
flux-cli commands remove COMMAND_ID
flux-cli run COMMAND_ID
```

Put `--device` before `--` with `notify --run`.
The process exits with the wrapped command's exit code.

For SMS, use the recipient and message from the user:

```sh
flux-cli --device "$DEVICE" sms "$RECIPIENT" "$MESSAGE"
```

The phone must have **Text messages** on. Without it, the device has no `sms` plugin in `flux-cli status --json`.
The command sends to 1 recipient. It returns when the request reaches the phone, not when the message is delivered.

`flux-cli commands` manages desktop commands that a paired phone can request.
The command ID comes from the list or the add result.

## Camera, microphone, and screen

Start capture on the phone.
The CLI reports state, changes webcam settings, and stops streams.

```sh
flux-cli webcam
flux-cli webcam set aspect=1:1 brightness=0.2
flux-cli webcam reset
flux-cli webcam stop
flux-cli mic
flux-cli mic stop
flux-cli screen
flux-cli screen stop
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
| `auto_clipboard` | Sync clipboard text and images in both directions |
| `notifications` | Show phone notifications on the desktop |
| `share_home` | Share the desktop home folder read-only |
| `pause_media_on_call` | Pause desktop media during a phone call |
| `sync_dnd` | Sync Do Not Disturb |
| `herdr` | Show the herdr agents of the computer on the phone |
| `herdr_control` | Let the phone send keys and prompts to herdr agents, start agents, and close them. Off by default |
| `herdr_terminals` | Let the phone open herdr terminals and type commands in them. Needs `herdr_control`. Off by default |
| `remote_input` | Let the phone move the pointer and type on the desktop. Off by default |
| `remote_desktop` | Let the phone show the desktop screen. Off by default |
| `gui` | Select the enabled plugin, otherwise the Qt app |
| `approve_timeout` | Wait 20 seconds for fingerprint approval |

`download_dir`, `scan_dir`, and `photo_dir` select destination folders.
The identity and paired-device certificates live in `~/.local/share/flux/`.
The socket is `$XDG_RUNTIME_DIR/flux/fluxd.sock`, with `FLUX_SOCKET` as an override.
Without `XDG_RUNTIME_DIR`, Flux uses a user-specific directory in the system temporary directory.

Do not delete the identity or trust store to diagnose a routine connection failure.
Their removal changes pairing identity.

## herdr agents

`fluxd` sends the herdr agents of the computer to Flux for Android.
Read `docs/herdr.md` for the phone screens, the notifications, and the wire format.

```sh
flux-cli doctor
flux-cli status --json
herdr agent list
journalctl --user -u fluxd --no-pager | grep herdr
```

The `herdr` field of the state has `enabled`, `running`, `control`, `terminals`, `agents`, `panes`, `workspaces`, and `kinds`.
`fluxd` and herdr must run as the same user.
`HERDR_SOCKET_PATH` selects a herdr session other than the default.

Replies, new agents, and closes from the phone need `herdr_control = true`.
A reply can make an agent run commands on the computer.
Do not turn on `herdr_control` unless the user asks for replies from the phone.

Terminals from the phone need `herdr_terminals = true` as well.
A terminal gives the phone a shell as the desktop user.
Do not turn on `herdr_terminals` unless the user asks for terminals on the phone.

## Touchpad and keyboard

The phone moves the pointer and types on the desktop only with `remote_input = true`.
The phone can then type in any window, such as a terminal.
Do not turn on `remote_input` unless the user asks for it.
`flux-cli input on` and `flux-cli input off` change the setting without a reload.
Read `docs/remote-input.md` for the gestures, `wtype`, and the wire format.

## Remote desktop

The phone shows the desktop screen only with `remote_desktop = true`.
The phone can then see each window. Its touches also need `remote_input = true`.
Do not turn on `remote_desktop` unless the user asks for it.
`flux-cli desktop on` and `flux-cli desktop off` change the setting without a reload.
The **Remote access** card on the **Overview** page of the Flux window has the same 2 switches.
The stream needs `gpu-screen-recorder`.
Read `docs/remote-desktop.md` for the gestures, the monitors, the lock screen, the Omarchy panel, and the stream format.
The stream shows the lock screen. `fluxd` turns the displays on when they are off.
The Omarchy panel runs Hyprland key bindings and workspace actions for the phone with `flux.shortcuts`. It needs `remote_input = true`.

```sh
flux-cli desktop on
flux-cli input on
flux-cli desktop
flux-cli desktop stop
flux-cli desktop off
flux-cli input off
```

## Fingerprint approval

Read `docs/approvals.md` for setup and `docs/approve.md` for the security design.
The root helper validates a phone signature against `/etc/flux/approve/<user>.pub`.
The daemon carries approval messages but does not establish trust by itself.

```sh
flux-cli approve
sudo flux-cli approve setup
sudo flux-cli approve enable polkit-1 hyprlock
sudo flux-cli approve disable
sudo flux-cli approve remove
```

Use root commands only for the requested setup or removal.
Keep the password fallback.
Do not change `sshd` or `login` PAM services.

## Connection diagnosis

1. Inspect `flux-cli doctor` and `flux-cli status --json`.
2. Inspect the user service and its logs.
3. Check `systemctl status avahi-daemon`.
4. Check that Flux runs on the phone.
5. Check that the network allows communication between clients.
6. Run `flux-cli discover` and inspect the state again.
7. For a phone away from the local network, check `flux-cli addresses`, `tailscale ping HOST`, and the `connect to` lines in the `fluxd` log.

If the plugin fails, test the Qt host with `FLUX_GUI=app flux-cli open`.
If that succeeds, inspect the plugin install and shell logs.
