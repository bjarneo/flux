.pragma library

// The colors of the motion cue dots. The dots float over any window, and
// most windows use the theme background, so the fill needs contrast with
// the theme background. The accent keeps the character of the theme, so it
// wins when it has a contrast of 3:1 or more (WCAG for graphics). Else the
// candidate with the most contrast wins. A dot is 1 flat color.

var minContrast = 3

// hex returns [r, g, b] from 0 to 1 for "#rrggbb" or "#aarrggbb", or null.
function rgb(hex) {
  var s = String(hex || "").trim()
  var m = /^#(?:[0-9a-f]{2})?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(s)
  if (!m) return null
  return [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255]
}

// luminance is the WCAG relative luminance of a color.
function luminance(c) {
  function lin(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])
}

// contrast is the WCAG contrast ratio of 2 "#rrggbb" colors, from 1 to 21.
// It is 0 when a color does not parse.
function contrast(a, b) {
  var ca = rgb(a), cb = rgb(b)
  if (!ca || !cb) return 0
  var la = luminance(ca), lb = luminance(cb)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

// pick returns {fill} for the theme colors. Each argument is a
// "#rrggbb" string; an empty or bad value is skipped.
function pick(accent, foreground, brightForeground, background) {
  var bg = rgb(background) ? background : "#000000"
  var fill = ""
  if (contrast(accent, bg) >= minContrast) {
    fill = accent
  } else {
    var best = 0
    var candidates = [accent, foreground, brightForeground]
    for (var i = 0; i < candidates.length; i++) {
      var c = contrast(candidates[i], bg)
      if (c > best) { best = c; fill = candidates[i] }
    }
  }
  if (fill === "") fill = luminance(rgb(bg)) > 0.5 ? "#000000" : "#ffffff"
  return { fill: String(fill) }
}

// hexOf returns "#rrggbb" for a color of QML, without its alpha.
function hexOf(color) {
  var s = String(color)
  return s.length === 9 ? "#" + s.slice(3) : s
}
