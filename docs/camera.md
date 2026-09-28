# Camera and streams

[Documentation index](README.md)

## Camera modes

The Android Camera screen includes text, QR, photo, document, signature, and webcam modes.
Text recognition and barcode recognition use models bundled in the app.
Document capture uses the Google Play services document scanner.

To add words to scanned text, select the mic key next to the text field and speak.
The words go in at the cursor on the phone and at the end of the text on the Mac.

Scanned text and documents use the desktop `scan_dir`.
Photos use `photo_dir`.
See [configuration](configuration.md) for their default paths.

## Signature

Signature mode turns a signature on paper into a transparent PNG that you can paste on the computer.

1. Sign on blank white paper with a dark pen.
2. Open **Camera**, then **Signature**, and fit the signature in the frame.
3. Tap the shutter. To use a photo that you already have, tap the gallery button instead.
4. Select **Black**, **Blue**, or **Original** for the ink color.
5. Tap **Send**.

The phone removes the paper, the shadows, and small specks, and crops to the ink.
The computer puts the PNG on the clipboard as `image/png` and saves a copy in `<photo_dir>/signatures`.
Paste it into an app that accepts images, such as a PDF editor or a document.

For a clean result, use even light and fill the frame with the signature.
A printed line or text near the signature also becomes part of the image.
To check the clipboard, run:

```sh
wl-paste --list-types
```

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
flux-cli webcam
flux-cli webcam set aspect=1:1 brightness=0.2
flux-cli webcam reset
flux-cli webcam stop
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

`flux-cli webcam reset` restores neutral image settings and keeps the aspect, resolution, and camera.
The phone limits values to its camera's capabilities and saves them for the next stream.

## Phone as microphone

On the phone, open Microphone and press Start.
The stream stops when you leave the screen.
Desktop apps see **Flux Microphone**.
The daemon uses `pw-cat` from PipeWire, so this feature needs no additional package on Omarchy.

```sh
flux-cli mic
flux-cli mic stop
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
flux-cli screen
flux-cli screen stop
```

The window uses the `flux-screen` app ID.
`dist/hyprland.lua` includes a floating-window rule for it.
