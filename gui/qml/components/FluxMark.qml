import QtQuick
import ".."

// The Flux mark, variant 4a: an outline square over a filled square. The
// mark sits on an 8 by 8 grid, and size is the grid in pixels. Positions
// are rounded to whole pixels, so the edges stay sharp.
Item {
  id: root
  property real size: 26
  property color fg: Theme.fg
  property color accent: Theme.accent
  readonly property real u: size / 8

  width: size
  height: size

  Rectangle {
    x: Math.round(2.6 * root.u)
    y: x
    width: Math.round(4.9 * root.u)
    height: width
    color: root.accent
  }

  Rectangle {
    x: Math.round(0.5 * root.u)
    y: x
    width: Math.round(4.9 * root.u)
    height: width
    color: "transparent"
    border.width: Math.max(1, Math.round(0.75 * root.u))
    border.color: root.fg
  }
}
