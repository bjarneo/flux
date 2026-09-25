import QtQuick
import ".."

// One device in the sidebar: type icon, name, status, and battery.
Rectangle {
  id: root
  property var device: ({})
  property bool selected: false
  signal clicked()

  readonly property bool online: !!device.online
  readonly property string statusText: !device.paired ? "not paired" : (online ? "connected" : "offline")

  implicitHeight: Math.max(32, info.implicitHeight) + 22
  color: selected ? Theme.bg : (area.containsMouse ? Theme.alpha(Theme.bg, 0.5) : "transparent")
  border.width: 1
  border.color: selected ? Theme.bg3 : "transparent"

  Rectangle {
    id: kind
    x: 11
    anchors.verticalCenter: parent.verticalCenter
    width: 32
    height: 32
    color: root.online && root.device.paired ? Theme.alpha(Theme.accent, 0.16) : Theme.bg3
    Icon {
      anchors.centerIn: parent
      name: Fmt.kindIcon(root.device.type)
      size: 18
      color: root.online && root.device.paired ? Theme.accent : Theme.dim
    }
  }

  Column {
    id: info
    anchors.left: kind.right
    anchors.leftMargin: 10
    anchors.right: battery.left
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    Txt {
      width: parent.width
      text: root.device.name || ""
      font.weight: Font.DemiBold
      elide: Text.ElideRight
    }
    Txt {
      width: parent.width
      text: "● " + root.statusText
      color: root.online && root.device.paired ? Theme.ok : Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
    }
  }

  Row {
    id: battery
    anchors.right: parent.right
    anchors.rightMargin: 11
    anchors.verticalCenter: parent.verticalCenter
    spacing: 2
    visible: !!root.device.battery && root.device.battery.charge >= 0
    Icon {
      anchors.verticalCenter: parent.verticalCenter
      name: Fmt.batteryIcon(root.device.battery)
      size: 14
      color: root.device.battery && root.device.battery.charge <= 15 && !root.device.battery.charging ? Theme.err : Theme.dim
    }
    Txt {
      anchors.verticalCenter: parent.verticalCenter
      text: Fmt.battery(root.device.battery)
      color: Theme.dim
      font.pixelSize: 11
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
