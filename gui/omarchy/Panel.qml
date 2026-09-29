import QtQuick
import Quickshell
import "Flux"

// The Flux window as an omarchy-shell panel. Summon it with:
//   omarchy-shell shell summon flux '{"page":"files"}'
// The payload is optional. "page" selects a screen: overview, clipboard,
// files, notifications, messages, browse, or commands.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var service: null
  property var manifest: null

  // The service can load after the panel, so the panel also asks for it.
  readonly property var flux: service || lookedUp
  property var lookedUp: null
  property int lookups: 0

  property bool closingFromHost: false
  property string pendingPage: ""
  // FluxView unloads while the window is hidden. The next FluxView starts
  // with the tab and the device of the last one.
  property string savedTab: "overview"
  property string savedDevice: ""
  readonly property bool opened: window.visible
  readonly property alias panelWindow: window
  readonly property alias viewLoader: view

  function findService() {
    if (!service && !lookedUp && shell && typeof shell.serviceFor === "function")
      lookedUp = shell.serviceFor("flux")
  }

  function open(payloadJson) {
    var page = ""
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && typeof parsed.page === "string") page = parsed.page
      } catch (e) {}
    }
    findService()
    lookups = 0
    // A plugin update can keep a service from an earlier version loaded.
    if (flux && typeof flux.panelOpened === "function") flux.panelOpened()
    closingFromHost = false
    window.visible = true
    if (page === "") return
    if (view.item) view.item.showPage(page)
    else pendingPage = page
  }

  // The host closes the panel. The host already knows, so do not tell it.
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // Looks for the service while the window shows, 20 times at most.
  Timer {
    interval: 500
    repeat: true
    running: window.visible && !root.flux && root.lookups < 20
    onTriggered: {
      root.lookups++
      root.findService()
    }
  }

  FloatingWindow {
    id: window
    visible: false
    title: "Flux"
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(900, 640)
    color: Theme.bg

    // The user closed the window. Tell the host, so the next toggle opens it.
    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("flux")
    }

    // FluxView exists only while the window shows. A hidden window then
    // does no work for state events, and its pages send no requests.
    Loader {
      id: view
      anchors.fill: parent
      active: window.visible && !!root.flux
      sourceComponent: FluxView {
        backend: root.flux.backend
        themeText: root.flux.themeText
        tab: root.savedTab
        selectedId: root.savedDevice
        onTabChanged: root.savedTab = tab
        onSelectedIdChanged: root.savedDevice = selectedId
      }
      onLoaded: {
        if (root.pendingPage !== "") item.showPage(root.pendingPage)
        root.pendingPage = ""
        item.forceActiveFocus()
      }
    }
  }
}
