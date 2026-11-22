import QtQuick
import ".."

// A modal question with a scrim, a title, a text, Cancel, and a confirm key.
// It uses plain items, so both hosts draw it. Cancel has the focus first.
// Escape and a click on the scrim cancel.
Item {
  id: root
  property string title: ""
  property string text: ""
  property string confirmText: "Confirm"
  property bool open: false
  signal confirmed()
  signal canceled()

  anchors.fill: parent
  visible: open
  Keys.onEscapePressed: root.cancel()
  onOpenChanged: if (open) cancelKey.forceActiveFocus()

  function cancel() {
    open = false
    canceled()
  }
  function confirm() {
    open = false
    confirmed()
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.alpha(Theme.bg, 0.6)
    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }
  }

  Card {
    objectName: "confirmBox"
    anchors.centerIn: parent
    width: Math.min(420, parent.width - 32)
    height: box.implicitHeight + 40

    // A click on the box does not reach the scrim and cancel.
    MouseArea { anchors.fill: parent }

    Column {
      id: box
      x: 20
      y: 20
      width: parent.width - 40
      spacing: 10

      Txt {
        objectName: "confirmTitle"
        width: parent.width
        text: root.title
        font.pixelSize: 16
        font.weight: Font.DemiBold
        wrapMode: Text.Wrap
      }
      Txt {
        objectName: "confirmText"
        width: parent.width
        text: root.text
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
      Item { width: 1; height: 2 }
      // RightToLeft puts the confirm key on the right, the primary action.
      Row {
        width: parent.width
        spacing: 8
        layoutDirection: Qt.RightToLeft
        OutlineButton {
          objectName: "confirmOk"
          text: root.confirmText
          textColor: Theme.accent
          onClicked: root.confirm()
        }
        OutlineButton {
          id: cancelKey
          objectName: "confirmCancel"
          text: "Cancel"
          onClicked: root.cancel()
        }
      }
    }
  }
}
