import QtQuick
import ".."

// A flat progress bar. value is between 0 and 1.
Rectangle {
  id: root
  property real value: 0
  property color fill: Theme.accent
  implicitHeight: 5
  color: Theme.bg3
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Math.max(0, Math.min(1, root.value)) * parent.width
    color: root.fill
  }
}
