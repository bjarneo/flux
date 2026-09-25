import QtQuick
import ".."

// A quick action tile: a glyph in accent and a label. The border turns
// accent on hover.
Rectangle {
  id: root
  property string glyph: ""
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
    spacing: 6
    Txt { text: root.glyph; color: Theme.accent; font.pixelSize: 18 }
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
