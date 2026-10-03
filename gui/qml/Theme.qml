pragma Singleton
import QtQuick

// Color tokens of the Flux window. The host reads colors.toml of the active
// Omarchy theme and gives the text to FluxView, which calls load(). The
// defaults are the Tokyo Night values of the design. When the object is
// complete, reset() runs them through the contrast guard.
//
// The tokens come from the theme through a contrast guard, with the rules
// of paletteOf in Flux for Android:
// - fg reaches 4.5:1 on bg, bg2, and bg3, and 1.4:1 on dim.
// - dim reaches 4.5:1 on bg and bg2, and 3:1 on bg3. It is the second ink.
// - accent, ok, warn, err, and alt reach 4.5:1 on bg and bg2, and 3:1 on
//   a fill with 18% of their own color. accent also reaches 4.5:1 on its
//   selection fill, which has 18% of the accent on bg2.
// - edge reaches 3:1 on bg and bg2. It is the border of a control.
// The guard moves only the lightness of a color, toward fg first, so the
// hue of the theme stays. A color that meets its needs stays as it is.
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
  // The border of a field, a button, a chip, a switch, and a dashed
  // button. bg3 is a surface and the border of a card.
  property color edge: "#292e42"

  readonly property string font: "monospace"
  readonly property int size: 13

  property string lastText: ""

  // The contrast that text needs, WCAG 2.2 AA.
  readonly property real textContrast: 4.5
  // The contrast that icons and the borders of controls need.
  readonly property real nonTextContrast: 3
  // The least contrast of fg against dim, so that the 2 inks look different.
  readonly property real textStep: 1.4

  // Returns a color between a and b. t = 0 gives a, t = 1 gives b.
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  readonly property var defaults: ({
    bg: "#1a1b26", bg2: "#16161e", bg3: "#292e42", fg: "#c0caf5", dim: "#737aa2",
    accent: "#7aa2f7", ok: "#9ece6a", warn: "#e0af68", err: "#f7768e", alt: "#bb9af7"
  })

  Component.onCompleted: reset()

  function reset() {
    var t = {}
    for (var k in defaults) t[k] = Qt.color(defaults[k])
    apply(t)
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
    apply({
      bg: b,
      fg: f,
      bg2: v.dark_background ? Qt.color(v.dark_background) : mix(b, Qt.rgba(0, 0, 0, 1), 0.2),
      bg3: v.selection ? Qt.color(v.selection) : mix(b, f, 0.12),
      accent: a,
      ok: v.green ? Qt.color(v.green) : a,
      warn: v.yellow ? Qt.color(v.yellow) : a,
      err: v.red ? Qt.color(v.red) : a,
      alt: v.magenta ? Qt.color(v.magenta) : a
    })
  }

  // Sets the tokens from the colors of a theme, through the contrast
  // guard. t has bg, bg2, bg3, fg, accent, ok, warn, err, and alt. Without
  // t.dim, dim is 60% of the way from bg to fg.
  function apply(t) {
    // Below this luminance of bg, the theme is dark, and the guard tries a
    // lighter color first.
    var dark = luminance(t.bg) < 0.179
    var ink = needs(textContrast, [t.bg, t.bg2, t.bg3])
    var first = guard(t.fg, ink, dark)
    var d = guard(t.dim !== undefined ? t.dim : mix(t.bg, first, 0.6), needs(textContrast, [t.bg, t.bg2]).concat(needs(nonTextContrast, [t.bg3])), dark)
    var f = guard(first, ink.concat(needs(textStep, [d])), dark)
    bg = t.bg
    bg2 = t.bg2
    bg3 = t.bg3
    fg = f
    dim = d
    accent = fill(t.accent, t, dark, true)
    ok = fill(t.ok, t, dark, false)
    warn = fill(t.warn, t, dark, false)
    err = fill(t.err, t, dark, false)
    alt = fill(t.alt, t, dark, false)
    edge = guard(t.bg3, needs(nonTextContrast, [t.bg, t.bg2]), dark)
  }

  // Guards a color for text and icons. The fills with 18% of the color
  // change with the color, so the guard runs again on its result until the
  // color stays the same.
  function fill(c, t, dark, selection) {
    var x = c
    for (var i = 0; i < 10; i++) {
      var tint = mix(t.bg2, x, 0.18)
      var n = needs(textContrast, [t.bg, t.bg2]).concat(needs(nonTextContrast, [tint, mix(t.bg, x, 0.16)]))
      if (selection) n = n.concat(needs(textContrast, [tint]))
      var next = guard(x, n, dark)
      if (Qt.colorEqual(next, x)) break
      x = next
    }
    return x
  }

  // The color math of the guard, as ColorMath.kt in Flux for Android. A
  // color in these functions is a list of 3 sRGB channels from 0 to 255.

  function needs(ratio, colors) {
    return colors.map(function (c) { return { against: c, ratio: ratio } })
  }

  function channels(c) {
    if (typeof c === "string") c = Qt.color(c)
    return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255)]
  }

  // Decodes 1 sRGB channel to linear light.
  function linear(c) {
    var v = c / 255
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
  }

  // Encodes linear light to 1 sRGB channel.
  function encode(v) {
    var c = Math.min(1, Math.max(0, v))
    var s = c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055
    return Math.min(255, Math.max(0, Math.round(s * 255)))
  }

  function lum(v) {
    return 0.2126 * linear(v[0]) + 0.7152 * linear(v[1]) + 0.0722 * linear(v[2])
  }

  function ratio(la, lb) {
    return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05)
  }

  // The relative luminance of WCAG 2.2, from 0 for black to 1 for white.
  function luminance(c) { return lum(channels(c)) }

  // The contrast ratio of WCAG 2.2, from 1 to 21.
  function contrast(a, b) { return ratio(luminance(a), luminance(b)) }

  // Converts a color to OKLCH: the lightness l from 0 to 1, the chroma c,
  // and the hue h in radians.
  function oklch(v) {
    var r = linear(v[0])
    var g = linear(v[1])
    var b = linear(v[2])
    var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    var la = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    var a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    var bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return { l: la, c: Math.sqrt(a * a + bb * bb), h: Math.atan2(bb, a) }
  }

  // Converts OKLAB to linear sRGB. The values can be outside 0 to 1.
  function linearRgb(l, a, b) {
    var l3 = Math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    var m3 = Math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    var s3 = Math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
    return [
      4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
      -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
      -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
    ]
  }

  function inGamut(v) {
    for (var i = 0; i < 3; i++) if (v[i] < -1e-4 || v[i] > 1 + 1e-4) return false
    return true
  }

  // Converts OKLCH to a color. A color outside sRGB loses chroma until it
  // fits. The lightness and the hue stay.
  function fromOklch(l, c, h) {
    var at = function (chroma) { return linearRgb(l, chroma * Math.cos(h), chroma * Math.sin(h)) }
    var v = at(c)
    if (!inGamut(v)) {
      var lo = 0
      var hi = c
      for (var i = 0; i < 24; i++) {
        var mid = (lo + hi) / 2
        if (inGamut(at(mid))) lo = mid
        else hi = mid
      }
      v = at(lo)
    }
    return [encode(v[0]), encode(v[1]), encode(v[2])]
  }

  // The contrast guard. It moves the lightness of c until c meets each of
  // the needs, a list of {against, ratio}, and it keeps the hue. It takes
  // the smallest move, and it tries the lighter side first when lighter is
  // true. A color that meets the needs stays as it is. When no lightness
  // meets every need, the guard returns the color that comes closest.
  function guard(c, list, lighter) {
    var start = channels(c)
    var lums = list.map(function (n) { return luminance(n.against) })
    var score = function (v) {
      var lv = lum(v)
      var s = Infinity
      for (var i = 0; i < list.length; i++) s = Math.min(s, ratio(lv, lums[i]) / list[i].ratio)
      return s
    }
    var bestScore = score(start)
    if (bestScore >= 1) return typeof c === "string" ? Qt.color(c) : c
    var best = start
    var o = oklch(start)
    var sides = lighter ? [1, -1] : [-1, 1]
    var step = 0.002
    for (var k = 1; k <= 1 / step + 1; k++) {
      var any = false
      for (var j = 0; j < 2; j++) {
        var l = o.l + sides[j] * k * step
        if (l < 0 || l > 1) continue
        any = true
        var x = fromOklch(l, o.c, o.h)
        var s = score(x)
        if (s >= 1) return Qt.rgba(x[0] / 255, x[1] / 255, x[2] / 255, 1)
        if (s > bestScore) {
          best = x
          bestScore = s
        }
      }
      if (!any) break
    }
    return Qt.rgba(best[0] / 255, best[1] / 255, best[2] / 255, 1)
  }
}
