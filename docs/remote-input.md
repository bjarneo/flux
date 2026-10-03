# Touchpad and keyboard

[Documentation index](README.md)

Flux for Android and Flux for macOS can move the pointer, click, scroll, and type on the Omarchy computer.
The phone or the Mac controls the computer. The computer does not control the phone or the Mac.
The phone is an Android phone or an iPhone with [Flux for iOS](ios.md). The iPhone uses the same gestures and keys. Its volume keys do not change slides, because iOS gives apps no public way to take them.
Remote input is off by default, because the phone or the Mac can then type in any window, such as a terminal or the lock screen.

## Turn on remote input

1. Turn on **Remote input** in the **Remote access** card of the Flux window.
   The card is on the **Overview** page.
   Or run this command:

   ```sh
   flux-cli input on
   ```

2. Check that `wtype` is installed:

   ```sh
   flux-cli doctor
   ```

Omarchy installs `wtype`.
On another system, install it with `sudo pacman -S wtype`.

`fluxd` saves the setting as `remote_input` in `~/.config/flux/config.toml`.
After a manual edit of that file, run `systemctl --user reload fluxd`.
To turn off remote input, turn off **Remote input** in the Flux window, or run `flux-cli input off`.

A script can also call the IPC method `settings.set` with the key `remoteInput`:

```json
{"id":1,"method":"settings.set","params":{"key":"remoteInput","value":true}}
```

See [IPC](ipc.md) for the socket.

## Use the touchpad on the phone

On the phone, open **Control** and select **Touchpad and keyboard**.
The phone asks for its screen lock first. The unlock stays valid for 5 minutes.
A phone without a screen lock cannot open the touchpad.
The phone also asks when the switch on the computer is off or not known yet.
The computer can turn the switch on while the page shows.

After the 5 minutes, the open page asks for the screen lock again in these cases:

- Flux comes back to the front.
- The computer connects again, or it turns its switch on.

