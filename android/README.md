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

The pages are `devices`, `home`, `touchpad`, `media`, `present`, `commands`, `browse`, `scan`, `ring`, and `icon`. Release builds ignore these extras.

## Layout

| Path | Content |
| --- | --- |
| `app/src/main/java/org/omarchy/flux/protocol` | Packets, identity, certificates, and the verification key. Plain Kotlin with JVM tests. |
| `app/src/main/java/org/omarchy/flux/net` | UDP discovery, TCP links, TLS, and payload transfers |
| `app/src/main/java/org/omarchy/flux/core` | Devices, pairing, trust store, and the plugins |
| `app/src/main/java/org/omarchy/flux/service` | The foreground service and the notification listener |
| `app/src/main/java/org/omarchy/flux/ui` | The Compose screens |
| `tools` | The test peer and the screenshot helper |
