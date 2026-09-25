import QtQuick
import ".."

// A pair request from a device. It shows the verification key, which must
// match the key on the device.
Rectangle {
  id: root
  property var device: ({})
  signal accept()
  signal reject()

  implicitHeight: col.implicitHeight + 28
  color: Theme.bg
  border.width: 1
  border.color: Theme.accent

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 14
    spacing: 8

    Txt {
      width: parent.width
      text: (root.device.name || "A device") + " wants to pair"
      font.weight: Font.DemiBold
      wrapMode: Text.Wrap
    }
    Txt {
      width: parent.width
      text: "Key " + (root.device.pairKey || "—") + ". Check that the phone shows the same key."
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
    Row {
      spacing: 8
      topPadding: 2
      AccentButton { icon: "link"; text: "Accept"; padX: 12; padY: 6; fontSize: 12; onClicked: root.accept() }
      OutlineButton { icon: "close"; text: "Reject"; padX: 12; padY: 6; fontSize: 12; onClicked: root.reject() }
    }
  }
}
