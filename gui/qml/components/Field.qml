import QtQuick
import ".."

// A one-line text field with a bg fill and a bg3 border.
Rectangle {
  id: root
  property alias text: input.text
  property string placeholder: ""
  property int padX: 12
  property int padY: 10
  property alias input: input
  signal accepted()
  // Esc takes the focus from the field. The owner can also cancel an edit.
  signal escaped()

  implicitHeight: input.implicitHeight + padY * 2 + 2
  implicitWidth: 200
  color: Theme.bg
  border.width: 1
  border.color: input.activeFocus ? Theme.accent : Theme.bg3

  TextInput {
    id: input
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.padX
    anchors.rightMargin: root.padX
    color: Theme.fg
    font.family: Theme.font
    font.pixelSize: Theme.size
    selectionColor: Theme.alpha(Theme.accent, 0.4)
    selectedTextColor: Theme.fg
    clip: true
    selectByMouse: true
    onAccepted: root.accepted()
    Keys.onEscapePressed: {
      focus = false
      root.escaped()
    }
  }

  Txt {
    anchors.fill: input
    verticalAlignment: Text.AlignVCenter
    visible: input.text.length === 0
    text: root.placeholder
    color: Theme.dim
    elide: Text.ElideRight
  }

  function clear() { input.text = "" }
}
