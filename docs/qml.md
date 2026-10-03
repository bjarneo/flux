# Flux window, shared QML

[Documentation index](README.md)

`gui/qml/` contains the Flux window in plain QtQuick. It has no Quickshell
imports, so 2 hosts use it without changes:

- The omarchy-shell plugin in `gui/omarchy/`.
- The Qt 6 C++ app in `gui/app/`.

The views need Qt 6.6 or later, because they use
`GridLayout.uniformCellWidths` and `Shape.CurveRenderer`.

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
| `showPage(key)` | function, returns `bool` | Selects a screen: `overview`, `clipboard`, `files`, `notifications`, `messages`, or `commands`. Returns `false` for an unknown key. |
| `appReplaced` | `bool` | The host sets it when an update replaced the host program. The window then shows **Flux was updated** with a **Restart** button. The shell plugin does not set it, because omarchy-shell reloads the plugin. |
| `restartApp()` | signal | The user selected **Restart**. The host starts its new program and quits. |

## Layouts

The window follows its width:

| Width | Layout |
| --- | --- |
| 1000 px and more | The full sidebar of 260 px |
| 680 to 999 px | A rail of 64 px, with 1 icon for each device and each tab |
| Less than 680 px | No sidebar. The header has a menu button. |

The rail and the narrow layout open the full sidebar as a drawer over the
content. A new pair request opens the drawer 1 time. Below 760 px of content,
the header buttons show only their icons. Messages shows 1 pane below
620 px. The smallest window is 360 × 480 px.

To render every screen at another size, add `size=<width>x<height>`:

```sh
mkdir -p /tmp/shots
QT_QPA_PLATFORM=offscreen gui/app/build/flux-gui --snapshot /tmp/shots "" size=480x820
```

## Icons

`components/Icon.qml` draws Material Design glyphs from the Nerd Font in
the `monospace` font, the same icons as the Omarchy shell. An icon takes
its color like text:

```qml
Icon { name: "phone"; size: 18; color: Theme.accent }
```

To add an icon, add its name and codepoint to `icons` in `Fmt.qml`. The
codepoints are in the Nerd Fonts `glyphnames.json`, under the `md-` names.
The package depends on `ttf-font-nerd`, which every Nerd Font provides.

## Colors

