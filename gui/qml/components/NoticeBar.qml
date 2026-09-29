import QtQuick
import ".."

// A message at the bottom right that stays until its cause goes away.
// action and secondary are the texts of the 2 buttons, or "" for no
// button.
Rectangle {
  id: root
  property string title: ""
  property string message: ""
  property string action: ""
  property string secondary: ""
  signal activated()
  signal secondaryActivated()

  width: Math.min(360, (parent ? parent.width : 392) - 32)
  implicitHeight: col.implicitHeight + 28
  color: Theme.bg2
  border.width: 2
  border.color: Theme.warn

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
    Row {
      spacing: 8
      visible: root.action !== "" || root.secondary !== ""
      AccentButton {
        visible: root.action !== ""
        text: root.action
        fontSize: 12
        onClicked: root.activated()
      }
      OutlineButton {
        visible: root.secondary !== ""
        text: root.secondary
        fontSize: 12
        onClicked: root.secondaryActivated()
      }
    }
  }
}
