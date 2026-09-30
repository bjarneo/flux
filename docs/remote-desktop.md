# Remote desktop

[Documentation index](README.md)

Flux for Android and Flux for macOS can show the screen of the Omarchy computer and control it.
The phone or the Mac controls the computer. The computer does not control the phone or the Mac.
The phone is an Android phone or an iPhone with [Flux for iOS](ios.md). The iPhone uses the same touches as the Android phone.
The remote desktop is off by default, because the phone or the Mac can then see each window, such as a password manager.

## Turn on the remote desktop

1. Turn on **Remote desktop** and **Remote input** in the **Remote access** card of the Flux window.
   The card is on the **Overview** page.
   Or run these commands:

   ```sh
   flux-cli desktop on
   flux-cli input on
   ```

   The remote desktop lets the phone or the Mac show the screen.
   Remote input lets the touches, the mouse, and the keys control the computer.
   Without remote input, the phone or the Mac shows the screen as view only.

2. Check that `gpu-screen-recorder` is installed:

   ```sh
   flux-cli doctor
   ```

Omarchy installs `gpu-screen-recorder`.
On another system, install it with `sudo pacman -S gpu-screen-recorder`.

`gpu-screen-recorder` supports AMD, Intel, and NVIDIA drivers.
On another GPU, for example an older NVIDIA card on `nouveau`, install `wf-recorder` with `sudo pacman -S wf-recorder`.
`fluxd` then captures the monitor through Hyprland and encodes it on the CPU.

`fluxd` saves the settings as `remote_desktop` and `remote_input` in `~/.config/flux/config.toml`.
After a manual edit of that file, run `systemctl --user reload fluxd`.

A script can also call the IPC method `settings.set` with the key `remoteDesktop`:

```json
{"id":1,"method":"settings.set","params":{"key":"remoteDesktop","value":true}}
```

See [IPC](ipc.md) for the socket.

## Show the screen

On the phone, open the computer and select **Remote desktop**.
The phone asks for its screen lock first. The unlock stays valid for 5 minutes.
A phone without a screen lock cannot open the remote desktop.
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
The computer shows its screen to each paired device while `remote_desktop` is on.

The phone turns to landscape and hides its system bars.
To show the system bars for a moment, swipe from the edge of the screen.
The phone turns back when you leave the remote desktop.

The stream shows the monitor with the focus.
When the computer has more than 1 monitor, the name of the monitor shows next to the keyboard button.
Select the name to show the next monitor.

The stream runs while the remote desktop shows.
It stops when you leave the screen, when the app goes to the background, or when the link drops.
It also stops when the phone closes the stream, and when the device is unpaired.
The screen of the phone stays on while the stream runs.

## Unlock the computer

The stream shows the lock screen, so you can unlock the computer from the phone.

1. Select **Remote desktop**. The video shows the lock screen.
2. Tap the video to put the cursor in the password field.
3. Select the keyboard button and type the password in the text field.
4. Select **Send** on the phone keyboard to press Enter.

The Omarchy lock screen turns the displays off 5 seconds after the last key or pointer move.
A display that is off has no image, so `fluxd` turns the displays on to start the stream.
When the displays go off during the stream, the video stops at the last image.
Tap the video to turn the displays on again.

If your phone keyboard corrects words, turn off the corrections before you type the password.
The keyboard can change a word after you type it, and the computer then gets the changed text.

`fluxd` does not limit the password tries from a phone.
The `faillock` setting of PAM on the computer limits them, as for the keyboard of the computer.

## Use the touches

| Gesture | Result |
| --- | --- |
| Tap | Click at the finger |
| Tap 2 times fast | Double-click. A second tap near the first tap clicks at the same position. |
| Hold 1 finger still | Right-click at the finger |
| Hold 1 finger still, then move it | Drag. The drag ends when the finger lifts. |
| Move 2 fingers | Scroll the window under the fingers. The content follows the fingers. |
| Tap with 2 fingers | Right-click |
| Pinch | Zoom the view on the phone, up to 6 times |
| Move 1 finger | Move the zoomed view |

The pointer of the computer goes to the position of each touch.
The stream shows the pointer.

## Move around Omarchy

