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

Pages: `overview`, `clipboard`, `files`, `notifications`, `messages`, and `commands`.

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
Names match without case, and only a paired or connected device. A paired device comes first.
When the name still matches more than 1 device, the command returns the `ambiguous` error with the device IDs. Use the ID then. `docs/cli.md#pair-and-discover` has the match rule of each command.
`flux-cli status` shows the ID and the certificate fingerprint under each device.

The verification key has 16 uppercase hex digits in 4 groups of 4, for example `5EE6 825F 974E D59A`.
The user must compare all 16 characters before the user accepts a pair request.
A pairing that this computer starts also needs a confirmation on this computer after the device accepts: **Confirm** in the Flux window or in the notification, `y` at the prompt of `flux-cli pair`, or `flux-cli accept DEVICE KEY`.
`flux-cli accept` always sends the key, and `fluxd` refuses it when the open pairing has another key.
Without a key and without a terminal, `flux-cli accept` accepts nothing. It prints a `flux-cli accept` command with the device ID and the key. Run that command only after the user says that the phone shows the same key.
An earlier Flux app shows only 8 characters, so the user must update Flux on every device first.
`flux-cli pair` and `flux-cli accept` print the name, the ID, and the key.
`flux-cli unpair` prints the name, the ID, and the certificate fingerprint.
An unpair from either side ends every session of the device and closes its link.
Flux for Android takes a new computer only while Flux is on the screen or while it scans.

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
| `share_home` | Browse PC: share the home folder, `download_dir`, and the Documents, Pictures, Music, and Videos folders read-only. Names that start with a dot, such as `~/.ssh`, and the Flux folders stay hidden |
| `pause_media_on_call` | Pause desktop media during a phone call |
| `sync_dnd` | Sync Do Not Disturb |
| `herdr` | Show the herdr agents of the computer on the phone |
| `herdr_control` | Let the phone send keys and prompts to herdr agents, start agents, and close them. A paired device can then run any command as the user through an agent. Off by default |
| `herdr_terminals` | Let the phone open herdr terminals and type commands in them. Needs `herdr_control`. Off by default |
| `remote_input` | Let the phone move the pointer and type on the desktop. Off by default |
| `remote_desktop` | Let the phone show the desktop screen. Off by default |
| `gui` | Select the enabled plugin, otherwise the Qt app |
| `approve_timeout` | Wait 20 seconds for fingerprint approval |

Each setting applies to every paired device. Flux has no setting for 1 device.
`docs/security.md` lists what a paired device can do and which settings limit it.
`flux-cli browse` lists the devices that browse the computer with Browse PC, and `flux-cli browse stop` ends their sessions.

`download_dir`, `scan_dir`, and `photo_dir` select destination folders.
The identity and paired-device certificates live in `~/.local/share/flux/`.
`fluxd`, `flux-cli`, and both desktop hosts find the socket with the same rule:

1. `$FLUX_SOCKET`, when it is set.
2. Else `$XDG_RUNTIME_DIR/flux/fluxd.sock`.
3. Else `/run/user/<uid>/flux/fluxd.sock`.

Flux never uses the system temporary directory for the socket.
The approval helper uses only `/run/user/<uid>/flux/fluxd.sock`.
`fluxd` refuses a socket folder that is a symbolic link, that another user owns, or that other users can write to.
In a shell without a login session, for example after `su`, set `XDG_RUNTIME_DIR` to a private folder of the user.

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
A reply can make an agent run any command as the desktop user, also with `herdr_terminals = false`.
The setting applies to every paired device.
Do not turn on `herdr_control` unless the user asks for replies from the phone.

`fluxd` refuses a prompt to an agent that waits for a choice, with the code `blocked`.
The app then offers **Send as answer**, which sends the same text with `"answer": true`.

Terminals from the phone need `herdr_terminals = true` as well.
A terminal gives the phone a shell as the desktop user in each herdr pane without an agent.
These panes include a `sudo -i` shell or an SSH session that the user opened.
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
While the session is locked, `fluxd` refuses the bindings and the window actions with `Unlock the computer first`. Remote input and the remote desktop stay available on the lock screen.

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
Flux for Android, Flux for iOS, and Flux for macOS can approve.
The root helper validates a device signature against `/etc/flux/approve/<user>.pub`.
The daemon carries approval messages but does not establish trust by itself.
During enrollment, the user types the 16-character key code from the device screen. The terminal does not show it.

```sh
flux-cli approve
sudo flux-cli approve setup
sudo flux-cli approve enable hyprlock
sudo flux-cli approve disable
sudo flux-cli approve remove
```

polkit gives PAM no item for the user that asks.
So `polkit-1` works only with a setuid `polkit-agent-helper-1`.
polkit 126 and later on Arch Linux run the agent helper as the `polkit-agent-helper@.service` system service, which cannot reach the socket of `fluxd`.
On such a system, `sudo flux-cli approve enable polkit-1` refuses the service, and `flux-cli approve` says why.
Do not weaken the sandbox of the polkit service to make approvals work.

The Omarchy lock screen runs in `omarchy-shell` with its own PAM services, `omarchy-lock-password` and `omarchy-lock-fingerprint`.
Flux does not change them, so the phone cannot unlock the Omarchy lock screen.
The `hyprlock` service applies only when `hyprlock` is the lock screen.

Use root commands only for the requested setup or removal.
Keep the password fallback.
Do not change `sshd` or `login` PAM services.

## Connection diagnosis

1. Inspect `flux-cli doctor` and `flux-cli status --json`.
2. Inspect the user service and its logs.
3. Check `systemctl status avahi-daemon`.
4. Check that Flux runs on the phone.
5. Check that the network allows communication between clients. `fluxd` opens the connections itself, so do not add an inbound firewall rule for the Flux ports.
6. Run `flux-cli discover` and inspect the state again.
7. For a phone away from the local network, check `flux-cli addresses`, `tailscale ping HOST`, and the `connect to` lines in the `fluxd` log.

If the plugin fails, test the Qt host with `FLUX_GUI=app flux-cli open`.
If that succeeds, inspect the plugin install and shell logs.
