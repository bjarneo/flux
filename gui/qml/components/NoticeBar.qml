import QtQuick
import ".."

// A message at the bottom right that stays until its cause goes away.
// action is the text of the button, or "" for no button.
Rectangle {
  id: root
  property string title: ""
  property string message: ""
  property string action: ""
  signal activated()

  width: Math.min(360, (parent ? parent.width : 392) - 32)
  implicitHeight: col.implicitHeight + 28
  color: Theme.bg2
  border.width: 2
  border.color: Theme.warn
  z: 9

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 14
    spacing: 8
    Txt { text: root.title; color: Theme.warn; font.pixelSize: 12 }
    Txt {
      width: parent.width
      text: root.message
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
    AccentButton {
      visible: root.action !== ""
      text: root.action
      fontSize: 12
      onClicked: root.activated()
    }
  }
}
