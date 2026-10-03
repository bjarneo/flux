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
  // The host sets appReplaced when an update replaced its program. The
  // window then offers a restart, and restartApp asks the host for it.
  property bool appReplaced: false
  signal restartApp()
  onThemeTextChanged: Theme.load(themeText)
  Component.onCompleted: Theme.load(themeText)

  readonly property var tabs: [
    { key: "overview", label: "Overview", page: "Overview", icon: "dashboard" },
    { key: "clipboard", label: "Clipboard", page: "Clipboard", icon: "clipboard" },
    { key: "files", label: "Files", page: "Files", icon: "transfers" },
    { key: "notifications", label: "Notifications", page: "Notifications", icon: "bell" },
    { key: "messages", label: "Messages", page: "Messages", icon: "message" },
    { key: "commands", label: "Phone commands", page: "PhoneCommands", icon: "console" }
  ]

  // The layout follows the width of the window. Wide shows the full
  // sidebar. Below 1000 px, a rail of icons takes its place. Below 680 px,
  // there is no sidebar. The rail and the narrow layout open the full
  // sidebar as a drawer over the content.
  readonly property bool wideLayout: width >= 1000
  readonly property bool narrowLayout: width < 680
  property bool drawerOpen: false
  readonly property bool sidebarFull: wideLayout || drawerOpen
  readonly property int sidebarSpace: wideLayout ? 260 : (narrowLayout ? 0 : 64)
  // The side margin of the content.
  readonly property int gutter: narrowLayout ? 16 : 28
  onWideLayoutChanged: if (wideLayout) drawerOpen = false

  // The header shows icon buttons with no text when the window is narrow.
  readonly property bool compactHeader: width - sidebarSpace < 760

  property string tab: "overview"
  onTabChanged: drawerOpen = false
  property string selectedId: ""
  property bool pairMode: false
  property string justPaired: ""
  property var prevPairStates: ({})
  // The device that the unpair confirm dialog acts on. Null when it is closed.
  property var unpairTarget: null
  // The scrim takes the keyboard while the dialog is open, so give it back to
  // the shortcuts when it closes.
  onUnpairTargetChanged: if (!unpairTarget) forceActiveFocus()

  readonly property bool daemonUp: !!backend && backend.connected
  readonly property var allDevices: backend ? (backend.devices || []) : []
  readonly property var paired: allDevices.filter(d => d.paired)
  readonly property var discovered: allDevices.filter(d => !d.paired && d.online && d.pairState !== "incoming" && d.pairState !== "confirm")
  // The pairings that wait for the user of this computer: a pair request of
  // a device, and a pairing that this computer started and the device
  // accepted ("confirm").
  readonly property var incoming: allDevices.filter(d => d.pairState === "incoming" || d.pairState === "confirm")
  readonly property var requested: allDevices.find(d => d.pairState === "requested") || null
  // The fields of the pair requests and of the discovered devices that the
  // sidebar shows. As for pairedRows, the text changes only when 1 of these
  // fields changes, so a state event does not build a card or a row again
  // under the pointer.
  readonly property string incomingText: JSON.stringify(incoming.map(d => ({
    id: d.id, name: d.name, ip: d.ip || "", pairKey: d.pairKey || "", pairState: d.pairState
  })))
  readonly property var incomingRows: JSON.parse(incomingText)
  readonly property string discoveredText: JSON.stringify(discovered.map(d => ({
    id: d.id, name: d.name, type: d.type, ip: d.ip || "", fingerprint: d.fingerprint || "",
    pairState: d.pairState, twin: twinText(d)
  })))
  readonly property var discoveredRows: JSON.parse(discoveredText)
  // The pair requests that showed, by device ID: since is the time in ms at
  // which the request first showed, and until is the time at which it
  // stopped showing, or 0 while it is open. An entry stays for requestQuiet
  // after the request stopped showing, so a device that withdraws its
  // request and sends it again does not count as new.
  property var requestShown: ({})
  readonly property int requestQuiet: 5 * 60 * 1000
  // The sidebar shows 1 pair request: the oldest one that is still open.
  // A later request does not replace the card under the pointer.
  readonly property var pairRequest: {
    var best = null
    var bestAt = 0
    for (var i = 0; i < incomingRows.length; i++) {
      var r = incomingRows[i]
      var e = Fmt.lookup(requestShown, r.id)
      var at = e ? e.since : Number.MAX_VALUE
      if (!best || at < bestAt) {
        best = r
        bestAt = at
      }
    }
    return best
  }
  // The fields of the paired devices that the device rows and the rail
  // show. The text changes only when 1 of these fields changes, so a new
  // notification or message does not build the rows again.
  readonly property string pairedRowsText: JSON.stringify(paired.map(d => ({
    id: d.id, name: d.name, type: d.type, online: !!d.online, paired: !!d.paired, battery: d.battery || null
  })))
  readonly property var pairedRows: JSON.parse(pairedRowsText)
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

  // Calls a fluxd method. cb receives the result. An error goes to onError
  // when the caller gives it. Otherwise the error becomes a toast.
  function call(method, params, cb, onError) {
    if (!backend) return
    backend.call(method, params || {}, function (err, result) {
      if (err) {
        if (onError) onError(err)
        else toast(err.message || err.code || "Error")
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

  // Opens the confirm dialog for the selected device.
  function unpair() {
    if (!dev) return
    unpairTarget = dev
  }

  // Removes the trust on this computer and tells the device, after the
  // confirm dialog. The row disappears when fluxd sends the new state.
  function confirmUnpair() {
    var target = unpairTarget
    unpairTarget = null
    if (!target) return
    call("pair.unpair", { device: target.id }, function () {
      toast((target.name || "Device") + " unpaired")
      if (selectedId === target.id) selectedId = ""
    })
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
  // The card shows only in the full sidebar, so a narrow window opens the
  // drawer. This happens only for a device whose request did not show in
  // the last requestQuiet, so a device that withdraws its request and sends
  // it again does not open the drawer again or move the sidebar.
  onIncomingRowsChanged: {
    var now = Date.now()
    var open = {}
    incomingRows.forEach(d => { open[d.id] = true })
    var shown = {}
    for (var id in requestShown) {
      var e = requestShown[id]
      var isOpen = !!Fmt.lookup(open, id)
      if (!e.until) shown[id] = isOpen ? e : { since: e.since, until: now }
      else if (now - e.until < requestQuiet) shown[id] = isOpen ? { since: now, until: 0 } : e
    }
    var fresh = false
    for (var rid in open) {
      if (Fmt.lookup(shown, rid)) continue
      shown[rid] = { since: now, until: 0 }
      fresh = true
    }
    requestShown = shown
    if (!fresh) return
    sideFlick.contentY = 0
    if (!wideLayout) drawerOpen = true
  }

  // A note for a discovered device with the name of another device, or "".
  // A device on the network can copy the name of a phone of the user.
  function twinText(d) {
    var key = Fmt.nameKey(d.name)
    var others = allDevices.filter(o => o.id !== d.id && Fmt.nameKey(o.name) === key)
    if (others.length === 0) return ""
    return others.some(o => o.paired) ? "Same name as a paired device" : "Same name as another device"
  }

  function startPair() {
    if (!wideLayout) drawerOpen = true
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
    } else if (event.text === "u") {
      unpair(); event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      if (drawerOpen) drawerOpen = false
      else if (pairMode) pairMode = false
      event.accepted = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.bg
  }

  // Sidebar
  // The scrim behind the drawer. A click on it closes the drawer.
  Rectangle {
    anchors.fill: parent
    z: 15
    visible: root.drawerOpen && !root.wideLayout && root.daemonUp
    color: Theme.alpha(Theme.bg2, 0.6)
    MouseArea { anchors.fill: parent; onClicked: root.drawerOpen = false }
  }

  // Sidebar
  Rectangle {
    id: sidebar
    width: root.sidebarFull ? 260 : root.sidebarSpace
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    color: Theme.bg2
    visible: root.daemonUp && width > 0
    z: root.drawerOpen ? 20 : 0

    // The edge of the drawer over the content.
    Rectangle {
      visible: root.drawerOpen && !root.wideLayout
      anchors.right: parent.right
      width: 1
      height: parent.height
      color: Theme.bg3
    }

    // The rail: 1 icon for each device and each tab. It exists only in the
    // rail layout. The open drawer hides it.
    Loader {
      anchors.fill: parent
      active: !root.wideLayout && !root.narrowLayout
      visible: !root.sidebarFull
      sourceComponent: Flickable {
        contentHeight: rail.implicitHeight + 28
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        clip: true
        Column {
          id: rail
          y: 14
          width: parent.width
          spacing: 6
          RailButton {
            icon: "menu"
            tip: "Show the devices and pages"
            onClicked: root.drawerOpen = true
          }
          Item { width: 1; height: 4 }
          Repeater {
            model: root.pairedRows
            delegate: RailButton {
              required property var modelData
              icon: Fmt.kindIcon(modelData.type)
              tip: modelData.name + (modelData.online ? " · connected" : " · offline")
              selected: !!root.dev && root.dev.id === modelData.id
              dot: modelData.online ? Theme.ok : "transparent"
              onClicked: root.selectedId = modelData.id
            }
          }
          RailButton {
            icon: root.incoming.length > 0 ? "key" : "plus"
            tip: root.incoming.length > 0 ? "A device asks to pair" : "Pair new device"
            dot: root.incoming.length > 0 ? Theme.warn : "transparent"
            onClicked: {
              root.drawerOpen = true
              if (root.incoming.length === 0 && !root.pairMode) root.startPair()
            }
          }
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 32
            height: 1
            color: Theme.bg3
            visible: !!root.dev
          }
          Repeater {
            model: root.dev ? root.visibleTabs : []
            delegate: RailButton {
              required property var modelData
              icon: modelData.icon
              tip: modelData.label
              selected: root.currentTab && root.currentTab.key === modelData.key
              onClicked: root.tab = modelData.key
            }
          }
        }
      }
    }

    // The sidebar scrolls when the devices and tabs are taller than the
    // window. The scroll bar shows only on hover or while it moves.
    HoverHandler { id: sideHover }

    Flickable {
      id: sideFlick
      anchors.fill: parent
      visible: root.sidebarFull
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

          PairCard {
            id: pairCard
            visible: !!root.pairRequest
            width: side.width
            device: root.pairRequest || ({})
            motion: [sideFlick.contentY, root.sidebarFull, sidebar.width]
            // The key binds the answer to the pairing that the card shows.
            onAccept: root.call("pair.accept", { device: pairCard.device.id, key: pairCard.device.pairKey })
            onReject: root.call("pair.reject", { device: pairCard.device.id, key: pairCard.device.pairKey })
          }
          Txt {
            visible: root.incomingRows.length > 1
            width: parent.width
            leftPadding: 4
            rightPadding: 4
            text: root.incomingRows.length === 2 ? "1 more device asks to pair" : (root.incomingRows.length - 1) + " more devices ask to pair"
            color: Theme.warn
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }

          Repeater {
            model: root.pairedRows
            delegate: DeviceRow {
              required property var modelData
              width: side.width
              device: modelData
              selected: !!root.dev && root.dev.id === modelData.id
              onClicked: {
                root.selectedId = modelData.id
                root.drawerOpen = false
              }
              onSelectedChanged: if (selected) Qt.callLater(root.revealInSidebar, this)
            }
          }

          DashedRect {
            id: pairButton
            width: parent.width
            height: pairLabel.implicitHeight + 18
            color: pairArea.containsMouse ? Theme.dim : Theme.edge
            Row {
              id: pairLabel
              anchors.centerIn: parent
              width: Math.min(implicitWidth, parent.width - 18)
              spacing: 6
              readonly property color tint: root.justPaired !== "" ? Theme.ok : Theme.dim
              Icon {
                id: pairIcon
                anchors.verticalCenter: parent.verticalCenter
                name: root.requested ? "key" : (root.justPaired !== "" ? "check" : "plus")
                size: 14
                color: pairLabel.tint
              }
              Txt {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, pairButton.width - 18 - pairIcon.width - 6)
                // The key has its own line, so all of its groups show.
                wrapMode: Text.Wrap
                color: pairLabel.tint
                font.pixelSize: 12
                text: {
                  if (root.requested) {
                    var key = Fmt.hexGroups(root.requested.pairKey)
                    var name = Fmt.showControls(root.requested.name)
                    return key !== "" ? "Confirm on " + name + "\n" + key : "Waiting for " + name + "…"
                  }
                  if (root.justPaired !== "") return root.justPaired + " paired"
                  return "Pair new device"
                }
              }
            }
            MouseArea {
              id: pairArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.requested) root.call("pair.reject", { device: root.requested.id, key: root.requested.pairKey })
                else root.startPair()
              }
            }
          }

          // Devices on the network that are not paired. Each row shows the
          // address and the certificate fingerprint of the device, and marks
          // a name that another device also has.
          Repeater {
            model: root.pairMode ? root.discoveredRows : []
            delegate: DashedRect {
              required property var modelData
              width: side.width
              height: Math.max(42, candInfo.implicitHeight + 18)
              color: candArea.containsMouse ? Theme.accent : (modelData.twin !== "" ? Theme.warn : Theme.edge)
              Rectangle {
                x: 9
                y: 9
                width: 24
                height: 24
                color: Theme.bg3
                Icon { anchors.centerIn: parent; name: Fmt.kindIcon(modelData.type); color: Theme.dim; size: 15 }
              }
              Column {
                id: candInfo
                x: 43
                y: 9
                width: parent.width - 43 - 56
                Txt {
                  id: candName
                  width: parent.width
                  text: Fmt.showControls(modelData.name)
                  elide: Text.ElideRight
                  font.weight: Font.DemiBold
                }
                Txt {
                  width: parent.width
                  visible: text !== ""
                  text: modelData.ip
                  color: Theme.dim
                  font.pixelSize: 11
                  elide: Text.ElideRight
                }
                Txt {
                  width: parent.width
                  visible: text !== ""
                  text: Fmt.hexGroups(modelData.fingerprint)
                  color: Theme.dim
                  font.pixelSize: 11
                  elide: Text.ElideRight
                }
                Txt {
                  width: parent.width
                  visible: text !== ""
                  topPadding: 2
                  text: modelData.twin
                  color: Theme.warn
                  font.pixelSize: 11
                  wrapMode: Text.Wrap
                }
              }
              Txt {
                anchors.right: parent.right
                anchors.rightMargin: 10
                y: candInfo.y + (candName.height - height) / 2
                text: modelData.pairState === "requested" ? "waiting" : "pair"
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
              required property int index
              readonly property bool sel: root.currentTab && root.currentTab.key === modelData.key
              width: side.width
              height: tabLabel.implicitHeight + 16
              color: sel ? Theme.alpha(Theme.accent, 0.18) : (tabArea.containsMouse ? Theme.alpha(Theme.fg, 0.05) : "transparent")
              Icon {
                id: tabIcon
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                name: modelData.icon
                size: 16
                color: parent.sel ? Theme.accent : Theme.dim
              }
              Txt {
                id: tabLabel
                anchors.left: tabIcon.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: parent.sel ? Theme.accent : Theme.fg
              }
              // The number key that opens the tab.
              Txt {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: index < 9 && (parent.sel || tabArea.containsMouse)
                text: index + 1
                color: Theme.dim
                font.pixelSize: 11
              }
              MouseArea {
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.tab = modelData.key
                  root.drawerOpen = false
                }
              }
            }
          }
        }
      }
    }
  }

  // An icon button of the rail, with a tooltip. dot marks a state, such as
  // a connected device.
  component RailButton: Rectangle {
    id: rb
    property string icon: ""
    property string tip: ""
    property bool selected: false
    property color dot: "transparent"
    signal clicked()
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    width: 44
    height: 40
    color: selected ? Theme.alpha(Theme.accent, 0.18) : (rbArea.containsMouse ? Theme.alpha(Theme.fg, 0.06) : "transparent")
    Icon {
      anchors.centerIn: parent
      name: rb.icon
      size: 18
      color: rb.selected ? Theme.accent : Theme.fg
    }
    Rectangle {
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 7
      width: 7
      height: 7
      radius: 3.5
      color: rb.dot
    }
    MouseArea {
      id: rbArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rb.clicked()
    }
    // The tip can hold a device name from the phone, so it shows as plain
    // text. The default tooltip text detects rich text.
    ToolTip {
      id: tipBox
      visible: rbArea.containsMouse && rb.tip !== ""
      delay: 400
      text: rb.tip
      contentItem: Text {
        text: tipBox.text
        font: tipBox.font
        color: tipBox.palette.toolTipText
        textFormat: Text.PlainText
      }
    }
  }

  // Main area
  Item {
    id: main
    anchors.left: parent.left
    anchors.leftMargin: root.sidebarSpace
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

      // The narrow layout has no rail, so the header opens the drawer.
      OutlineButton {
        id: menuButton
        visible: root.narrowLayout
        x: root.gutter
        anchors.verticalCenter: title.verticalCenter
        icon: "menu"
        padX: 8
        padY: 6
        onClicked: root.drawerOpen = true
      }
      Txt {
        id: title
        x: root.narrowLayout ? menuButton.x + menuButton.width + 12 : root.gutter
        width: Math.min(implicitWidth, (actions.visible ? actions.x - 14 : parent.width - root.gutter) - x)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -0.5
        text: root.dev ? root.currentTab.label : "Get started"
        font.pixelSize: root.narrowLayout ? 17 : 20
        font.weight: Font.Bold
        elide: Text.ElideRight
      }
      Txt {
        id: subtitle
        anchors.left: title.right
        anchors.leftMargin: 14
        anchors.right: actions.left
        anchors.rightMargin: 14
        anchors.verticalCenter: title.verticalCenter
        visible: !!root.dev && !root.compactHeader
        text: root.dev ? root.devName + " · " + (root.dev.ip || "—") : ""
        color: Theme.dim
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: root.gutter
        anchors.verticalCenter: title.verticalCenter
        spacing: 8
        visible: !!root.dev
        OutlineButton {
          visible: root.has("findmyphone")
          icon: "bell-ring"
          text: root.compactHeader ? "" : "Ring " + Fmt.noun(root.dev ? root.dev.type : "")
          active: root.devOnline
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.ring()
        }
        AccentButton {
          icon: "paste"
          text: root.compactHeader ? "" : "Send clipboard"
          active: root.devOnline
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.sendClipboard()
        }
        OutlineButton {
          icon: "unlink"
          text: root.compactHeader ? "" : "Unpair"
          textColor: Theme.err
          iconColor: Theme.err
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.unpair()
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
        x: root.gutter
        y: root.narrowLayout ? 16 : 24
        width: flick.width - 2 * root.gutter
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
          // A host can set tab when it creates the view. The url then
          // changes before the view is complete, so load only the last url.
          property bool complete: false
          onUrlChanged: if (complete) setSource(url, { view: root })
          Component.onCompleted: {
            complete = true
            setSource(url, { view: root })
          }
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
      width: Math.min(420, parent.width - 32)
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
        icon: "power"
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

  // The update notices. Later hides a release until the window opens
  // again.
  readonly property var update: (backend && backend.state && backend.state.update) || ({})
  property string laterVersion: ""
  // The first connected phone with a newer Android app in the release.
  property var laterApp: ({})
  readonly property var appUpdateDevice: paired.find(d => d.online && d.appUpdate && !laterApp[d.id + " " + d.appUpdate]) || null
  Column {
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.margins: 16
    width: Math.min(360, root.width - 32)
    spacing: 10
    z: 9
    NoticeBar {
      width: parent.width
      visible: root.daemonUp && !!root.update.available && root.update.latest !== root.laterVersion && !root.appReplaced
      title: "Flux " + (root.update.latest || "") + " is available"
      message: "This computer has Flux " + ((root.backend && root.backend.selfDevice && root.backend.selfDevice.version) || "") + ". Update opens a terminal that runs flux-cli update."
      action: "Update"
      secondary: "Later"
      onActivated: root.call("update.install", {})
      onSecondaryActivated: root.laterVersion = root.update.latest
    }
    NoticeBar {
      width: parent.width
      visible: root.daemonUp && !!root.appUpdateDevice
      title: "Flux for Android " + (root.appUpdateDevice ? root.appUpdateDevice.appUpdate : "") + " is available"
      message: root.appUpdateDevice ? root.appUpdateDevice.name + " has Flux " + root.appUpdateDevice.appVersion + ". Send the new app, then open its notification on the phone to install it." : ""
      action: "Send to phone"
      secondary: "Later"
      onActivated: root.call("update.sendApp", { device: root.appUpdateDevice.id })
      onSecondaryActivated: {
        var later = Object.assign({}, root.laterApp)
        later[root.appUpdateDevice.id + " " + root.appUpdateDevice.appUpdate] = true
        root.laterApp = later
      }
    }
    NoticeBar {
      width: parent.width
      visible: root.appReplaced
      title: "Flux was updated"
      message: "This window runs the earlier version. Restart it to use the new version."
      action: "Restart"
      onActivated: root.restartApp()
    }
  }

  // The unpair confirm dialog. A full-window scrim blocks the page behind
  // it, and the card holds the question and the actions. It is a plain item
  // in this view so both hosts render it. The scrim takes the keyboard while
  // it is open, so Escape closes the dialog.
  Item {
    id: unpairScrim
    anchors.fill: parent
    z: 30
    visible: !!root.unpairTarget
    focus: visible
    Keys.onEscapePressed: root.unpairTarget = null

    Rectangle {
      anchors.fill: parent
      color: Theme.alpha(Theme.bg, 0.6)
      MouseArea {
        anchors.fill: parent
        onClicked: root.unpairTarget = null
      }
    }

    Card {
      anchors.centerIn: parent
      width: Math.min(400, parent.width - 32)
      height: unpairCol.implicitHeight + 40

      // A click on the card does not reach the scrim behind it and close.
      MouseArea { anchors.fill: parent }

      Column {
        id: unpairCol
        x: 20
        y: 20
        width: parent.width - 40
        spacing: 10

        Txt {
          width: parent.width
          text: "Unpair " + (root.unpairTarget ? (root.unpairTarget.name || "device") : "device") + "?"
          font.pixelSize: 16
          font.weight: Font.DemiBold
          wrapMode: Text.Wrap
        }
        Txt {
          width: parent.width
          text: "This removes the device from Flux on this computer and on the device. You can pair it again later."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
        Item { width: 1; height: 2 }
        // RightToLeft puts Unpair on the right, the primary action.
        Row {
          width: parent.width
          spacing: 8
          layoutDirection: Qt.RightToLeft
          OutlineButton {
            text: "Unpair"
            textColor: Theme.err
            onClicked: root.confirmUnpair()
          }
          OutlineButton {
            text: "Cancel"
            onClicked: root.unpairTarget = null
          }
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
