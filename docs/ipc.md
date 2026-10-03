# Local IPC

[Documentation index](README.md)

The CLI and desktop hosts use JSON lines over a Unix socket.
`fluxd`, `flux-cli`, and both desktop hosts find the socket with the same rule:

1. `$FLUX_SOCKET`, when it is set.
2. Else `$XDG_RUNTIME_DIR/flux/fluxd.sock`.
3. Else `/run/user/<uid>/flux/fluxd.sock`.

Flux does not use the system temporary folder for the socket.
The daemon makes the folder of the socket with mode `0700` and the socket with mode `0600`.
It refuses a folder that is a symbolic link, that another user owns, or that other users can write to.
When others can read the `flux` runtime folder, the daemon changes its mode to `0700`.
It does not change the mode of a folder that `FLUX_SOCKET` names.
`flux-cli` checks that the folder and the socket belong to the user, and with `SO_PEERCRED` that `fluxd` runs as the user.

A second `fluxd` finds the socket of the first `fluxd`, and it stops before it starts the network.

## Requests and responses

Each request ends with a newline and has a numeric ID:

```json
{"id":1,"method":"state"}
```

Methods with arguments use a `params` object:

```json
{"id":2,"method":"ping","params":{"device":"DEVICE_ID","message":"Connection check"}}
```

A response uses the same ID and contains either `result` or `error`:

```json
{"id":2,"result":{}}
{"id":2,"error":{"code":"offline","message":"The phone is offline"}}
```

Responses can arrive out of order.
Match responses by ID.
A request line has at most 16 MiB. A longer line closes the connection.
A method that `fluxd` does not know returns the `unknown_method` error, also when no device is connected.

A client can close its write side after its requests, for example with `socat` or `nc -N`.
`fluxd` then sends the remaining responses and closes the connection:

```sh
printf '{"id":1,"method":"state"}\n' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/flux/fluxd.sock"
```

When a client closes the connection completely, `fluxd` stops the calls of that connection that still wait.
The Go types live in `internal/ipc/ipc.go`.
Method names and parameter handling live in `internal/core/api.go`.

## State and events

