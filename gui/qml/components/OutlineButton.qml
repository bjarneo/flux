import QtQuick
import ".."

// A button with a 1 px bg3 border and no fill.
Rectangle {
  id: root
  property string text: ""
  // An Icon name, shown before the text.
  property string icon: ""
  property int padX: 14
  property int padY: 7
  property int fontSize: Theme.size
  property color textColor: Theme.fg
  property color iconColor: textColor
  property bool active: true
  property int fontWeight: Font.Normal
  signal clicked()

  implicitWidth: content.implicitWidth + padX * 2 + 2
  implicitHeight: content.implicitHeight + padY * 2 + 2
  color: area.containsMouse && root.active ? Theme.alpha(Theme.fg, 0.06) : "transparent"
  border.width: 1
  border.color: Theme.bg3
  opacity: active ? 1 : 0.4

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 7
    Icon {
      visible: root.icon !== ""
      anchors.verticalCenter: parent.verticalCenter
      name: root.icon
      size: root.fontSize + 2
      color: root.iconColor
    }
    Txt {
      visible: root.text !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      color: root.textColor
      font.pixelSize: root.fontSize
      font.weight: root.fontWeight
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active) root.clicked()
  }
}
