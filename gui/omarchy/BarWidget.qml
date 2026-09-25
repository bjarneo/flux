import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Flux/components" as FluxUi

// The Flux bar widget: the Flux mark and the first connected device with its
// battery, as in the design. The tooltip lists every paired device. A left
// click opens or closes the Flux window.
BarWidget {
  id: root
  moduleName: "flux"

  readonly property var service: {
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor(root.moduleName)
  }
  readonly property var backend: service ? service.backend : null
  readonly property bool up: !!backend && backend.connected
  readonly property var paired: backend ? (backend.devices || []).filter(d => d.paired) : []
  readonly property var primary: paired.find(d => d.online) || null

  readonly property string label: {
    if (!primary) return ""
    var b = primary.battery
    var charge = b && b.charge !== undefined && b.charge !== null && b.charge >= 0 ? " " + b.charge + "%" : ""
    return primary.name + charge
  }

  readonly property string tooltip: {
    if (!backend) return "Flux"
    if (!up) return "Flux · fluxd is not running"
    if (paired.length === 0) return "Flux · no paired devices"
    var lines = []
    // The connected device in the label comes first.
    var sorted = paired.slice().sort(function (a, b) {
      if (a === root.primary) return -1
      if (b === root.primary) return 1
      return (b.online ? 1 : 0) - (a.online ? 1 : 0)
    })
    for (var i = 0; i < sorted.length; i++)
      lines.push(sorted[i].name + " · " + (sorted[i].online ? "connected" : "offline"))
    return lines.join("\n")
  }

  function togglePanel() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function")
      root.bar.shell.toggle(root.moduleName, "{}")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? mark.height + scaledVerticalPadding * 2 : -1
    tooltipText: root.tooltip
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 6

      FluxUi.FluxMark {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        size: 14
        fg: button.foreground
        accent: Color.accent
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical && text !== ""
        textFormat: Text.PlainText
        text: root.label
        color: Color.accent
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }
}
