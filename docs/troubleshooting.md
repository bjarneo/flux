# Troubleshoot Flux

[Documentation index](README.md)

## Start with diagnostics

```sh
flux version
flux doctor
flux status --json
systemctl --user status fluxd
journalctl --user -u fluxd -n 100 --no-pager
```

Inspect `flux setup` output directly.
It can print a failed setup step and still exit with zero.

## The daemon does not run

If you previously turned Flux off, turn it on:

```sh
flux on
```

If the service is missing, repeat user setup:

```sh
flux setup
```

If another daemon holds the socket, stop that process before you start the service.
A foreground development daemon and the user service cannot share one socket.
See [isolated development](development.md#isolated-daemon).

## The phone does not appear

1. Open Flux for Android.
2. Check that both devices use the same local network.
3. Check Avahi:

   ```sh
   systemctl status avahi-daemon
   ```

4. Request discovery:

   ```sh
   flux discover
   flux status
   ```

Guest Wi-Fi and client isolation can block devices on the same access point.
Flux uses outbound desktop connections and mDNS, so a new inbound desktop firewall rule is not the default fix.
Keep the existing identity and trust store while you diagnose connectivity.

## The window or bar item is missing

Try the Qt host directly:

```sh
FLUX_GUI=app flux open
```

If it works, refresh the installed plugin:

```sh
flux setup
omarchy-shell shell rescanPlugins
```

For a user-only install, install the plugin from the checkout with `make install-plugin`.
See [plugin layout](omarchy.md#install-layout).
Missing icons usually indicate a missing Nerd Font or Qt SVG package.

## Camera, microphone, or screen fails

```sh
flux webcam
flux mic
flux screen
flux doctor
```

The webcam needs `ffmpeg`, `v4l2loopback-dkms`, and headers for the active kernel.
The microphone needs PipeWire and phone microphone permission.
The screen mirror needs `mpv` or `ffplay` and the Android capture prompt.
See [camera and streams](camera.md) for setup commands.

## Android build or install fails

Check the Java and Gradle versions from `android/`:

```sh
java -version
./gradlew --version
```

Use JDK 21 and SDK platform 36.
Keep the local SDK path in `ANDROID_HOME` or ignored `local.properties`.
Do not add a machine-specific JDK path to `gradle.properties`.

An APK with a different certificate cannot update an installed app.
A lower version code cannot replace a higher version code through a normal update.
Use the original release key and a higher code for release upgrades.
See [APK signatures](releasing.md#android-release-key).

## Fingerprint approval falls back to a password

```sh
flux approve
flux status
```

Check the phone connection, enrolled key, fingerprint setup, and approval timeout.
A new fingerprint can invalidate the phone key and require enrollment again.
Keep the password fallback active while you diagnose approval.
See [approval setup](approvals.md).
