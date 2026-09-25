import QtQuick
import Quickshell
import "Flux"

// The Flux window as an omarchy-shell panel. Summon it with:
//   omarchy-shell shell summon flux '{"page":"files"}'
// The payload is optional. "page" selects a screen: overview, clipboard,
// files, notifications, media, messages, browse, or commands.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var service: null
  property var manifest: null

  // The service can load after the panel, so the panel also asks for it.
  readonly property var flux: service || lookedUp
  property var lookedUp: null

  property bool closingFromHost: false
  property bool shown: false
  property string pendingPage: ""
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
    closingFromHost = false
    shown = true
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

  Timer {
    interval: 500
    repeat: true
    running: root.shown && !root.flux
    onTriggered: root.findService()
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

    // FluxView loads on the first open and then keeps its state.
    Loader {
      id: view
      anchors.fill: parent
      active: root.shown && !!root.flux
      sourceComponent: FluxView {
        backend: root.flux.backend
        themeText: root.flux.themeText
      }
      onLoaded: {
        if (root.pendingPage !== "") item.showPage(root.pendingPage)
        root.pendingPage = ""
        item.forceActiveFocus()
      }
    }
  }
}