Call `state` for a snapshot.
The snapshot includes `self`, `devices`, `clipboard`, `transfers`, `commands`, `settings`, `webcam`, `mic`, `screen`, `desktop`, `browse`, and `herdr`.
`browse` lists the [Browse PC](features.md#browse-pc) sessions, the oldest first: the `device` ID, the `name`, and `since`, the Unix time of the start.

`self` describes this computer:

| Field | Value |
| --- | --- |
| `id`, `name`, `type` | The device ID, the name, and the device type that fluxd announces. |
| `tcpPort` | The TCP port of fluxd. |
| `version` | The build version of the running fluxd. An earlier fluxd has no `version`. |
| `pendingVersion` | The version of a new fluxd binary on disk, or an empty string. `fluxd.service` restarts into it when no transfer, stream, Browse PC session, app send, or approval runs. |

`update` is the result of the [release check](configuration.md#release-check):

| Field | Value |
| --- | --- |
| `enabled` | `false` when `check_updates` is off. The other fields are then empty. |
| `latest` | The version of the latest release, such as `0.7.0`, or an empty string before the first answer. |
| `available` | `true` when `latest` is newer than the running fluxd. |
| `url` | The GitHub page of the latest release. |
| `apk` | The download address of the Android app in the latest release. |
| `checkedAt` | The Unix time of the last answer, or `0`. |
| `error` | The error of the last check, such as a missing network, or an empty string. |

To receive events, send:

```json
{"id":3,"method":"subscribe"}
```

Events use `event` and `data` fields:

```json
{"event":"state","data":{"devices":[]}}
```

The example omits the other state fields.
Events can arrive before the subscription response.
fluxd sends a `state` event only when the state changed.
The other event is `toast`, with a short `text` for the window.
A client that reads slowly gets only the newest `state` event.

Next to the newest `state` event, fluxd queues at most 256 messages for each connection: the responses and the `toast` events.
When a `toast` event does not fit in the queue, the client loses its connection.
A response waits for a free place.
The socket buffer of the kernel takes the data first.
When that buffer is full and a write does not end in 5 seconds, the client loses its connection.
So read the socket all the time, also while you wait for a response.

For shell scripts, use the CLI wrappers:

```sh
flux-cli status --json
flux-cli watch
```

## Devices

Each device in `devices` has these fields:

| Field | Value |
| --- | --- |
| `id`, `name`, `type` | The device ID, the name, and the device type, such as `phone` or `laptop`. |
| `fingerprint` | 16 uppercase hex digits: the first 8 bytes of the SHA-256 of the SubjectPublicKeyInfo of the certificate of the device. An empty string when fluxd knows no certificate. It tells 2 devices with the same name apart. |
| `paired`, `online` | Whether the device is paired, and whether it has a link now. |
| `pairState` | `none`, `paired`, `requested` for a request of this computer, `confirm` for a request of this computer that the device accepted, or `incoming` for a request of the device. |
| `pairKey` | The verification key of an open pairing: 16 uppercase hex digits. The apps show it in 4 groups of 4. |
| `ip`, `addresses`, `lastSeen` | The address of the last link, the [extra addresses](#extra-addresses), and the Unix time of the last packet. |
| `battery`, `notifications`, `conversations` | The phone data. A device that is not paired has none. |
| `outbox` | The text messages that `sms.send` sent through the device and that the device did not report yet. See [the outbox](#outbox). A device that is not paired has an empty list. |
| `plugins` | The features that the device offers. `streamrequest` means that the device can start its camera and its microphone when this computer asks. |
| `app` | The Flux program of the device: `android`, `android-debug`, `ios`, `macos`, or `fluxd`. An earlier app sends none. |
| `appVersion` | The version of that program, such as `0.7.0`. |
| `appUpdate` | The version of a newer Android app in the latest release, or an empty string. |

A device that is not paired shows only while it has a link.

## Method groups

| Group | Methods |
| --- | --- |
| State | `state`, `subscribe`, `discover` |
| Pairing | `pair.request`, `pair.accept`, `pair.reject`, `pair.unpair` |
| Addresses | `addresses.add`, `addresses.remove` |
| Device | `ring`, `ping` |
| Sharing | `clipboard.send`, `clipboard.copy`, `share.files`, `share.text`, `share.url`, `transfer.cancel` |
| Commands | `commands.add`, `commands.remove`, `commands.run` |
| Notifications | `notification.dismiss`, `notification.dismissAll`, `notification.reply`, `notification.action`, `notify.send` |
| Text messages | `sms.refresh`, `sms.thread`, `sms.send` |
| Streams | `webcam.start`, `webcam.config`, `webcam.stop`, `mic.start`, `mic.stop`, `screen.stop`, `desktop.stop`, `browse.stop` |
| Approval | `approve.request`, `approve.wait`, `approve.enroll`, `approve.cancel` |
| Settings and updates | `settings.set`, `update.install`, `update.sendApp` |

`share.files` takes `paths`, a list of absolute file paths. A relative path returns the error code `bad_params`.
`update.install` opens a terminal that runs `flux-cli update`.
`update.sendApp` with a `device` downloads the Android app of the latest release, checks it, and sends it to that phone.
It first checks `SHA256SUMS.sig` with the public release key when the build of `fluxd` has one.
Then it checks the APK against `SHA256SUMS`.
When the build has a key and the release has no `SHA256SUMS.sig`, the phone gets no offer.

### Parameters

The `device` parameter takes a device ID or a name.
A name matches only a device that is paired or connected, and a paired device comes first.
Without `device`, a method uses the only connected paired device.

| Method | Parameters |
| --- | --- |
| `state`, `subscribe`, `discover` | None |
| `pair.request`, `pair.unpair` | `device` |
| `pair.accept`, `pair.reject` | `device`, and an optional `key`. See [pairing](#pairing). |
| `addresses.add`, `addresses.remove` | `device`, `address` |
| `ring` | `device` |
| `ping` | `device`, and an optional `message` |
| `clipboard.send` | `device`, and `text`. Without `text`, the clipboard of the computer. |
| `clipboard.copy` | `id` of an entry, or `text`, or `path` of an image in the history |
| `share.files` | `device`, and `paths`, a list of absolute paths. The result has the IDs of the new `transfers`. |
| `share.text`, `share.url` | `device`, and `text` or `url` |
| `transfer.cancel` | `id` of a transfer |
| `commands.add` | `name`, `command`. The result has the new `id`. |
| `commands.remove`, `commands.run` | `id` |
| `notification.dismiss` | `device`, `id` |
| `notification.dismissAll` | `device`. The result has the number that it `dismissed`. |
| `notification.reply` | `device`, `id`, `message` |
| `notification.action` | `device`, `id`, `action` |
| `notify.send` | `device`, `title`, `body`. It shows a notification on the device. |
| `sms.refresh`, `sms.thread`, `sms.send` | See [text messages](#text-messages). |
| `webcam.start`, `mic.start` | An optional `device`. See [start a stream](#start-a-stream). |
| `webcam.config` | `config`, or `reset` set to `true` |
| `webcam.stop`, `mic.stop`, `screen.stop`, `desktop.stop` | None |
| `browse.stop` | An optional `device`. Without `device`, it ends every Browse PC session. It returns `not_active` when no session ends. |
| `approve.request`, `approve.enroll`, `approve.wait`, `approve.cancel` | For the approval helper and `flux-cli approve`. See [approval](#approval). |
| `settings.set` | `key`, `value` |
| `update.install` | None |
| `update.sendApp` | `device` |

`share.url` takes only an `http` or `https` URL with a host.
`share.text`, `share.url`, and `clipboard.send` refuse a text of more than 256 KiB with `too_large`.

`settings.set` takes these keys with a boolean `value`: `autoClipboard`, `notifications`, `shareHome`, `pauseMediaOnCall`, `syncDnd`, `herdr`, `herdrControl`, `herdrTerminals`, `remoteInput`, `remoteDesktop`, and `checkUpdates`.
`name` and `downloadDir` take a string.
To turn the release check off or on over IPC, send:

```json
{"id":4,"method":"settings.set","params":{"key":"checkUpdates","value":false}}
```

### Pairing

`pair.request`, `pair.accept`, `pair.reject`, and `pair.unpair` return the device that they acted on:

```json
{"id":7,"method":"pair.request","params":{"device":"Pixel 8"}}
{"id":7,"result":{"device":"DEVICE_ID","name":"Pixel 8","key":"5EE6825F974ED59A","fingerprint":"0A1B2C3D4E5F6071"}}
```

| Field | Value |
| --- | --- |
| `device`, `name` | The device ID and the name. |
| `key` | The verification key of the request: 16 uppercase hex digits, without spaces. Empty for `pair.unpair` when no pair request is open. |
| `fingerprint` | The `fingerprint` of the device, as in the state. |

`pair.request` finds a name only among the devices that are connected and not paired.
`pair.accept` and `pair.reject` find a name only among the devices with `pairState` `incoming` or `confirm`.
A client follows the device ID of the result, so that another device with the same name cannot change the answer.

A pairing that this computer starts has 2 steps:

1. `pair.request` sets `pairState` to `requested`, and the device shows the key.
2. When the device accepts, `pairState` changes to `confirm`. The device pinned this computer, but `fluxd` pins the device only after `pair.accept`.

In state `confirm`, `pair.accept` pins the device and sends nothing to it.
`pair.reject`, the timeout of 30 seconds, and a new link of the device send `pair: false`, so that the device removes its pin.
When the link of the pairing closes, `fluxd` sends `pair: false` on the next link of the device with the same certificate.

`pair.accept` and `pair.reject` take the `key` that the user compared.
The key can have spaces and lower case letters.
With a `key`, fluxd acts only on the pairing with that key, and returns `no_request` when the open pairing has another key.
The Flux window and `flux-cli` always send the key:

```json
{"id":8,"method":"pair.accept","params":{"device":"DEVICE_ID","key":"5EE6825F974ED59A"}}
```

`pair.unpair` sends `pair: false` to the device, closes its link, and ends each session of the device.

## Errors

An error has a `code` for scripts and a `message` for people.
These codes need a step from the client:

| Code | Meaning |
| --- | --- |
| `ambiguous` | The name matches more than 1 device. The message lists the device IDs. Send the ID. Without `device`, more than 1 paired device is connected. |
| `unknown_method` | fluxd does not know the method, for example an earlier `fluxd`. |
| `not_found` | No device, command, transfer, clipboard entry, or request has the name or the ID. |
| `no_device` | No paired device is connected, and the request has no `device`. For `webcam.start` and `mic.start`, no connected device can take the request. |
| `not_supported` | The device cannot do the request, for example an earlier app. |
| `already_active` | A stream of that kind runs. Stop it first. |
| `too_soon` | The same request went to the same device less than 3 seconds ago. Wait, then send it again. |
| `not_paired`, `offline` | The device is not paired, or it has no link now. |
| `no_request` | No device with the name has an open pair request, or the open pairing has another `key`. |
| `not_saved` | `pair.unpair` could not save `devices.json`. The device is unpaired only until fluxd restarts. |
| `too_large` | The text has more than 256 KiB, the most that fluxd sends to a device. |
| `bad_params`, `bad_setting` | A parameter or a setting is missing or has the wrong type. |

The [herdr wire format](herdr.md#wire-format) uses the code `blocked` for a prompt to an agent that waits for a choice.
That code comes in a `flux.herdr` packet on the link of the device, not on this socket.

## Start a stream

`webcam.start` and `mic.start` ask a device to start its camera or its microphone for this computer.
The device asks its user first. The stream starts only after a tap on the device.

```json
{"id":9,"method":"webcam.start","params":{"device":"Pixel 8"}}
{"id":9,"result":{"device":"DEVICE_ID","name":"Pixel 8"}}
```

The result names the device that got the request: the `device` ID and the `name`.
It does not mean that the stream started.
The stream shows in `webcam` or `mic` of a later state event.

Without `device`, fluxd selects the only paired, connected device with `streamrequest` in its `plugins`.
With no such device, the method returns `no_device`.
With more than 1, it returns `ambiguous` with their names.

A `device` that cannot take the request returns `not_supported`.
A `device` that is not paired returns `not_paired`, and a `device` with no link now returns `offline`.
A `fluxd` in headless mode returns `not_supported` for each request.
While a stream of that kind runs, the method returns `already_active`.
A second request of the same kind to the same device in 3 seconds returns `too_soon`.
See [start from the computer](camera.md#start-from-the-computer).

## herdr

The `herdr` field of the state has the agents, the terminals, and the switches of the [herdr agents](herdr.md).
The socket has no herdr method.
The apps talk to `fluxd` with `flux.herdr` packets on their link:

- A `prompt` has an `answer` flag. Without `"answer": true`, fluxd refuses a prompt to an agent that waits for a choice, with the code `blocked` and the message `The agent waits for a choice. Pick a choice first.`
- An app can add a `request` number to `keys`, `prompt`, `input`, `create`, and `close`. fluxd copies it into the answer: `sent`, `created`, or `closed`.

See the [wire format](herdr.md#wire-format).

## Approval

Read the handler before you add a client call.
The approval helper applies additional peer and signature checks beyond this general socket protocol.
See the [approval design](approve.md).

- `approve.request` and `approve.enroll` start a request and return its `id`.
- `approve.wait` with the `id` waits for the answer of the phone, for at most 50 seconds. After 50 seconds, it returns the state `pending`, and the client calls it again. When the wait time of the request ends in this call, `fluxd` cancels the request on the phone.
- `approve.cancel` with the `id` ends the request and closes it on the phone.

An `approve.request` or `approve.enroll` belongs to the connection that started it.
When that connection closes, `fluxd` ends the request and closes it on the phone.
So a stopped `sudo` does not keep the phone busy until the timeout.
The helper connects only to `/run/user/<uid>/flux/fluxd.sock`. It does not read `FLUX_SOCKET` or `XDG_RUNTIME_DIR`.

## Clipboard

Each `clipboard` entry has an `id`, and `text` or an `image` with the path of a PNG, JPEG, GIF, or WebP file.
The text of an image entry is empty.
The state holds only the first 1024 bytes of a longer text.
Such an entry has `"truncated": true` and the full length in bytes in `size`.

To put an entry on the desktop clipboard again, call `clipboard.copy` with its `id`:

```json
{"id":4,"method":"clipboard.copy","params":{"id":"a1b2c3"}}
```

The call copies the full text or the image of the entry.
`clipboard.copy` also accepts `text`, or `path` with the `image` of an entry in the history.
`clipboard.send` without `text` sends the image on the desktop clipboard, or else its text.

## Text messages

`sms.refresh` asks the phone for the latest message of each conversation.
The conversations arrive in the `conversations` list of the device in the next state event.
The answer of Flux for Android replaces the list, so a conversation that you delete on the phone goes.
An older app only adds conversations.
`sms.thread` returns the last 100 messages of 1 conversation, the oldest first:

```json
{"id":5,"method":"sms.thread","params":{"device":"Pixel 8","thread":12}}
{"id":5,"result":{"messages":[{"id":881,"thread":12,"body":"On my way","address":"+15550100123","addresses":["+15550100123"],"name":"Kari","time":1790000000,"outgoing":true,"pending":false,"failed":false,"read":true}]}}
```

`name` is the contact name, or the address when the phone has no contact.
`pending` marks a sent message that is still on its way, and `failed` marks a sent message that the phone could not send.
A phone that does not answer in 8 seconds returns the `timeout` error.

`sms.send` sends a text message through the phone:

```json
{"id":6,"method":"sms.send","params":{"device":"Pixel 8","addresses":["+15550100123"],"body":"On my way"}}
{"id":6,"result":{}}
```

The result means that the request went to the phone.
The phone reports the sent message, and the conversation changes in a later state event.
Flux for Android sends a text message to 1 address. More addresses return the `unsupported` error.

### Outbox

fluxd adds each text message that `sms.send` sends to the `outbox` list of the device, the oldest first.
The window shows the entries in the thread, with **Sending…** or **Not sent** under each one.

```json
{"thread":12,"address":"+15550100123","body":"On my way","time":1790000000,"outgoing":true,"pending":true,"failed":false}
```

| Field | Value |
| --- | --- |
| `thread` | The thread of the newest conversation with only this address, or `-1` when no conversation has the address. |
| `address`, `body` | The address and the text of the message. |
| `time` | The Unix time of the send, from the clock of the computer. |
| `outgoing` | Always `true`, so that a client can show the entry as a message of `sms.thread`. |
| `pending`, `failed` | `pending` is `true` while fluxd waits for the phone. After 60 seconds without a report, `pending` changes to `false` and `failed` changes to `true`. |

fluxd removes an entry when the phone reports a sent message with the same text in the same thread.
For an entry with thread `-1`, the address of the message must match: a phone number matches on its last 8 digits.
A message from the phone that is more than 120 seconds older than the entry does not count, because the clocks of the 2 devices can differ.
A late report also removes a failed entry.

fluxd keeps at most 50 entries for each device. A new entry removes the oldest one.
An unpair removes all entries of the device.
A device that stops offering its text messages also loses its entries.
fluxd keeps the outbox only in memory, so a restart of fluxd also removes the entries.

## Extra addresses

`addresses.add` and `addresses.remove` change the extra addresses of a paired device.
`fluxd` dials these addresses while the device is offline, for example through [Tailscale](tailscale.md).

```json
{"id":4,"method":"addresses.add","params":{"device":"Pixel 8","address":"pixel-8"}}
{"id":4,"result":{"device":"Pixel 8","address":"pixel-8","addresses":["pixel-8"]}}
```

The result gives the address in its stored form and the new list.
Each device in the state has the same list in its `addresses` field.
An address with a port or a scheme returns the `bad_address` error.
A sixth address returns `too_many`.
An address that the device does not have returns `not_found` from `addresses.remove`.
