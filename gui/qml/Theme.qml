pragma Singleton
import QtQuick

// Color tokens of the Flux window. The host reads colors.toml of the active
// Omarchy theme and gives the text to FluxView, which calls load(). The
// defaults are the Tokyo Night values of the design.
QtObject {
  id: root

  property color bg: "#1a1b26"
  property color bg2: "#16161e"
  property color bg3: "#292e42"
  property color fg: "#c0caf5"
  property color dim: "#737aa2"
  property color accent: "#7aa2f7"
  property color ok: "#9ece6a"
  property color warn: "#e0af68"
  property color err: "#f7768e"
  property color alt: "#bb9af7"

  readonly property string font: "monospace"
  readonly property int size: 13

  property string lastText: ""

  // Returns a color between a and b. t = 0 gives a, t = 1 gives b.
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  readonly property var defaults: ({
    bg: "#1a1b26", bg2: "#16161e", bg3: "#292e42", fg: "#c0caf5", dim: "#737aa2",
    accent: "#7aa2f7", ok: "#9ece6a", warn: "#e0af68", err: "#f7768e", alt: "#bb9af7"
  })

  function reset() {
    for (var k in defaults) root[k] = defaults[k]
  }

  // Applies the text of a colors.toml file. An empty text gives the
  // Tokyo Night defaults.
  function load(text) {
    text = text || ""
    if (text === lastText) return
    lastText = text
    if (text === "") {
      reset()
      return
    }
    var v = {}
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/)
      if (m) v[m[1]] = m[2]
    }
    if (!v.background || !v.foreground) return
    var b = Qt.color(v.background)
    var f = Qt.color(v.foreground)
    var a = Qt.color(v.accent || v.blue || "#7aa2f7")
    bg = b
    fg = f
    bg2 = v.dark_background ? Qt.color(v.dark_background) : mix(b, Qt.rgba(0, 0, 0, 1), 0.2)
    bg3 = v.selection ? Qt.color(v.selection) : mix(b, f, 0.12)
    dim = mix(b, f, 0.6)
    accent = a
    ok = v.green ? Qt.color(v.green) : a
    warn = v.yellow ? Qt.color(v.yellow) : a
    err = v.red ? Qt.color(v.red) : a
    alt = v.magenta ? Qt.color(v.magenta) : a
  }
}
