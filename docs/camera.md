# Camera and streams

[Documentation index](README.md)

## Camera modes

The Android Camera screen has text, QR, photo, document, and signature modes.
Select a mode in the mode strip above the shutter.
The webcam has its own screen: open **Control**, then **Webcam** in the **Stream** band.
Text recognition and barcode recognition use models bundled in the app.
Document capture uses the Google Play services document scanner.
The iPhone has the same modes with Apple's Vision and VisionKit. See [Flux for iOS](ios.md#features).

To add words to scanned text, select the mic key next to the text field and speak.
The words go in at the cursor on the Android phone and at the end of the text on the iPhone and the Mac.

Scanned text and documents use the desktop `scan_dir`.
Photos use `photo_dir`.
See [configuration](configuration.md) for their default paths.

## Signature

Signature mode turns a signature on paper into a transparent PNG that you can paste on the computer.

1. Sign on blank white paper with a dark pen.
2. In **Send**, open a camera mode, select **Signature** in the mode strip, and fit the signature in the frame.
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

An iPhone streams as a webcam too, and stops when Flux leaves its screen, because iOS gives the camera only to the app on the screen.

Install the optional packages and your kernel's matching headers.
For the standard Arch `linux` kernel:

```sh
sudo pacman -S --needed ffmpeg v4l2loopback-dkms linux-headers
sudo sh /usr/share/flux/post-install.sh
```

For another kernel, select its matching headers package.
The setup preserves existing `v4l2loopback` camera settings.

On the phone, open **Control**, select **Webcam** in the **Stream** band, and press **Start webcam**.
Desktop video apps see **Flux Camera**.

```sh
flux-cli webcam
flux-cli webcam set aspect=1:1 brightness=0.2
flux-cli webcam reset
flux-cli webcam stop
```

On the desktop, open the PHONE CAMERA card on Overview and select Settings.
On the phone, select **Settings** on the Webcam screen.
The preview shows each change.
Changes to `aspect` or `resolution` restart the stream.
Other settings apply while the stream runs.

| Key | Values | Default |
| --- | --- | --- |
| `aspect` | `16:9`, `4:3`, `1:1`, `9:16` | `16:9` |
| `resolution` | `720`, `1080`, measured on the frame's short side | `720` |
| `camera` | `back`, `front` | `back` |
| `mirror` | `true`, `false` | `false` |
| `zoom` | `1` to the camera maximum. Flux for Android allows at most `10`, and the iPhone and the Mac at most `4`. | `1` |
| `exposure` | The camera's EV range | `0` |
| `whiteBalance` | `auto`, `daylight`, `cloudy`, `shade`, `incandescent`, `fluorescent`, `twilight` | `auto` |
| `brightness` | `-1` to `1` | `0` |
| `contrast` | `0` to `2` | `1` |
| `saturation` | `0` to `2` | `1` |
| `warmth` | `-1` to `1`. Higher values make the image warmer. | `0` |

`flux-cli webcam reset` restores neutral image settings and keeps the aspect, resolution, and camera.
The phone limits values to its camera's capabilities and saves them for the next stream.

`fluxd` takes the settings and the camera capabilities only from the phone that streams.
It refuses settings with more than 4096 bytes, a list with more than 16 values, or a text with more than 128 characters.
It forgets the settings when the stream stops.
`fluxd` sends only the keys in the table to the phone.
It refuses a number outside the range -65536 to 65536, and a resolution that is negative or not a whole number.

The udev rule `61-flux-v4l2loopback.rules` gives the user at the seat access to the control device of `v4l2loopback`.
Each process of that user can then add and remove the loopback devices that no app has open.
`fluxd` removes only the device with the label **Flux Camera**.
A headless `fluxd` does not start the webcam.

## Phone as microphone

On the phone, open **Control**, select **Mic** in the **Stream** band, and press **Start the mic**.
The stream stops when you leave the screen.
Desktop apps see **Flux Microphone**.
The daemon uses `pw-cat` from PipeWire, so this feature needs no additional package on Omarchy.

```sh
flux-cli mic
flux-cli mic stop
```

To include audio with the webcam, enable **Also send the microphone** in the phone's Webcam settings.
The virtual source exists only while the phone streams.

`fluxd` keeps at most 150 milliseconds of audio in front of `pw-cat`.
After a stall of the network, it drops the oldest audio, so the delay does not grow.
The journal then shows `dropped audio after a network stall` once for the stream.

## Start from the computer