`Theme.qml` turns the text of `colors.toml` into color tokens.
A contrast guard checks each token against the colors that it sits on, with the rules of [Flux for Android](android.md#theme).
The guard moves only the lightness of a color, toward `fg` first, so the hue of the theme stays.
A color that meets its needs stays as it is.

| Token | Use | Contrast |
| --- | --- | --- |
| `bg`, `bg2`, `bg3` | The page, a card or the sidebar, and a raised surface or the border of a card. | The theme values without a change. |
| `fg` | Body text. | 4.5:1 on `bg`, `bg2`, and `bg3`. 1.4:1 on `dim`. |
| `dim` | Secondary text and icons. | 4.5:1 on `bg` and `bg2`. 3:1 on `bg3`. |
| `accent`, `ok`, `warn`, `err`, `alt` | Actions and states, as text and as icons. | 4.5:1 on `bg` and `bg2`. 3:1 on a fill with 18% of the color. `accent` also reaches 4.5:1 on its selection fill. |
| `edge` | The border of a field, a button, a chip, a switch, and a dashed button. | 3:1 on `bg` and `bg2`. |

Use `edge` for the border of a control, and `bg3` for the border of a card.
To check a change in a stock theme, render the screens in that theme:

```sh
mkdir -p /tmp/shots
QT_QPA_PLATFORM=offscreen gui/app/build/flux-gui --snapshot /tmp/shots "" theme=/usr/share/omarchy/themes/rose-pine/colors.toml
```

## Backend contract

Every host implements these members.

| Member | Type | Use |
| --- | --- | --- |
| `connected` | `bool`, read-only | True while the host has an open connection to the fluxd socket. |
| `attempted` | `bool` | True after the first connection attempt ends. The window shows `fluxd is not running` only when this is true. |
| `state` | `var` | The last `state` event from fluxd. |
| `devices`, `clipboard`, `transfers`, `commands` | `var` | `state.devices`, `state.clipboard`, `state.transfers`, `state.commands`, or an empty list. |
| `settings`, `selfDevice` | `var` | `state.settings` and `state.self`, or an empty object. |
| `call(method, params, cb)` | function | Sends one IPC request. `cb(err, result)` runs once. `err` is `{code, message}` or `null`. When the connection closes, each waiting `cb` gets the error `{code: "offline", message: "fluxd is not running"}`. |
| `pickFiles(title, cb)` | function | Runs `omarchy file select --title <title> --multiple`. `cb(paths)` gets the absolute paths from the output, or an empty list when the user cancels or the chooser fails. The host does not trim the lines. A line that does not start with `/` continues the path before it, because a file name can contain a newline. |
| `startDaemon(cb)` | function | Removes the `flux-cli off` marker `~/.config/flux/off`, then runs `systemctl --user start fluxd`. This is the same as `flux-cli on`. `cb(ok, message)` runs when the command ends. |
| `toast(text)` | signal | A message from fluxd or the host. The window shows it for 2.2 seconds. |

The host finds the socket in the same place as fluxd and flux-cli:

1. `$FLUX_SOCKET`, when it is set.
2. `$XDG_RUNTIME_DIR/flux/fluxd.sock`, when `XDG_RUNTIME_DIR` is set.
3. `/run/user/<uid>/flux/fluxd.sock`.

There is no `/tmp` fallback, because another user can make a folder there
first. The Qt app also refuses a socket whose process runs as another user.
After the connection opens, the host calls `subscribe`. The IPC protocol is
in the [IPC guide](ipc.md).

The host drops a line from fluxd that is longer than 32 MiB and keeps the
connection open. A normal state event is much smaller.

While the connection is down, the host tries to connect again. The wait
starts at 2 seconds and doubles after each failed attempt, up to 60 seconds.
The host tries at once when the window opens and after `startDaemon`.

## Lists

A `Repeater` with a JavaScript array builds every delegate again when 1
field of 1 element changes. Every state event from fluxd gives new arrays.
For a list that changes often, use `KeyedModel` from `components/`. It
inserts, moves, and removes only the rows that changed, so the other
delegates keep their state, such as the text in a field.

```qml
KeyedModel { id: rows; values: root.transfers }

Repeater {
  model: rows
  delegate: Card {
    required property string key
    readonly property var modelData: rows.byId[key] || ({})
  }
}
```

Each row holds only the key. `keyField` names the key, and the default is
`id`. The delegate reads the object from `byId`. `byId` has no prototype, so
a key from a phone such as `__proto__` is an ordinary key. A new `scope`
removes all rows first. Set it to the device ID when the rows keep state
that belongs to 1 device, such as a reply that the user types:

```qml
KeyedModel { id: rows; values: root.notifs; scope: root.dev ? root.dev.id : "" }
```

## Text from a phone

`Txt` shows plain text, so a name from a phone cannot add markup. A
`ToolTip` detects rich text, so give it a plain `Text` as its
`contentItem`. For a file name or a device name from a phone, use
`Fmt.showControls(name)`. It shows each control character and bidi control
as its code, so `invoice\u202Efdp.exe` shows as `invoice[U+202E]fdp.exe`, not
as `invoiceexe.pdf`.

A pair key and a certificate fingerprint show in groups of 4 digits, for
example `5EE6 825F 974E D59A`. Use `Fmt.hexGroups(key)`.

## Pair requests

The sidebar shows 1 pair request card, for the oldest open request. The card
shows the address of the device and the key on its own line, in 4 groups of
4 digits. A line under the card gives the number of the other requests. Each new request
opens the drawer and scrolls the sidebar to the top 1 time. A request that
comes again does not.

**Accept** works only after the card has shown the same request, at the same
place, for 1 second. A new key or a move of the card starts the wait again.

In pair mode, each device on the network shows its name, its address, and
the fingerprint of its certificate. A row with the name of another device
has a warning line. After the pairing, the Overview of the device shows the
same fingerprint under **certificate**.

## Layout

- `qmldir` declares the `Theme` and `Fmt` singletons and `FluxView`.
- `components/` has the shared controls. `components/qmldir` lists them.
- `pages/` has 1 file per screen. `FluxView` loads them by URL.
- `tools/` has the snapshot harness, the mock backend, and the fixture.
- `../tests/` has the view tests.

## Snapshot harness

To render every fixture screen into PNG files from the repository root, run:

```sh
mkdir -p /tmp/flux-shots
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_XHR_ALLOW_FILE_READ=1 \
  FLUX_SNAPSHOT=/tmp/flux-shots qml6 gui/qml/tools/Snapshot.qml
```

- `FLUX_SNAPSHOT_ONLY=<text>` renders only the screens with `<text>` in the name.
- `FLUX_THEME_FILE=<colors.toml>` renders with that theme.
- Arguments work too: `qml6 gui/qml/tools/Snapshot.qml -- <dir> [only] [theme=<colors.toml>]`.
- To see the progress lines, also set `QT_FORCE_STDERR_LOGGING=1`.

## View tests

`gui/tests/tst_views.qml` checks the views with the mock backend. It covers
the device switch in Messages, the outbox of sent messages, the pair
requests, the key format, the errors from fluxd, the list limits, the text
from a phone, the contrast rules of the theme, and the **Start** buttons of
the camera and the mic. To run the tests from the repository root:

```sh
make test-gui
```

The target runs this command:

```sh
QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 \
  /usr/lib/qt6/bin/qmltestrunner -input gui/tests
```

To use a `qmltestrunner` in another folder, set `QMLTESTRUNNER`:

```sh
make test-gui QMLTESTRUNNER=/usr/lib64/qt6/bin/qmltestrunner
```

## Qt app

`flux-gui` keeps 1 window for each user. The first `flux-gui` takes a lock on
`gui.lock` and listens on `gui.sock`. Both files are in
`$XDG_RUNTIME_DIR/flux`, or in `/run/user/<uid>/flux`. A later `flux-gui`
sends its page to that socket and exits. Only the holder of the lock listens,
so 2 `flux-gui` that start at the same time open 1 window. A `flux-gui` from
before the lock listens without it. The holder of the lock first sends its
page to `gui.sock`, and exits when such an instance answers. The folder must
belong to the user. `flux-gui` sets its mode to `0700`.

After an update, **Restart** starts the new `flux-gui` first. The old window
keeps its lock and its socket until the new process runs. When the start
fails, the old window stays open and keeps its socket.
