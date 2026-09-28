# Flux CLI

[Documentation index](README.md)

The CLI sends requests to the local `fluxd` daemon.
Without a command, `flux-cli` opens the desktop window.

The command is `flux-cli`.
`flux` also works when no other program, such as `fluxcd`, uses that name.
See [the command name](install.md#the-command-name).

## Select a device

Flux uses the only connected paired device by default.
With multiple devices, select a name or device ID:

```sh
flux-cli status --json
flux-cli --device "Pixel 8" ring
flux-cli --device "Pixel 8" send "$HOME/Downloads/report.txt"
```

Names match without case.
Use the device ID when names are not unique.
`-d NAME` and `--device=NAME` also work.

## Service and window

```sh
flux-cli help
flux-cli version
flux-cli setup --dry-run
flux-cli setup
flux-cli setup --no-plugin
flux-cli doctor
flux-cli status
flux-cli status --json
flux-cli off
flux-cli on
flux-cli open files
```

Window pages: `overview`, `clipboard`, `files`, `notifications`, `messages`, `browse`, and `commands`.

To select the Qt app or shell plugin explicitly:

```sh
FLUX_GUI=app flux-cli open files
FLUX_GUI=plugin flux-cli open notifications
```

## Pair and discover

```sh
flux-cli discover
flux-cli pair "Pixel 8"
flux-cli accept "Pixel 8"
flux-cli reject "Pixel 8"
flux-cli unpair "Pixel 8"
```

Compare the verification key on both devices before you accept.
See [phone pairing](features.md#pair-a-phone).

## Reach a device away from the local network

```sh
flux-cli addresses
flux-cli --device "Pixel 8" addresses add pixel-8
flux-cli --device "Pixel 8" addresses add 100.101.102.103
flux-cli --device "Pixel 8" addresses remove 100.101.102.103
```

An extra address is a host name or an IP address without a port, for example the Tailscale name of the phone.
While the device is offline, `fluxd` dials the extra addresses after the last address.
The device must be paired.
See [Connect through Tailscale](tailscale.md).

## Share and communicate

```sh
flux-cli ring
flux-cli ping "Connection check"
flux-cli send "$HOME/Downloads/report.txt" "$HOME/Pictures/photo.png"
flux-cli clip
flux-cli clip "Text from the desktop"
flux-cli url https://omarchy.org
flux-cli notifications
flux-cli notifications clear
flux-cli notify "Backup done" "412 files, 2.1 GB"
```

`flux-cli ring` rings only a phone or a tablet.
`flux-cli send` starts transfers and returns their count.
Inspect `transfers` in `flux-cli status --json` for completion.
`flux-cli clip` without text sends the desktop clipboard.
When the clipboard holds an image, the command sends the image and returns when the transfer ends.
See [clipboard images](features.md#clipboard-images).
`flux-cli notifications clear` dismisses the phone notifications on the phone and on the desktop. Ongoing notifications stay.

To send an SMS, set the recipient and message first:

```sh
RECIPIENT='+15550100123'
MESSAGE='On my way'
flux-cli sms "$RECIPIENT" "$MESSAGE"
```

Turn on **Text messages** on the phone first. See [text messages](features.md#text-messages).
The command sends the message to 1 recipient.

## Notify when a command ends

```sh
flux-cli notify --run -- make -j8
flux-cli --device "Pixel 8" notify --run -- rsync -a ~/Photos nas:/backup
```

Flux runs the command in the current terminal.
It sends the result, exit code, and elapsed time to the phone.
The CLI returns the command's exit code.
Ctrl+C stops the command and still sends the result.
Put Flux flags before `--`.

## Desktop commands

```sh
flux-cli commands
flux-cli commands add "Lock screen" omarchy-system-lock
flux-cli commands remove COMMAND_ID
flux-cli run COMMAND_ID
```

`flux-cli commands` lists desktop commands available to the phone.
Replace `COMMAND_ID` with an ID from that list.
`flux-cli run` executes the command on the desktop.

## Streams and approval

```sh
flux-cli webcam
flux-cli webcam set aspect=1:1 brightness=0.2
flux-cli webcam reset
flux-cli webcam stop
flux-cli mic
flux-cli mic stop
flux-cli screen
flux-cli screen stop
flux-cli desktop
flux-cli desktop stop
flux-cli approve
```

Start camera, microphone, and screen capture on the phone.
`flux-cli desktop` shows whether a phone shows the screen of this computer, and `flux-cli desktop stop` ends it.
See [remote desktop](remote-desktop.md).
See [camera and streams](camera.md) for settings and [fingerprint approval](approvals.md) for root setup commands.

## Watch state changes

```sh
flux-cli watch
```

The command prints one JSON event per line until you stop it.
Use `flux-cli status --json` for a single snapshot.
See [IPC](ipc.md) for the event envelope and socket protocol.
