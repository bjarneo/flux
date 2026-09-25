import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The Flux service. It stays loaded, owns the connection to fluxd, and reads
// the active Omarchy theme. The bar widget and the panel get this object
// through the plugin's own service lookup.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property alias backend: backend
  // The text of the active colors.toml. FluxView reads it.
  property string themeText: ""

  readonly property string themePath: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml"

  Backend { id: backend }

  FileView {
    id: themeFile
    path: root.themePath
    watchChanges: true
    printErrors: false
    onLoaded: root.themeText = text()
    onLoadFailed: root.themeText = ""
    onFileChanged: reload()
  }

  // omarchy-shell applies a new theme to Color over IPC. Read the file again
  // at once, so Flux follows the theme at the same time as the bar.
  Connections {
    target: Color
    function onAccentChanged() { themeFile.reload() }
    function onBackgroundChanged() { themeFile.reload() }
  }

  // The theme switch replaces the file, which can drop the file watch.
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: themeFile.reload()
  }
}
