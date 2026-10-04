# Flux for Android

[Documentation index](README.md)

Flux for Android connects a phone to an Omarchy computer that runs `fluxd`.
It uses Flux protocol version 8.
Flux supports the Flux desktop and phone apps as a pair.
The app requires Android 10 or later, API 29.

## Requirements

| Item | Requirement |
| --- | --- |
| Phone | Android 10 or later |
| Computer | Flux installed and set up, as in [Install Flux](install.md). `flux-cli doctor` reports no errors. |
| Network | The phone and the computer are on the same local network. |
| Install with `adb` | `adb` on the computer, and **USB debugging** or **Wireless debugging** on the phone |

You need `adb` only to install the APK from the computer, for example when Play Protect blocks it.
On Omarchy and Arch Linux, the `android-tools` package contains `adb`:

```sh
sudo pacman -S --needed android-tools
adb version
```

You do not need the Android SDK to install a release APK.
The SDK is necessary only to [build the app](#build-and-install).

systemd 258 and later give your user access to a phone in USB debugging mode, so no udev rule is necessary.
With an earlier systemd, `adb devices` shows `no permissions` for the phone.
Install the `android-udev` package, then connect the phone again.

To check the USB connection, connect the phone and run:

```sh
adb devices
```

The phone shows with the state `device`.
If the state is `unauthorized`, accept the **Allow USB debugging** prompt on the phone.

## Install a release APK

Download `flux-android-VERSION.apk`, `SHA256SUMS`, and `SHA256SUMS.sig` from the same GitHub release.
When the release has a signature, check `SHA256SUMS.sig` first, as [check a release](install.md#check-a-release) shows.
Then verify the downloaded files:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

For a first install, also compare the certificate of the APK with the Flux release certificate.
See [check a release](install.md#check-a-release).

Open the APK on the phone and allow installation from that source.
If Play Protect shows **App blocked to protect your device**, see [Android setup and Play Protect](android-setup.md).
With USB debugging enabled and [`adb` installed](#requirements), you can also install through ADB:

```sh
adb install -r flux-android-0.1.0.apk
```

Replace the filename with the downloaded version.
Release APKs use one persistent release key.
A debug APK cannot replace a release APK with a different key.
To switch keys, uninstall the previous app first, which removes its local data and pairing identity.

## Update the app

Flux uses UDP port 12100 and TCP ports 12070 to 12108.
An earlier Flux for Android uses other ports and cannot connect to a `fluxd` with these ports.
**Send to phone** then cannot reach the phone.
Install the new APK from the GitHub releases once, as in [Install a release APK](#install-a-release-apk).
The new app also cannot connect to an earlier `fluxd`, so update Flux on the computer too.

When a newer Flux for Android exists, the Flux window on the computer shows **Flux for Android 0.7.0 is available**.
The device card also shows the app version of the phone.
To update the phone:

1. Select **Send to phone** in the window.
2. On the phone, open the notification **Flux 0.7.0 from COMPUTER**.
3. The first time, allow **Install unknown apps** for Flux.
4. Select **Update** in the Android installer.

From the terminal, step 1 is:

```sh
flux-cli --device "Pixel 8" update --phone
```

The computer downloads the APK of the latest release before it sends the file.
It checks `SHA256SUMS.sig` with the public release key when the build of `fluxd` has one, then it checks the APK against `SHA256SUMS`.
The phone checks the received APK before it offers the installer.
The installer shows only for a file `flux-android-VERSION.apk` with a newer Flux in it.
The signing key must also be the key of the installed Flux.
The phone saves each other app in **Downloads**, and its notification does not install it.
The Android installer also accepts the update only with the same signing key.
After the update, Android starts the Flux service again.

The offer needs the [release check](configuration.md#release-check) and a phone app that reports its version.
Earlier versions of the app do not report it, so update them once with an APK from the release.
A debug build gets no offer, because a release APK has another signing key and cannot replace it.

## First run

On Android 12 and later, the system splash screen shows the Flux mark until the first screen is ready.
Flux shows no permission dialog before the first pairing.

Before the first pairing, the **Inbox** shows a pairing guide in the place of the master tile:

- 1 line that tells what Flux does.
- **Set up Flux on the computer**: the setup command and **Read the install guide**, which opens [Install Flux](install.md) on GitHub.
- **Pair this phone**: the computers on the network of the phone that run Flux. Tap a computer to open the pairing sheet. Then compare the key on both screens.

When the phone already found a computer, **Pair this phone** comes first.
The setup then shows only the command and **Read the install guide**.

To start `fluxd` on the computer, run this command as your desktop user after you install the package:

```sh
flux-cli setup
```

When the pairing ends, Flux opens the **Inbox** of the new computer.
For 6 seconds, the **Inbox** shows **COMPUTER is paired**.
After the first pairing, the success state also tells why Flux needs notifications.
1 second later, Android asks once for the permission.
See [permissions](android-setup.md#permissions).

After a start, the **Inbox** shows **Connecting to COMPUTER** for up to 3 seconds while the links connect.
If no computer in scope connects in this time, the **Inbox** shows **COMPUTER is not reachable** with **Retry**.
**Retry** shows **Connecting to COMPUTER** again while Flux looks for the computer.

## Pairing and connections

The pairing key has 16 characters in 4 groups, for example `5EE6 825F 974E D59A`.
Compare all 16 characters on the phone and on the computer before you accept.
Earlier versions of Flux show only 8 characters, so update Flux on all devices before you pair.

Open Flux on the phone before you pair.
The phone takes a connection from a new computer only while the app is on screen or while it scans.
When the app comes to the front, the phone sends its identity, so a computer on the network connects at once.
A paired computer connects at any time, also through Tailscale.

Flux for Android applies these limits to the network:

- A computer that is not paired can send lines of at most 64 KiB. The phone drops a longer line. While Flux is not on screen, its connection closes after 2 minutes without data.
- A computer that is not paired can send only pair packets. The phone answers another packet with an unpair, once for each connection. A computer that still trusts the phone then removes its old pairing.
- The phone keeps at most 8 connections of computers that are not paired. A new computer closes the oldest one.
- The handshake of a new connection must finish in 10 seconds.
- At most 4 connections that UDP identities start run at a time. They do not use the handshake slots of the incoming connections, in total or for one address.
- A pairing stays on the connection and the certificate on which it started. A new connection of the computer ends an open pairing, and you pair again. While a pairing is open, and after pairing, the phone refuses a connection with another certificate for the same device ID.
- A file, stream, or tunnel port takes only the paired computer from the address of its link. Other connections close, and the port waits for the computer.
- The phone sends its identity to a stored address only when the address is on a network of the phone or on Tailscale.
- The phone finds a computer that sleeps or loses power in 90 seconds or less. While data waits for the computer, it finds it in 30 seconds.
- The Wi-Fi multicast lock is on while the phone scans and before the first pairing. While a paired computer is away, the lock is on for only 3 minutes after an event. The events are: Flux starts, the phone joins a network, a computer disconnects, the screen comes on, and you open Flux or tap **Retry**. A computer finds the phone at its last address without the lock.

When you unpair a computer on either side, the phone stops the screen mirror, the webcam, the microphone, the remote desktop, and **Get files** for that computer.
It also closes its approval request and its stream requests, and removes its notifications.
When you start the screen mirror to a second computer, the mirror to the first computer stops.

The phone accepts clipboard text of at most 256 KiB from a computer. Larger text shows a message, and the clipboard does not change.
**Sync clipboard**, the **Send clipboard** tile, and the **Send clipboard** notification action skip a clip that its app marks as sensitive, for example a password. These paths send phone text of up to 1 MiB.
A computer shows at most 10 notifications on the phone, and you can always remove them.

## Clipboard from another app

A copy on the phone reaches the computer while Flux is on the screen.
For a copy in another app, use a 1-tap path.
See [send a copy from another app](features.md#send-a-copy-from-another-app).

## Webcam and mic requests

The computer can ask the phone to start the webcam or the mic:

```sh
flux-cli --device "Pixel 8" webcam start
flux-cli --device "Pixel 8" mic start
```

The request only asks.
The phone turns on the camera or the microphone only after you tap Start on the phone, also while Flux is on the screen.

- While Flux is on the screen, a prompt shows the title `omarchy asks for the webcam` with **Start webcam** and **Not now**. For the mic, the prompt shows `omarchy asks for the mic` with **Start the mic**. The title names the computer.
- While Flux is not on the screen, a notification shows the request. The notification has the same title, with the text `Tap to start the webcam.` or `Tap to start the mic.` below it. It has the action **Start webcam** or **Start the mic**. The notification uses the **Stream requests** channel.
- A tap on the notification opens Flux, and Flux shows the prompt. Only the action **Start webcam** or **Start the mic** starts the stream.
- A new request of the same computer and kind replaces the notification and does not alert again.
- When Flux comes on the screen, the prompt shows each open request, and the notifications of those requests go away.
- Each computer has at most 1 open request of each kind. The prompt shows the newest request first. After you answer it, the prompt shows the next one.
- **Start webcam** and **Start the mic** take a tap only 0.8 seconds after the prompt is fully open and Flux is in front. A touch that started earlier does nothing.
- Without the notification permission, the phone shows a request only in the prompt. The prompt shows while Flux is on the screen, or when Flux comes on the screen within 60 seconds.
- The prompt and the notification go away after 60 seconds.
- A tap on Start opens the **Webcam** or **Mic** page of that computer, and the page starts the stream with the saved settings. On a locked phone, Android asks you to unlock it first.
- When the page cannot start the stream in 60 seconds, for example while the computer is not reachable, it does not start it. Then press Start on the page.
- While a stream of that kind runs to that computer, a request does nothing.
- The phone ignores a request of the same kind from the same computer that comes less than 3 seconds after the last request. An ignored request also counts as the last request.
- The prompt refuses a tap while another app draws over Flux.

The stream starts from the visible page with the start code of its Start button.
Android lets an app use the camera and the microphone only while the app is visible or after an action of the user.
The stream keeps running after the page closes and while Flux is in the background, as after a start on the page.
See [streams in the background](camera.md#streams-in-the-background).

Another app on the phone can start Flux with the extras of the Start action.
Only the one-time key of the notification opens the page and starts the stream.
An intent without a valid key opens no page and removes no notification.
The keys stay in memory.
When the Flux process starts again, it removes the notifications of the stream requests.

The phone lists `flux.stream.request` in its incoming packet types.
An earlier Flux for Android does not list it, so the computer sends no request to it.

## Build and install

Use JDK 21, Android SDK platform 36, and Build Tools 36.0.0.
Install the SDK with Android Studio or the Android command-line tools.
Set `ANDROID_HOME` to the SDK directory.

```sh
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
sdkmanager --licenses
sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
java -version
```

Set `JAVA_HOME` to your JDK 21 directory if your default Java version differs.
Use the committed Gradle wrapper rather than a system Gradle installation.

From the repository root, build a debug APK:

```sh
make android
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The remaining commands in this guide run from `android/`:

```bash
cd android
./gradlew :app:assembleDebug
```

To install it on a phone with USB debugging on, run:

```bash
./gradlew :app:installDebug
```

As an alternative to `ANDROID_HOME`, set the SDK path in the ignored `android/local.properties` file:

```properties
sdk.dir=/absolute/path/to/Android/Sdk
```

Keep SDK paths and keystores out of Git.
See [releases](releasing.md#android-release-key) for signed builds and release secrets.

## Theme

Flux follows the active Omarchy theme of the computer.
`fluxd` sends the theme in a `flux.theme` packet when the phone connects and when the theme changes.
Flux saves the theme of each computer, so the next start draws it at once.

To change the theme, open **Computers** and select a choice under **Theme**. The choices are:

- **Computer**, the default: the theme of the computer in scope. The scope chip at the top of the app sets the scope. In the scope of all computers, Flux uses the theme that changed most recently. A reconnect does not change the theme. Without a theme from the computer in scope, Flux uses Tokyo Night on a dark phone and Tokyo Night Day on a light phone. The choice shows the theme name and the computer that sent it.
- **System**: Tokyo Night on a dark phone and Tokyo Night Day on a light phone.
- **Light**: Tokyo Night Day.
- **Dark**: Tokyo Night.

A contrast guard maps the theme to the colors of the app. It moves only the lightness of a color, so each hue stays:

- Body text and secondary text reach 4.5:1 on each surface, on the border color `line`, and on the selected tile `accentTile`. The body text keeps a step of 1.4:1 from the secondary text.
- The accent and the status colors reach 4.5:1 as text on each surface and on `accentTile`. On `line`, they reach 3:1, for icons and borders.
- The text on a filled button reaches 4.5:1.
- The dim color is for borders, icons, and disabled states only, and reaches 3:1. Text that carries meaning uses the secondary text color.
- The selected tile `accentTile` takes the hue of the accent at the luminance of `tileHi`, so it does not change a contrast.
- Red means "needs you" or an error. When the theme accent looks like red, the theme blue, cyan, or magenta takes its place as the primary color. The border gradient keeps the theme accent.
- ANSI blue in the agent output uses the theme blue, as in the terminal on the computer.
- The master tile takes the gradient of `hyprland_active_border`, at 3:1 or more.

The theme engine is in `app/src/main/java/org/omarchy/flux/theme`.

## Test

To run the JVM tests for packets, identity, certificates, and the verification key, run:

```bash
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleRelease --no-daemon
```

The release task also checks the R8-optimized build.
Without signing variables, it produces `app/build/outputs/apk/release/app-release-unsigned.apk`.

To test the app against a desktop peer without a firewall rule, run the test peer. It connects through `adb forward`, pairs, and sends sample battery, command, and media packets. Open Flux on the phone first, because the phone takes a new computer only while the app is on screen:

```bash
python3 tools/test_peer.py
```

To send an Omarchy theme from the test peer, give it a `colors.toml` file:

```bash
python3 tools/test_peer.py --theme ~/.local/state/omarchy/current/theme/colors.toml
```

To test the remote desktop, add `--desktop`. The peer streams the first monitor of this computer with `gpu-screen-recorder`, like `fluxd`, and prints the touches. It also answers the Omarchy panel with sample shortcuts and workspaces. It does not run the touches or the shortcuts:

```bash
python3 tools/test_peer.py --desktop
```

To take a screenshot of one page on a locked test phone, use the debug-only launch extras:

```bash
tools/shot.sh media /tmp/media.png
```

To render the pages on an emulator with no computer, turn on the sample computers with `FLUX_DEMO=1`. Set `ANDROID_SERIAL` when a phone is also connected:

```bash
ANDROID_SERIAL=emulator-5554 FLUX_DEMO=1 tools/shot.sh inbox /tmp/inbox.png
```

The pages are:

- `inbox`, `send`, `control`, and `computers` for the 4 destinations of the navigation bar. `devices` is the same as `computers`.
- `sync` for the sync switches.
- `home` for **Control** with the first paired computer in scope.
- `media`, `commands`, `browse`, `mic`, `webcam`, `touchpad`, `desktop`, `omarchy`, `agents`, and `camera`.
- `agent:<pane>` for the output of one herdr agent. The sample blocked agent is `agent:w2:p1`.
- `newpane` for the screen that starts a herdr agent or opens a terminal.
- `terminal:<pane>` for one herdr terminal. The sample terminals are `terminal:w1:p2` and `terminal:w3:p3`.
- `camera:<mode>` for a camera mode: `text`, `qr`, `photo`, `document`, or `signature`. `camera:webcam` opens the `webcam` page.
- `ring`, `pair`, and `unpair` for the ring overlay, the pairing sheet, and the unpair dialog.
- `ask:webcam` and `ask:mic` for the prompt of a stream request from the first paired computer, over the Inbox. With `FLUX_DEMO=1`, Start on the prompt of the sample computer opens the page and does not start the stream.
- `notify:webcam` and `notify:mic` for the notification of a stream request from the first paired computer. The notification shows also while Flux is on the screen, so open the notification shade to see it.
- `<page>@offline` for the page of a paired computer that is not reachable. A destination with `@offline` shows that computer as the scope.
- `<page>@connecting` for the same page while that computer still connects. For example, `inbox@connecting` shows the Inbox in the connecting state.
- `empty` for the app with no computers.
- `firstrun` for the pairing guide of the **Inbox** before the first pairing, with the sample computer to pair. It needs `FLUX_DEMO=1`.
- `paired` for the success state of a new pairing on the sample computer to pair. It needs `FLUX_DEMO=1`. The success state shows for 6 seconds.
- `icon` for the launcher and notification icons.

With `FLUX_DEMO=1`, the Inbox also shows a sample approval, 2 sample transfers, and a sample clip, and the sample computer shows the Omarchy panel. A tap on the sample approval does not open the approval screen.

To show the prompt of a webcam request on an emulator, run:

```bash
ANDROID_SERIAL=emulator-5554 FLUX_DEMO=1 tools/shot.sh ask:webcam /tmp/ask-webcam.png
```

To draw the sample computer in a sample theme, set `FLUX_THEME` to `neon`, `tokyo-night`, `tokyo-night-day`, `catppuccin-latte`, `cotton-candy`, `futurism`, or `low-contrast`. The value `none` removes the theme:

```bash
ANDROID_SERIAL=emulator-5554 FLUX_DEMO=1 FLUX_THEME=catppuccin-latte tools/shot.sh inbox /tmp/inbox-latte.png
```

Release builds ignore these extras.

To reproduce terminal layout bugs without pairing the emulator, a debug build also
accepts an ANSI sample in `flux.debug.output` while demo mode is on:

```bash
sample=$(< /path/to/sample.ansi)
sample=${sample//\'/\'\\\'\'}
adb -s emulator-5554 shell am start -n org.omarchy.flux/.ui.MainActivity \
  --ez flux.debug.demo true --es flux.debug.page agent:w2:p1 \
  --es flux.debug.output "'$sample'"
```

Use a small, non-private sample. This only changes the demo output; it sends no
keys or prompts to a real agent. Omit the output extra to restore the default sample.

## Icons

The app uses Material Symbols Rounded at the 24 dp optical size, under the Apache License 2.0. To add an icon, add its name to `ICONS` in `tools/fetch_icons.py`, run the script, and add the drawable to `Ic` in `ui/Icons.kt`:

```bash
python3 tools/fetch_icons.py
```

## Layout

| Path | Content |
| --- | --- |
| `app/src/main/java/org/omarchy/flux/protocol` | Packets, identity, certificates, and the verification key. Plain Kotlin with JVM tests. |
| `app/src/main/java/org/omarchy/flux/net` | UDP discovery, TCP links, TLS, and payload transfers |
| `app/src/main/java/org/omarchy/flux/core` | Devices, pairing, trust store, and the plugins |
| `app/src/main/java/org/omarchy/flux/service` | The foreground service and the notification listener |
| `app/src/main/java/org/omarchy/flux/stream` | The stream connection, and the foreground service that keeps the webcam and the mic running in the background |
| `app/src/main/java/org/omarchy/flux/theme` | The computer theme, the contrast guard, and the palettes. Plain Kotlin with JVM tests. |
| `app/src/main/java/org/omarchy/flux/ui` | The Compose screens |
| `tools` | The test peer, the screenshot helper, and the icon script |

Continue with [phone pairing](features.md#pair-a-phone).
