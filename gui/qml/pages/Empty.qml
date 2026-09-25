import QtQuick
import ".."
import "../components"

// The first-run screen when no device is paired.
Item {
  id: root
  property var view
  property bool fillHeight: false
  implicitHeight: col.implicitHeight

  Column {
    id: col
    width: Math.min(parent.width, 640)
    spacing: 14

    FluxMark { size: 48 }
    Item { width: 1; height: 2 }
    Txt {
      text: "No devices yet"
      font.pixelSize: 20
      font.weight: Font.Bold
    }
    Txt {
      width: parent.width
      text: "Flux pairs with Flux for Android on your phone."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Card {
      width: parent.width
      implicitHeight: steps.implicitHeight + 38
      Column {
        id: steps
        x: 19
        y: 19
        width: parent.width - 38
        spacing: 10
        Repeater {
          model: [
            "Install Flux for Android on the phone.",
            "Connect the phone to the same network as this computer.",
            "Press + Pair new device, then select the phone.",
            "Make sure that the key on the phone is the same as the key in Flux."
          ]
          delegate: Row {
            required property var modelData
            required property int index
            width: steps.width
            spacing: 12
            Txt { text: (index + 1) + "."; color: Theme.accent; font.weight: Font.Bold }
            Txt { width: parent.width - 30; text: modelData; wrapMode: Text.Wrap }
          }
        }
      }
    }

    AccentButton {
      text: "+ Pair new device"
      onClicked: if (!root.view.pairMode) root.view.startPair()
    }

    Item { width: 1; height: 4 }

    Txt {
      width: parent.width
      text: "The phone does not appear? Open the app on the phone, and keep the phone on the same Wi-Fi network. Flux finds it with mDNS and needs no open port."
      color: Theme.dim
      wrapMode: Text.Wrap
    }
    Txt {
      width: parent.width
      text: "To check the setup, run flux doctor."
      color: Theme.dim
      wrapMode: Text.Wrap
    }
  }
}