The computer can ask a paired device to start its webcam or its mic.
The device always asks you first.
Its camera and its microphone turn on only after you tap start on the device, also while Flux is on its screen.

To ask the device, run:

```sh
flux-cli webcam start
flux-cli mic start
```

The command prints the device that got the request:

```text
Asked Pixel 8 to start the webcam. Confirm on Pixel 8.
```

To ask 1 device of many, give its name or its ID:

```sh
flux-cli --device "Pixel 8" webcam start
flux-cli mic start --device "Pixel 8"
```

In the Flux window, open **Overview** and select **Start** on the **PHONE CAMERA** card or the **PHONE MICROPHONE** card.
The cards show **Start** while no stream of that kind runs and the selected device can take the request.
After the request, the card shows `Confirm on Pixel 8.` for 60 seconds, or until the stream starts.

The device shows the request in 1 of 2 forms:

| Flux on the device | What the device shows |
| --- | --- |
| On the screen | A prompt with the title `omarchy asks for the webcam` or `omarchy asks for the mic`. The prompt has the buttons **Start webcam** or **Start the mic**, and **Not now**. |
| Not on the screen | A notification with the text `Tap to start the webcam.` or `Tap to start the mic.` under the same title. On a Mac, the text starts with `Click`. The notification has a start action. |

The title has the name of the computer, as `flux-cli status` shows it.
The request ends after 60 seconds.
The prompt or the notification then goes away.
A tap on start opens the Webcam screen or the Mic screen of that computer.
The device then starts the stream with the saved settings when it can reach the computer.
When a stream of that kind already runs to that computer, the request does nothing.

Each platform has its own limits:

- Flux for Android waits up to 60 seconds until it can start the stream. It waits for the unlock of the phone and for the link. A tap on the notification shows the prompt. Only the start action starts the stream. See [webcam and mic requests](android.md#webcam-and-mic-requests).
- Flux for iOS waits up to 15 seconds until it can start the stream. A suspended Flux cannot remove the notification after 60 seconds. See [start a stream from the computer](ios.md#start-a-stream-from-the-computer).
- Flux for macOS shows the prompt only while Flux is the active app. Else it shows the notification. See [start a stream from the computer](macos.md#start-a-stream-from-the-computer).

`fluxd` refuses a request in these cases:

| Case | Error code |
| --- | --- |
| No `--device`, and no paired, connected device can take the request. An earlier Flux app cannot take it. Update Flux on the device. | `no_device` |
| No `--device`, and more than 1 device can take the request. The error lists the devices. Give `--device`. The name in `--device` can also match more than 1 device. Then give the device ID. | `ambiguous` |
| No device has the name or the ID in `--device`. | `not_found` |
| The device that `--device` names is not paired. | `not_paired` |
| The device that `--device` names has no link now. | `offline` |
| The device that `--device` names cannot take the request. An earlier Flux app cannot take it. `fluxd` in headless mode also returns this code, with or without `--device`. | `not_supported` |
| A stream of that kind runs. Stop it first, for example with `flux-cli webcam stop`. | `already_active` |
| The same device got a request of the same kind less than 3 seconds ago. The device also ignores such a request. | `too_soon` |

### Wire format

`fluxd` sends a `flux.stream.request` packet to the device:

```json
{"type":"flux.stream.request","body":{"kind":"webcam"}}
```

`kind` is `webcam` or `mic`.
The device ignores any other kind and any extra field.
A device lists `flux.stream.request` in its incoming packet types only when it can stream both kinds.
`fluxd` sends the packet only to a paired, connected device that lists it, the same as `flux.theme`.
The state of such a device has `streamrequest` in its `plugins`.

The packet only asks.
It never starts the camera or the microphone.
After the tap, the device starts the stream with its usual `flux.webcam` or `flux.mic` start packet, and `fluxd` handles it as each other start.

## Screen mirror

The iPhone does not mirror its screen. See [Flux for iOS](ios.md#screen-mirror).

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
`dist/hyprland.lua` includes a rule that floats the window and keeps it from taking the keyboard focus.
`ffplay` closes its window at the end of the stream, as `mpv` does.
A phone can start a new mirror at most once in 3 seconds.

## Stream sessions

The webcam, the microphone, and the screen mirror each have 1 session.
A new start stops the session that runs.
The new `ffmpeg`, `pw-cat`, or player starts after the old one stopped, so 2 of them never write to 1 device.
A stream stops when the phone stops it, when the link drops, when the device is unpaired, or when you stop it on the computer.
