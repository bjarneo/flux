# Transfer and workflow controls

[Documentation index](README.md)

## Desktop outbox

Queue files for a paired device, including a device that is offline:

```sh
flux-cli --device "Pixel 8" send "$HOME/Downloads/report.txt"
flux-cli transfers
```

The desktop stores a private copy of each queued file.
Later source changes do not change that copy.
The outbox survives a daemon restart and holds at most 100 files or folder archives.
Flux retries failed transfers with a delay of up to 256 seconds.
The Files page shows pending bytes, the last error, **Retry now**, and **Cancel**.

Use the transfer ID from the list to control a transfer:

```sh
flux-cli transfers retry TRANSFER_ID
flux-cli transfers cancel TRANSFER_ID
```

Updated Android, iOS, and macOS clients acknowledge each chunk.
After a reconnect, the desktop starts at the receiver's saved byte offset.
The receiver checks the SHA-256 checksum before it reports completion.
Older clients use the standard transfer and retry from the start after a failure.

The outbox applies to files sent from the desktop.
The existing iOS share-sheet queue remains separate.
The send command confirms that Flux queued the files.
To check completion, run `flux-cli transfers`.

## Folder transfers

Drop a folder on the Files page, or pass its path to the CLI:

```sh
flux-cli --device "Pixel 8" send "$HOME/Documents/project"
```

Flux creates `project.zip` with the folder structure and empty folders intact.
The receiver saves the archive as a file.
Extract it with the receiving device's file manager.
Flux rejects symbolic links and special files inside the folder.

## Saved clipboard snippets

Select **Save** beside a clipboard entry.
The saved text or image stays after a restart.
Select **Saved snippets** to show saved entries only.
The search field searches the full text, including text outside the preview.
Select **Unsave** to delete the saved copy.

The CLI lists entries with their IDs:

```sh
flux-cli snippets
flux-cli snippets search "report"
flux-cli snippets save CLIP_ID 24h
flux-cli snippets copy CLIP_ID
flux-cli snippets remove CLIP_ID
```

Replace `CLIP_ID` with an ID from the list.
The duration is optional.
A snippet without a duration has no expiry.
Flux removes expired snippets within one minute, or when the daemon starts.
A separate recent-history entry can still contain the same content.

Flux keeps up to 100 saved snippets.
A text snippet can contain up to 1 MiB.
An image snippet can contain up to 16 MiB.

## Per-device access

The Overview page has a **Device access** section.
Each switch controls access for the selected device.
A global feature switch must also be on.
Agent control also needs agent output access.
Agent terminals also need agent control access.

```sh
flux-cli --device "Pixel 8" device-settings
flux-cli --device "Pixel 8" device-settings clipboard false
flux-cli --device "Pixel 8" device-settings clipboard inherit
```

The keys are `clipboard`, `notifications`, `shareHome`, `remoteInput`, `remoteDesktop`, `herdr`, `herdrControl`, and `herdrTerminals`.
`false` blocks the feature for that device.
`true` permits it when the global settings permit it.
`inherit` removes the restriction.

The configuration stores restrictions by device ID:

```toml
[devices."DEVICE_ID"]
clipboard = false
herdrControl = false
```

## Notification rules

Select **Mute app for 1 hour** to suppress later notifications from that app on the selected phone.
The page shows the expiry and keeps **Remove rule** available after expiry.
The rule does not dismiss notifications on the phone.

The CLI also supports permanent rules and quiet hours:

```sh
flux-cli --device "Pixel 8" notification-rules add Messages mute 1h
flux-cli notification-rules add Calendar silent
flux-cli notification-rules quiet 22:00 07:00
flux-cli notification-rules
flux-cli notification-rules remove RULE_ID
```

An app name must match the phone notification's app name.
Use `*` to match all apps.
Without `--device`, a rule applies to all devices.
The last matching rule wins.
Quiet hours use the desktop's local time and can cross midnight.

| Mode | Result |
| --- | --- |
| `normal` | Apply normal notification behavior. |
| `silent` | Keep the notification and request no sound from the desktop notification service. |
| `mute` | Ignore new notifications that match the rule. |

The global notification switch and per-device restrictions still apply.

## Local automation

An automation rule runs an existing desktop command after a device event.
A new configuration has no rules.

First add a command:

```sh
flux-cli commands add "Transfer notice" 'notify-send "Flux" "A file arrived: $FLUX_FILE"'
flux-cli commands
```

Use its command ID in a rule:

```sh
flux-cli automation add file.received COMMAND_ID
flux-cli --device "Pixel 8" automation add battery.low COMMAND_ID 20
flux-cli automation
flux-cli automation remove RULE_ID
```

| Event | Trigger |
| --- | --- |
| `device.connected` | A paired device connects. |
| `file.received` | A received file completes. |
| `battery.low` | Battery charge falls below the threshold while the device does not charge. |

The default battery threshold is 15 percent.
A battery rule runs once per low-charge period.
A rule has a default cooldown of 60 seconds per device.
Set `cooldown` in its `[[automation_rules]]` table to change that interval.
Set `disabled = true` in that table to disable the rule.
Each command has a one-minute time limit.

The command receives these environment variables:

- `FLUX_EVENT` contains the event name.
- `FLUX_DEVICE_ID` contains the device ID.
- `FLUX_FILE` contains the received file path for a file event.
- `FLUX_BATTERY` contains the charge for a battery event.

Quote these variables when a command uses them as arguments.
Flux passes event data through the environment, without inserting it into the command text.

## Agent diff review

Open an agent and select **Changes** on Android, iOS, or macOS.
The view shows changed file names, tracked changes, and previews of new text files.
Enter a repository-relative file path and submit the field to review that file only.
Leave the field empty to review all changes.
Select **Output** to return to the terminal output.

Replies from Changes include the selected review path.
They use the existing agent reply permission and phone or Mac unlock.
The view shows the working tree, including changes made by other tools or the user.
It does not attribute each change to the agent.

The daemon limits each preview to 512 KiB before color codes.
It previews new text files up to 128 KiB and labels binary files.
It does not follow untracked symbolic links or run Git external diff tools.

## Remote desktop audio

On Android or macOS, select **Audio on** in the remote desktop controls.
On iOS, open the speaker menu and select **Start desktop audio**.
The audio control restarts the screen stream with the selected audio state.
Use **Mute** or the volume control to change local playback.
Audio stops with the remote desktop session.

The computer needs `pw-record` from PipeWire.
Flux captures the default output monitor, without changing the computer's output volume.
Audio uses stereo, 48 kHz, signed 16-bit PCM through the existing authenticated stream.
Its uncompressed data rate is about 1.54 Mbit/s.

## State files

These folders are inside the Flux data directory, normally `~/.local/share/flux`:

| Folder | Content |
| --- | --- |
| `outbox` | Private queued file copies and transfer records. |
| `incoming` | Partial resumable receives and completion receipts. |
| `snippets` | Saved clipboard text and images. |

When another resumable offer arrives, the receiver removes inactive partial files and receipts older than seven days.
The phone and Mac keep partial files in private app storage.
The desktop removes queued transfers when the destination becomes unpaired.