Select the grid button to show the Omarchy panel.
In landscape, the panel shows at the right of the video. In portrait, it shows under the video.

| Control | Result |
| --- | --- |
| Workspace 1 to 10 | Tap to switch to the workspace. Hold to move the focused window there. |
| Arrows | Focus the window in that direction. |
| **focus** in the middle of the arrows | Select **move**. The arrows then swap the window in that direction. |
| **close**, **full**, **float**, **split** | Close the window, show it full screen, float or tile it, or toggle the split. |
| **next**, **scratch** | Focus the next window, or show and hide the scratchpad. |
| Launch | Run a pinned shortcut, such as the Omarchy menu, the terminal, or the browser. |
| **all shortcuts** | Search all key bindings of Hyprland that have a description. Tap one to run it. Select the star to pin it to Launch. |

The active workspace is blue. A workspace with windows has a dot.
The panel reads the workspaces again every 3 seconds.
The panel pins the Omarchy menu, the Apps menu, the terminal, the browser, the file manager, and the screenshot until you pin others.

The panel needs `remote_input = true` and Hyprland with a Lua configuration, as in Omarchy.
It runs each action in Hyprland, so it works also for the Omarchy bindings that the keys cannot press.

While the computer is locked, the panel shows only the workspaces.
A shortcut, a window action, or the list of shortcuts shows **Unlock the computer first**.
The keyboard of the computer also runs no normal binding on the lock screen.
Unlock the computer on the remote desktop, then open the panel again.

## Type

