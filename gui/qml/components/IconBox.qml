import QtQuick
import ".."

// A square with a centered icon, for art placeholders, file tiles, and
// app icons.
Rectangle {
  id: root
  property string icon: ""
  property int iconSize: Math.round(Math.min(width, height) * 0.45)
  property color fg: Theme.dim
  color: Theme.bg3

  Icon {
    anchors.centerIn: parent
    name: root.icon
    size: root.iconSize
    color: root.fg
  }
}
