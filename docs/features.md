# Everyday use

[Documentation index](README.md)

This page describes Flux for Android.
For the Mac app, see [Flux for macOS](macos.md#features).

## Pair a phone

1. Install [Flux for Android](android.md).
2. Connect the phone and desktop to the same local network.
3. Open Flux on the phone.
4. Run `flux-cli open` on the desktop.
5. Select **+ Pair new device**.
6. Select the phone.
7. Compare the 8-character key on both screens.
8. Accept the matching request on the phone.

To pair from the terminal:

```sh
flux-cli discover
flux-cli pair "Pixel 8"
flux-cli status
```

Flux uses TLS with pinned device certificates after pairing.
The desktop discovers phones through mDNS and opens the connections itself.
To use the phone away from the local network, see [Connect through Tailscale](tailscale.md).

## Files, clipboard, and links

Use the Files and Clipboard pages in the desktop window, or run:

```sh
flux-cli send "$HOME/Downloads/report.txt"
flux-cli clip
flux-cli clip "Text from the desktop"
flux-cli url https://omarchy.org
```

On Android, share content to Flux from the system share sheet.
Received files use `download_dir`.
The phone can browse the desktop home folder read-only when `share_home` is enabled.
The tunnel carries SSH traffic without an inbound SSH firewall rule.

## Notifications

Enable notification access on the phone to show its notifications on the desktop.
To send a notification in the other direction:

```sh
flux-cli notify "Backup done" "412 files, 2.1 GB"
```

The phone uses the **From computers** notification channel.
The desktop name identifies the sender.

## Text messages

Turn on **Text messages** on the phone's device screen.
The phone asks for SMS access and contacts access.
Flux needs SMS access. Contacts access adds names to the conversations.
A tablet without a SIM slot does not show the switch.

The desktop then shows the **Messages** page for that phone:

- The list shows the latest message of each conversation. A dot marks an unread conversation.
- Select a conversation to read its last 100 messages and to reply.
- Select **New message** to send a text message to a phone number.
- A new message on the phone appears on the desktop in about 1 second.
- A reply goes out on the SIM of the conversation. A new message uses the default SMS SIM of the phone.

To send a text message from a script, use the [SMS command](cli.md#share-and-communicate):

```sh
flux-cli sms '+15550100123' 'On my way'
```

Flux sends a text message to 1 phone number.
The page shows group conversations and the text of MMS messages, but you must reply to a group on the phone.
An MMS attachment shows as a label, for example `[Image]`.
Flux reads the SMS and MMS database of the phone.
Chat messages that an app keeps in its own database, for example RCS chats, do not show.

## Media and desktop commands

The phone controls desktop media players.
The desktop can also control supported media on the phone:

```sh
flux-cli media play-pause
```

Add desktop commands in the Phone commands page or through the CLI:

```sh
flux-cli commands add "Lock screen" omarchy-system-lock
flux-cli commands
```

A new configuration has no commands.
The phone can request only the commands configured on the desktop.

## Calls

Enable **Call alerts** on the phone's device screen.
Phone access reports call state.
Call-log access supplies the number, and contacts access supplies the name.
Without those optional details, the notification shows **Unknown caller**.

The daemon pauses desktop players that are active when the call starts.
When the call ends, it resumes those players.
A player that you manually resume during the call keeps its state.
A missed call produces a notification.

To keep media active during calls, set:

```toml
pause_media_on_call = false
```

Reload with `systemctl --user reload fluxd`.

## Do Not Disturb

Enable **Sync Do Not Disturb** on the phone's device page.
Android requests Do Not Disturb access the first time.
Each side sends state only after a change, so daemon startup does not change either side.

The desktop reads the Omarchy shell notification state every two seconds.
Without the Omarchy shell, it uses mako's `do-not-disturb` mode.
The daemon log identifies the selected service.

To disable the desktop side, set:

```toml
sync_dnd = false
```

Reload with `systemctl --user reload fluxd`.

## Automatic screenshots and photos

Enable **Send new screenshots** or **Send new photos** on the phone's device page.
Both options default to off.
Allow access to all photos when Android asks.
Selected-photo access does not expose new captures.

| Phone folder | Desktop destination |
| --- | --- |
| `Pictures/Screenshots` or `DCIM/Screenshots` | `<photo_dir>/screenshots` |
| `DCIM/Camera` | `<photo_dir>` |

Flux sends each completed image to every connected computer once.
Images from before the option was enabled stay on the phone.
An image that no computer received waits for a computer to connect.
The desktop notification includes an Open action.

See [camera and streams](camera.md) for direct capture and live media.

## herdr agents

When [herdr](https://herdr.dev) runs on the computer, select **Agents** on the phone's device page.
The phone shows the status and the colored output of each coding agent, and posts a notification when an agent needs input or finishes.

To answer agents from the phone, set:

```toml
herdr_control = true
```

Reload with `systemctl --user reload fluxd`.
See [herdr agents](herdr.md) for the replies, the notifications, and the access rules.
