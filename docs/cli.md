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

Put the device flag before the command, or right after the command name.
`flux-cli` reads it only in these places.
The text after the first argument of a command stays as you typed it.
For example, `flux-cli commands add Sync rsync -a -d src dst` keeps `-d src` in the command.

## Service and window

```sh
flux-cli help
flux-cli version
flux-cli setup --dry-run
flux-cli setup
flux-cli setup --no-plugin
flux-cli doctor
flux-cli update --check
flux-cli update
flux-cli status
flux-cli status --json
flux-cli off
flux-cli on
flux-cli open files
```

Window pages: `overview`, `clipboard`, `files`, `notifications`, `messages`, and `commands`.

`flux-cli setup` returns 1 when a step fails, so a script can check it:

```sh
flux-cli setup && echo "Flux is ready"
```

`flux-cli setup` and `flux-cli on` wait until `fluxd` answers a request on its socket.
`fluxd` answers only after it starts the network, so a connection alone does not count.
If `fluxd` stops at start, for example because `config.toml` has an error, the command prints the cause and returns 1.
In a checkout, `flux-cli setup` refuses a `fluxd` path with a quote or a backslash, because systemd cannot run it.
To see the log of the service, run `journalctl --user -u fluxd -e`.

After you install the package, `flux-cli setup` removes the `~/.config/systemd/user/fluxd.service` unit that an earlier `flux-cli setup` of a checkout or of `make install-user` wrote.
That unit hides the unit of the package.
`flux-cli setup` keeps a unit that you changed and prints its path.
To change the service, use a drop-in file:

```sh
systemctl --user edit fluxd
```

`flux-cli doctor` shows which unit file systemd loads for `fluxd.service`, and whether its program exists.
It also checks that no other program uses UDP port 12100, the discovery port of `fluxd`.

When `fluxd` does not answer, `flux-cli` tells you the cause:

