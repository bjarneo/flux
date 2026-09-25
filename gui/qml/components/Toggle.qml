import QtQuick
import ".."

// An on and off switch with a label. The knob is square, like the rest of
// the window.
Item {
  id: root
  property string text: ""
  property bool checked: false
  property bool active: true
  signal toggled(bool checked)

  implicitWidth: box.width + 10 + label.implicitWidth
  implicitHeight: Math.max(box.height, label.implicitHeight)
  opacity: active ? 1 : 0.4

  Rectangle {
    id: box
    anchors.verticalCenter: parent.verticalCenter
    width: 34
    height: 18
    color: root.checked ? Theme.alpha(Theme.accent, 0.18) : "transparent"
    border.width: 1
    border.color: root.checked ? Theme.accent : Theme.bg3
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? parent.width - width - 3 : 3
      width: 12
      height: 12
      color: root.checked ? Theme.accent : Theme.dim
    }
  }

  Txt {
    id: label
    anchors.left: box.right
    anchors.leftMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    text: root.text
    font.pixelSize: 12
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active) root.toggled(!root.checked)
  }
}
