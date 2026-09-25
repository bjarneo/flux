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
| `showPage(key)` | function, returns `bool` | Selects a screen: `overview`, `clipboard`, `files`, `notifications`, `media`, `messages`, `browse`, or `commands`. Returns `false` for an unknown key. |

## Layouts

The window follows its width:

| Width | Layout |
| --- | --- |
| 1000 px and more | The full sidebar of 260 px |
| 680 to 999 px | A rail of 64 px, with 1 icon for each device and each tab |
| Less than 680 px | No sidebar. The header has a menu button. |

The rail and the narrow layout open the full sidebar as a drawer over the
content. A pair request opens the drawer by itself. Below 760 px of content,
the header buttons show only their icons. Messages shows 1 pane below
620 px. The smallest window is 360 × 480 px.

To render every screen at another size, add `size=<width>x<height>`:

```sh
QT_QPA_PLATFORM=offscreen gui/app/build/flux-gui --snapshot /tmp/shots "" size=480x820
```

## Icons

`components/Icon.qml` draws Material Design glyphs from the Nerd Font in
the `monospace` font, the same icons as the Omarchy shell. An icon takes
its color like text:

```qml
Icon { name: "phone"; size: 18; color: Theme.accent }
```

To add an icon, add its name and codepoint to `codes` in `Icon.qml`. The
codepoints are in the Nerd Fonts `glyphnames.json`, under the `md-` names.
The package depends on `ttf-font-nerd`, which every Nerd Font provides.

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