Select the keyboard button to show the keys.
The keys and the text field work as on the [touchpad](remote-input.md#type-on-the-phone).
In landscape, the keys show at the right of the video.

To use a Super shortcut, select **super**, then type the key in the text field.
For example, select **super**, then type `w` to close the window.
Super and a digit switch to that workspace, and 0 is workspace 10.
Super, shift, and a digit move the window to that workspace.

To dictate, select the mic button next to the keyboard button, or the mic key next to the text field.
The phone changes your speech to text on the device, and the computer types it at the cursor.
Select the mic key again to stop. A long press on the mic key records until you lift the finger.
The Enter key next to the mic key sends Enter.

## Use a Mac

On the Mac, open the computer in Flux.
In the **Remote Desktop** card, select **Open Remote Desktop…**.
The menu bar item also has **Remote Desktop…**.
The Mac asks for Touch ID or its password first. The unlock stays valid for 5 minutes, until the Mac sleeps or locks.
After that, the Mac asks again before it opens the remote desktop. See [Touch ID lock](macos.md#touch-id-lock).

The card shows **Off** and the steps to turn it on when the remote desktop is off on the computer.
Without remote input, the window shows **View only**, and the mouse and the keys do nothing on the computer.

The window shows the monitor with the focus.
The video keeps the shape of the monitor, with bars at the sides or at the top and the bottom.
You can resize the window or show it full screen.
When the computer has more than 1 monitor, select the monitor in the bar over the video.

The Mac shows 1 remote desktop at a time.
The stream stops when you close the window.
It stops while the window is in the Dock and while the Mac sleeps or is locked, and it starts again when you come back.
It also stops when the link drops, and it starts again when the link comes back while the window shows and the Mac is unlocked.
To start it by hand, select **Start Again**.

### The mouse on a Mac

The pointer of the computer goes to the position of the Mac pointer on the video.

| Action on the Mac | Result on the computer |
| --- | --- |
| Move the pointer over the video | Move the pointer |
| Click | Click |
| Double-click | Double-click |
| Secondary click or Control-click | Right-click |
| Middle button or Option-click | Middle-click |
| Press and move | Drag. The drag ends when you release the button. |
| Scroll with 2 fingers or the wheel | Scroll the window under the pointer, in the same direction as on the Mac |

A click on the bars does nothing.

### The keys on a Mac

Click the video to give it the keyboard focus.
The keys that you type then go to the computer, as on the [touchpad](remote-input.md#type-on-the-mac).
Control, Option, Shift, and Command are **ctrl**, **alt**, **shift**, and **super**.
Command shortcuts go to the computer only while the pointer is over the video.
Move the pointer off the video to use a Command shortcut of the Mac, such as Command-W.
macOS keeps its system shortcuts, such as Command-Tab and Command-Space.
Command and a digit switch to that workspace, and Command, Shift, and a digit move the window there.

Select the keyboard button in the bar to show the key rows and the text field.
They work as on the touchpad.
To dictate, select the mic button in the bar, or the mic key next to the text field.
The Mac changes your speech to text, and the computer types it at the cursor.
The Mac uses the language of the dictation of herdr agents.
The Enter key next to the mic key sends Enter.

### The Omarchy panel on a Mac

Select the grid button in the bar to show the Omarchy panel at the right of the video.
It has the same controls as on the phone.
Click a workspace to switch to it.
Option-click a workspace to move the focused window there, or use the menu of the workspace.
Select **All Shortcuts…** to search the shortcuts. Select the star to pin a shortcut to Launch.
The Mac saves the pinned shortcuts.

## Stop from the computer

When the stream starts, the computer shows a notification with a **Stop** button.

The **Remote access** card of the Flux window shows the device and the monitor, with a **Stop** button.
To see the state or to stop the stream from a terminal, run:

```sh
flux-cli desktop
flux-cli desktop stop
```

To turn off the remote desktop, turn off **Remote desktop** in the Flux window, or run:

```sh
flux-cli desktop off
```

This also stops a stream that runs, and a stream that still starts.
To stop the stream of a phone that you do not trust, unpair the phone.

## How it works

1. The phone opens a TLS listener and sends `flux.desktop` with `{"state": "start", "port": PORT, "maxSize": 1920}`.
   The Mac does the same, with the longest side of its screen in pixels as `maxSize`.
2. `fluxd` connects to the port and checks the pinned certificate of the phone.
   When `gpu-screen-recorder` lists no monitor, `fluxd` turns the displays on with `hyprctl` and lists them again for up to 3 seconds.
3. `gpu-screen-recorder` captures the monitor on the GPU and encodes H.264 into FLV.
   When `gpu-screen-recorder` fails to list the monitors and `wf-recorder` is installed, `wf-recorder` captures the monitor through Hyprland and `libx264` encodes it on the CPU.
4. `fluxd` reads each FLV tag and writes its frame to the phone.
5. `fluxd` sends `flux.desktop` with `{"state": "live"}`, the monitor, the monitor names, and the stream size.
6. The phone decodes the frames with the hardware decoder of the phone and shows each frame at once.

`fluxd` runs 1 stream at a time.
A new start stops the stream that runs, and the new recorder starts after the old recorder stopped.
Before the recorder starts, `fluxd` checks again that `remote_desktop` is on and that the device is paired.
The phone sends nothing on the stream, so `fluxd` stops the stream when the phone closes it.

The phone can add `"monitor": "DP-1"` to the start packet to select a monitor.
`maxSize` limits the long side of the stream from 640 to 3840 pixels.
The stream keeps the shape of the monitor.

The stream uses constant quality at 30 frames each second, with a key frame each 2 seconds.
A screen that does not change needs less than 0.5 Mbit/s.
A small socket buffer keeps the delay short on a slow network, because the recorder then skips frames.

Each frame on the stream has this form:

| Field | Size | Content |
| --- | --- | --- |
| Length | 4 bytes, big-endian | The size of the data |
| Flags | 1 byte | 1: the SPS and the PPS. 2: a key frame. 4: the video size. 0: another frame. |
| Data | Length bytes | H.264 NAL units with 4-byte start codes, or 2 big-endian 16-bit numbers for the width and the height |

The first frame is the video size.
Each frame comes whole, so the phone can decode it when its last byte arrives.

The touches are `flux.mousepad.request` packets with the fields `x` and `y`.
The values go from 0 at the top left corner to 1 at the bottom right corner of the monitor.
`fluxd` moves the pointer to the position, then runs the action of the packet.
It moves the pointer through a `zwlr_virtual_pointer_v1` pointer for the monitor of the stream.
`fluxd` ignores a position when the phone shows no remote desktop.
See the [wire format of remote input](remote-input.md#how-it-works).

`fluxd` sends `flux.input` with `{"enabled": bool, "desktop": bool}` after the link starts and after a setting changes.
The phone uses `desktop` to show the **Remote desktop** tile as on or off.

### Omarchy panel

The Omarchy panel uses `flux.shortcuts`. Each packet needs `remote_input = true`.

| Body from the phone | Result |
| --- | --- |
| `{"request": true}` | The key bindings and the workspaces |
| `{}` | The workspaces |
| `{"run": "315"}` | Run the key binding with that reference, then send the workspaces |
| `{"action": "workspace", "workspace": 3}` | Switch to the workspace, from 1 to 10 |
| `{"action": "moveToWorkspace", "workspace": 3}` | Move the focused window to the workspace |
| `{"action": "focus", "direction": "l"}` | Focus the window at the left. The directions are `l`, `r`, `u`, and `d`. |
| `{"action": "swap", "direction": "l"}` | Swap the window with the window at the left |
| `{"action": "close"}` | Also `fullscreen`, `float`, `split`, `scratchpad`, `nextWindow`, `nextWorkspace`, and `previousWorkspace` |

`fluxd` answers with `{"shortcuts": [{"ref", "keys", "description"}], "workspaces": [{"id", "windows"}], "active": 3}`, or with `{"error": "..."}`.
An answer to an action has no `shortcuts`.

While the computer is locked, `fluxd` answers each body except `{}` with `{"error": "Unlock the computer first"}`.
It finds the lock in 3 ways: the `LockedHint` of the logind session, a running `hyprlock`, or a Hyprland session lock on a monitor.
The Omarchy lock screen is a Hyprland session lock.

Each device has 1 request in flight.
The requests that come during it join into 1 next request, and the last action wins.

In a Lua configuration, each Hyprland key binding calls a Lua function.
`hyprctl binds` shows the registry reference of that function as the argument of the `__lua` dispatcher.
To run a binding, `fluxd` reads the bindings again, checks that the reference is in the list, and runs `hyprctl eval` with that reference.
The phone can run only a binding that the configuration defines.

`fluxd` runs each action with `hyprctl dispatch` and a fixed Lua dispatcher, for example `hl.dsp.focus({ workspace = "3" })`.
It checks the workspace number and the direction first.
The keys of the phone go through `wtype`, which has its own keymap.
A binding to a key code, such as `SUPER + code:10` for workspace 1, does not match those keys, so the phone uses the actions for the workspaces.

## Troubleshooting

| Problem | Next step |
| --- | --- |
| The phone or the Mac says that the remote desktop is off | Run `flux-cli desktop on`, or turn on **Remote desktop** in the Flux window. |
| The phone or the Mac says that `gpu-screen-recorder` finds no monitor | The displays are off. `fluxd` turns them on with `hyprctl`, so check that `hyprctl monitors` answers. |
| The video stops at the lock screen | The lock screen turned the displays off. Tap or click the video. |
| The phone or the Mac says to update Flux on the computer | Install a `fluxd` that lists `flux.desktop`. |
| The phone shows the screen, but a tap does nothing | Run `flux-cli input on`, or turn on **Remote input** in the Flux window. |
| The Mac shows **View only** | Run `flux-cli input on`, or turn on **Remote input** in the Flux window. |
| The Mac shows no **Remote Desktop** card | Connect the Mac to the computer. The card shows only for a `fluxd` that lists `flux.desktop`. |
| A Command shortcut goes to the Mac | Move the pointer over the video, then press the shortcut again. |
| The screen capture stops | Run `journalctl --user -u fluxd --no-pager \| grep "remote desktop"` for the error of `gpu-screen-recorder`. |
| The Mac or the phone says `list the monitors: exit status 22` | `gpu-screen-recorder` does not support the GPU. Install `wf-recorder`, then start the remote desktop again. |
| `gpu-screen-recorder` cannot capture the monitor | Run `getcap /usr/bin/gsr-kms-server`. The result must show `cap_sys_admin`. Install the package again to restore it. |
| The pointer goes to the wrong place | The compositor must name its monitors with `wl_output` version 4. Hyprland does. |
| The Omarchy panel shows an error | Run `flux-cli input on`. The panel also needs `hyprctl` and a Hyprland with a Lua configuration. |
| A shortcut is gone | Hyprland read its configuration again, so the references changed. Close the panel and open it again. |
| The Omarchy panel shows **Unlock the computer first** | The computer is locked. Unlock it on the remote desktop, then open the panel again. |
