# Troubleshoot Flux

[Documentation index](README.md)

## Start with diagnostics

```sh
flux-cli version
flux-cli doctor
flux-cli status --json
systemctl --user status fluxd
journalctl --user -u fluxd -n 100 --no-pager
```

`flux-cli setup` returns 1 when the service step or the plugin step fails.
A missing system part does not change the exit code, so also read the list under `3. System parts` in its output.

## flux runs another program

If `flux` prints a Kubernetes error, the `fluxcd` package owns `/usr/bin/flux`.
That file comes before the Flux short name in `PATH`.
Use `flux-cli` for Flux:

```sh
flux-cli status
```

If the shell says `flux: command not found` after an install, log in again.
`/etc/profile.d/flux-path.sh` adds the short name at login.
See [the command name](install.md#the-command-name).

## The daemon does not run

If you previously turned Flux off, turn it on:

```sh
flux-cli on
```

If the service is missing, repeat user setup:

```sh
flux-cli setup
```

If another daemon holds the socket, stop that process before you start the service.
A foreground development daemon and the user service cannot share one socket.
See [isolated development](development.md#isolated-daemon).

## fluxd runs an earlier version

`flux-cli version` shows the version of the running `fluxd`.
`fluxd.service` restarts by itself after an update.
It waits while 1 of these runs:

- A file transfer
- A webcam, microphone, or screen mirror stream
- The remote desktop
- A Browse PC session
- The send of the Android app
- A fingerprint approval

The journal then shows a line such as `the restart waits for Browse PC`.
To end a Browse PC session, select **Stop** in its desktop notification.

If `flux-cli version` says `fluxd runs an earlier version`, restart the service once:

```sh
systemctl --user restart fluxd
```

If the new version still does not start, read the log:

```sh
journalctl --user -u fluxd -n 50 --no-pager
```

The line `the new ... does not run` means that the new binary failed its version check.
Install the update again.

### The service runs an old fluxd after a package install

systemd uses a unit in `~/.config/systemd/user/` before the unit of the package in `/usr/lib/systemd/user/`.
A `flux-cli setup` of a checkout or `make install-user` writes such a unit.
After a package install, it hides the unit of the package, and the service runs the old `fluxd`.
`flux-cli doctor` reports it:

```text
✗ /home/you/.config/systemd/user/fluxd.service hides /usr/lib/systemd/user/fluxd.service, so the service does not run the fluxd of the package. To remove it, run: flux-cli setup
```

To remove a unit that `flux-cli setup` wrote, run `flux-cli setup` again.
`flux-cli setup` keeps a unit that you changed and prints its path.
Remove such a unit yourself, then reload systemd:

```sh
systemctl --user daemon-reload
```

## The release check fails

Flux works without the internet.
Only the daily [release check](configuration.md#release-check) needs a connection to `api.github.com`.
`flux-cli doctor` shows the error of the last failed check.
`fluxd` tries again after 1 hour or at the next network change, but not earlier than 1 minute after the failure.

To turn the check off, set `check_updates = false` in `~/.config/flux/config.toml`, then run:

```sh
systemctl --user reload fluxd
```

## flux-cli update refuses a release

`flux-cli update` checks `SHA256SUMS.sig` with the public release key of its build, then it checks the package against `SHA256SUMS`.
When a check fails, it installs nothing and prints the cause:

| Message | Next step |
| --- | --- |
| `the release has no SHA256SUMS.sig, so Flux cannot check who made it` | The upload of the release can be incomplete. Try again later. |
| `SHA256SUMS.sig does not match SHA256SUMS and the release key, so Flux does not trust this release` | Do not install the release. Report it to the maintainer. |
| `the SHA-256 checksum of FILE is …, and SHA256SUMS gives …` | The download is damaged. Run `flux-cli update` again. |

A `flux-cli` without a release key checks only `SHA256SUMS` and says so.
See [check a release](install.md#check-a-release) to check the files by hand.

## The phone does not appear

1. Open Flux for Android or Flux for macOS.
2. Check that both devices use the same local network.
3. Check Avahi:

   ```sh
   systemctl status avahi-daemon
   ```

4. Request discovery:

   ```sh
   flux-cli discover
   flux-cli status
   ```

Guest Wi-Fi and client isolation can block devices on the same access point.
`fluxd` listens on 1 TCP port from 1716 to 1764 and on UDP port 1716, but it does not need inbound traffic.
It finds the devices through mDNS and opens the connections itself.
So a new inbound desktop firewall rule is not the default fix.
See [network ports](security.md#network-ports).
Keep the existing identity and trust store while you diagnose connectivity.

Flux for Android takes a connection from a new computer only while Flux is on the screen or while it scans.
Open Flux on the phone before you pair.

On a Mac, check that Flux has access to the local network.
To read the Mac logs, run:

```sh
log stream --predicate 'subsystem == "org.omarchy.flux"'
```

## The pairing keys differ

The pairing key has 16 characters in 4 groups of 4, for example `5EE6 825F 974E D59A`.
An earlier Flux app shows only 8 characters.
If 1 screen shows 8 characters, reject the request, update Flux on that device, and pair again.
If the 16 characters differ, reject the request.
Another device can be between the phone and the computer.

`flux-cli pair` finds a name only among the devices that are connected and not paired.
When the name still matches more than 1 device, `flux-cli pair` returns the `ambiguous` error with the device IDs.
See [pair and discover](cli.md#pair-and-discover) for the match rule of each command.
Give the device ID in place of the name.

## A pairing from the computer stops after the phone accepts

A pairing that you start on the computer can stop right after you accept on the phone.
The Flux window then shows `Pairing with Pixel 8 stopped, because the connection closed`.
A large phone clipboard can be the cause, because Flux for Android sends its clipboard when it accepts.
Until you confirm on the computer, `fluxd` reads at most 64 KiB in 1 packet from the phone.
It closes the connection for a larger packet, and the pairing stops.

To find the cause, run:

```sh
journalctl --user -u fluxd -n 50 --no-pager | grep "packet too large"
```

To pair, do 1 of these steps:

- Clear the phone clipboard, or copy a short text on the phone, and pair again.
- Start the pairing on the phone, and accept it on the computer.

## The phone does not connect away from home

Flux reaches a phone outside the local network only through an extra address, for example its Tailscale name.

```sh
flux-cli addresses
flux-cli doctor
tailscale ping pixel-8
journalctl --user -u fluxd -n 50 --no-pager | grep "connect to"
```

If `flux-cli addresses` shows `none` for the phone, add its Tailscale name.
See [Connect through Tailscale](tailscale.md#troubleshoot) for the other checks.

## The window or bar item is missing

Try the Qt host directly:

```sh
FLUX_GUI=app flux-cli open
```

If it works, refresh the installed plugin:

```sh
flux-cli setup
omarchy-shell shell rescanPlugins
```

For a user-only install, install the plugin from the checkout with `make install-plugin`.
See [plugin layout](omarchy.md#install-layout).
Missing icons usually indicate a missing Nerd Font or Qt SVG package.

## Text messages do not show

If the Messages page is missing, the phone does not offer its text messages.

1. Open **Computers > Sync** in Flux for Android.
2. Turn on **Text messages**.
3. Allow SMS access when the phone asks.

If the switch stays off, open **Settings > Apps > Flux > Permissions** on the phone and allow **SMS**.
If Android shows **Restricted setting**, open **Settings > Apps > Flux**, open the menu, and select **Allow restricted settings**.
Then turn on **Text messages** again.

If a sent message shows **Not sent**, the phone could not send it.
Check the signal and the SMS app on the phone.
Flux does not send messages to a group. Reply to a group on the phone.

## Automatic clipboard sync stopped

A copy on the phone stops reaching the computer after a reboot, a Flux
update, or an app kill.
Android does not keep the log access, so the automatic sync ends.

To resume it, open Flux and tap **Allow one-time access**.
The status line under the switches of the **Sync** screen then shows **Automatic clipboard sync is on**.
Flux checks the log access the first time that you leave the app after the automatic sync starts.
If the access is off, the status line shows **Open Flux to resume automatic sync**.
The service notification then shows **Open Flux to resume clipboard sync**.

If the status line stays on **Only while Flux is open. Set up automatic sync**,
**Automatic sync** is off, or Flux has no `READ_LOGS` permission or no overlay access.
Tap the status line to open the setup sheet.
If the sheet shows **Allow drawing over apps**, tap it.
To give the overlay access with adb, run:

```sh
adb shell appops set org.omarchy.flux SYSTEM_ALERT_WINDOW allow
```

When Flux has both accesses, turn on **Automatic sync** at the end of the sheet.

To give the log access again, follow [set up the automatic clipboard](android-setup.md#automatic-clipboard-sync).

A copy that its app marks as sensitive, for example a password, does not sync by itself.
The **Send clipboard** tile does not send it either.
To send such a copy, open Flux and tap **Send clipboard** in **Send**.

## Media controls do not show on the phone

The phone shows the controls of a desktop player that publishes its state over MPRIS.
To list these players and the media log of the daemon:

```sh
busctl --user list | grep org.mpris.MediaPlayer2
journalctl --user -u fluxd --no-pager | grep media
```

If the list does not show the player, the player has no MPRIS support.
For mpv, install `mpv-mpris`.
If the log shows `media control off`, `fluxd` did not connect to the session bus.
Restart it with `systemctl --user restart fluxd`.

A player that does not accept a new volume shows no volume control.
Chromium is an example.

## Camera, microphone, or screen fails

```sh
flux-cli webcam
flux-cli mic
flux-cli screen
flux-cli doctor
```

The webcam needs `ffmpeg`, `v4l2loopback-dkms`, and headers for the active kernel.
The microphone needs PipeWire and phone microphone permission.
The screen mirror needs `mpv` or `ffplay` and the Android capture prompt.
See [camera and streams](camera.md) for setup commands.

## herdr agents do not show

```sh
herdr status
flux-cli doctor
journalctl --user -u fluxd --no-pager | grep herdr
```

`fluxd` and herdr must run as the same user.
See [herdr agents](herdr.md#troubleshoot) for the socket path and the phone states.

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

If Play Protect shows **App blocked to protect your device**, install with `adb`.
See [Android setup and Play Protect](android-setup.md#install-flux-past-the-block).

## Fingerprint approval falls back to a password

```sh
flux-cli approve
flux-cli status
```

Check the phone connection, enrolled key, fingerprint setup, and approval timeout.
A new fingerprint can invalidate the phone key and require enrollment again.
Keep the password fallback active while you diagnose approval.
See [approval setup](approvals.md).
