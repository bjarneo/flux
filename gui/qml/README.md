# Flux window, shared QML

This directory is the Flux window in plain QtQuick. It has no Quickshell
imports, so 2 hosts use it without changes:

- The omarchy-shell plugin in `gui/omarchy/`.
- The Qt 6 C++ app in `gui/app/`.

A host creates `FluxView`, gives it a backend object, and gives it the text
of the active Omarchy `colors.toml`.

```qml
import "path/to/gui/qml"

FluxView {
  anchors.fill: parent
  backend: myBackend
  themeText: colorsTomlText
}
```

## FluxView

| Member | Type | Use |
| --- | --- | --- |
| `backend` | `var`, required | The backend object. The contract is below. |
| `themeText` | `string` | The content of `~/.local/state/omarchy/current/theme/colors.toml`. Set it again when the file changes. An empty string gives the Tokyo Night defaults. |
| `showPage(key)` | function, returns `bool` | Selects a screen: `overview`, `clipboard`, `files`, `notifications`, `media`, `messages`, `input`, `browse`, or `commands`. Returns `false` for an unknown key. |

## Backend contract

Every host implements these members.

| Member | Type | Use |
| --- | --- | --- |
| `connected` | `bool`, read-only | True while the host has an open connection to the fluxd socket. |
| `attempted` | `bool` | True after the first connection attempt ends. The window shows `fluxd is not running` only when this is true. |
| `state` | `var` | The last `state` event from fluxd. |
| `devices`, `clipboard`, `transfers`, `commands` | `var` | `state.devices`, `state.clipboard`, `state.transfers`, `state.commands`, or an empty list. |
| `settings`, `selfDevice` | `var` | `state.settings` and `state.self`, or an empty object. |
| `ringing` | `bool` | `state.ringing`. |
| `call(method, params, cb)` | function | Sends one IPC request. `cb(err, result)` runs once. `err` is `{code, message}` or `null`. |
| `pickFiles(title, cb)` | function | Runs `omarchy file select --title <title> --multiple`. `cb(paths)` gets the absolute paths from the newline-separated output, or an empty list when the user cancels or the chooser fails. |
| `startDaemon(cb)` | function | Runs `systemctl --user start fluxd`. `cb(ok, message)` runs when the command ends. |
| `toast(text)` | signal | A message from fluxd or the host. The window shows it for 2.2 seconds. |

The socket is `$XDG_RUNTIME_DIR/flux/fluxd.sock`, or `$FLUX_SOCKET` when it
is set. After the connection opens, the host calls `subscribe`. The IPC
protocol is in the Flux specification.

## Layout

- `qmldir` declares the `Theme` and `Fmt` singletons and `FluxView`.
- `components/` has the shared controls. `components/qmldir` lists them.
- `pages/` has 1 file per screen. `FluxView` loads them by URL.
- `tools/` has the snapshot harness, the mock backend, and the fixture.

## Snapshot harness

To render all 28 screens from the fixture into PNG files, run:

```
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_XHR_ALLOW_FILE_READ=1 \
  FLUX_SNAPSHOT=/tmp/flux-shots qml6 gui/qml/tools/Snapshot.qml
```

- `FLUX_SNAPSHOT_ONLY=<text>` renders only the screens with `<text>` in the name.
- `FLUX_THEME_FILE=<colors.toml>` renders with that theme.
- Arguments work too: `qml6 gui/qml/tools/Snapshot.qml -- <dir> [only] [theme=<colors.toml>]`.
- To see the progress lines, also set `QT_FORCE_STDERR_LOGGING=1`.
