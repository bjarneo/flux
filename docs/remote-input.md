# Touchpad and keyboard

[Documentation index](README.md)

Flux for Android and Flux for macOS can move the pointer, click, scroll, and type on the Omarchy computer.
The phone or the Mac controls the computer. The computer does not control the phone or the Mac.
Remote input is off by default, because the phone or the Mac can then type in any window, such as a terminal or the lock screen.

## Turn on remote input

1. Add this line to `~/.config/flux/config.toml`:

   ```toml
   remote_input = true
   ```

2. Reload the daemon:

   ```sh
   systemctl --user reload fluxd
   ```

3. Check that `wtype` is installed:

   ```sh
   flux-cli doctor
   ```

Omarchy installs `wtype`.
On another system, install it with `sudo pacman -S wtype`.

A script can also call the IPC method `settings.set` with the key `remoteInput`:

```json
{"id":1,"method":"settings.set","params":{"key":"remoteInput","value":true}}
```

See [IPC](ipc.md) for the socket.

## Use the touchpad on the phone

On the phone, open the computer and select **Touchpad and keyboard**.
The phone asks for its screen lock first. The unlock stays valid for 5 minutes.
A phone without a screen lock cannot open the touchpad.

| Gesture | Result |
| --- | --- |
| Move 1 finger | Move the pointer |
| Tap with 1 finger | Click |
| Tap with 2 fingers | Right-click |
| Tap with 3 fingers | Middle-click |
| Move 2 fingers | Scroll. The content follows the fingers. |
| Hold 1 finger still, then move it | Drag. The drag ends when the finger lifts. |

Hold **left** with 1 thumb and move a finger on the touchpad to drag with 2 hands.
**right** clicks the right button.

A fast finger moves the pointer further than a slow finger.
The screen stays on while the touchpad shows.

## Type on the phone

Tap the field at the bottom and type with the phone keyboard.
Flux sends each word after the keyboard stops composing it.
A correction from the keyboard replaces the word on the computer.
**Send** on the keyboard presses Enter.

To dictate, select the mic key next to the field.
The phone changes your speech to text on the device, and the computer types it at the cursor.
The Enter key next to the mic key sends Enter.

The key rows send Escape, Tab, the arrow keys, Backspace, and Enter.
**ctrl**, **alt**, **shift**, and **super** hold for the next key or letter.
For example, select **ctrl**, then type `c` to send Ctrl+C.
Select **super**, then type a space to open the Omarchy launcher.

`wtype` sends each character as its own key symbol.
The keyboard layout of the computer does not change the text.

## Change slides on the phone

Select the slides icon at the top right of the touchpad.
The volume keys then change slides: volume down sends Right, and volume up sends Left.
The volume keys work again as usual when you leave the touchpad or select the icon again.

## Use a Mac

The trackpad, the mouse, and the keyboard of the Mac can control the pointer and the keys of the Omarchy computer.

1. On the Mac, open the computer in Flux.
2. In the **Touchpad and Keyboard** card, select **Open Touchpad…**.
   The menu bar item also has **Touchpad and Keyboard…**.
3. Confirm with Touch ID or the password of the Mac.
   The unlock stays valid for 5 minutes while Flux runs.

The card shows **Off** and the steps above when `remote_input` is off on the computer.

### Give the pointer to the computer

Click the pad in the window.
The Mac cursor then hides and stays still, and the pad sends each motion, click, scroll, and key to the computer.
The pad has a green border while it controls the computer.

To give the pointer back to the Mac, press Control and Option together, then release them.
Control and Option with another key, such as Control-Option-T, go to the computer and do not release the pointer.
The pad also gives the pointer back when you close the window, or when another window or app comes to the front.
If the Mac cursor does not come back, press Command-Tab to go to another app.

| Action on the Mac | Result on the computer |
| --- | --- |
| Move on the trackpad or the mouse | Move the pointer |
| Click | Click |
| Secondary click or Control-click | Right-click |
| Middle button or Option-click | Middle-click |
| Scroll with 2 fingers or the wheel | Scroll |
| Press and move | Drag. The drag ends when you release the button. |

The pointer moves the same distance as the Mac cursor, with the tracking speed of the Mac.
The computer scrolls in the same direction as the Mac, so the **Natural scrolling** setting of the Mac applies.

### Type on the Mac

