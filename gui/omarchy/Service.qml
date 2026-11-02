import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "MotionColors.js" as MotionColors

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

  Backend {
    id: backend
    wantMotion: root.motionCues
  }

  // The motion cues overlay loads only while the setting is on.
  readonly property bool motionCues: backend.settings.motionCues === true

  // The bright foreground of colors.toml. Color has no such property.
  readonly property string brightForeground: {
    var m = /^\s*bright_foreground\s*=\s*["'](#[0-9a-fA-F]{6})["']/m.exec(themeText)
    return m ? m[1] : ""
  }
  readonly property var motionColors: MotionColors.pick(
    MotionColors.hexOf(Commons.Color.accent), MotionColors.hexOf(Commons.Color.foreground),
    brightForeground, MotionColors.hexOf(Commons.Color.background))

  LazyLoader {
    active: root.motionCues
    MotionCues {
      motion: backend.motion
      fill: root.motionColors.fill
    }
  }

  // The panel calls this when it opens. The theme switch replaces the file,
  // which can drop the file watch, so read the file again. A closed
  // connection to fluxd tries again at once.
  function panelOpened() {
    themeFile.reload()
    backend.retryNow()
  }

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
    target: Commons.Color
    function onAccentChanged() { themeFile.reload() }
    function onBackgroundChanged() { themeFile.reload() }
  }
}
