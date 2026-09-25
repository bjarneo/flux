# Flux CLI

[Documentation index](README.md)

The CLI sends requests to the local `fluxd` daemon.
Without a command, `flux` opens the desktop window.

## Select a device

Flux uses the only connected paired device by default.
With multiple devices, select a name or device ID:

```sh
flux status --json
flux --device "Pixel 8" ring
flux --device "Pixel 8" send "$HOME/Downloads/report.txt"
```

Names match without case.
Use the device ID when names are not unique.
`-d NAME` and `--device=NAME` also work.

## Service and window

```sh
flux help
flux version
flux setup --dry-run
flux setup
flux setup --no-plugin
flux doctor
flux status
flux status --json
flux off
flux on
flux open files
```

Window pages: `overview`, `clipboard`, `files`, `notifications`, `media`, `messages`, `browse`, and `commands`.

To select the Qt app or shell plugin explicitly:

```sh
FLUX_GUI=app flux open files
FLUX_GUI=plugin flux open media
```

## Pair and discover

```sh
flux discover
flux pair "Pixel 8"
flux accept "Pixel 8"
flux reject "Pixel 8"
flux unpair "Pixel 8"
```

Compare the verification key on both devices before you accept.
See [phone pairing](features.md#pair-a-phone).

## Share and communicate

```sh
flux ring
flux ping "Connection check"
flux send "$HOME/Downloads/report.txt" "$HOME/Pictures/photo.png"
flux clip
flux clip "Text from the desktop"
flux url https://omarchy.org
flux notifications
flux notify "Backup done" "412 files, 2.1 GB"
```

`flux send` starts transfers and returns their count.
Inspect `transfers` in `flux status --json` for completion.
`flux clip` without text reads the desktop clipboard.

To send an SMS, set the recipient and message first:

```sh
RECIPIENT='+15550100123'
MESSAGE='On my way'
flux sms "$RECIPIENT" "$MESSAGE"
```

The phone needs SMS permission.

## Notify when a command ends

```sh
flux notify --run -- make -j8
flux --device "Pixel 8" notify --run -- rsync -a ~/Photos nas:/backup
```

Flux runs the command in the current terminal.
It sends the result, exit code, and elapsed time to the phone.
The CLI returns the command's exit code.
Ctrl+C stops the command and still sends the result.
Put Flux flags before `--`.

## Media and desktop commands

```sh
flux media play-pause
flux media next
flux commands
flux commands add "Lock screen" omarchy-system-lock
flux commands remove COMMAND_ID
flux run COMMAND_ID
```

Media actions: `play-pause`, `play`, `pause`, `next`, `previous`, and `stop`.
`flux commands` lists desktop commands available to the phone.
Replace `COMMAND_ID` with an ID from that list.
`flux run` executes the command on the desktop.

## Streams and approval

```sh
flux webcam
flux webcam set aspect=1:1 brightness=0.2
flux webcam reset
flux webcam stop
flux mic
flux mic stop
flux screen
flux screen stop
flux approve
```

Start camera, microphone, and screen capture on the phone.
See [camera and streams](camera.md) for settings and [fingerprint approval](approvals.md) for root setup commands.

## Watch state changes

```sh
flux watch
```

The command prints one JSON event per line until you stop it.
Use `flux status --json` for a single snapshot.
See [IPC](ipc.md) for the event envelope and socket protocol.
