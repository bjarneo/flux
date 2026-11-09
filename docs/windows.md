# Flux for Windows

[Documentation index](README.md)

Flux for Windows connects a Windows computer to an Omarchy computer that runs `fluxd`.
Windows takes the place of a phone, as the Mac does: it uses Flux protocol version 8 and pairs only with computers that run `fluxd`.
The app follows the Mac app. Its core library, FluxKit, is a port of the Swift FluxKit, and its views follow the macOS section of the [design system](../DESIGN.md).
The app requires Windows 10 version 2004 or later, or Windows 11.

The Windows app is new. Its views run on the Windows runner of CI, but nobody checked them on a Windows computer yet.

## Install

Each release has the app as `flux-windows-VERSION.exe` on the [releases page](https://github.com/bjarneo/flux/releases). It is 1 file that holds .NET, so the computer needs no .NET runtime. Put it in a folder of your choice and start it.

The file has no Authenticode signature yet. Windows SmartScreen then shows "Windows protected your PC". Check the file against `SHA256SUMS` of the release first:

```powershell
Get-FileHash flux-windows-VERSION.exe -Algorithm SHA256
```

Then select **More info** and **Run anyway**.

At the first start, Flux adds a shortcut to the Start menu. Windows needs it to show the notifications of Flux.

## Build and run

Install the .NET 10 SDK. From the repository root, run the tests and build the app:

```powershell
dotnet test windows/FluxKit.Tests -c Release
dotnet run --project windows/Flux.UiTests -c Release
dotnet publish windows/Flux -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o windows/artifacts/win-x64
windows/artifacts/win-x64/Flux.exe
```

`Flux.exe` is 1 file that holds .NET, so the computer needs no .NET runtime.
The Windows workflow builds the same file on each push to `master` that changes `windows/`, and keeps it as the artifact `Flux-win-x64`.

On Linux, the tests and the build run in the .NET SDK container, because WPF builds for Windows on any system:

```sh
docker run --rm -v "$PWD":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test windows/FluxKit.Tests -c Release
```

`Flux.UiTests` runs only on Windows.

## Pair a Windows computer

1. On the Omarchy computer, run `flux-cli setup` once.
2. Start Flux on Windows. Before the first pairing, Chats shows the pairing guide with the computers that Flux found.
3. Select the computer, then select **Pair…**. The dialog shows a key of 16 characters.
4. Select **Send request**. Accept the request on the computer when it shows the same key.

A request from the computer shows in the list of Chats and as a notification with the key. Accept it only when both screens show the same key.
Flux looks for computers for 10 seconds at the start and after **Search again** in Computers. A paired computer connects by itself.

Windows asks once whether Flux may use the network. Allow private networks, or the computer cannot connect to Windows.

## Features

| Feature | What Windows does |
| --- | --- |
| Files | Sends files to the computer from **File** in the tray of its chat, a drop on its chat, the tray menu, or **Send to > Flux** in File Explorer. The tray of a chat also sends the newest screenshots, see [Screenshots](#screenshots). Settings > Features > Files adds Flux to the **Send to** menu. Receives files from `flux-cli send` in Downloads, with resumable transfers |
| Text and links | Sends the text of the field of a chat. A single web address opens in the browser of the computer, and other text goes on its clipboard. A link from the computer waits in a notification with **Open** |
| Clipboard | Syncs copied text both ways. **Send** in the clipboard row of a chat sends the clipboard at once |
| Theme | Draws the Omarchy theme of the computer in scope. Settings has Computer, System, Light, and Dark |
| Battery | Sends the battery of a laptop. Shows the battery of a computer in the scope menu and in Computers |
| Notifications | Shows the notifications of `flux-cli notify` as Windows notifications. A click on a notification opens the chat of its computer |
| Commands | Runs the commands of the computer from Control |
| Media | Plays, pauses, skips, seeks, and sets the volume of the players of the computer, from Control. The [audio outputs](features.md#audio-outputs) and the [phone as speaker](camera.md#phone-as-speaker) are only in Flux for Android. |
| Ping | Sends a ping from the tray. A ping from the computer shows in the window |
| herdr agents | Shows each agent as a chat in the list of Chats, and the agents in Control and the tray panel. The chat of an agent shows its thread, the question with its choices, the changes, and the keys. The agents window shows the same thread for each agent of a computer. A click on an agent notification opens the chat of the agent. **Start Agent** starts a coding agent in a folder of the computer |
| Touchpad | Moves the pointer, clicks, scrolls, and types on the computer. A click on the pad holds the pointer, and `Ctrl+Alt` gives it back |
| Remote desktop | Shows the screen of the computer in a window, with its sound, and takes the pointer and the keys. The Windows key goes to Hyprland while the video has the focus. The video pauses while the window is minimized and while Windows is locked |
| Omarchy panel | Shows the workspaces, the windows, and the key bindings of Hyprland next to the remote desktop, and runs them |
| Get files | Browses the folders of the computer, searches them, and downloads files to Downloads |
| Fingerprint approval | Approves `sudo`, polkit, and the `hyprlock` lock screen of the computer with Windows Hello: a fingerprint, a face, or the Windows Hello PIN. See [Fingerprint approval](#fingerprint-approval) |
| Microphone | Sends the microphone of this computer to the computer, where apps see **Flux Microphone**. Start it from **Mic** in Control or from the tray. The page picks the input and shows the level |
| Webcam | Sends a camera of this computer to the computer, where apps see **Flux Camera**. The page shows a preview and sets the shape, the resolution, the mirror, the zoom, the exposure, and the colors. **Also send the microphone** sends the microphone with the camera |
| Screen mirror | Shows a display of this computer in a window on the computer |
| Stream requests | `flux-cli webcam start` and `flux-cli mic start` ask Windows for a stream. A prompt shows the request while Flux is in front, else a notification. Only a click on start starts the stream |
| Camera modes | Text, QR, Photo, Document, and Signature, as on the Mac. Open them from **Camera**, **Scan**, **Text**, **QR**, and **Signature** in the tray of a chat, or from **Camera…** in the tray menu of a computer. See [Camera modes](#camera-modes) |
| Screenshots | **Send new screenshots** sends each new screenshot of the Screenshots folder of Windows to the connected computers. See [Screenshots](#screenshots) |
| Dictation | Each text field has a mic key: the agent replies, the touchpad and the remote desktop, the field of a chat, the search of Chats, the scanned text, and the search of **All shortcuts**. Search fields get the words in place of the search. The touchpad and the remote desktop type the words on the computer. Other fields get them at the cursor or at the end of the text. All fields use the same language. Flux uses the online speech recognition of Windows. See [Dictation](#dictation) |
| Clear and expand | The agent replies, the field of a chat, the search of Chats, and the search of **All shortcuts** have a clear key while they have text. The scanned text has **Clear**. The agent replies and the field of a chat also have an expand key that opens a larger editor with **Send**. The type field of the touchpad and the remote desktop has a clear key and the draft editor with **Type**, as on the Mac. See [Type on the Mac](remote-input.md#type-on-the-mac). In an editor, `Ctrl+Enter` selects **Send** or **Type**, and `Esc` closes it |

The touchpad, the remote desktop, the answers to agents, and **Start Agent** ask for Windows Hello first: a face, a fingerprint, or the Windows Hello PIN. A check stays valid for 5 minutes, and it ends when Windows locks, sleeps, or turns off the display. Without Windows Hello, these features do not open. Set up a PIN in Settings > Accounts > Sign-in options.

Windows has no public interface that turns Do Not Disturb on or off, so the Windows app does not sync Do Not Disturb.

## Chats and navigation

The sidebar holds the list of chats, and the open chat fills the rest of the window.
Under the list, **Control** and **Computers** open their pages, and this computer shows at the bottom.
`Ctrl+1` opens Chats, and `Ctrl+2` and `Ctrl+3` open Control and Computers. `Ctrl+F` goes to the search of Chats. `Esc` and `Alt+Left` go back from a page. `Ctrl+,` opens the settings.

The list has 1 chat for each agent and each paired computer, in 3 groups:

- **Needs you**: the approval with **Deny** and **Approve**, the pair requests, and the agents that wait for input. The newest comes first.
- **Agents**: the agents that work, then the agents that are done, then the idle agents. An agent that works shows how long it works, and an agent that waits shows how long it waits.
- **Computers**: the paired computers, the online computers first. Each row shows the newest entry of its chat, such as "You: Dinner at 7". A computer that is not reachable shows "Offline" and the time that it went offline while Flux ran.

The header of the list counts what needs you and the computers online. The **+** key next to the Flux mark starts an agent. The search keeps the chats that hold its text: an agent by its task, its agent, or its project, and a computer by its name or by an entry of its chat. `Esc` empties the search.

- **The chat of a computer** shows what Windows sent on the right, and on the left the files and the last clip of the computer, its open approval, and the answers. The newest entry is at the bottom. Agents do not show in it, because each agent has its own chat. Under the thread, the clipboard row sends the clipboard of Windows, and the field sends text or a link. The **+** key opens the tray: the 4 newest screenshots, **All screenshots**, and the tools Camera, File, Scan, Text, QR, Signature, Get files, and Agent. Agent shows when the computer lets this computer start agents. A click selects a screenshot, and the send key sends the selected screenshots with the text. `Esc` closes the tray. The menu of the top bar opens Control for the computer, the agents window, and **Start Agent…**.
- **The chat of an agent** shows its task, its agent, its project, and its computer in the top bar, with **±** for the changes, **Keys**, Copy, and Refresh. The thread and the dock are the same as in the agents window. `Ctrl+R` reads the output again, and `Ctrl+D` shows the changes. While the agents window of a computer is open, an agent of that computer opens in that window, because the computer sends the output of 1 agent at a time.
- **Control** shows the tools of the computers in scope, and a player dock while a computer plays media.
- **Computers** shows this computer, the paired computers, and the computers to pair. A click on a paired computer sets the scope.

A chat puts its computer in scope. The scope menu in the header of Control and Computers picks 1 computer or all computers. The scope filters Control, and the Computer theme follows it.

The tray icon is the Flux mark. It is dim while no paired computer is connected, and a red dot shows when an item needs you. A click opens a panel with the items and a menu for each online computer. The right button opens Open Flux, Settings, and Quit Flux.
Flux keeps running in the tray after the window closes. Settings > Start > **Open at login** starts Flux in the tray when you log in.

## Clipboard

Flux syncs text only. It reads the clipboard every 0.5 seconds while a paired computer is connected.
Flux does not sync a copy that its source marks as private. A password manager marks a copy with the clipboard formats `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`, or `CanUploadToCloudClipboard`.
Text from a computer never goes back to that computer. Text larger than 1 MB does not sync. Send it as a file.

## Received files

Files go to the Downloads folder of Windows. Settings > Features > Files picks another folder.
Flux never opens a received file by itself. It writes the Mark of the Web on each received file, so Windows and Office check the file before it opens, as a file from the internet.

## Fingerprint approval

Windows approves `sudo`, polkit, and the `hyprlock` lock screen of a paired computer, as the phone and the Mac do. [Fingerprint approval](approvals.md) tells how to set it up, and [the security design](approve.md#windows) tells how it works.

1. Set up Windows Hello in Settings > Accounts > Sign-in options. A PIN is enough.
2. On the Omarchy computer, run `sudo flux-cli approve setup`.
3. Select **Enroll** in the prompt of Flux, and confirm with Windows Hello 2 times: once to make the key, and once to sign with it.
4. Type the key code that Flux shows in the terminal, all 16 characters.

Flux makes 1 key for each computer in Windows Hello, an RSA 2048 key in the TPM when the computer has one. The private key never leaves Windows Hello.
Each request opens a prompt in front of the other windows, with the countdown, **Deny**, and **Approve**. **Approve** asks Windows Hello for each signature. `Esc` denies, and `Enter` does not approve.
The request also shows in the list of Chats, in the chat of the computer, in the tray panel, and as a notification. **Approve** in the notification asks Windows Hello at once, and a click on the notification shows the prompt.

Windows Hello always takes its PIN, so the PIN can approve too. Anyone who knows the PIN can approve at this computer. Use a PIN that other people do not know.
A computer without Windows Hello refuses each request, and PAM asks for the password.

The Omarchy computer needs a `fluxd` newer than 0.17.0. Version 0.17.0 and earlier drop the answers of Windows Hello, because its RSA signature is larger than an EC signature.
On Windows 11 24H2 and later, the prompt of Windows Hello belongs to the prompt of Flux. On an older Windows, Flux brings it to the front.

The page of the computer in Computers shows the key code, the recent requests, and **Remove Key**. **Remove Key** and an unpair delete the key of that computer. The key file on the Omarchy computer stays until you run `sudo flux-cli approve remove`.

## Camera modes

The camera window has the 5 modes of the Mac app. Select a mode in the mode bar at the top. The camera picker shows when this computer has more than 1 camera.

| Mode | What Flux sends | Where the computer puts it |
| --- | --- | --- |
| Text | The text that Flux reads, after you edit it | A text file in `scan_dir` |
| QR | The link of a code opens in the browser of the computer, or its text goes on the clipboard or in a file | The browser, the clipboard, or `scan_dir` |
| Photo | A JPEG named `IMG_yyyyMMdd_HHmmss.jpg` | `photo_dir` |
| Document | A PDF named `scan-yyyyMMdd-HHmmss.pdf`, with 1 page for each photo | `scan_dir` |
| Signature | A transparent PNG named `signature-yyyyMMdd-HHmmss.png` | The clipboard, and a copy in `<photo_dir>/signatures` |

[Configuration](configuration.md) gives the default folders. [Signature](camera.md#signature) tells how to sign on paper.

Text, QR, Document, and Signature also read an image from outside the camera. Select **From Image**, then **Open Image…**, **Screen Region…**, or **Paste Image**, or drop an image on the camera. **Screen Region…** hides the camera window, and you drag over the part of the screen to read. Photo mode takes photos with the camera only. In Signature, **Paper** reads a photo of paper, and **Draw** takes a signature that you draw with the mouse, a pen, or a touch screen.

| Key | Action |
| --- | --- |
| `Space` | Presses the shutter |
| `Ctrl+V` | Pastes an image |
| `Ctrl+Z` | Removes the last stroke of a drawn signature |
| `Ctrl+Enter` | Sends the scanned text |
| `Esc` | Closes the window |

- Text mode uses the text recognition of Windows in the languages of your user profile. If Flux cannot read text, add a language with **Optical character recognition** in Settings > Time & language > Language & region. The mic key next to the text adds words with the dictation of Windows, see [Dictation](#dictation).
- QR mode reads QR codes, Data Matrix, PDF417, Aztec, and the common barcodes with the ZXing.Net library, because Windows has no decoder for them.
- Document mode looks for a bright page on a darker surface and flattens it. If Flux finds no page, the PDF gets the whole photo. The menu of a page switches between the found page and the whole image.
- The camera modes use the camera at 1080 pixels on the short side, or less when the camera has no such format. A photo has the size of that format, and the Mac takes a photo in the full size of the camera.
- The camera stops while the window is minimized, and when the window closes. Windows has no prompt for the camera. When **Let desktop apps access your camera** is off, the window shows **Open Privacy Settings**.

## Dictation

The mic key uses the speech recognition of Windows. Flux needs no download for it.

- To start a dictation, click the mic key. To stop it, click the key again.
- To talk only while you hold the key, press and hold it. The dictation stops when you release it.
- To drop the dictation, select the close button in the panel.

While Windows listens, a panel takes the place of the field. It shows the language, the time, and the words that Windows still revises.
Each phrase that Windows settles goes into the field at once. The touchpad and the remote desktop send it to the computer, which types it at its cursor.
A pause does not end the dictation. The dictation ends when you stop it, or after 20 seconds with no speech.
The bar of the remote desktop also has a mic button. It shows the keys and starts the dictation.

A dictation only writes text. A reply goes to an agent when you select **Send**, after Windows Hello.

Windows transcribes online, so the audio goes to Microsoft.

- Turn on **Online speech recognition** in Settings > Privacy & security > Speech. While the setting is off, the field shows the problem and **Open Privacy Settings**.
- Windows does not ask a desktop app for the microphone. Turn on **Let desktop apps access your microphone** in Settings > Privacy & security > Microphone.

All fields use the same language, and Flux keeps it for the next dictations.
**Automatic** uses the speech language of Windows in Settings > Time & language > Speech.
To choose another language, select the language button in the panel. The list holds the languages that the speech recognition of this computer supports.
**Speech Settings…** at the end of the list opens Settings > Time & language > Speech. To add a language, add it with its speech features in Settings > Time & language > Language & region.
When Windows does not support the language, the field shows the problem and **Choose a language**.

## Screenshots

Settings > Features > **Send new screenshots** sends each new screenshot to the connected computers once. The setting is off by default.

- Flux watches the Screenshots folder of Windows, usually `Pictures\Screenshots`. `Windows+Print Screen` saves there, and so does the Snipping Tool of Windows 11.
- A screenshot from before you turned on the setting stays on this computer. A screenshot that a copy puts into the folder goes out as a new screenshot.
- A screenshot waits until a computer connects. 1 scan sends at most 50 screenshots. The rest go with the next scan, for example after the next screenshot or the next connect.
- The computer saves each screenshot in `<photo_dir>/screenshots`.

The tray of a chat shows the 4 newest screenshots of the same folder, also while the setting is off. A click selects a screenshot, and the send key sends the selected screenshots to the computer of the chat. **All screenshots** opens the folder to pick other images.

The Mac app also sends new photos from the Photos library. Windows has no such photo library, so the Windows app sends only screenshots.

## Streams

The microphone, the webcam, and the screen mirror listen on TCP 12070 to 12099, and the computer connects to Windows. The [camera and streams](camera.md) page describes the side of the computer.

- Windows does not ask a desktop app for the microphone or the camera. Turn on **Let desktop apps access your microphone** in Settings > Privacy & security > Microphone, and the same setting under Camera. While a setting is off, the page of the stream shows **Open Privacy Settings**.
- The webcam and the screen mirror use the H.264 encoder of Windows on the processor: Main profile, level 4.1, and a key frame each second. A 1080p webcam needs more processor time than 720p.
- The screen mirror uses the screen capture of Windows, with the pointer. It sends at most 30 frames each second, and at most 1080 pixels on the long side.
- The Windows app does not turn the camera image. A tablet camera in portrait orientation gives a sideways image.

## Pairing data

Flux keeps its data in `%LOCALAPPDATA%\Flux`:

| File | Content |
| --- | --- |
| `identity\identity.bin` | The certificate and private key of this computer, protected with DPAPI for the Windows user |
| `trusted.json` | The paired computers and their pinned certificates |
| `settings.json` | The settings of Flux and of the features |
| `approve\` | The name and the public key of the Windows Hello key for each computer, with the host, the user, and the time of the enrollment |
| `incoming\` | Parts of resumable files, removed after 7 days |
| `flux.log` | The log. It never holds clipboard text, file contents, or notification text |

The certificate uses an ECDSA P-256 key. Its common name is the device ID.
To pair from scratch, quit Flux and delete `%LOCALAPPDATA%\Flux`.

## Network

| Use | Port |
| --- | --- |
| Discovery | UDP 12100 and mDNS `_flux._udp` |
| Links | TCP 12100 to 12108, the first free port |
| Files and streams | TCP 12070 to 12099 |

TLS uses version 1.2, as the Mac and Android apps do.

## Test against a computer

The FluxKit tests pair with a headless `fluxd` when `FLUX_E2E_BIN` names a folder with `fluxd` and `flux-cli`:

```sh
mkdir -p windows/artifacts/e2e
CGO_ENABLED=0 go build -o windows/artifacts/e2e/fluxd ./cmd/fluxd
CGO_ENABLED=0 go build -o windows/artifacts/e2e/flux-cli ./cmd/flux
docker run --rm -v "$PWD":/src -w /src -e FLUX_E2E_BIN=/src/windows/artifacts/e2e mcr.microsoft.com/dotnet/sdk:10.0 dotnet test windows/FluxKit.Tests -c Release
```

The container keeps the test network apart from a `fluxd` that runs on the computer. The `fluxd` job of the Windows workflow runs these tests on each push.

To point the app at a headless `fluxd`, set these variables:

| Variable | Effect |
| --- | --- |
| `FLUX_DATA_DIR` | Identity, trust store, and settings in a separate folder |
| `FLUX_UDP_PORT` | UDP port that receives identity broadcasts. The default is `12100` |
| `FLUX_PEER_UDP_PORT` | UDP port of the computer that Windows announces itself to. The default is `12100` |
| `FLUX_TCP_PORT` | First TCP port for links. The default is `12100` |
| `FLUX_LOOPBACK=1` | Announce only to 127.0.0.1 and skip mDNS |

## Layout

| Path | Content |
| --- | --- |
| `windows/FluxKit/Protocol` | Packets, identity, certificates, and the verification key |
| `windows/FluxKit/Net` | UDP discovery, mDNS, TCP links, TLS, payload servers, and tunnels |
| `windows/FluxKit/Core` | The core, computers, pairing, the trust store, the plugin interface, notifications, and settings |
| `windows/FluxKit/Plugins` | 1 folder per feature |
| `windows/FluxKit/Theme` | The theme packet, the contrast guard, and the palettes |
| `windows/FluxKit.Tests` | xUnit tests, and the tests against `fluxd` |
| `windows/Flux` | The WPF app. `Features/Features.cs` lists the plugins and their views |
| `windows/Flux/Kit` | The theme brushes, the stack panel, the buttons, and the parts of the design system |
| `windows/Flux/Shell` | The main window, the sidebar, the header, and the scope menu |
| `windows/Flux/Chat` | Chats: the list of chats, the chat of a computer with its cards, its dock, and its tray, the cards of the tray panel, the notices, and the pairing guide |
| `windows/Flux/Destinations` | Control, Computers, and the pairing pages |
| `windows/Flux/Platform` | DPAPI, toasts, the clipboard, the battery, Windows Hello, the microphone, the cameras, the screen capture, the H.264 encoder and decoder, the images and the text recognition of the camera modes, the screen region, the Screenshots folder, and other Windows parts |
| `windows/Flux.UiTests` | Builds each page with sample computers on Windows |

The views are C# code, not XAML, so that the compiler checks each property. Each view draws itself from the models again after a change, as a SwiftUI view does.