| Message | Next step |
| --- | --- |
| `fluxd is off` | Run `flux-cli on`. |
| `fluxd does not run` | Run `flux-cli on`, then `flux-cli doctor`. |
| `cannot connect to fluxd on PATH` | The socket or its folder belongs to another user, or it is not a socket. See [data paths](configuration.md#data-paths). |

`flux-cli version` prints the version of `flux-cli` and of the running `fluxd`.
After an update, it also prints the new `fluxd` version that waits for its restart.
When the [release check](configuration.md#release-check) found a newer release, it prints that release.

`flux-cli update --check` asks GitHub for the latest release and prints it.
`flux-cli update` also installs it.
For a pacman package, it checks `SHA256SUMS.sig` with the public release key when the build has one.
Then it downloads the release package, checks it against `SHA256SUMS`, and runs `sudo pacman -U`.
When the signature is missing or does not match, it installs nothing.
See [update with flux-cli](install.md#update-with-flux-cli).
For a source install, it prints the commands for the checkout.
Without a network, it prints the error and returns 1.

`flux-cli --device "Pixel 8" update --phone` sends the latest Flux for Android to the phone.
`flux-cli status` shows when a phone has an earlier Android app.
See [update the app](android.md#update-the-app).
See [update](install.md#update).

`flux-cli open` starts `fluxd.service` when no `fluxd` answers.
After `flux-cli off`, it leaves `fluxd` off.

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
flux-cli accept DEVICE_ID 5EE6 825F 974E D59A
flux-cli reject "Pixel 8"
flux-cli unpair "Pixel 8"
```

The verification key has 16 uppercase hex digits in 4 groups of 4, for example `5EE6 825F 974E D59A`.
Compare all 16 characters on both devices before you accept.
An earlier Flux app shows only 8 characters, so update Flux on each device before you pair.

`flux-cli pair` asks the device to pair and prints the key.
After the device accepts, `flux-cli pair` asks you to compare the key:

```text
Confirm 5EE6 825F 974E D59A on Pixel 8 (DEVICE_ID)…
Does Pixel 8 show 5EE6 825F 974E D59A? [y/N] y
✓ Pixel 8 (DEVICE_ID) paired with the key 5EE6 825F 974E D59A
```

Type `y` only when the device shows the same key.
Any other answer rejects the pairing, and the device removes it.
The question ends when the pairing ends in another way.
For example, you select **Confirm** in the Flux window, the device ends the pairing, or the 30 seconds end.
When stdin is not a terminal, `flux-cli pair` prints the command that confirms the pairing, and then it stops:

```text
Pixel 8 accepted. Compare the key. When Pixel 8 shows 5EE6 825F 974E D59A, run:
  flux-cli accept DEVICE_ID 5EE6 825F 974E D59A
```

Run that command within 30 seconds, after you compare the key.

`flux-cli accept` accepts a pair request of a device.
It also confirms a pairing that this computer started and that the device accepted.
It always sends a key to `fluxd`, and `fluxd` accepts only the pairing with that key.
To accept only the key that you compared, give the key after the device.
The key can have spaces, for example `flux-cli accept DEVICE_ID "5EE6 825F 974E D59A"`.
Without a key, `flux-cli accept` shows the key of the open pairing and asks you to compare it:

```text
Does Pixel 8 show 5EE6 825F 974E D59A? [y/N] y
✓ Pixel 8 (DEVICE_ID) paired with the key 5EE6 825F 974E D59A
```

`flux-cli accept` sends the key that it showed, so `fluxd` refuses the answer when another pairing opened after the question.
Any answer other than `y` rejects the pairing.
When stdin is not a terminal, `flux-cli accept` without a key accepts nothing.
It prints the command with the key and exits with status 1:

```text
flux-cli: compare the key first. When Pixel 8 shows 5EE6 825F 974E D59A, run:
  flux-cli accept DEVICE_ID 5EE6 825F 974E D59A
```

`flux-cli reject` also sends a key, and it takes the same key argument.
Without a key, `flux-cli reject` rejects the pairing that is open when it runs.
With the device ID, it also cancels a pair request of this computer that the device did not answer.

Each command prints the device ID next to the name:

| Command | Output |
| --- | --- |
| `flux-cli pair` | `Confirm 5EE6 825F 974E D59A on Pixel 8 (DEVICE_ID)…`, then the question, then `✓ Pixel 8 (DEVICE_ID) paired with the key 5EE6 825F 974E D59A` |
| `flux-cli accept` | Without a key, the question. Then `✓ Pixel 8 (DEVICE_ID) paired with the key 5EE6 825F 974E D59A` |
| `flux-cli unpair` | `Unpaired Pixel 8 (DEVICE_ID), certificate FINGERPRINT` |

The fingerprint has 16 hex digits from the public key of the certificate of the device.
`flux-cli status` shows the ID and the fingerprint on the line under each device:

```text
  Pixel 8                phone   connected  78%    192.168.1.20    paired
                         ID DEVICE_ID · certificate 0A1B 2C3D 4E5F 6071
```

The `fingerprint` field of each device in `flux-cli status --json` has the same value, without spaces.

A name matches only a device that is paired or connected, and a paired device comes first.
`flux-cli pair` finds a name only among the devices that are connected and not paired.
`flux-cli accept` and `flux-cli reject` find a name only among the devices with an open pair request or a pairing in state `confirm`.
When the name still matches more than 1 device, the command returns the `ambiguous` error with the device IDs:

```text
flux-cli: 2 devices are named "Pixel 8": DEVICE_ID_1, DEVICE_ID_2. Give the device ID
```

Give the device ID in place of the name:

```sh
flux-cli pair 9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b
```

See [phone pairing](features.md#pair-a-phone) and [security](security.md).

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
`flux-cli url` sends only an `http` or `https` URL with a host. The device shows the link in a notification and opens it after a tap.
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
The notification has only the program name, such as `make`, because the phone can show it on the lock screen.
The arguments of a command can hold a password or a token.
The CLI returns the command's exit code.
Ctrl+C stops the command and still sends the result.
Put Flux flags before `--`.

To send the full command line, add `--show-command` right after `--run`:

```sh
flux-cli notify --run --show-command -- make -j8
```

The phone then gets at most the first 200 bytes of the command line.

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

Give the command as 1 argument in quotes. `fluxd` runs it with `sh -c`:

```sh
flux-cli commands add Backup "rsync -a ~/Documents nas:/backup"
```

When you give more than 1 argument, `flux-cli` quotes each argument for `sh`.
So `flux-cli commands add Open xdg-open "My File.pdf"` stores `xdg-open 'My File.pdf'`.

## Streams and approval

```sh
flux-cli webcam
flux-cli webcam start
flux-cli webcam set aspect=1:1 brightness=0.2
flux-cli webcam reset
flux-cli webcam stop
flux-cli mic
flux-cli mic start
flux-cli mic stop
flux-cli screen
flux-cli screen stop
flux-cli desktop
flux-cli desktop stop
flux-cli browse
flux-cli browse stop
flux-cli approve
```

Start camera, microphone, and screen capture on the phone.
`flux-cli webcam start` and `flux-cli mic start` ask the phone to start its camera or its microphone.
The phone asks you first, and the stream starts only after you tap start on the phone.
On success, the command prints the device:

```text
Asked Pixel 8 to start the webcam. Confirm on Pixel 8.
```

Without `--device`, the command selects the only paired, connected device that can take the request.
For these 2 commands, `--device NAME` can also come after `start`:

```sh
flux-cli webcam start --device "Pixel 8"
```

See [start from the computer](camera.md#start-from-the-computer) for what the phone shows and for the errors.

`flux-cli desktop` shows whether a phone shows the screen of this computer, and `flux-cli desktop stop` ends it.
`flux-cli browse` shows the devices that browse this computer with [Browse PC](features.md#browse-pc).
`flux-cli browse stop` ends each session, or only the session of the device that `--device` names.
See [remote desktop](remote-desktop.md).
See [camera and streams](camera.md) for settings and [fingerprint approval](approvals.md) for root setup commands.

## Remote access

To let a paired phone or Mac show and control this computer, run:

```sh
flux-cli desktop on
flux-cli input on
```

`flux-cli desktop on` lets the device show the screen.
`flux-cli input on` lets the device move the pointer and type.
To take the access back, run `flux-cli desktop off` and `flux-cli input off`.
`flux-cli desktop off` also stops a stream that runs.
`flux-cli input` without an argument shows whether remote input is on.

`fluxd` saves the change in `config.toml` at once.
The **Remote access** card on the **Overview** page of the Flux window has the same 2 switches.
See [remote desktop](remote-desktop.md) and [touchpad and keyboard](remote-input.md).

## Watch state changes

```sh
flux-cli watch
```

The command prints one JSON event per line until you stop it.
When `fluxd` stops, the command prints `fluxd closed the connection` and returns 1.
Use `flux-cli status --json` for a single snapshot.
See [IPC](ipc.md) for the event envelope and socket protocol.
