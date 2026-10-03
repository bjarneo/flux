# Flux plugin for omarchy-shell

[Documentation index](README.md)

This plugin runs the Flux window inside `omarchy-shell`. It has 3 kinds:

| Kind | Entry point | Job |
| --- | --- | --- |
| `service` | `Service.qml` | Stays loaded. Owns the fluxd connection (`Backend.qml`) and reads the active `colors.toml`. |
| `bar-widget` | `BarWidget.qml` | The Flux mark. The mark has the accent color while a paired device is connected. The tooltip lists every paired device. A left click opens or closes the window. |
| `panel` | `Panel.qml` | The Flux window, a `FloatingWindow` titled `Flux`, 1180 × 760, minimum 900 × 640. |

The plugin ID is `flux`.

## Open the window

To open the window on a screen, run:

```
omarchy-shell shell summon flux '{"page":"files"}'
```

The payload is optional. `page` is one of `overview`, `clipboard`, `files`,
`notifications`, `messages`, or `commands`.
To open or close the window, use `omarchy-shell shell toggle flux '{}'`.

The panel loads the Flux view when the window opens and unloads it when the
window closes. The service keeps its connection to fluxd while the window is
closed. It reads each state event for the bar widget. A closed window builds
no views, and its pages send no requests to the phone. The next open shows
the last tab and device.
Each open also reads `colors.toml` again. When fluxd is down, each open
connects at once.

## Install layout

omarchy-shell finds third-party plugins only in
`~/.config/omarchy/plugins/<id>/`. Install the plugin in this layout:

```
~/.config/omarchy/plugins/flux/
  manifest.json
  Service.qml
  Backend.qml
  BarWidget.qml
  Panel.qml
  Flux/            a copy of gui/qml
    qmldir
    FluxView.qml
    Theme.qml
    Fmt.qml
    components/
    pages/
```

In this checkout, `Flux` is a symlink to `../qml`. An install copies
`gui/qml` to `<plugin dir>/Flux`, because `omarchy plugin validate` rejects a
symlink inside a plugin folder, and `omarchy plugin add` and
`omarchy plugin update` run that check. The `gui/qml/tools` and
`gui/omarchy/tools` directories are for tests. Leave them out of the install.

At run time, the registry follows symlinks. A plugin directory that is a
symlink to this checkout loads, and so does the `Flux` symlink inside it. Use
this only for development. The file watcher that reloads a changed plugin
does not follow a symlinked directory, so after an edit run
`omarchy-shell shell rescanPlugins`.

After the install, run these commands:

```
omarchy-shell shell rescanPlugins
omarchy plugin enable flux --section right
```

## Updates

`fluxd` keeps an added plugin at the version of its own install.
At each start, it compares `~/.config/omarchy/plugins/flux` with `PREFIX/share/flux/omarchy-plugin` beside its binary.
It writes only the changed files, removes the files that its earlier copy wrote and that the new version does not have, and runs `omarchy-shell shell rescanPlugins`.
The list of the copied files is in `.flux-files` in the plugin folder.
It keeps the files that you added.
It does not add a plugin that you removed.
It does not change a symlink to a checkout, or a plugin folder that holds a symlink, such as a `Flux` link to a checkout.
The journal of `fluxd` then says that it did not update the plugin.

## Offscreen test

`gui/omarchy/tools/test-offscreen.sh` starts a separate omarchy-shell with this plugin.
It does not touch the running shell, `~/.config/omarchy`, or the session bus.

```
gui/omarchy/tools/test-offscreen.sh /tmp/flux-shell copy "$XDG_RUNTIME_DIR/flux/fluxd.sock"
qs ipc --pid "$(pgrep -f '^qs -p /tmp/flux-shell/omarchy/shell')" call shell summon flux '{"page":"files"}'
qs ipc --pid "$(pgrep -f '^qs -p /tmp/flux-shell/omarchy/shell')" call shell call flux snapshot overview:/tmp/flux-shell/panel.png
```

- `copy` installs the plugin with the test wrappers in `tools/`. The bar widget
  then saves `bar-widget-N.png` in `/tmp/flux-shell/shots` every 3 seconds.
- `link` installs the plugin as a symlink to this checkout, unchanged.
- `qs ipc` finds the test shell only by `--pid` or `--id`, because the test
  shell has no display.
- With `copy`, `call shell call flux probe <method>` calls a fluxd method.
  Each run of its callback writes `flux test: probe <method> <result>` to
  `shell.log`. A call that waits when fluxd stops gets `offline` 1 time.
- To stop the test shell, run `pkill -f '^qs -p /tmp/flux-shell/omarchy/shell'`.

## Select the desktop host

