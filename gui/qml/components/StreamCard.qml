import QtQuick
import ".."

// A live stream from the phone, such as the microphone or the screen
// mirror: a heading, 1 or 2 lines of state, and Stop. A card with canStart
// also shows Start while no stream runs.
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

  // idle is true while no stream runs. The card then shows idleTitle. With
  // canStart, Start shows while the card is idle or failed, and emits
  // start(). note is a line under the title or the error of an idle or
  // failed card, for example the device to confirm on. While startActive
  // is false, Start is dim and does nothing, for example in the 3 seconds
  // after a request.
  property bool idle: false
  property string idleTitle: ""
  property string note: ""
  property bool canStart: false
  property bool startActive: true
  signal start()

  readonly property bool failed: !idle && !!stream && !!stream.error
  readonly property bool live: !idle && !!stream && !!stream.active && !failed

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
      height: Math.max(text.implicitHeight, buttons.implicitHeight)

      Column {
        id: text
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        Txt {
          width: parent.width
          visible: root.idle
          text: root.idleTitle
          color: Theme.dim
          wrapMode: Text.Wrap
        }
        Txt {
          width: parent.width
          visible: !root.failed && !root.idle
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
        Txt {
          width: parent.width
          visible: (root.idle || root.failed) && root.note !== ""
          text: root.note
          color: Theme.dim
          wrapMode: Text.Wrap
        }
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        OutlineButton {
          objectName: "startButton"
          visible: root.canStart && (root.idle || root.failed)
          icon: "play"
          text: "Start"
          active: root.startActive
          onClicked: root.start()
        }
        OutlineButton {
          visible: !root.failed && !root.idle
          icon: "stop"
          text: "Stop"
          onClicked: root.stop()
        }
      }
    }
  }
}
