import QtQuick
import ".."

// The Flux mark, Φ phi: a square ring with an accent bar through it. The
// mark sits on a 16 by 16 grid, and size is the grid in pixels. The ring is
// 10 units with a 2 unit stroke, at 3 units. The bar is 2 by 14 units, at
// 7 and 1 units. Each edge is rounded to a whole pixel, so the edges stay
// sharp and the bar stays centered in the ring.
Item {
  id: root
  property real size: 26
  property color fg: Theme.fg
  property color accent: Theme.accent
  readonly property real u: size / 16

  function at(units) { return Math.round(units * root.u) }

  width: size
  height: size

  Rectangle {
    x: root.at(3)
    y: root.at(3)
    width: root.at(13) - root.at(3)
    height: width
    color: "transparent"
    border.width: Math.max(1, root.at(5) - root.at(3))
    border.color: root.fg
  }

  Rectangle {
    x: root.at(7)
    y: root.at(1)
    width: Math.max(1, root.at(9) - root.at(7))
    height: root.at(15) - root.at(1)
    color: root.accent
  }
}
