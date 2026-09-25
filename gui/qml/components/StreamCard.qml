import QtQuick
import ".."

// A live stream from the phone, such as the microphone or the screen
// mirror: a heading, 1 or 2 lines of state, and Stop.
Card {
  id: root
  property string icon: ""
  property string heading: ""
  // The stream state from fluxd, for example state.mic. Null hides nothing:
  // the parent sets visible.
  property var stream: ({})
  property string title: ""
  property string detail: ""
  signal stop()

  readonly property bool failed: !!stream && !!stream.error
  readonly property bool live: !!stream && !!stream.active && !failed

  implicitHeight: col.implicitHeight + 38

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 19
    spacing: 12

    Row {
      spacing: 8
      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: root.icon
        size: 14
        color: root.live ? Theme.err : Theme.dim
      }
      SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: root.live ? root.heading + " · LIVE" : root.heading }
    }

    Item {
      width: parent.width
      height: Math.max(text.implicitHeight, stopButton.implicitHeight)

      Column {
        id: text
        anchors.left: parent.left
        anchors.right: stopButton.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        Txt {
          width: parent.width
          visible: !root.failed
          text: root.live ? root.title : "Starting…"
          font.weight: root.live ? Font.Bold : Font.Normal
          color: root.live ? Theme.fg : Theme.dim
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          visible: root.live && root.detail !== ""
          text: root.detail
          color: Theme.dim
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          visible: root.failed
          text: root.stream ? (root.stream.error || "") : ""
          color: Theme.err
          wrapMode: Text.Wrap
        }
      }

      OutlineButton {
        id: stopButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.failed
        icon: "stop"
        text: "Stop"
        onClicked: root.stop()
      }
    }
  }
}
