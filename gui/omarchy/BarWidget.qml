import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Flux/components" as FluxUi

// The Flux bar widget: the Flux mark alone. The mark takes the accent color
// while a paired device is connected. The tooltip lists every paired device.
// A left click opens or closes the Flux window.
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
  readonly property bool linked: up && !!primary

  readonly property string tooltip: {
    if (!backend) return "Flux"
    if (!up) return "Flux · fluxd is not running"
    if (paired.length === 0) return "Flux · no paired devices"
    var lines = []
    // The connected device comes first.
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
    fixedWidth: root.vertical ? -1 : mark.width + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? mark.height + scaledVerticalPadding * 2 : -1
    tooltipText: root.tooltip
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
    }

    FluxUi.FluxMark {
      id: mark
      anchors.centerIn: parent
      size: 14
      fg: button.foreground
      accent: root.linked ? Color.accent : button.foreground
    }
  }
}
