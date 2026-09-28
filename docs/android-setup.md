# Flux for Android setup and Play Protect

[Documentation index](README.md)

Google Play Protect can block the Flux APK with **App blocked to protect your device**.
This page tells you why Android blocks Flux and how to install it.
It also describes how Flux for Android is set up: the service, the network, and each permission.

## Why Play Protect blocks Flux

The block comes from enhanced fraud protection, a part of Google Play Protect.
The dialog shows this text:

> This app can request access to sensitive data. This can increase the risk of identity theft or financial fraud.

The dialog has only a **Got it** button, so you cannot install the app from it.

Enhanced fraud protection checks each app that you install from a browser, a messaging app, or a file manager.
It blocks the install when the app declares one of these permissions:

- `RECEIVE_SMS`
- `READ_SMS`
- A notification listener
- An accessibility service

Flux declares 2 of them:

| Permission | Flux feature |
| --- | --- |
| `READ_SMS` | **Text messages** shows the phone conversations on the computer. |
| Notification listener | **Share notifications** shows the phone notifications on the computer. |

Flux does not come from Google Play, so the check runs for each APK that you open from the browser or the Files app.
An update through the browser or the Files app gets the same check.
Google turns on enhanced fraud protection by country, so a phone in one country can install the APK and a phone in another country cannot.

## Install Flux past the block

Use one of these 2 methods.
The `adb` method keeps Play Protect on, so use it when you can.

### Install with adb

`adb install` does not go through the check for a browser, a messaging app, or a file manager.

1. On the phone, open **Settings > About phone** and tap **Build number** 7 times.
2. Open **Settings > Developer options** and turn on **USB debugging**.
3. Connect the phone to the computer with a USB cable.
4. Accept the **Allow USB debugging** prompt on the phone.
5. Install the APK from the computer:

   ```sh
   adb install -r flux-android-0.1.0.apk
   ```

Replace the filename with the downloaded version.
The `-r` flag keeps the app data and the pairings when you update.

To use Wi-Fi instead of a cable, turn on **Wireless debugging** in **Developer options**.
Select **Pair device with pairing code**, then pair and connect with the address and the code that the phone shows:

```sh
adb pair 192.168.1.20:37215
adb connect 192.168.1.20:41393
adb install -r flux-android-0.1.0.apk
```

The pairing port and the connection port are different.
Use the ports that the phone shows.

On a Samsung phone, **Auto Blocker** blocks apps from unknown sources and commands through USB.
If the install or `adb` fails, open **Settings > Security and privacy > Auto Blocker** and turn it off for the install.

### Install with app scanning off

CAUTION: While app scanning is off, Play Protect does not check any app that you install. Turn it on again after the install.

1. Open the Google Play Store.
2. Tap the profile icon, then **Play Protect**.
3. Tap the settings icon.
4. Turn off **Scan apps with Play Protect**.
5. Open the Flux APK in the Files app and install it.
6. Turn on **Scan apps with Play Protect** again.

## Allow restricted settings

Android 13 and later restrict notification access for an app that you install from a browser, a messaging app, or a file manager.
Android 15 and later also restrict SMS access for these apps.
Android then shows **Restricted setting** when you turn on **Share notifications** or **Text messages**.

To give Flux these permissions:

1. Open **Settings > Apps > Flux**.
2. Open the menu in the top corner and select **Allow restricted settings**.
   The menu item shows only after Android has shown **Restricted setting** for Flux once.
3. Confirm with the PIN or the fingerprint of the phone.
4. Return to Flux and turn on **Share notifications** or **Text messages** again.

## How Flux for Android is set up

### Distribution

Each GitHub release has `flux-android-VERSION.apk` and `SHA256SUMS`.
All release APKs use one persistent release key.
Flux is not on Google Play.
See [Install a release APK](android.md#install-a-release-apk) to check the download.

### Background service

`FluxService` is a foreground service of the `connectedDevice` type.
It keeps the links to the computers open while the app is in the background.
Android requires a visible notification for this service, so Flux shows **Waiting for a computer on this network** or the number of connected computers.

The service starts again after a restart of the phone and after an app update.
**Turn off Flux** in the app menu or **Turn off** in the notification stops the service.
Flux then stays off after a restart, until you turn it on again.

### Network

Flux uses KDE Connect protocol version 8 with Flux extensions.
Both devices must be on the same local network, or use an [extra address](tailscale.md).

| Part | Port or name | Direction |
| --- | --- | --- |
| mDNS announcement | `_kdeconnect._udp` | The phone announces itself for as long as the service runs. `fluxd` finds the phone this way. |
| UDP identity | UDP port 1716 | The phone listens for identities from computers and sends its own identity. |
| TLS link | A TCP port from 1716 to 1764 | The phone accepts links and opens links to computers. |

When the app opens, the phone scans for computers for 10 seconds.
A scan sends the identity over UDP and browses mDNS, then stops.
To scan again, tap **Scan again** on the device list.

### Permissions

Flux asks for a runtime permission only when you turn on the feature that uses it.
The other permissions need no prompt.

| Permission | Feature | When Flux asks |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `CHANGE_NETWORK_STATE` | Discovery and links on the local network | No prompt |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK` | The background service | No prompt |
| `POST_NOTIFICATIONS` | The service notification, pair requests, and alerts | When the app first opens |
| `USE_FULL_SCREEN_INTENT`, `VIBRATE` | **Find my phone** and fingerprint approval requests | No prompt |
| Notification listener | **Share notifications** | The switch opens the Android settings page |
| `QUERY_ALL_PACKAGES` | App names on shared notifications | No prompt |
| `READ_SMS`, `SEND_SMS`, `READ_CONTACTS` | **Text messages** | When you turn on the switch |
| `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS` | **Call alerts** | When you turn on the switch |
| `ACCESS_NOTIFICATION_POLICY` | **Sync Do Not Disturb** | The switch opens the Android settings page |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VISUAL_USER_SELECTED`, `READ_EXTERNAL_STORAGE` | **Send new screenshots** and **Send new photos** | When you turn on the switch |
| `CAMERA` | The camera modes and the webcam | When a camera page opens |
| `RECORD_AUDIO`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` | The microphone, dictation, and the screen mirror | When the feature starts |
| `USE_BIOMETRIC` | [Fingerprint approval](approvals.md) of `sudo` and polkit | No prompt |

`READ_EXTERNAL_STORAGE` applies only to Android 12 and earlier.
The call log and the contacts are optional for **Call alerts**. They add the number and the name of the caller.
The source of truth is `android/app/src/main/AndroidManifest.xml`.

## Developer verification

Google adds a second install check for apps from outside Google Play.
From September 30, 2026, certified Android devices in Brazil, Indonesia, Singapore, and Thailand install only apps from registered developers.
Google plans to add other countries from 2027.

For an app from a developer that is not registered, Google gives 2 install routes:

- `adb install`, as in [Install with adb](#install-with-adb).
- An advanced flow in the Android settings, with a one-time setup and a waiting period.

This check is separate from enhanced fraud protection.
A phone can get both checks.

## References

- [Developer guidance for Google Play Protect warnings](https://developers.google.com/android/play-protect/warning-dev-guidance)
- [Understanding Android developer verification](https://support.google.com/android-developer-console/answer/16561738)
- [Android developer verification: Balancing openness and choice with safety](https://android-developers.googleblog.com/2026/03/android-developer-verification.html)
