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
Install `adb` on the computer first, as in [Android requirements](android.md#requirements).

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
On Android 15, an app that you install with `adb` can also get the restriction.
Android then shows **Restricted setting** when you turn on **Share notifications** or **Text messages**.

To give Flux these permissions:

1. Open **Settings > Apps > Flux**.
2. Open the menu in the top corner and select **Allow restricted settings**.
   The menu item shows only after Android has shown **Restricted setting** for Flux once.
3. Confirm with the PIN or the fingerprint of the phone.
4. Return to Flux and open **Computers > Sync**.
   Turn on **Share notifications** or **Text messages** again.

If the menu item does not show, allow restricted settings from the computer with `adb`:

```sh
adb shell appops set org.omarchy.flux ACCESS_RESTRICTED_SETTINGS allow
```

Then turn on the switch in Flux again.

## Send clipboard tile

The **Send clipboard** tile sends the current clip to each connected paired computer.
To add the tile:

1. Open the Quick Settings panel and open the edit screen.
2. Drag **Send clipboard** into the panel.
3. Copy in any app, then tap the tile.

The Flux service notification also has a **Send clipboard** action while a computer is connected.
The text selection menu of any app has a **Send to computer** action.
It sends the selected text to the computer that you pick.
These paths need no setup and no extra permission.

## How Flux for Android is set up

### Distribution

Each GitHub release has `flux-android-VERSION.apk` and `SHA256SUMS`.
When the release signing key is set, the release also has `SHA256SUMS.sig`, the signature of `SHA256SUMS`.
Check the signature before you check the APK against `SHA256SUMS`.
All release APKs use one persistent release key.
Flux is not on Google Play.
See [Install a release APK](android.md#install-a-release-apk) to check the download.

### Background service

`FluxService` is a foreground service of the `connectedDevice` type.
It keeps the links to the computers open while the app is in the background.
Android requires a visible notification for this service, so Flux shows **Waiting for a computer on this network** or the number of connected computers.

The service starts again after a restart of the phone and after an app update.
**Turn off Flux** in **Computers** or **Turn off** in the notification stops the service.
Flux then stays off after a restart, until you turn it on again.

While the webcam or the mic streams, `StreamService` also runs.
It is a foreground service of the `camera` and `microphone` types, so the streams keep running in the background.
Its notification is in the **Live streams** channel.
See [streams in the background](camera.md#streams-in-the-background).

### Network

Flux uses Flux protocol version 8.
Both devices must be on the same local network, or use an [extra address](tailscale.md).

| Part | Port or name | Direction |
| --- | --- | --- |
| mDNS announcement | `_flux._udp` | The phone announces itself for as long as the service runs. `fluxd` finds the phone this way. |
| UDP identity | UDP port 12100 | The phone listens for identities from computers and sends its own identity. |
| TLS link | A TCP port from 12100 to 12108 | The phone accepts links and opens links to computers. |
| File, stream, and tunnel connections | A TCP port from 12070 to 12099 | The phone listens, and the paired computer connects. |

An earlier Flux for Android uses other ports and cannot connect to a `fluxd` with these ports.
See [Update the app](android.md#update-the-app).

When the app opens, the phone scans for computers for 10 seconds.
A scan sends the identity over UDP and browses mDNS, then stops.
To scan again, open **Computers** and pull the list down, or tap **Scan again**.

### Permissions

Flux asks for a runtime permission only when you turn on the feature that uses it.
The other permissions need no prompt.

| Permission | Feature | When Flux asks |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `CHANGE_NETWORK_STATE` | Discovery and links on the local network | No prompt |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK` | The background service | No prompt |
| `POST_NOTIFICATIONS` | The service notification, pair requests, and alerts | Once after the first pairing. The **Inbox** tells why. |
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
| `HIDE_OVERLAY_WINDOWS` | The pair sheet and the approval screen hide the windows of other apps on Android 12 and later | No prompt |
| `REQUEST_INSTALL_PACKAGES` | [Updates that the computer sends](android.md#update-the-app) | Android asks to allow **Install unknown apps** at the first update |

Flux shows no permission dialog before the first pairing.
Keep Flux open for the first pairing. Before you allow notifications, Android 13 and later show no notification for a pair request.
After the first pairing, the **Inbox** tells why Flux needs notifications: **Allow notifications, so that Flux can show when an agent needs you.**
1 second later, Android asks once for notifications.
If you deny it, the **Inbox** keeps the question with **Allow**.
After 2 denials, Android does not show its dialog again, so the **Inbox** shows **Open settings** in its place.
**Hide** removes the question. You can allow notifications in the settings of Android at any time.

`READ_EXTERNAL_STORAGE` applies only to Android 12 and earlier.
The call log and the contacts are optional for **Call alerts**. They add the number and the name of the caller.
When you allow the call log later, the next call shows the number without a restart of Flux.
The source of truth is `android/app/src/main/AndroidManifest.xml`.

### Sync switches

The switches on the **Sync** screen in **Computers** are settings of the phone.
Each switch applies to every paired computer, not only to the computer whose page shows it.
For example, **Text messages** lets each paired computer read your conversations and send text messages.
**Send new photos** sends each new photo to each connected computer.
The page lists the computers that get the data.

### Shared notifications

**Share notifications** sends the notifications of other apps to the connected computers.
Flux does not send these notifications:

- The notifications of Flux.
- Ongoing notifications and the notifications of foreground services, for example a call or a VPN.
- Group summaries.
- Notifications whose visibility, or whose channel lock screen visibility, is `VISIBILITY_SECRET`. The lock screen setting of the whole phone does not change what Flux sends.

Flux sends the notifications of the apps in a work profile too.

A computer gets the reply field and the buttons of a notification.
Flux keeps a button on the phone when it needs text input or the phone unlock.
A reply that needs the phone unlock also stays on the phone.

A computer can reply, press a button, or dismiss a notification only when Flux sent that notification to that computer.
It can press only the buttons that Flux sent.
When you turn off **Share notifications**, the computers remove the shared notifications, and their replies and buttons stop working.
The same happens when you take the notification access away from Flux.

### Received files and links

Flux saves each received file in **Downloads**.
Flux removes control characters and format characters, such as the marks that change the text direction, from the file name.
A received app opens the Android installer only when it is a newer Flux with the signing key of the installed Flux.
Flux saves any other app in **Downloads**, and its notification does not install it.
The notification of a file with a type that Android does not know opens **Downloads**.

Flux opens a received link only when it is an `http` or `https` URL with a host.
Flux puts any other value, such as a `file:` URL, on the clipboard as text.

The share sheet of Android sends the files that another app shares.
Flux does not send `file:` paths or its own files from the share sheet.

### Automatic screenshots and photos

**Send new screenshots** and **Send new photos** send only the images of the default camera app and of the system apps.
The camera and the screenshot tool of the phone are such apps.
Flux does not send an image that another app puts in the camera or screenshot folder.
When you turn off a switch, Flux stops the images of that switch that did not go out yet.

When no computer is connected, the new images wait.
They go out when a computer connects.

When a connected computer does not take an image, Flux tries again after 1 minute.
Each new wait is 2 times longer, up to 1 hour.
After 8 tries, Flux stops and shows a notification.
Only a try with a connected computer counts.

### Remote control and the phone lock

**Touchpad and keyboard** and **Remote desktop** ask for the phone lock before they open.
They ask also when the switch on the computer is off, because the computer can turn it on while the page shows.
An unlock stays valid for 5 minutes.
After this time, the page asks for the phone lock again in these cases:

- The app comes back to the front.
- The computer connects again, or it turns its switch on.

If you cancel, the page closes.

### Data and backups

Flux keeps its data out of cloud backups and out of the transfer to a new phone.
The data holds the identity of the phone and the certificates of the paired computers, so a copy could act as this phone.
After a move to a new phone, pair each computer again.
Then enroll [fingerprint approval](approvals.md) again with `sudo flux-cli approve enroll`.

When you unpair a computer on the phone, the phone deletes its fingerprint approval key for that computer.
The key file on the computer stays until you run `sudo flux-cli approve remove`.

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
