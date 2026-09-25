# Camera and streams

[Documentation index](README.md)

## Camera modes

The Android Camera screen includes text, QR, photo, document, and webcam modes.
Text recognition and barcode recognition use models bundled in the app.
Document capture uses the Google Play services document scanner.

Scanned text and documents use the desktop `scan_dir`.
Photos use `photo_dir`.
See [configuration](configuration.md) for their default paths.

## Phone as webcam

Install the optional packages and your kernel's matching headers.
For the standard Arch `linux` kernel:

```sh
sudo pacman -S --needed ffmpeg v4l2loopback-dkms linux-headers
sudo sh /usr/share/flux/post-install.sh
```

For another kernel, select its matching headers package.
The setup preserves existing `v4l2loopback` camera settings.

On the phone, open Camera, select Webcam, and press Start.
Desktop video apps see **Flux Camera**.

```sh
flux webcam
flux webcam set aspect=1:1 brightness=0.2
flux webcam reset
flux webcam stop
```

On the desktop, open the PHONE CAMERA card on Overview and select Settings.
On the phone, select Settings in Webcam mode.
The preview shows each change.
Changes to `aspect` or `resolution` restart the stream.
Other settings apply while the stream runs.

| Key | Values | Default |
| --- | --- | --- |
| `aspect` | `16:9`, `4:3`, `1:1`, `9:16` | `16:9` |
| `resolution` | `720`, `1080`, measured on the frame's short side | `720` |
| `camera` | `back`, `front` | `back` |
| `mirror` | `true`, `false` | `false` |
| `zoom` | `1` to the camera maximum | `1` |
| `exposure` | The camera's EV range | `0` |
| `whiteBalance` | `auto`, `daylight`, `cloudy`, `shade`, `incandescent`, `fluorescent`, `twilight` | `auto` |
| `brightness` | `-1` to `1` | `0` |
| `contrast` | `0` to `2` | `1` |
| `saturation` | `0` to `2` | `1` |
| `warmth` | `-1` to `1`. Higher values make the image warmer. | `0` |

`flux webcam reset` restores neutral image settings and keeps the aspect, resolution, and camera.
The phone limits values to its camera's capabilities and saves them for the next stream.

## Phone as microphone

On the phone, open Microphone and press Start.
The stream stops when you leave the screen.
Desktop apps see **Flux Microphone**.
The daemon uses `pw-cat` from PipeWire, so this feature needs no additional package on Omarchy.

```sh
flux mic
flux mic stop
```

To include audio with the webcam, enable **Also send the microphone** in the phone's Webcam settings.
The virtual source exists only while the phone streams.

## Screen mirror

Install `mpv` or use `ffplay` from FFmpeg:

```sh
sudo pacman -S --needed mpv
```

On the phone, select **Mirror screen** and accept the Android capture prompt.
The desktop window shows the screen but does not control phone input.

To stop, close the window, use the phone notification, or run:

```sh
flux screen
flux screen stop
```

The window uses the `flux-screen` app ID.
`dist/hyprland.lua` includes a floating-window rule for it.
