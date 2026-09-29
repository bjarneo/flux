import QtQuick
import ".."

// A pair request from a device. It shows the verification key, which must
// match the key on the device.
Rectangle {
  id: root
  property var device: ({})
  // A value that changes when the card moves on the screen, for example
  // the scroll position of the sidebar.
  property var motion
  // Accept works only after the card showed the same request at the same
  // place for this time. A card that appears or moves under the pointer
  // then does not take a click that was meant for another control.
  property int armDelay: 1000
  property bool armed: false
  signal accept()
  signal reject()

  implicitHeight: col.implicitHeight + 28
  color: Theme.bg
  border.width: 1
  border.color: Theme.accent

  readonly property string armKey: (device.id || "") + ":" + (device.pairKey || "")

  function hold() {
    armed = false
    if (visible) armTimer.restart()
    else armTimer.stop()
  }

  onArmKeyChanged: hold()
  onVisibleChanged: hold()
  onYChanged: hold()
  onMotionChanged: hold()
  Component.onCompleted: hold()

  Timer {
    id: armTimer
    interval: root.armDelay
    onTriggered: root.armed = root.visible
  }

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 14
    spacing: 8

    Txt {
      width: parent.width
      text: (root.device.name ? Fmt.showControls(root.device.name) : "A device") + " wants to pair"
      font.weight: Font.DemiBold
      wrapMode: Text.Wrap
    }
    Txt {
      width: parent.width
      visible: text !== ""
      text: root.device.ip || ""
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
    }
    Txt {
      width: parent.width
      text: "Check that the device shows all 16 digits of this key:"
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
    // The key has its own line, so no group of 4 digits breaks.
    Txt {
      width: parent.width
      text: Fmt.hexGroups(root.device.pairKey) || "—"
      font.pixelSize: 15
      font.weight: Font.Bold
      elide: Text.ElideRight
    }
    Row {
      spacing: 8
      topPadding: 2
      AccentButton { icon: "link"; text: "Accept"; padX: 12; padY: 6; fontSize: 12; active: root.armed; onClicked: root.accept() }
      OutlineButton { icon: "close"; text: "Reject"; padX: 12; padY: 6; fontSize: 12; onClicked: root.reject() }
    }
  }
}
