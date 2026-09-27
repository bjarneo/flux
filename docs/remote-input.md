# Touchpad and keyboard

[Documentation index](README.md)

Flux for Android can move the pointer, click, scroll, and type on the computer.
Remote input is off by default, because the phone can then type in any window, such as a terminal or the lock screen.

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

## Use the touchpad

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

## Type

Tap the field at the bottom and type with the phone keyboard.
Flux sends each word after the keyboard stops composing it.
A correction from the keyboard replaces the word on the computer.
**Send** on the keyboard presses Enter.

The key rows send Escape, Tab, the arrow keys, Backspace, and Enter.
**ctrl**, **alt**, **shift**, and **super** hold for the next key or letter.
For example, select **ctrl**, then type `c` to send Ctrl+C.
Select **super**, then type a space to open the Omarchy launcher.

`wtype` sends each character as its own key symbol.
The keyboard layout of the computer does not change the text.

## Change slides

Select the slides icon at the top right of the touchpad.
The volume keys then change slides: volume down sends Right, and volume up sends Left.
The volume keys work again as usual when you leave the touchpad or select the icon again.

## How it works

The phone sends `kdeconnect.mousepad.request` packets, like KDE Connect.
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

## Troubleshooting

| Problem | Next step |
| --- | --- |
| The phone says that remote input is off | Set `remote_input = true` and reload `fluxd`. |
| The phone says to update Flux on the computer | Install a `fluxd` that lists `kdeconnect.mousepad.request`. |
| The pointer does not move | Run `journalctl --user -u fluxd --no-pager \| grep "remote input"`. The compositor must offer `zwlr_virtual_pointer_manager_v1`. |
| The keys do nothing | Run `flux-cli doctor` and install `wtype` if it is missing. |
