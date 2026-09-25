import QtQuick
import ".."

// A message at the top right that hides after 2.2 seconds.
Rectangle {
  id: root
  property string message: ""
  width: 340
  implicitHeight: col.implicitHeight + 24
  color: Theme.bg2
  border.width: 2
  border.color: Theme.accent
  visible: message !== ""
  z: 10

  function show(text) {
    message = text
    timer.restart()
  }

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 14
    anchors.topMargin: 12
    Txt { text: "flux"; color: Theme.accent; font.pixelSize: 12 }
    Txt {
      width: parent.width
      text: root.message
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
  }

  Timer {
    id: timer
    interval: 2200
    onTriggered: root.message = ""
  }
}
