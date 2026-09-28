# Remote desktop

[Documentation index](README.md)

Flux for Android can show the screen of the computer and control it with touches.
The remote desktop is off by default, because the phone can then see each window, such as a password manager.

## Turn on the remote desktop

1. Add these lines to `~/.config/flux/config.toml`:

   ```toml
   remote_desktop = true
   remote_input = true
   ```

   `remote_desktop` lets the phone show the screen.
   `remote_input` lets the touches and the keys control the computer.
   Without `remote_input`, the phone shows the screen as view only.

2. Reload the daemon:

   ```sh
   systemctl --user reload fluxd
   ```

3. Check that `gpu-screen-recorder` is installed:

   ```sh
   flux-cli doctor
   ```

Omarchy installs `gpu-screen-recorder`.
On another system, install it with `sudo pacman -S gpu-screen-recorder`.

A script can also call the IPC method `settings.set` with the key `remoteDesktop`:

```json
{"id":1,"method":"settings.set","params":{"key":"remoteDesktop","value":true}}
```

See [IPC](ipc.md) for the socket.

## Show the screen

On the phone, open the computer and select **Remote desktop**.
The phone asks for its screen lock first. The unlock stays valid for 5 minutes.
A phone without a screen lock cannot open the remote desktop.

The phone turns to landscape and hides its system bars.
To show the system bars for a moment, swipe from the edge of the screen.
The phone turns back when you leave the remote desktop.

The stream shows the monitor with the focus.
When the computer has more than 1 monitor, the name of the monitor shows next to the keyboard button.
Select the name to show the next monitor.

The stream runs while the remote desktop shows.
It stops when you leave the screen, when the app goes to the background, or when the link drops.
The screen of the phone stays on while the stream runs.

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

## Type

Select the keyboard button to show the keys.
The keys and the text field work as on the [touchpad](remote-input.md#type).
In landscape, the keys show at the right of the video.

To use a Super shortcut, select **super**, then type the key in the text field.
For example, select **super**, then type `w` to close the window.
Super and a digit switch to that workspace, and 0 is workspace 10.
Super, shift, and a digit move the window to that workspace.

To dictate, select the mic button next to the keyboard button, or the mic key next to the text field.
The phone changes your speech to text on the device, and the computer types it at the cursor.
Select the mic key again to stop. A long press on the mic key records until you lift the finger.
The Enter key next to the mic key sends Enter.

## Stop from the computer

When the stream starts, the computer shows a notification with a **Stop** button.

To see the state or to stop the stream, run:

```sh
flux-cli desktop
flux-cli desktop stop
```

To turn off the remote desktop, set `remote_desktop = false` and reload `fluxd`.
The reload stops a stream that runs.

## How it works

1. The phone opens a TLS listener and sends `flux.desktop` with `{"state": "start", "port": PORT, "maxSize": 1920}`.
2. `fluxd` connects to the port and checks the pinned certificate of the phone.
3. `gpu-screen-recorder` captures the monitor on the GPU and encodes H.264 into FLV.
4. `fluxd` reads each FLV tag and writes its frame to the phone.
5. `fluxd` sends `flux.desktop` with `{"state": "live"}`, the monitor, the monitor names, and the stream size.
6. The phone decodes the frames with the hardware decoder of the phone and shows each frame at once.

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

The touches are `kdeconnect.mousepad.request` packets with the Flux fields `x` and `y`.
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
| The phone says that the remote desktop is off | Set `remote_desktop = true` and reload `fluxd`. |
| The phone says to update Flux on the computer | Install a `fluxd` that lists `flux.desktop`. |
| The phone shows the screen, but a tap does nothing | Set `remote_input = true` and reload `fluxd`. |
| The screen capture stops | Run `journalctl --user -u fluxd --no-pager \| grep "remote desktop"` for the error of `gpu-screen-recorder`. |
| `gpu-screen-recorder` cannot capture the monitor | Run `getcap /usr/bin/gsr-kms-server`. The result must show `cap_sys_admin`. Install the package again to restore it. |
| The pointer goes to the wrong place | The compositor must name its monitors with `wl_output` version 4. Hyprland does. |
| The Omarchy panel shows an error | Set `remote_input = true` and reload `fluxd`. The panel also needs `hyprctl` and a Hyprland with a Lua configuration. |
| A shortcut is gone | Hyprland read its configuration again, so the references changed. Close the panel and open it again. |
