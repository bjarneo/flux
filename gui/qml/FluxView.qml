import QtQuick
import QtQuick.Controls
import "components"

// The whole Flux window: a 260 px sidebar and the content area. The host
// gives the backend and the text of the active colors.toml. The backend
// contract is in README.md.
Item {
  id: root
  required property var backend
  property string themeText: ""
  onThemeTextChanged: Theme.load(themeText)
  Component.onCompleted: Theme.load(themeText)

  readonly property var tabs: [
    { key: "overview", label: "Overview", page: "Overview" },
    { key: "clipboard", label: "Clipboard", page: "Clipboard" },
    { key: "files", label: "Files", page: "Files" },
    { key: "notifications", label: "Notifications", page: "Notifications" },
    { key: "media", label: "Media", page: "Media" },
    { key: "messages", label: "Messages", page: "Messages" },
    { key: "browse", label: "Browse files", page: "Browse" },
    { key: "commands", label: "Phone commands", page: "PhoneCommands" }
  ]

  property string tab: "overview"
  property string selectedId: ""
  property bool pairMode: false
  property string justPaired: ""
  property var prevPairStates: ({})

  readonly property bool daemonUp: !!backend && backend.connected
  readonly property var allDevices: backend ? (backend.devices || []) : []
  readonly property var paired: allDevices.filter(d => d.paired)
  readonly property var discovered: allDevices.filter(d => !d.paired && d.online && d.pairState !== "incoming")
  readonly property var incoming: allDevices.filter(d => d.pairState === "incoming")
  readonly property var requested: allDevices.find(d => d.pairState === "requested") || null
  readonly property var dev: {
    for (var i = 0; i < paired.length; i++)
      if (paired[i].id === selectedId) return paired[i]
    return paired.length > 0 ? paired[0] : null
  }
  readonly property bool devOnline: !!dev && !!dev.online
  readonly property string devName: dev ? (dev.name || "device") : "device"
  readonly property var visibleTabs: tabs.filter(t => tabAllowed(t.key))
  readonly property var currentTab: {
    for (var i = 0; i < visibleTabs.length; i++)
      if (visibleTabs[i].key === tab) return visibleTabs[i]
    return visibleTabs[0]
  }

  focus: true

  function has(plugin) {
    if (!dev || !dev.plugins || dev.plugins.length === 0) return true
    return dev.plugins.indexOf(plugin) >= 0
  }

  function tabAllowed(key) {
    if (key === "messages") return has("sms")
    if (key === "browse") return has("sftp")
    return true
  }

  function go(key) {
    if (tabAllowed(key)) tab = key
  }

  function showPage(key) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].key === key) {
        go(key)
        return true
      }
    }
    return false
  }

  function toast(text) { toastBox.show(text) }

  // Calls a fluxd method. An error becomes a toast. cb receives the result.
  function call(method, params, cb) {
    if (!backend) return
    backend.call(method, params || {}, function (err, result) {
      if (err) {
        toast(err.message || err.code || "Error")
        return
      }
      if (cb) cb(result)
    })
  }

  function selectOffset(n) {
    if (paired.length === 0) return
    var i = 0
    for (var j = 0; j < paired.length; j++) if (dev && paired[j].id === dev.id) i = j
    i = Math.max(0, Math.min(paired.length - 1, i + n))
    selectedId = paired[i].id
  }

  function ring() {
    if (!dev) return
    if (!dev.online) {
      toast(devName + " is offline")
      return
    }
    call("ring", { device: dev.id }, function () { toast("Ringing " + root.devName + "…") })
  }

  function sendClipboard() {
    if (!dev) return
    if (!dev.online) {
      toast(devName + " is offline")
      return
    }
    call("clipboard.send", { device: dev.id }, function () { toast("Clipboard sent to " + root.devName) })
  }

  property alias sidebarFlick: sideFlick

  // Scrolls the sidebar so that item is in view, for example the device
  // that j and k select.
  function revealInSidebar(item) {
    if (!item || sideFlick.contentHeight <= sideFlick.height) return
    var top = item.mapToItem(sideFlick.contentItem, 0, 0).y
    var bottom = top + item.height
    var y = sideFlick.contentY
    if (top - 18 < y) y = top - 18
    else if (bottom + 18 > y + sideFlick.height) y = bottom + 18 - sideFlick.height
    sideFlick.contentY = Math.max(0, Math.min(y, sideFlick.contentHeight - sideFlick.height))
  }

  // A new pair request scrolls the sidebar to the top, where the card is.
  onIncomingChanged: if (incoming.length > 0) sideFlick.contentY = 0

  function startPair() {
    pairMode = !pairMode
    if (pairMode) call("discover", {})
  }

  onAllDevicesChanged: {
    var next = {}
    for (var i = 0; i < allDevices.length; i++) {
      var d = allDevices[i]
      var before = prevPairStates[d.id]
      if (before !== undefined && before !== "paired" && d.pairState === "paired") {
        justPaired = d.name
        selectedId = d.id
        pairMode = false
        pairedTimer.restart()
      }
      next[d.id] = d.pairState
    }
    prevPairStates = next
  }

  Timer {
    id: pairedTimer
    interval: 3000
    onTriggered: root.justPaired = ""
  }

  Connections {
    target: root.backend
    ignoreUnknownSignals: true
    function onToast(text) { root.toast(text) }
  }

  function typing() {
    var item = root.Window.activeFocusItem
    return !!item && item.cursorPosition !== undefined && item.selectByMouse !== undefined
  }

  Keys.onPressed: function (event) {
    if (typing() || (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
    if (page.item && page.item.handleKey) {
      page.item.handleKey(event)
      if (event.accepted) return
    }
    var n = parseInt(event.text, 10)
    if (n >= 1 && n <= 9) {
      if (n <= visibleTabs.length) tab = visibleTabs[n - 1].key
      event.accepted = true
    } else if (event.text === "j") {
      selectOffset(1); event.accepted = true
    } else if (event.text === "k") {
      selectOffset(-1); event.accepted = true
    } else if (event.text === "r") {
      ring(); event.accepted = true
    } else if (event.text === "s") {
      sendClipboard(); event.accepted = true
    } else if (event.text === "p") {
      startPair(); event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      if (pairMode) pairMode = false
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.bg
  }

  // Sidebar
  Rectangle {
    id: sidebar
    width: 260
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    color: Theme.bg2
    visible: root.daemonUp

    // The sidebar scrolls when the devices and tabs are taller than the
    // window. The scroll bar shows only on hover or while it moves.
    HoverHandler { id: sideHover }

    Flickable {
      id: sideFlick
      anchors.fill: parent
      contentHeight: side.implicitHeight + 36
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      clip: true
      ScrollBar.vertical: ScrollBar {
        policy: sideFlick.contentHeight > sideFlick.height && (sideHover.hovered || sideFlick.moving || active)
          ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        contentItem: Rectangle { implicitWidth: 6; color: Theme.bg3 }
        background: Item {}
      }

      Column {
        id: side
        x: 14
        y: 18
        width: parent.width - 28
        spacing: 18

        // Logo: the 4a mark and the word, as in the app header lockup.
        Row {
          x: 6
          spacing: 10
          FluxMark { size: 26 }
          Txt {
            anchors.verticalCenter: parent.verticalCenter
            text: "flux"
            font.pixelSize: 16
            font.weight: Font.ExtraBold
          }
        }

        // Devices
        Column {
          width: parent.width
          spacing: 6

          Repeater {
            model: root.incoming
            delegate: PairCard {
              required property var modelData
              width: side.width
              device: modelData
              onAccept: root.call("pair.accept", { device: modelData.id })
              onReject: root.call("pair.reject", { device: modelData.id })
            }
          }

          Repeater {
            model: root.paired
            delegate: DeviceRow {
              required property var modelData
              width: side.width
              device: modelData
              selected: !!root.dev && root.dev.id === modelData.id
              onClicked: root.selectedId = modelData.id
              onSelectedChanged: if (selected) Qt.callLater(root.revealInSidebar, this)
            }
          }

          DashedRect {
            id: pairButton
            width: parent.width
            height: pairLabel.implicitHeight + 18
            color: pairArea.containsMouse ? Theme.dim : Theme.bg3
            Txt {
              id: pairLabel
              anchors.centerIn: parent
              width: parent.width - 18
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              color: root.justPaired !== "" ? Theme.ok : Theme.dim
              font.pixelSize: 12
              text: {
                if (root.requested) {
                  var key = root.requested.pairKey || ""
                  return key !== "" ? "Confirm " + key + " on " + root.requested.name + "…" : "Waiting for " + root.requested.name + "…"
                }
                if (root.justPaired !== "") return "✓ " + root.justPaired + " paired"
                return "+ Pair new device"
              }
            }
            MouseArea {
              id: pairArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.requested) root.call("pair.reject", { device: root.requested.id })
                else root.startPair()
              }
            }
          }

          // Devices on the network that are not paired
          Repeater {
            model: root.pairMode ? root.discovered : []
            delegate: DashedRect {
              required property var modelData
              width: side.width
              height: 42
              color: candArea.containsMouse ? Theme.accent : Theme.bg3
              Rectangle {
                x: 9
                anchors.verticalCenter: parent.verticalCenter
                width: 24
                height: 24
                color: Theme.bg3
                Txt { anchors.centerIn: parent; text: Fmt.kindShort(modelData.type); color: Theme.dim; font.pixelSize: 10 }
              }
              Txt {
                x: 43
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 43 - 60
                text: modelData.name
                elide: Text.ElideRight
                font.weight: Font.DemiBold
              }
              Txt {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.pairState === "requested" ? "waiting" : "pair ▸"
                color: Theme.accent
                font.pixelSize: 11
              }
              MouseArea {
                id: candArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.call("pair.request", { device: modelData.id })
              }
            }
          }

          Txt {
            visible: root.pairMode && root.discovered.length === 0 && !root.requested
            width: parent.width
            topPadding: 2
            leftPadding: 4
            rightPadding: 4
            text: "Searching. Open Flux on the phone and join the same network."
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
        }

        // Tabs
        Column {
          width: parent.width
          spacing: 2
          visible: !!root.dev
          Repeater {
            model: root.visibleTabs
            delegate: Rectangle {
              required property var modelData
              readonly property bool sel: root.currentTab && root.currentTab.key === modelData.key
              width: side.width
              height: tabLabel.implicitHeight + 16
              color: sel ? Theme.alpha(Theme.accent, 0.18) : (tabArea.containsMouse ? Theme.alpha(Theme.fg, 0.05) : "transparent")
              Txt {
                id: tabLabel
                x: 12
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: parent.sel ? Theme.accent : Theme.fg
              }
              MouseArea {
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.tab = modelData.key
              }
            }
          }
        }
      }
    }
  }

  // Main area
  Item {
    id: main
    anchors.left: sidebar.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    visible: root.daemonUp

    // A press on an empty area gives the keyboard back to the shortcuts.
    MouseArea {
      anchors.fill: parent
      z: -1
      onPressed: function (mouse) {
        root.forceActiveFocus()
        mouse.accepted = false
      }
    }

    Item {
      id: header
      anchors.left: parent.left
      anchors.right: parent.right
      height: Math.max(title.implicitHeight, actions.implicitHeight) + 36 + 1

      Txt {
        id: title
        x: 28
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -0.5
        text: root.dev ? root.currentTab.label : "Get started"
        font.pixelSize: 20
        font.weight: Font.Bold
      }
      Txt {
        id: subtitle
        anchors.left: title.right
        anchors.leftMargin: 14
        anchors.right: actions.left
        anchors.rightMargin: 14
        anchors.verticalCenter: title.verticalCenter
        visible: !!root.dev
        text: root.dev ? root.devName + " · " + (root.dev.ip || "—") : ""
        color: Theme.dim
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: 28
        anchors.verticalCenter: title.verticalCenter
        spacing: 8
        visible: !!root.dev
        AccentButton {
          visible: !!root.backend && root.backend.ringing
          text: "Stop ringing"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.call("ring.stop", {})
        }
        OutlineButton {
          text: "Ring " + Fmt.noun(root.dev ? root.dev.type : "")
          active: root.devOnline
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.ring()
        }
        AccentButton {
          text: "Send clipboard"
          active: root.devOnline
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.sendClipboard()
        }
      }
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.bg3
      }
    }

    Flickable {
      id: flick
      objectName: "contentFlick"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: header.bottom
      anchors.bottom: parent.bottom
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      contentWidth: width
      contentHeight: body.height + 48
      ScrollBar.vertical: ScrollBar {
        policy: flick.contentHeight > flick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        contentItem: Rectangle { implicitWidth: 6; color: Theme.bg3 }
        background: Item {}
      }

      Column {
        id: body
        x: 28
        y: 24
        width: flick.width - 56
        spacing: 18
        readonly property real fillHeight: flick.height - 48 - (offlineLine.visible ? offlineLine.height + spacing : 0)

        Txt {
          id: offlineLine
          width: parent.width
          visible: !!root.dev && !root.dev.online
          text: root.dev ? root.devName + " is offline. Last seen " + Fmt.lastSeen(root.dev.lastSeen) + "." : ""
          color: Theme.dim
          wrapMode: Text.Wrap
        }

        Loader {
          id: page
          width: parent.width
          height: item ? (item.fillHeight ? body.fillHeight : item.implicitHeight) : 0
          readonly property string url: root.dev ? "pages/" + root.currentTab.page + ".qml" : "pages/Empty.qml"
          onUrlChanged: setSource(url, { view: root })
          Component.onCompleted: setSource(url, { view: root })
        }
      }
    }
  }

  // fluxd is not running
  Item {
    anchors.fill: parent
    visible: !!root.backend && root.backend.attempted && !root.backend.connected
    Column {
      anchors.centerIn: parent
      spacing: 10
      width: 420
      FluxMark {
        anchors.horizontalCenter: parent.horizontalCenter
        size: 64
      }
      Item { width: 1; height: 6 }
      Txt {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "fluxd is not running"
        font.pixelSize: 20
        font.weight: Font.Bold
      }
      Txt {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "The Flux window gets its devices from the fluxd service. Start the service to continue."
        color: Theme.dim
        wrapMode: Text.Wrap
      }
      Item { width: 1; height: 6 }
      AccentButton {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Start fluxd"
        onClicked: {
          root.toast("Starting fluxd…")
          root.backend.startDaemon(function (ok, message) {
            if (!ok) root.toast(message || "systemctl could not start fluxd. Run: journalctl --user -u fluxd")
          })
        }
      }
    }
  }

  Toast {
    id: toastBox
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: 16
    anchors.rightMargin: 16
  }
}
