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
The snapshot includes `self`, `devices`, `clipboard`, `transfers`, `commands`, `settings`, `webcam`, `mic`, `screen`, and `herdr`.

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
| Media | `media.action` |
| Text messages | `sms.refresh`, `sms.thread`, `sms.send` |
| Streams | `webcam.config`, `webcam.stop`, `mic.stop`, `screen.stop` |
| Approval | `approve.request`, `approve.wait`, `approve.enroll` |

Read the handler before you add a client call.
The approval helper applies additional peer and signature checks beyond this general socket protocol.

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
