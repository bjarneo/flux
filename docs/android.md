# Flux for Android

[Documentation index](README.md)

Flux for Android connects a phone to an Omarchy computer that runs `fluxd`.
It uses KDE Connect protocol version 8 with Flux extensions.
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

Download `flux-android-VERSION.apk` and `SHA256SUMS` from the same GitHub release.
Verify the downloaded files:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

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

The computer downloads the APK of the latest release and checks it against `SHA256SUMS` before it sends the file.
The phone reads the package name of the APK. Only a build of Flux gets the update notification.
The Android installer accepts the update only with the same signing key.
After the update, Android starts the Flux service again.

The offer needs the [release check](configuration.md#release-check) and a phone app that reports its version.
Earlier versions of the app do not report it, so update them once with an APK from the release.
A debug build gets no offer, because a release APK has another signing key and cannot replace it.

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

## Test

To run the JVM tests for packets, identity, certificates, and the verification key, run:

```bash
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleRelease --no-daemon
```

The release task also checks the R8-optimized build.
Without signing variables, it produces `app/build/outputs/apk/release/app-release-unsigned.apk`.

To test the app against a desktop peer without a firewall rule, run the test peer. It connects through `adb forward`, pairs, and sends sample battery, theme, command, and media packets:

```bash
python3 tools/test_peer.py
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
ANDROID_SERIAL=emulator-5554 FLUX_DEMO=1 tools/shot.sh home /tmp/home.png
```

The pages are:

- `devices`, `home`, `media`, `commands`, `browse`, `mic`, `agents`, and `camera`.
- `agent:<pane>` for the output of one herdr agent. The sample blocked agent is `agent:w2:p1`.
- `newpane` for the screen that starts a herdr agent or opens a terminal.
- `terminal:<pane>` for one herdr terminal. The sample terminals are `terminal:w1:p2` and `terminal:w3:p3`.
- `camera:<mode>` for a camera mode: `text`, `qr`, `photo`, `document`, `signature`, or `webcam`.
- `ring`, `pair`, and `unpair` for the ring overlay, the pairing sheet, and the unpair dialog.
- `<page>@offline` for the page of a paired computer that is not reachable.
- `empty` for the app with no computers.
- `icon` for the launcher and notification icons.

Release builds ignore these extras.

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
| `app/src/main/java/org/omarchy/flux/ui` | The Compose screens |
| `tools` | The test peer, the screenshot helper, and the icon script |

Continue with [phone pairing](features.md#pair-a-phone).
