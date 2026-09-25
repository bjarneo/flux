# Flux for Android

Flux for Android connects a phone to an Omarchy computer that runs `fluxd`. It speaks the KDE Connect protocol, version 8, so it also pairs with KDE Connect desktops.

## Build and install

To build a debug APK, run:

```bash
./gradlew :app:assembleDebug
```

To install it on a phone with USB debugging on, run:

```bash
./gradlew :app:installDebug
```

The build needs JDK 21 and the Android SDK with platform 36. Set the SDK path in `local.properties`:

```properties
sdk.dir=/home/you/Android/Sdk
```

## Test

To run the JVM tests for packets, identity, certificates, and the verification key, run:

```bash
./gradlew :app:testDebugUnitTest
```

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

- `devices`, `home`, `media`, `commands`, `browse`, and `camera`.
- `camera:<mode>` for a camera mode: `text`, `qr`, `photo`, `document`, or `webcam`.
- `ring`, `pair`, and `unpair` for the overlay and the dialogs.
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
