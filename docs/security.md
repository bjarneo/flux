# Security

[Documentation index](README.md)

This page tells what a paired device can do on the computer and what the network exposes.
It also tells which setting turns a feature off, when one exists.
A paired device is an Android phone, an iPhone, or a Mac that you paired with `fluxd`.

`fluxd` treats each paired device the same.
Each setting in `~/.config/flux/config.toml` applies to every paired device.
Flux has no setting for 1 device.
To take the access of 1 device away, [unpair it](#unpair-a-device).

## Pair only with your own device

The pairing key has 16 uppercase hex digits in 4 groups of 4, for example `5EE6 825F 974E D59A`.
Both devices compute it from their 2 certificates and the time of the request.
The key has 64 bits.
So a device between the phone and the computer cannot find a certificate with the same key while the request is open.

Before you accept a pair request, check these items:

- You started the pairing yourself, now.
- The request names your device.
- All 16 characters are the same on both screens.

If 1 item is not true, reject the request.
An earlier Flux app shows only 8 characters.
Update Flux on the computer and on each phone, iPhone, and Mac before you pair, and compare all 16 characters.

A pairing that the computer starts needs a confirmation on the computer too.
After the device accepts, the Flux window, the notification, and `flux-cli pair` ask you to confirm the key.
`fluxd` pins the device only after that step.
So a device that copies the name of your phone cannot pair when you select it by mistake.
Each accept and confirm names the key that you compared, and `fluxd` refuses it when the open pairing has another key.
Without a key, `flux-cli accept` shows the key of the open pairing and asks you to compare it before it sends the key.
When stdin is not a terminal, it accepts nothing and prints the command with the key.
The Flux window and the notification also send the key with a reject.
Without a key, `flux-cli reject` rejects the pairing that is open when it runs.

After the pairing, `fluxd` pins the certificate of the device.
It refuses each link that does not show that certificate.
Each device in `flux-cli status --json` has a `fingerprint`: 16 hex digits from the public key of its certificate.
`flux-cli status` shows the device ID and the fingerprint under each device.
The device card on the **Overview** page of the Flux window shows the fingerprint under **certificate**.
`flux-cli pair` and `flux-cli accept` print the device ID and the key.
`flux-cli unpair` prints the device ID and the fingerprint.
See [pairing security](features.md#pairing-security) and [pairing and trust](architecture.md#pairing-and-trust).

## What a paired device can do

The table lists what a paired device can do on the computer with the default settings.
It also tells which setting turns a feature off, when one exists.

| Feature | Default | What a paired device can do | Turn it off |
| --- | --- | --- | --- |
| Files | On | Send files into `download_dir`, scans into `scan_dir`, and photos, screenshots, and signatures into `photo_dir`. `fluxd` also puts a signature on the clipboard. `fluxd` makes each name safe and never replaces a file. See [files, clipboard, and links](features.md#files-clipboard-and-links). | No setting. Unpair the device. |
| Links and text | On | Open an `http` or `https` URL with a host in the browser. Each other value goes on the clipboard as text. | No setting. Unpair the device. |
| Clipboard sync | `auto_clipboard = true` | Get each text and image that you copy on the computer, and put text and images on the clipboard of the computer. | `auto_clipboard = false` |
| Browse PC | `share_home = true` | Read the home folder, `download_dir`, and `~/Documents`, `~/Pictures`, `~/Music`, and `~/Videos`. `fluxd` hides each name that starts with a dot, such as `~/.ssh`, and the Flux folders. The device cannot change a file. See [Browse PC](features.md#browse-pc). | `share_home = false`. It ends each session at once. |
| Notifications | `notifications = true` | Show its notifications on the computer. | `notifications = false` |
| Do Not Disturb | `sync_dnd = true` | Turn Do Not Disturb of the computer on and off. | `sync_dnd = false` |
| Calls | `pause_media_on_call = true` | Pause the media players of the computer during a call. | `pause_media_on_call = false` |
| Media | On | Play, pause, skip, seek, and set the volume of the media players of the computer. | No setting. Unpair the device. |
| Desktop commands | No commands | Run each command in `commands`. | `flux-cli commands remove ID` |
| herdr agents | `herdr = true` | Read the list of the [herdr agents](herdr.md) and the recent output of each agent. | `herdr = false` |
| Agent control | `herdr_control = false` | Send keys and prompts to the agents, start agents, and close them. An agent runs commands, so the device can run any command as your user. | `herdr_control = false` |
| Terminals | `herdr_terminals = false` | Read and type in each herdr pane that has no agent, also a `sudo -i` shell or an SSH session that you opened. Needs `herdr_control`. | `herdr_terminals = false` |
| Remote input | `remote_input = false` | Move the pointer and type in each window, also on the lock screen. See [touchpad and keyboard](remote-input.md). | `flux-cli input off` |
| Remote desktop | `remote_desktop = false` | See the screen, each window, and the lock screen. See [remote desktop](remote-desktop.md). | `flux-cli desktop off`. It stops each stream at once. |
| Webcam, microphone, and screen mirror | On | Stream its camera to the **Flux Camera** device, its microphone to a PipeWire source, and its screen to a window. The device starts each stream. The computer cannot start the camera or the microphone of the device. See [camera and streams](camera.md). | No setting. `flux-cli webcam stop`, `flux-cli mic stop`, and `flux-cli screen stop` stop a stream. |
| Approvals | Off | Approve `sudo`, and `hyprlock` or `polkit-1` when you enable them, for the user who enrolled the device. See [fingerprint approval](approvals.md). | `sudo flux-cli approve disable` or `sudo flux-cli approve remove` |

To change a setting, edit `~/.config/flux/config.toml`, then reload `fluxd`:

```sh
systemctl --user reload fluxd
```

The **Remote access** card of the Flux window turns remote input and the remote desktop on and off.
A script can call the IPC method `settings.set`. See [IPC](ipc.md).
See [configuration](configuration.md#settings) for each setting.

The apps ask for the screen lock, Face ID, or Touch ID before the touchpad, the remote desktop, and the replies to agents.
This check protects the app only, and `fluxd` cannot see it.
The settings in `config.toml` are the checks that `fluxd` makes.
So turn on `remote_input`, `remote_desktop`, `herdr_control`, and `herdr_terminals` only when you trust each paired device.

## What a device sends to the computer

Flux for Android has 6 switches that share data of the device with the computers.
They are on the **Sync** screen in **Computers**:

- **Text messages** lets each paired computer read your conversations and send text messages.
- **Share notifications** sends the notifications of other apps. A notification whose visibility, or whose channel lock screen visibility, is `VISIBILITY_SECRET` stays on the phone. The lock screen setting of the whole phone does not change what Flux sends. A button that needs the phone unlock also stays on the phone.
- **Send new screenshots** and **Send new photos** send new images of the camera app and the screenshot tool.
- **Sync clipboard** sends the text and the images that you copy while Flux is on the screen. A 1-tap path or the opt-in automatic sync sends a copy from another app. See [send a copy from another app](features.md#send-a-copy-from-another-app).
- **Call alerts** sends the state of calls, and with more permissions the number and the name of the caller.

Each switch applies to every paired computer, not only to the computer whose page shows it.
See [sync switches](android-setup.md#sync-switches).
Flux for iOS and Flux for macOS send less, because their systems give apps less access.
See [Flux for iOS](ios.md#features) and [Flux for macOS](macos.md#features).

The computer can send files, links, text, and notifications to a paired device.
Each app opens a link or a file from the computer only after a tap.
Flux for Android installs no app that the computer sends, except a newer Flux with the signing key of the installed Flux, after your tap.

## Network ports

`fluxd` listens on these ports on all network interfaces:

| Port | Use |
| --- | --- |
| The first free TCP port from 1716 to 1764 | Links from devices |
| UDP 1716 | Identity broadcasts from devices |

`flux-cli status` shows the TCP port in its first line.
`fluxd` also publishes the `_flux._udp` service through Avahi, and it sends its identity to UDP port 1716 of the local networks.

`fluxd` opens the links to the devices itself, so Flux needs no inbound firewall rule.
The default Omarchy firewall blocks inbound traffic to the Flux ports, and it lets mDNS in.
With this firewall, `fluxd` finds the devices through mDNS and the [extra addresses](tailscale.md).
The UDP broadcasts of the devices reach `fluxd` only without such a firewall.
To see the rules, run:

```sh
sudo ufw status verbose
```

Without such a firewall, each host that reaches the computer can open a link to `fluxd` and send a pair request.
The same is true for a rule that lets in the traffic of an interface, for example `ufw allow in on tailscale0`.
The [limits below](#devices-that-are-not-paired) apply to such hosts.

The Android phone, the iPhone, and the Mac also listen on TCP ports 1716 to 1764.
Flux for Android takes a link from a computer that is not paired only while Flux is on the screen or while it scans.

## Album art

Besides the paired computers, the apps connect to 1 other kind of host.
The **Media** screen loads the album art from the `https` address that a player on the computer reports.
That host is usually a server of the music or video service, and it sees the IP address of the device.
`fluxd` sends only `https` addresses to the devices, never a `file:` address with a local path.
Without an address, the screen shows no art and loads nothing.

## Devices that are not paired

Any host on the network can send an identity and open a link.
`fluxd` ignores each packet of a device that is not paired, except a pair request.
It keeps these limits for such devices:

- A link reads lines of at most 64 KiB.
- `fluxd` keeps at most 8 such links, and 2 for each address. A new link closes the oldest one.
- A link without a pair request closes after 2 minutes.
- `fluxd` takes 1 pair request for each device in 2 seconds, shows 1 notification for each device, and keeps at most 4 open requests. At most 2 of them come from 1 address.
- When a request of a device ends with a withdraw, a reject, a timeout, or the end of its connection, `fluxd` refuses a new request of that device for 30 seconds.
- When `fluxd` refuses a request because too many requests are open, the Flux window shows the name and the address of the device.
- Dials to these devices share a limit of 16 at the same time. Dials to paired devices do not count, so these devices cannot keep a paired device offline.

See [limits for devices that are not paired](architecture.md#limits-for-devices-that-are-not-paired) for the complete list.

## Unpair a device

To unpair a device from the computer, run:

```sh
flux-cli unpair "Pixel 8"
```

A name matches only a device that is paired or connected, and a paired device comes first.
When the name still matches more than 1 device, the command returns the `ambiguous` error with the device IDs.
See [pair and discover](cli.md#pair-and-discover) for the match rule of each command.
Give the device ID in place of the name.

An unpair from either side ends every session of the device:

- `fluxd` sends the unpair message, `pair: false`, to the device and closes the link.
- Browse PC, the streams, the remote desktop, and remote input stop. `fluxd` drops the input that waits and releases a held button.
- `fluxd` sends no answer of a herdr read, a reply, or a start that still runs.
- `fluxd` removes the notifications, the messages, the battery state, and the extra addresses of the device. It closes the desktop notifications of the device, because their buttons no longer reach it.

When `fluxd` cannot save `devices.json`, the command returns the `not_saved` error.
The device is then unpaired only until `fluxd` restarts, because `~/.local/share/flux/devices.json` still has it.
Fix the cause in the error, for example the permissions of the file.
Then restart `fluxd` and unpair the device again:

```sh
systemctl --user restart fluxd
flux-cli unpair "Pixel 8"
```

After an unpair, the device must send a new pair request, and you must accept it again.

If you lose a device, unpair it on the computer at once.
If the device can approve `sudo`, also remove its key:

```sh
sudo flux-cli approve remove
```

An unpair on the Android phone, the Mac, or the iPhone deletes its approval key for that computer.
The key file on the computer stays until you run `sudo flux-cli approve remove`.
