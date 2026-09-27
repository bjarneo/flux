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
flux status --json
flux watch
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
| Streams | `webcam.config`, `webcam.stop`, `mic.stop`, `screen.stop` |
| Approval | `approve.request`, `approve.wait`, `approve.enroll` |

Read the handler before you add a client call.
The approval helper applies additional peer and signature checks beyond this general socket protocol.

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
