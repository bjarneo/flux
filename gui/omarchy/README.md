# Flux plugin for omarchy-shell

This plugin runs the Flux window inside `omarchy-shell`. It has 3 kinds:

| Kind | Entry point | Job |
| --- | --- | --- |
| `service` | `Service.qml` | Stays loaded. Owns the fluxd connection (`Backend.qml`) and reads the active `colors.toml`. |
| `bar-widget` | `BarWidget.qml` | The Flux mark and the first connected device with its battery, for example `Pixel 8 78%`. The tooltip lists every paired device. A left click opens or closes the window. |
| `panel` | `Panel.qml` | The Flux window, a `FloatingWindow` titled `Flux`, 1180 × 760, minimum 900 × 640. |

The plugin ID is `flux`.

## Open the window

To open the window on a screen, run:

```
omarchy-shell shell summon flux '{"page":"files"}'
```

The payload is optional. `page` is one of `overview`, `clipboard`, `files`,
`notifications`, `media`, `messages`, `input`, `browse`, or `commands`.
To open or close the window, use `omarchy-shell shell toggle flux '{}'`.

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

## Offscreen test

`tools/test-offscreen.sh` starts a separate omarchy-shell with this plugin.
It does not touch the running shell, `~/.config/omarchy`, or the session bus.

```
tools/test-offscreen.sh /tmp/flux-shell copy "$XDG_RUNTIME_DIR/flux/fluxd.sock"
qs ipc --pid "$(pgrep -f '^qs -p /tmp/flux-shell/omarchy/shell')" call shell summon flux '{"page":"files"}'
qs ipc --pid "$(pgrep -f '^qs -p /tmp/flux-shell/omarchy/shell')" call shell call flux snapshot overview:/tmp/flux-shell/panel.png
```

- `copy` installs the plugin with the test wrappers in `tools/`. The bar widget
  then saves `bar-widget-N.png` in `/tmp/flux-shell/shots` every 3 seconds.
- `link` installs the plugin as a symlink to this checkout, unchanged.
- `qs ipc` finds the test shell only by `--pid` or `--id`, because the test
  shell has no display.
- To stop the test shell, run `pkill -f "qs -p /tmp/flux-shell/omarchy/shell"`.