`flux-cli open` uses the enabled shell plugin when the Omarchy shell runs.
Otherwise it starts the standalone Qt app.
To select a host explicitly:

```sh
FLUX_GUI=app flux-cli open files
FLUX_GUI=plugin flux-cli open notifications
```

The `gui` key in `config.toml` accepts the same values.
Both hosts use the [shared QML views](qml.md).

## Theme and desktop integration

The desktop reads `~/.local/state/omarchy/current/theme/colors.toml` and follows theme changes.
Flux for Android, Flux for iOS, and Flux for macOS follow the active Omarchy theme of the computer, light or dark, through the [theme packet](#theme-packet).
For the contrast guard and the fallback, see the theme of [Flux for Android](android.md#theme), [Flux for iOS](ios.md#theme), and [Flux for macOS](macos.md#theme).
The Flux window uses the same contrast rules. See [colors](qml.md#colors).

`dist/hyprland.lua` supplies floating-window rules and the `SUPER + ALT + P` shortcut for `flux-cli open`.
`dist/omarchy-menu.jsonc` supplies a Flux item for the Trigger menu.
Merge the menu item into `~/.config/omarchy/extensions/omarchy-menu.jsonc` to enable it.
The package does not merge these examples into your desktop configuration.

### Theme packet

`fluxd` sends the active Omarchy theme to a device in a `flux.theme` packet.
Only a paired device that lists `flux.theme` in its incoming types gets the packet.
Flux for iOS and Flux for macOS list `flux.theme` from the version that adds `ThemePlugin` to FluxKit.
`fluxd` sends it at these times:

- When a paired device connects, and when a pairing completes.
- When the theme changes. `fluxd` watches the theme folder and its parent folder, and reads the file 500 ms after the last change. A poll every 30 seconds finds a change that the watch misses.
- When the device sends a new identity that adds `flux.theme` to its incoming types.

When `colors.toml` is missing or does not parse, `fluxd` sends nothing.
The device then keeps the last theme that it got, or its default theme.
A headless `fluxd` sends no theme.

The body of the packet:

```json
{
  "name": "synthwave-aether-studio-2",
  "mode": "dark",
  "colors": {
    "accent": "#d563fe",
    "background": "#0c031f",
    "foreground": "#e8e6ef",
    "muted": "#665a8c",
    "red": "#fe288f"
  },
  "border": {"colors": ["#21e4f8ee", "#d563feee"], "angle": 45}
}
```

| Field | Value |
| --- | --- |
| `name` | The first line of `~/.local/state/omarchy/current/theme.name`, such as `tokyo-night`. It is an empty string when the file is missing. |
| `mode` | `dark` or `light`, from `mode` in `colors.toml`. Without a valid `mode`, the theme is `light` when `background` has a higher luminance than `foreground`. |
| `colors` | Each color key that `colors.toml` sets to a `#rrggbb` value, in lowercase. `background` and `foreground` are always present. |
| `border` | The Hyprland active border from `hyprland_active_border`: 1 to 10 colors as `#rrggbbaa`, and the angle of the gradient in degrees, from 0 to less than 360. The angle is 0 when the value has none. |

`fluxd` reads these color keys:

- `accent`, `selection`, `muted`, and `cursor`.
- `background`, `dark_background`, `darker_background`, and `lighter_background`.
- `foreground`, `dark_foreground`, `light_foreground`, and `bright_foreground`.
- `selection_foreground` and `selection_background`.
- `red`, `yellow`, `orange`, `green`, `cyan`, `blue`, `magenta`, and `brown`.
- `bright_red`, `bright_yellow`, `bright_green`, `bright_cyan`, `bright_blue`, and `bright_magenta`.
- `color0` to `color15`. A theme that Omarchy made from an Alacritty file has these keys.

`colors.toml` must have a `#rrggbb` color in `background` and in `foreground`.
`fluxd` drops each other color that is not a `#rrggbb` color.
When `colors.toml` is not valid TOML, `fluxd` reads it line by line, as `omarchy-theme-color` does.
In this case, the last value of a key wins, and a value can be without quotes.
The `border` field is missing when the file has no `hyprland_active_border`, or when a part of the value does not parse.
Then a device starts the border with `accent`.
Omarchy draws a solid `accent` border in Hyprland when the file has no `hyprland_active_border`.
The Flux apps draw a gradient from `accent` to `cyan`.
A part of the border value can be `rgba(rrggbbaa)`, `rgb(rrggbb)`, `#rrggbb`, `#rrggbbaa`, `0xaarrggbb`, `rgba(r,g,b,a)`, or the name of a color in `colors`, such as `accent`.

A theme can have colors with low contrast.
Before a device shows text in a theme color, it must check the contrast and change the color when the check fails.
