# Flux for Android

[Documentation index](README.md)

Flux for Android connects a phone to an Omarchy computer that runs `fluxd`.
It uses KDE Connect protocol version 8 with Flux extensions.
Flux supports the Flux desktop and phone apps as a pair.
The app requires Android 10 or later, API 29.

## Install a release APK

Download `flux-android-VERSION.apk` and `SHA256SUMS` from the same GitHub release.
Verify the downloaded files:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

Open the APK on the phone and allow installation from that source.
With USB debugging enabled, you can also install through ADB:

```sh
adb install -r flux-android-0.1.0.apk
```

Replace the filename with the downloaded version.
Release APKs use one persistent release key.
A debug APK cannot replace a release APK with a different key.
To switch keys, uninstall the previous app first, which removes its local data and pairing identity.

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

To take a screenshot of one page on a locked test phone, use the debug-only launch extras:

```bash
tools/shot.sh media /tmp/media.png
```

To render the pages on an emulator with no computer, turn on the sample computers with `FLUX_DEMO=1`. Set `ANDROID_SERIAL` when a phone is also connected:

```bash
ANDROID_SERIAL=emulator-5554 FLUX_DEMO=1 tools/shot.sh home /tmp/home.png
```

The pages are:

- `devices`, `home`, `media`, `commands`, `browse`, `mic`, and `camera`.
- `camera:<mode>` for a camera mode: `text`, `qr`, `photo`, `document`, or `webcam`.
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