If you cancel, the page closes.
See [remote control and the phone lock](android-setup.md#remote-control-and-the-phone-lock).

The iPhone asks for Face ID, Touch ID, or the passcode.
Its unlock also ends when the iPhone locks, and the open page asks again when Flux comes back after the unlock ended.

This check protects the phone app only.
The computer takes the input of each paired device while `remote_input` is on, also on its lock screen.
The `faillock` setting of PAM on the computer limits the password tries on the lock screen.
On the lock screen, the touchpad and the remote desktop keep working, but the [Omarchy panel](remote-desktop.md#move-around-omarchy) runs no shortcut and no window action.

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

The field keeps the text that it typed since the last click, key, or dictation.
To delete that text on the computer, select the clear key at the end of the field.
The computer gets 1 Backspace for each character.
A click, a key of the key rows, Enter, or a dictation can move the cursor of the computer.
After each of them, the field starts again empty, and the text stays on the computer.

To write a longer text first, select the expand key at the start of the field.
The draft editor opens on the full screen.
Write and correct the text there with the phone keyboard, then select **Type**.
The computer types the whole text at its cursor.
Each line break goes as Shift+Enter, so that a chat box keeps the lines in 1 message.
The close button keeps the draft for later, and **Clear** empties it.
A draft holds at most 4000 characters and 100 lines.

To dictate, select the mic key next to the field.
The phone changes your speech to text on the device, and the computer types it at the cursor.
The Enter key next to the mic key sends Enter.

The key rows send Escape, Tab, the arrow keys, Backspace, and Enter.
While the field has text, Backspace deletes the last character of the field and of the computer.
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

1. On the Mac, open **Control** in Flux.
2. Select **Touchpad and keyboard**.
   When more than 1 computer can take the input, select the computer.
   While remote input is on, the menu of the computer in the menu bar panel also has **Touchpad and Keyboard…**.
3. Confirm with Touch ID or the password of the Mac.
   The unlock stays valid for 5 minutes, until the Mac sleeps or locks.
   After that, the Mac asks again before it opens the touchpad. See [Touch ID lock](macos.md#touch-id-lock).

While `remote_input` is off on the computer, the tool is dimmed and its line shows `Off on <computer>`.
To turn on remote input, run `flux-cli input on` on the computer.
Or set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.
See [Turn on remote input](#turn-on-remote-input).

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
The clear key at the end of the field empties the field.
The field holds only the text that did not go to the computer yet, so the clear key sends no keys.

To write a longer text first, select the expand key next to the field.
The draft editor works as on the phone.
Command-Return selects **Type**.

To dictate, select the mic key next to the field.
The Mac changes your speech to text, and the computer types it at the cursor.
The Enter key next to the mic key sends Enter.

### Change slides on the Mac

The arrow keys change slides while the pad has the keyboard focus.
A presenter remote that sends Page Up and Page Down works the same way.

## How it works

The phone and the Mac send `flux.mousepad.request` packets.
`fluxd` runs them only while `remote_input` is on.
After the link starts and after the setting changes, `fluxd` sends `flux.input` with `{"enabled": true, "keyRepeat": true}` or `{"enabled": false, "keyRepeat": true}`.
`keyRepeat` tells the phone and the Mac that `fluxd` reads `repeat`.

The actions wait in 1 queue of at most 256 actions, and of at most 16384 characters of text and repeated key presses.
A packet goes into the queue with all of its actions, or `fluxd` drops it.
4 places of the queue stay free for a button release, so a full queue does not keep a button down.
Before each action, `fluxd` checks again that `remote_input` is on, that the device is paired, and that its link is the same.
When 1 of these checks fails, `fluxd` does these steps:

- It drops the actions that wait.
- It stops the text that `wtype` still types.
- It releases a button that the device holds, for example after a drag.

A `wtype` run stops after 5 seconds plus 5 milliseconds for each character, so a compositor that does not answer does not stop the next keys.

`fluxd` moves the pointer through the `zwlr_virtual_pointer_v1` Wayland protocol.
It types with `wtype`, which uses the `zwp_virtual_keyboard_v1` Wayland protocol.
Neither needs access to `/dev/uinput` or root.

A packet holds 1 action:

| Field | Action |
| --- | --- |
| `dx`, `dy` | Move the pointer by that many logical pixels. |
| `scroll` with `dx`, `dy` | Scroll. A positive `dy` scrolls down. |
| `singleclick`, `middleclick`, `rightclick` | Click. |
| `singlehold`, `singlerelease` | Press or release the left button. |
| `key` | Type the text. Control characters are removed. |
| `specialKey` | Press a key: 1 Backspace, 2 Tab, 4 Left, 5 Up, 6 Right, 7 Down, 8 Page Up, 9 Page Down, 10 Home, 11 End, 12 Enter, 13 Delete, 14 Escape, 21 to 32 F1 to F12. |
| `repeat` with `specialKey` | Press the key that many times in 1 `wtype` run, at most 4096 times. The clear key of the type field uses it. Without `keyRepeat` in `flux.input`, the phone sends 1 packet for each press, and the type field starts again after 48 characters at the end of a word, so that a clear never fills the queue. |
| `ctrl`, `alt`, `shift`, `super` | Hold the modifier for `key` or `specialKey`. |
| `x`, `y` | Move the pointer to this position of the [remote desktop](remote-desktop.md) first. The values go from 0 to 1 across the monitor. |

## Troubleshooting

| Problem | Next step |
| --- | --- |
| The phone or the Mac says that remote input is off | Run `flux-cli input on`, or turn on **Remote input** in the Flux window. |
| The phone or the Mac says to update Flux on the computer | Install a `fluxd` that lists `flux.mousepad.request`. |
| The Mac shows no **Touchpad and keyboard** tool in **Control** | Connect the Mac to the computer. The tool shows only when a computer in the scope has a `fluxd` that lists `flux.mousepad.request`. |
| The Mac cursor does not come back | Press Control and Option together, then release them. Or press Command-Tab. |
| The pointer does not move | Run `journalctl --user -u fluxd --no-pager \| grep "remote input"`. The compositor must offer `zwlr_virtual_pointer_manager_v1`. |
| The keys do nothing | Run `flux-cli doctor` and install `wtype` if it is missing. |
