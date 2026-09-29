# Local IPC

[Documentation index](README.md)

The CLI and desktop hosts use JSON lines over a Unix socket.
The default socket is `$XDG_RUNTIME_DIR/flux/fluxd.sock`.
`FLUX_SOCKET` overrides the path.
The daemon creates the socket with mode `0600`.

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
The Go types live in `internal/ipc/ipc.go`.
Method names and parameter handling live in `internal/core/api.go`.

## State and events

Call `state` for a snapshot.
The snapshot includes `self`, `devices`, `clipboard`, `transfers`, `commands`, `settings`, `webcam`, `mic`, `screen`, `desktop`, and `herdr`.

`self` describes this computer:

| Field | Value |
| --- | --- |
| `id`, `name`, `type` | The device ID, the name, and the device type that fluxd announces. |
| `tcpPort` | The TCP port of fluxd. |
| `version` | The build version of the running fluxd. An earlier fluxd has no `version`. |
| `pendingVersion` | The version of a new fluxd binary on disk, or an empty string. `fluxd.service` restarts into it when no transfer or stream runs. |

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
A client that reads slowly gets only the newest `state` event.
A client that reads nothing for 5 seconds loses its connection.

For shell scripts, use the CLI wrappers:

```sh
flux-cli status --json
flux-cli watch
```

## Method groups

| Group | Examples |
| --- | --- |
| State | `state`, `subscribe`, `discover` |
| Pairing | `pair.request`, `pair.accept`, `pair.reject`, `pair.unpair` |
| Addresses | `addresses.add`, `addresses.remove` |
| Sharing | `clipboard.send`, `share.files`, `share.url` |
| Commands | `commands.add`, `commands.remove`, `commands.run` |
| Notifications | `notification.dismiss`, `notification.dismissAll`, `notification.reply` |
| Text messages | `sms.refresh`, `sms.thread`, `sms.send` |
| Streams | `webcam.config`, `webcam.stop`, `mic.stop`, `screen.stop`, `desktop.stop` |
| Approval | `approve.request`, `approve.wait`, `approve.enroll` |
| Settings and updates | `settings.set`, `update.install` |

`update.install` opens a terminal that runs `flux-cli update`.
To turn the release check off or on over IPC, send:

```json
{"id":4,"method":"settings.set","params":{"key":"checkUpdates","value":false}}
```

Read the handler before you add a client call.
The approval helper applies additional peer and signature checks beyond this general socket protocol.

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
