import QtQuick
import ".."

// A quick action tile: an icon in accent and a label. The border turns
// accent on hover.
Rectangle {
  id: root
  // An Icon name.
  property string icon: ""
  property string label: ""
  property bool active: true
  signal clicked()

  implicitHeight: col.implicitHeight + 28
  color: Theme.bg2
  border.width: 1
  border.color: area.containsMouse && active ? Theme.accent : Theme.bg3
  opacity: active ? 1 : 0.4

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 14
    spacing: 8
    Icon { name: root.icon; color: Theme.accent; size: 20 }
    Txt { width: parent.width; text: root.label; font.weight: Font.DemiBold; elide: Text.ElideRight }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (root.active) root.clicked()
  }
}
