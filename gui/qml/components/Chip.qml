import QtQuick
import ".."

// A choice in a row of options. The selected chip has the accent fill.
Rectangle {
  id: root
  property string text: ""
  property bool selected: false
  property bool active: true
  signal clicked()

  implicitWidth: label.implicitWidth + 24
  implicitHeight: label.implicitHeight + 12
  color: selected ? Theme.accent : (area.containsMouse && active ? Theme.alpha(Theme.fg, 0.06) : "transparent")
  border.width: selected ? 0 : 1
  border.color: Theme.bg3
  opacity: active ? 1 : 0.4

  Txt {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: root.selected ? Theme.bg : Theme.fg
    font.pixelSize: 12
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active && !root.selected) root.clicked()
  }
}
