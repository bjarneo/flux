# Everyday use

[Documentation index](README.md)

This page describes Flux for Android.
For the Mac app, see [Flux for macOS](macos.md#features). For the iPhone, see [Flux for iOS](ios.md#features).

The switches on the **Sync** screen in **Computers** are settings of the phone.
Each switch applies to every paired computer, not only to the computer whose page shows it.
For example, **Text messages** lets each paired computer read your conversations.
See [sync switches](android-setup.md#sync-switches) and [security](security.md).

## Pair a phone

1. Install [Flux for Android](android.md).
2. Connect the phone and desktop to the same local network.
3. Open Flux on the phone.
4. Run `flux-cli open` on the desktop.
5. Select **+ Pair new device**.
6. Select the phone.
7. Compare the 16-character key on both screens, for example `5EE6 825F 974E D59A`.
8. Accept the matching request on the phone.
9. Select **Confirm** on the desktop, in the Flux window or in the notification. The desktop pins the phone only after this step.

The phone shows the desktop as paired after step 8.
The desktop keeps the first packets of the phone, for example the battery level, and uses them after step 9.
When you reject the pairing on the desktop, the phone removes the pairing.

Compare all 16 characters.
An earlier Flux app shows only 8 characters. Update Flux on each phone, iPhone, and Mac before you pair.
If the keys differ, reject the request and pair again.
Each step waits at most 30 seconds. After that, the pairing stops, and the phone removes it.

To pair from the terminal:

```sh
flux-cli discover
flux-cli pair "Pixel 8"
flux-cli status
```

After the phone accepts, `flux-cli pair` asks `Does Pixel 8 show 5EE6 825F 974E D59A? [y/N]`.
Type `y` only when the phone shows the same key.
When stdin is not a terminal, `flux-cli pair` prints the `flux-cli accept` command with the device ID and the key. Run it after you compare the key.
`flux-cli pair` and `flux-cli accept` print the name, the device ID, and the key of the pairing.
`flux-cli unpair` prints the name, the device ID, and the fingerprint of the certificate that it removed.
When the name matches more than 1 device, `fluxd` refuses the name with the `ambiguous` error and lists the device IDs.
See [pair and discover](cli.md#pair-and-discover) for the match rule of each command.
Give the ID instead of the name:

```sh
flux-cli pair 9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b
```

Flux uses TLS with pinned device certificates after pairing.
The desktop discovers phones through mDNS and opens the connections itself.
The phone scans for computers for 10 seconds when the app opens.
The phone takes a connection from a computer that is not paired only while Flux is on the screen or while it scans.
So keep Flux open on the phone while you pair.
If the desktop is not in the list, tap **Scan again** on the phone.
To use the phone away from the local network, see [Connect through Tailscale](tailscale.md).

### Pairing security

- The key comes from the certificates of both devices and the time of the request. It has 64 bits, so a device between the phone and the computer cannot find a certificate with the same key while the request is open.
- A pairing that the desktop starts needs a confirmation on each side. After the phone accepts, the desktop waits for **Confirm**. A device that copies the name of your phone cannot pair with 1 click.
- Each accept and each confirm names the key that you compared. The Flux window, the pair notification, and `flux-cli` send the key, and `fluxd` refuses the answer when the open pairing has another key. Without a key, `flux-cli accept` shows the key and asks you to compare it. Without a terminal, it accepts nothing and prints the command with the key. `flux-cli reject` without a key rejects the pairing that is open when it runs. `fluxd` closes the pair notification when the pairing ends.
- A pairing stays on the connection and the certificate on which it started. While a pairing is open, `fluxd` refuses a second connection with another certificate for the same device ID. When the connection of the pairing closes, the pairing stops.
- After the pairing, `fluxd` refuses each connection that does not show the pinned certificate.
- The state from `flux-cli status --json` has the `fingerprint` of each device: 16 hex digits from its certificate. `flux-cli status` shows the device ID and the fingerprint under each device. Use them to tell 2 devices with the same name apart.
- When you unpair on either side, the other side gets the unpair message and `fluxd` closes the connection. `fluxd` also removes the notifications, messages, and battery state of the device, and closes the desktop notifications of the phone.
- A device that is not paired can send packets of at most 64 KiB. `fluxd` closes its connection when it sends no pair request for 2 minutes.
- `fluxd` shows at most 1 pair notification for each device and at most 4 open pair requests. At most 2 of them come from 1 address.
- When a request of a device ends with a withdraw, a reject, a timeout, or the end of its connection, `fluxd` refuses a new request of that device for 30 seconds.
- When `fluxd` refuses a request because too many requests are open, the Flux window shows the name and the address of the device. Reject the other requests, or pair from the desktop.
- The Flux window opens the sidebar for a request only once in 5 minutes for each device.

If `devices.json` has a certificate that `fluxd` cannot read, the device counts as not paired, and `fluxd` refuses its connections.
The journal names the device. To pair it again, run:

```sh
flux-cli unpair DEVICE_ID
```

If `devices.json` does not parse, `fluxd` moves it to `devices.json.broken-<Unix time>` in the same folder and starts without paired devices.
The journal and a desktop notification name the moved file.
Pair your devices again.

## Files, clipboard, and links

The [workflow controls](workflows.md) add an offline desktop outbox, folder archives, and saved clipboard snippets.

Use the Files and Clipboard pages in the desktop window, or run:

```sh
flux-cli send "$HOME/Downloads/report.txt"
flux-cli clip
flux-cli clip "Text from the desktop"
flux-cli url https://omarchy.org
```

On Android, share content to Flux from the system share sheet.
Received files use `download_dir`.
The phone can read folders of the desktop when `share_home` is enabled. See [Browse PC](#browse-pc).
The tunnel carries SSH traffic without an inbound SSH firewall rule.

A shared link opens in the browser of the desktop only when it is an `http` or `https` URL with a host.
Every other shared value is text, for example a `file:` URL, a path, or a link with another scheme.
Shared text goes on the desktop clipboard and in the clipboard history.
A notification shows the first 300 characters.
`flux-cli url` sends only an `http` or `https` URL with a host and refuses other values.

`fluxd` sends clipboard text and shared text of up to 256 KiB to a device, and it takes up to 1 MiB from a device.
`fluxd` ignores a larger text from a device and shows a message in the desktop window.
A desktop copy above 256 KiB goes only to the clipboard history. When a paired device is connected, the desktop window shows a message.
`flux-cli clip` and the `share.text` method refuse a text above 256 KiB.
The clipboard history keeps at most 16 MiB of text and drops the oldest entries first.
When `fluxd` restarts, the desktop clipboard loses text or an image that came from a device.

`fluxd` makes the name of a received file safe:

- It keeps only the file name and removes control characters and characters that change the text direction.
- It puts `_` before a name that starts with a dot or a dash, so the file is not hidden.
- It cuts a name to 200 bytes and keeps the extension.
- It adds a number, for example `photo (2).jpg`, when the name is taken. It never replaces a file.

A received file shows in the folder with its final name while it arrives, as an empty file.
`fluxd` writes the data to a hidden `.flux-*.part` file in the same folder and removes both files when the transfer fails.
Each device sends at most 4 files at the same time.
`fluxd` refuses or stops a file when less than 1 GiB would stay free on the disk.
On a disk that is smaller than 20 GiB, the limit is 5% of the disk.
It stops a transfer when the device sends no data for 1 minute.

The programs that `fluxd` opens, for example a browser, a received file, or a [desktop command](#media-and-desktop-commands), start in their own systemd scope.
A restart of `fluxd` after an update does not stop them.

## Browse PC

With `share_home = true`, a paired phone can read these folders of the desktop.
On the phone, open **Send > Get files**.

- The home folder.
- The `download_dir` folder.
- `~/Documents`, `~/Pictures`, `~/Music`, and `~/Videos`, when they exist.

`fluxd` serves only these folders, and only to read:

- It refuses each path outside the folders, also a `..` path and a symlink that points out of its folder.
- It hides each name that starts with a dot, such as `~/.ssh`, `~/.gnupg`, `~/.config`, and `~/.local`.
- It hides the Flux folders, which hold the private key of the computer.
- It shows only files and folders. A device, a socket, or a named pipe does not show.
- It refuses each change: an upload, a new folder, a rename, a removal, and a link.

A symlink to another drive does not show in the home folder.
When `~/Documents` or another folder of the list is such a symlink, open it from the list of folders.
`fluxd` does not offer a `download_dir` that holds the home folder, such as `/`, or a `download_dir` in a folder of home with a dot name.

To find a file by its name, type in the search field at the top of **Get files**.

- At the top of Home, the search reads each shared folder.
- In another folder, the search reads that folder and its subfolders.
- Each word must be in the name, in any case. For example, `invoice 2026` finds `Invoice-2026-09.pdf`.
- The search uses the same rules as the folder list. It also skips each `node_modules` folder. It does not read the contents of a folder that is a symlink.
- The search shows the first 100 matches, the best first.
- The search stops after 10 seconds. To find more, open a folder and search there.

A tap on a file downloads it. A tap on a folder opens it.

While the phone browses, the desktop shows a notification with a **Stop** button until the session ends.
The Overview page of the Flux window shows a **BROWSE PC** card with a **Stop** button too.
To see and end the sessions from a terminal, run:

```sh
flux-cli browse
flux-cli browse stop
```

A session ends after 1 hour, when the phone closes it, when the link drops, or when the device is unpaired.
A new session of the same phone ends the old one.

To end each session at once and stop new ones, set `share_home = false` in `~/.config/flux/config.toml`, then run:

```sh
systemctl --user reload fluxd
```

A script can also call the IPC method `settings.set` with the key `shareHome`:

```json
{"id":1,"method":"settings.set","params":{"key":"shareHome","value":false}}
```

## Clipboard images

A copied image goes to the other device, like copied text.
Turn on `auto_clipboard` on the desktop and **Sync clipboard** on the phone.
Both are on by default.

- Copy an image on the desktop, for example a screenshot. Then paste it in an app on the phone.
- Copy an image on the phone, open Flux, and tap **Send clipboard**. Then paste it on the desktop.

Android lets only the app on the screen read the clipboard.
Flux sends a phone copy by itself while Flux is on the screen.
For a copy in another app, use a 1-tap path.
See [Send a copy from another app](#send-a-copy-from-another-app).

The desktop sends PNG images.
The phone sends PNG, JPEG, GIF, and WebP images.
Flux syncs images of up to 16 MiB.
A copy that also has plain text syncs as text, for example cells from a spreadsheet.

Each device sends 1 image at a time. A newer image or text stops the image that is on its way.
When you turn off `auto_clipboard` or unpair the phone, the desktop stops the image that it sends.
An image that arrives after an unpair does not go into the history.

The Clipboard page shows the last 10 images.
Select **Copy** to put an image on the desktop clipboard again.
`fluxd` keeps these images in `$XDG_RUNTIME_DIR/flux/clipboard`, which is in memory.
It empties the folder when it starts and when it stops.

## Send a copy from another app

Android lets only the app on the screen read the clipboard, so a copy in
another app does not reach the computer by itself.
Flux offers 4 paths that need no setup:

- **Send clipboard** tile. Add it to the Quick Settings panel, then tap it after a copy. See [add the tile](android-setup.md#send-clipboard-tile).
- **Send clipboard** action on the Flux service notification, while a computer is connected.
- **Send to computer** in the text selection menu of any app.
- **Send with Flux** in the system share sheet.

The tile and the notification action send the current clip to each connected paired computer.
They skip a clip that its app marks as sensitive, for example a password, the same as **Sync clipboard**.
When no computer is connected yet, for example because the tile started a stopped Flux, the tile keeps the text for 15 seconds and sends it to the first computer that connects.
**Send to computer** and **Send with Flux** send the selected or shared text to the computer that you pick.
A link opens in the browser of the desktop, and other text goes on the desktop clipboard.
See [Files, clipboard, and links](#files-clipboard-and-links).

While Flux is on the screen, **Sync clipboard** skips a sensitive clip and the echo of a text that a computer put on the clipboard.
A later copy of the same text goes out.
Flux sends phone text of up to 1 MiB.

Android shows the message **Flux pasted from your clipboard** after each read.
To hide it, turn off **Show clipboard access** in the privacy settings of Android.
On a Samsung phone, the setting is **Alert when clipboard accessed**.

## Notifications

Enable notification access on the phone to show its notifications on the desktop.
**Share notifications** on the phone sends them to each connected paired computer.

Some notifications stay on the phone:

- A notification that the lock screen hides, because the notification or its channel has the visibility `VISIBILITY_SECRET`.
- The notifications of Flux, ongoing notifications, the notifications of foreground services, and group summaries.

Flux also shares the notifications of the apps in a work profile, with their reply fields and buttons.
Flux has no separate switch for them.

A button that needs the phone unlock or text input also stays on the phone.
The computer gets the reply field only when the reply does not need the phone unlock.
See [shared notifications](android-setup.md#shared-notifications).

To dismiss all of them, select **Clear all** on the Notifications page, or run:

```sh
flux-cli notifications clear
```

Clear all also dismisses the notifications on the phone.
An ongoing notification, such as a media player, stays.

The desktop shows the text of a phone notification as plain text.
`fluxd` keeps the first 256 bytes of the app name and the title, the first 4 KiB of the text, and up to 8 actions.
When the phone connects again, it sends its notifications again.
After 15 seconds, `fluxd` closes the desktop notifications that the phone no longer has.

A button on a desktop notification works only for a notification that `fluxd` showed with that button.
`fluxd` takes a click only from the program that owns `org.freedesktop.Notifications` on the session bus.

To send a notification in the other direction:

```sh
flux-cli notify "Backup done" "412 files, 2.1 GB"
```

The phone uses the **From computers** notification channel.
The desktop name identifies the sender.

## Text messages

Turn on **Text messages** in **Computers > Sync** on the phone.
The switch applies to every paired computer: each of them can then read your conversations and send text messages.
The phone asks for SMS access and contacts access.
Flux needs SMS access. Contacts access adds names to the conversations.
A tablet without a SIM slot does not show the switch.

The desktop then shows the **Messages** page for that phone:

- The list shows the latest message of each conversation. A dot marks an unread conversation.
- Select a conversation to read its last 100 messages and to reply.
- Select **New message** to send a text message to a phone number.
- A new message on the phone appears on the desktop in about 1 second.
- A reply goes out on the SIM of the conversation. A new message uses the default SMS SIM of the phone.
- The list keeps the 500 newest conversations and shows the first 1 KiB of each latest message.
- A conversation keeps up to 20 addresses and the first 256 bytes of its name. `fluxd` ignores an address that is longer than 64 bytes.
- A message from the desktop has at most 1600 characters, which is about 10 SMS parts. The phone also refuses a longer message.

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
Open **Media** in **Control** on the phone to play, pause, skip, seek, and set the volume. The **Inbox** also shows what plays now, with play and pause.
The controls show when a desktop player publishes its state over MPRIS.
The phone selects the player that plays.
If more than one player runs, select another player at the top of the screen.

The volume control shows only for a player that accepts a new volume, such as mpv.
Chromium does not accept one, so the phone shows no volume control for it.
When a player reports album art at an `https` address, the phone loads the image from that address and shows it above the controls.
Without album art, the controls move up.
The desktop does not show or control the players on the phone.

Add desktop commands in the Phone commands page or through the CLI:

```sh
flux-cli commands add "Lock screen" omarchy-system-lock
flux-cli commands
```

A new configuration has no commands.
The phone can request only the commands configured on the desktop.
A tap on a command shows **Sent** on the phone.
The desktop does not report the end of a command, so the phone does not show **Done**.

## Calls

Enable **Call alerts** in **Computers > Sync** on the phone.
Phone access reports call state.
Call-log access supplies the number, and contacts access supplies the name.
Without those optional details, the notification shows **Unknown caller**.

The daemon pauses desktop players that are active when the call starts.
When the call ends, it resumes those players.
A player that you manually resume during the call keeps its state.
A missed call produces a notification.
When the phone disconnects during a call, the call notification closes.
The paused players then stay paused, and the end of a later call does not resume them.

To keep media active during calls, set:

```toml
pause_media_on_call = false
```

Reload with `systemctl --user reload fluxd`.

## Do Not Disturb

Enable **Sync Do Not Disturb** in **Computers > Sync** on the phone.
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

Enable **Send new screenshots** or **Send new photos** in **Computers > Sync** on the phone.
Both options default to off.
Allow access to all photos when Android asks.
Selected-photo access does not expose new captures.

| Phone folder | Desktop destination |
| --- | --- |
| `Pictures/Screenshots` or `DCIM/Screenshots` | `<photo_dir>/screenshots` |
| `DCIM/Camera` | `<photo_dir>` |

Flux sends each completed image to every connected computer once.
The switches apply to every paired computer.
Images from before the option was enabled stay on the phone.
An image waits while no computer is connected.
The desktop notification includes an Open action.

Any app can put an image in a camera folder.
So Flux sends only the images of the default camera app and of the system apps, such as the camera and the screenshot tool.
It also sends an image without an owner app, which the media scanner found.
It skips the images of other apps and logs `not a camera or screenshot app`.

When a connected computer does not take an image, Flux tries again after 1 minute.
Each new wait is 2 times longer, up to 1 hour.
After 8 failed tries, Flux stops and shows the notification **Flux did not send** with the file name.
Only a try with a connected computer counts.

See [camera and streams](camera.md) for direct capture and live media.

## herdr agents

When [herdr](https://herdr.dev) runs on the computer, an agent that waits for input shows first in the phone's **Inbox**. To see all agents, select **Agents and terminals** in **Control**.
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

Then select **Touchpad and keyboard** in **Control** on the phone or in Flux for macOS.
See [Touchpad and keyboard](remote-input.md) for the gestures, the keys, and the slides.

## Remote desktop

The phone, the iPhone, or the Mac can show the screen of the computer and control it.
To allow it, turn on **Remote desktop** and **Remote input** in the **Remote access** card of the Flux window, or run:

```sh
flux-cli desktop on
flux-cli input on
```

Then select **Remote desktop** in **Control** on the phone. The phone turns to landscape.
In Flux for macOS, select **Remote desktop** in **Control**.
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

## Clear and expand text fields

Each text field of the app shows a clear key while it has text.
A field for a longer text also has an expand key. It opens a large editor of the same text on the full screen.

| Field | Clear key | Expand key |
| --- | --- | --- |
| Reply to a herdr agent | Empties the field | Editor with **Send** |
| Command of a herdr terminal | Empties the field | Editor with **Run** |
| Folder search when you start a herdr agent | Empties the search | None |
| Text field of the touchpad and the remote desktop | Deletes the typed text on the computer | Draft editor with **Type** |
| Scanned text in the text mode of the camera | Empties the field | Editor with **Send to** the computer |
| Search of **All shortcuts** in the Omarchy panel | Empties the search | None |
| Search of the dictation language picker | Empties the search | None |

The editor keeps the text when you close it, and **Clear** empties it.
On a phone in landscape with the keyboard open, the editor moves its keys to the top row, so that the text keeps the room.
See [Type on the phone](remote-input.md#type-on-the-phone) for the type field and the draft editor.
