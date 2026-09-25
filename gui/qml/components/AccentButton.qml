import QtQuick
import ".."

// A button with the accent fill and bold text in the background color.
Rectangle {
  id: root
  property string text: ""
  property int padX: 14
  property int padY: 7
  property int fontSize: Theme.size
  property int fontWeight: Font.Bold
  property bool active: true
  signal clicked()

  implicitWidth: label.implicitWidth + padX * 2
  implicitHeight: label.implicitHeight + padY * 2
  color: area.containsMouse && root.active ? Theme.mix(Theme.accent, Theme.fg, 0.15) : Theme.accent
  opacity: active ? 1 : 0.4

  Txt {
    id: label
    anchors.centerIn: parent
    text: root.text
    color: Theme.bg
    font.pixelSize: root.fontSize
    font.weight: root.fontWeight
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active) root.clicked()
  }
}
