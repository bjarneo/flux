import QtQuick
import ".."
import "../components"

// Clipboard history. Incoming entries have a down arrow, outgoing entries
// have an up arrow.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var entries: view && view.backend ? (view.backend.clipboard || []) : []

  implicitHeight: list.implicitHeight

  function source(e) {
    if (e.dir === "out") return "this pc"
    if (e.deviceName) return e.deviceName
    var devs = view ? view.allDevices : []
    for (var i = 0; i < devs.length; i++) if (devs[i].id === e.device) return devs[i].name
    return "phone"
  }

  Column {
    id: list
    width: parent.width
    spacing: 10

    Txt {
      visible: root.entries.length === 0
      width: parent.width
      text: "No clipboard entries yet. Copy text on this computer or on the phone."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Repeater {
      model: root.entries
      delegate: Card {
        required property var modelData
        readonly property bool incoming: modelData.dir !== "out"
        width: list.width
        implicitHeight: Math.max(textCol.implicitHeight, copy.implicitHeight) + 30

        // The direction: from the device, or from this computer.
        Icon {
          id: arrow
          x: 17
          anchors.verticalCenter: parent.verticalCenter
          name: parent.incoming ? "arrow-in" : "arrow-out"
          size: 18
          color: parent.incoming ? Theme.ok : Theme.accent
        }
        Column {
          id: textCol
          anchors.left: arrow.right
          anchors.leftMargin: 16
          anchors.right: copy.left
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          Txt {
            width: parent.width
            text: (modelData.text || "").replace(/\s*\n\s*/g, " ")
            elide: Text.ElideRight
          }
          Txt {
            width: parent.width
            text: root.source(modelData) + " · " + Fmt.clock(modelData.time)
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
        }
        OutlineButton {
          id: copy
          anchors.right: parent.right
          anchors.rightMargin: 19
          anchors.verticalCenter: parent.verticalCenter
          icon: "copy"
          text: "Copy"
          padX: 12
          padY: 5
          fontSize: 12
          onClicked: root.view.call("clipboard.copy", { text: modelData.text }, function () { root.view.toast("Copied to the clipboard") })
        }
      }
    }
  }
}