While the pad has the keyboard focus, the keys that you type go to the computer.
The pad has the focus when the window opens.
After you use the field at the bottom, click the pad to give it the focus again. The click also gives the pad the pointer.
Control, Option, Shift, and Command are **ctrl**, **alt**, **shift**, and **super** on the computer.

Command shortcuts go to the computer only while the pad controls the pointer.
Before that, the Mac keeps them, so Command-W closes the window.
macOS keeps its system shortcuts, such as Command-Tab and Command-Space.
To open the Omarchy launcher, select **super**, then press Space.
While the pad controls the pointer, Command and a digit switch to that workspace, and Command, Shift, and a digit move the window there.
This needs a `fluxd` that lists `flux.shortcuts`.

Option types the characters of the Mac keyboard layout, such as `@` on a Nordic layout.
With Control, Command, or a special key, Option is **alt**.
Select **Option is Alt** in the window to make Option **alt** for letters too.
Dead keys and input methods work as in other Mac apps.

These keys send the special keys of the computer: Delete (Backspace), Tab, the arrow keys, Page Up, Page Down, Home, End, Return, Fn-Delete (Delete), Escape, and F1 to F12.
On a Mac laptop, Fn with an arrow key sends Page Up, Page Down, Home, or End.
Hold Fn for F1 to F12 when the top row controls the brightness and the volume.

The key row sends Escape, Tab, the arrow keys, Backspace, and Enter.
**ctrl**, **alt**, **shift**, and **super** hold for the next key or text, as on the phone.

The field at the bottom sends each word after you type a space.
Return sends the rest of the field and presses Enter.
Backspace in the empty field presses Backspace on the computer.
The field does not correct the spelling and does not change quotes or dashes.

To dictate, select the mic key next to the field.
The Mac changes your speech to text, and the computer types it at the cursor.
The Enter key next to the mic key sends Enter.

### Change slides on the Mac

The arrow keys change slides while the pad has the keyboard focus.
A presenter remote that sends Page Up and Page Down works the same way.

## How it works

The phone and the Mac send `kdeconnect.mousepad.request` packets, like KDE Connect.
`fluxd` runs them only while `remote_input` is on.
After the link starts and after the setting changes, `fluxd` sends `flux.input` with `{"enabled": true}` or `{"enabled": false}`.

`fluxd` moves the pointer through the `zwlr_virtual_pointer_v1` Wayland protocol.
It types with `wtype`, which uses the `zwp_virtual_keyboard_v1` Wayland protocol.
Neither needs access to `/dev/uinput` or root.

A packet holds 1 action:

| Field | Action |
| --- | --- |
| `dx`, `dy` | Move the pointer by that many logical pixels. |
| `scroll` with `dx`, `dy` | Scroll. A positive `dy` scrolls down. |
| `singleclick`, `doubleclick`, `middleclick`, `rightclick` | Click. |
| `singlehold`, `singlerelease` | Press or release the left button. |
| `key` | Type the text. Control characters are removed. |
| `specialKey` | Press a key: 1 Backspace, 2 Tab, 4 Left, 5 Up, 6 Right, 7 Down, 8 Page Up, 9 Page Down, 10 Home, 11 End, 12 Enter, 13 Delete, 14 Escape, 21 to 32 F1 to F12. |
| `ctrl`, `alt`, `shift`, `super` | Hold the modifier for `key` or `specialKey`. |
| `x`, `y` | Flux extension: move the pointer to this position of the [remote desktop](remote-desktop.md) first. The values go from 0 to 1 across the monitor. |

## Troubleshooting

| Problem | Next step |
| --- | --- |
| The phone or the Mac says that remote input is off | Set `remote_input = true` and reload `fluxd`. |
| The phone or the Mac says to update Flux on the computer | Install a `fluxd` that lists `kdeconnect.mousepad.request`. |
| The Mac shows no **Touchpad and Keyboard** card | Connect the Mac to the computer. The card shows only for a `fluxd` that lists `kdeconnect.mousepad.request`. |
| The Mac cursor does not come back | Press Control and Option together, then release them. Or press Command-Tab. |
| The pointer does not move | Run `journalctl --user -u fluxd --no-pager \| grep "remote input"`. The compositor must offer `zwlr_virtual_pointer_manager_v1`. |
| The keys do nothing | Run `flux-cli doctor` and install `wtype` if it is missing. |
