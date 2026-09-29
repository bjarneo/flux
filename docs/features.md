# Everyday use

[Documentation index](README.md)

This page describes Flux for Android.
For the Mac app, see [Flux for macOS](macos.md#features). For the iPhone, see [Flux for iOS](ios.md#features).

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
The phone scans for computers for 10 seconds when the app opens.
If the desktop is not in the list, tap **Scan again** on the phone.
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

## Clipboard images

A copied image goes to the other device, like copied text.
Turn on `auto_clipboard` on the desktop and **Sync clipboard** on the phone.
Both are on by default.

- Copy an image on the desktop, for example a screenshot. Then paste it in an app on the phone.
- Copy an image on the phone, open Flux, and tap **Send clipboard**. Then paste it on the desktop.

Android lets only the app on the screen read the clipboard.
Flux sends a phone copy by itself only while Flux is on the screen.
For a copy in another app, use **Send clipboard**.

The desktop sends PNG images.
The phone sends PNG, JPEG, GIF, and WebP images.
Flux syncs images of up to 16 MiB.
A copy that also has plain text syncs as text, for example cells from a spreadsheet.

The Clipboard page shows the last 10 images.
Select **Copy** to put an image on the desktop clipboard again.
`fluxd` keeps these images in `$XDG_RUNTIME_DIR/flux/clipboard`, which is in memory.
It empties the folder when it starts and when it stops.

## Notifications

Enable notification access on the phone to show its notifications on the desktop.
To dismiss all of them, select **Clear all** on the Notifications page, or run:

```sh
flux-cli notifications clear
```

Clear all also dismisses the notifications on the phone.
An ongoing notification, such as a media player, stays.

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

The phone controls the media players on the desktop.
Open **Media** on the phone to play, pause, skip, seek, and set the volume.
The controls show when a desktop player publishes its state over MPRIS.
The phone selects the player that plays.
If more than one player runs, select another player at the top of the screen.

The volume control shows only for a player that accepts a new volume, such as mpv.
Chromium does not accept one, so the phone shows no volume control for it.
The desktop does not show or control the players on the phone.

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
The same key lets the phone start new agents and close agents.
To talk to an agent, use the mic key next to **Send**. The phone changes your speech to text on the device.
To also open herdr terminals and type commands in them, set `herdr_terminals = true`.
See [herdr agents](herdr.md) for the replies, new agents, terminals, dictation, the notifications, and the access rules.

## Touchpad and keyboard

The phone, the iPhone, or the Mac can be a touchpad and a keyboard for the computer.
To allow it, turn on **Remote input** in the **Remote access** card of the Flux window, or run:

```sh
flux-cli input on
```

Then select **Touchpad and keyboard** on the phone's device page, or **Open Touchpad…** on the computer's page in Flux for macOS.
See [Touchpad and keyboard](remote-input.md) for the gestures, the keys, and the slides.

## Remote desktop

The phone, the iPhone, or the Mac can show the screen of the computer and control it.
To allow it, turn on **Remote desktop** and **Remote input** in the **Remote access** card of the Flux window, or run:

```sh
flux-cli desktop on
flux-cli input on
```

Then select **Remote desktop** on the phone's device page. The phone turns to landscape.
In Flux for macOS, select **Open Remote Desktop…** on the computer's page.
See [Remote desktop](remote-desktop.md) for the gestures, the monitors, and the stream.

## Dictation in text fields

Each text field of the app has a mic key.
The phone changes your speech to text on the device.

| Field | Where the words go |
| --- | --- |
| Reply to a herdr agent | At the cursor of the field |
| Command of a herdr terminal | At the cursor of the field, without the capital and the period of a sentence |
| Folder search when you start a herdr agent | In place of the search |
| Text field of the touchpad and the remote desktop | The computer types them at its cursor |
| Scanned text in the text mode of the camera | At the cursor of the field |
| Search of **All shortcuts** in the Omarchy panel | In place of the search |
| Search of the dictation language picker | In place of the search |

Tap the mic key to start, and tap it again to stop.
To talk only while you hold the key, press and hold it.
All fields use the same dictation language.
See [herdr agents](herdr.md#dictate-a-reply) for the panel, the languages, and the model downloads.
