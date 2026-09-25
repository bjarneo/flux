import QtQuick
import ".."

// Renders every screen of FluxView from the fixture into PNG files, then
// quits. It needs only QtQuick:
//   QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML_XHR_ALLOW_FILE_READ=1 \
//   FLUX_SNAPSHOT=<dir> qml6 gui/qml/tools/Snapshot.qml
// Arguments after "--" also work: -- <dir> [only] [theme=<colors.toml>] [size=<w>x<h>].
// Environment: FLUX_SNAPSHOT, FLUX_SNAPSHOT_ONLY (a part of a screen name),
// FLUX_THEME_FILE (a colors.toml; empty gives the Tokyo Night defaults).
Window {
  id: win
  // size=<width>x<height>, or FLUX_SNAPSHOT_SIZE, renders at another size.
  readonly property var size: (arg("size") || env.FLUX_SNAPSHOT_SIZE || "1180x760").split("x")
  width: parseInt(size[0]) || 1180
  height: parseInt(size[1]) || 760
  visible: true
  color: Theme.bg

  // qml6 has no environment API, so the harness reads /proc/self/environ.
  readonly property var env: {
    var out = {}
    var x = new XMLHttpRequest()
    x.open("GET", "file:///proc/self/environ", false)
    x.send()
    var parts = (x.responseText || "").split("\u0000")
    for (var i = 0; i < parts.length; i++) {
      var k = parts[i].indexOf("=")
      if (k > 0) out[parts[i].slice(0, k)] = parts[i].slice(k + 1)
    }
    return out
  }

  readonly property var args: {
    var a = Qt.application.arguments
    var i = a.indexOf("--")
    return i >= 0 ? a.slice(i + 1) : []
  }

  function arg(key) {
    for (var i = 0; i < args.length; i++)
      if (args[i].indexOf(key + "=") === 0) return args[i].slice(key.length + 1)
    return ""
  }

  readonly property var positional: args.filter(function (a) { return a.indexOf("=") < 0 })
  readonly property string out: positional.length > 0 ? positional[0] : (env.FLUX_SNAPSHOT || "")
  readonly property string only: positional.length > 1 ? positional[1] : (env.FLUX_SNAPSHOT_ONLY || "")
  readonly property string themeFile: arg("theme") || env.FLUX_THEME_FILE || ""

  function readFile(path) {
    if (!path) return ""
    var x = new XMLHttpRequest()
    x.open("GET", "file://" + path, false)
    x.send()
    return x.responseText || ""
  }

  MockBackend { id: mock }

  FluxView {
    id: view
    anchors.fill: parent
    backend: mock
    themeText: win.readFile(win.themeFile)
  }

  readonly property string pixel: "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93"
  readonly property string iphone: "b71c04e9d2a84f3e9c6a5d1b0e8f2c47"
  readonly property string tablet: "5d2e9f1a7c3b4e8d9a0f6c2b1e7d4a38"
  readonly property string oneplus: "e4a1c8f2b9d3470a8c5e6f1d2b9a7c30"

  // Each step prepares the view. The harness waits, then saves a PNG.
  property var steps: [
    ["01-overview", function () { view.selectedId = pixel; view.tab = "overview" }],
    ["02-camera-starting", function () { mock.setState(function (s) { s.webcam.active = false }) }],
    ["03-camera-error", function () { mock.setState(function (s) { s.webcam.error = "The v4l2loopback module is not loaded. Run: sudo modprobe v4l2loopback" }) }],
    ["04-camera-settings", function () { mock.setState(function (s) { s.webcam = mock.fixture.state.webcam }) }, function () { camera().settingsOpen = true ; scrollToEnd() }],
    ["05-camera-settings-changed", function () {
      var c = camera()
      c.setKey("zoom", 2.5)
      c.setKey("exposure", 0.666)
      c.setKey("warmth", 0.3)
      c.setKey("whiteBalance", "daylight")
      c.setKey("mirror", true)
    }, function () { scrollToEnd() }],
    ["06-camera-restarting", function () { camera().setKey("aspect", "4:3") }, function () { scrollToEnd() }, 300],
    ["07-camera-restarted", function () {}, function () { scrollToEnd() }, 1500],
    ["08-camera-narrow", function () { view.anchors.fill = undefined; view.width = 900; view.height = 760 }, function () { scrollToEnd() }],
    ["09-camera-closed", function () { view.anchors.fill = win.contentItem; camera().settingsOpen = false }],
    ["10-camera-stopped", function () { mock.call("webcam.stop", {}, null) }],
    ["11-streams-error", function () {
      mock.setState(function (s) { s.mic = { error: "pw-cat is not installed on the computer. Install it with: sudo pacman -S pipewire", source: "Flux Microphone" } })
    }, function () { scrollToEnd() }],
    ["12-streams-stopped", function () { mock.call("mic.stop", {}, null); mock.call("screen.stop", {}, null) }],
    ["13-clipboard", function () { mock.setState(function (s) { s.webcam = mock.fixture.state.webcam }); view.tab = "clipboard" }],
    ["14-files", function () { view.tab = "files" }],
    ["15-notifications", function () { view.tab = "notifications" }],
    ["16-media", function () { view.tab = "media" }],
    ["17-messages", function () { view.tab = "messages" }],
    ["18-browse", function () { view.tab = "browse" }],
    ["19-commands", function () { view.tab = "commands" }],
    ["20-commands-form", function () { view.tab = "commands" }, function () {
      pageItem().openForm()
      setField("Name", "Screenshot")
      setField("omarchy-system-lock", "omarchy-capture-screenshot fullscreen save")
    }],
    ["21-commands-empty", function () { pageItem().cancel(); mock.setState(function (s) { s.commands = [] }); view.tab = "commands" }],
    ["22-commands-offline", function () {
      if (pageItem().cancel) pageItem().cancel()
      mock.state = mock.fixTimes(mock.fixture.state)
      view.selectedId = tablet
      view.tab = "commands"
    }],
    ["23-pair-list", function () { view.tab = "overview"; view.pairMode = true }],
    ["24-pair-requested", function () {
      mock.updateDevice(oneplus, function (d) { d.pairState = "requested"; d.pairKey = "4F21A9C3"; return d })
    }],
    ["25-paired", function () {
      mock.updateDevice(oneplus, function (d) { d.pairState = "paired"; d.paired = true; d.pairedAt = "2026-09-25"; d.battery = { charge: 91, charging: false }; d.signal = { type: "5G", strength: 4 }; return d })
    }],
    ["26-pair-incoming", function () {
      mock.setState(function (s) {
        s.devices.push({ id: "c0ffee0000000000000000000000beef", name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: "9B03E7D1", plugins: [], notifications: [], conversations: [] })
      })
      view.selectedId = pixel
    }],
    ["27-iphone", function () {
      mock.setState(function (s) { s.devices = s.devices.filter(function (d) { return d.pairState !== "incoming" }) })
      view.selectedId = iphone; view.tab = "overview"
    }],
    ["28-offline", function () { view.selectedId = tablet; view.tab = "overview" }],
    ["29-offline-files", function () { view.tab = "files" }],
    ["30-toast", function () { view.selectedId = pixel; view.tab = "overview"; view.toast("Clipboard sent to Pixel 8") }],
    ["31-ringing", function () { view.toast(""); mock.setState(function (s) { s.ringing = true }) }],
    ["32-notif-reply", function () { mock.setState(function (s) { s.ringing = false }); view.tab = "notifications" }, function () { replyFirst() }],
    ["33-browse-deeper", function () { view.tab = "browse" }, function () { var p = pageItem(); p.list(p.root_, p.root_.path + "/Camera") }],
    ["34-empty", function () { mock.setState(function (s) { s.devices = [] }) }],
    ["35-not-running", function () { mock.connected = false }],
    // Sidebar overflow at the 640 px minimum height: 6 paired devices, a pair
    // request, and the list of discovered devices.
    ["36-sidebar-640-top", function () {
      mock.connected = true
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.setState(function (s) {
        s.devices.forEach(function (d) { if (d.id === oneplus) { d.paired = true; d.pairState = "paired"; d.pairedAt = "2026-09-25"; d.battery = { charge: 91, charging: false } } })
        s.devices.push({ id: "a0000000000000000000000000000001", name: "Pixel 7a", type: "phone", ip: "192.168.1.80", paired: true, online: true, pairState: "paired", pairedAt: "2026-01-02", battery: { charge: 55, charging: false }, plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000002", name: "Living room TV", type: "tv", ip: "", paired: true, online: false, pairState: "paired", pairedAt: "2025-11-30", battery: null, plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000003", name: "Nothing Phone 2", type: "phone", ip: "192.168.1.90", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000004", name: "Galaxy S25", type: "phone", ip: "192.168.1.91", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "c0ffee0000000000000000000000beef", name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: "9B03E7D1", plugins: [], notifications: [], conversations: [] })
      })
      view.anchors.fill = undefined
      view.width = 1180
      view.height = 640
      view.selectedId = pixel
      view.tab = "overview"
      view.pairMode = true
    }],
    ["37-sidebar-640-bottom", function () { view.sidebarFlick.contentY = view.sidebarFlick.contentHeight - view.sidebarFlick.height }],
    ["38-sidebar-640-select-last", function () { view.sidebarFlick.contentY = 0; view.selectedId = "a0000000000000000000000000000002"; view.tab = "files" }],
    ["39-sidebar-640-moving", function () { view.sidebarFlick.contentY = 0 }, function () { view.sidebarFlick.flick(0, -1200) }, 60],
    // The drawer of the rail and the narrow layouts, and 1 open thread of a narrow Messages page.
    ["40-drawer", function () {
      view.anchors.fill = win.contentItem
      mock.state = mock.fixTimes(mock.fixture.state)
      view.pairMode = false
      view.selectedId = pixel
      view.tab = "overview"
      view.drawerOpen = true
    }],
    ["41-messages-thread", function () { view.drawerOpen = false; view.tab = "messages" }, function () { pageItem().threadOpen = true }]
  ]

  function pageItem() {
    // The Loader is the second child of the content column.
    return findLoader(view).item
  }

  function findLoader(item) {
    for (var i = 0; i < item.children.length; i++) {
      var c = item.children[i]
      if (c.hasOwnProperty("url") && c.hasOwnProperty("sourceComponent")) return c
      var r = findLoader(c)
      if (r) return r
    }
    return null
  }

  // Sets the text of the Field with this placeholder on the current page.
  function setField(placeholder, text) {
    var f = findBy(pageItem(), "placeholder", placeholder)
    if (f) f.text = text
  }

  function findBy(item, prop, value) {
    if (!item) return null
    if (item[prop] === value) return item
    for (var i = 0; i < item.children.length; i++) {
      var r = findBy(item.children[i], prop, value)
      if (r) return r
    }
    return null
  }

  function camera() { return findBy(pageItem(), "objectName", "cameraCard") }

  // Scrolls the content area to the end, where the camera settings are.
  function scrollToEnd() {
    var f = findBy(view, "objectName", "contentFlick")
    if (f) f.contentY = Math.max(0, f.contentHeight - f.height)
  }

  function replyFirst() {
    // Opens the reply field of the first notification.
    var list = pageItem().children[0]
    for (var i = 0; i < list.children.length; i++) {
      var c = list.children[i]
      if (c.hasOwnProperty("replying") && c.replyable) {
        c.replying = true
        return
      }
    }
  }

  property int index: -1

  function next() {
    index++
    while (index < steps.length && only !== "" && steps[index][0].indexOf(only) < 0) index++
    if (index >= steps.length) {
      console.log("snapshot: done, " + failures + " failed steps")
      Qt.exit(failures > 0 ? 1 : 0)
      return
    }
    run(steps[index][1])
    after.restart()
  }

  // Runs a step function. A step that fails logs the error, and the run
  // goes on, so that 1 broken screen does not stop the others.
  property int failures: 0
  function run(f) {
    try {
      f()
    } catch (e) {
      failures++
      console.warn("snapshot: " + steps[index][0] + " failed: " + e)
    }
  }

  Timer {
    id: after
    interval: 150
    onTriggered: {
      var s = win.steps[win.index]
      if (s.length > 2 && s[2]) win.run(s[2])
      shoot.interval = s.length > 3 ? s[3] : 500
      shoot.restart()
    }
  }

  Timer {
    id: shoot
    interval: 500
    onTriggered: {
      var name = win.steps[win.index][0]
      view.grabToImage(function (result) {
        var file = win.out + "/" + name + ".png"
        result.saveToFile(file)
        console.log("snapshot:", file)
        win.next()
      })
    }
  }

  Timer {
    interval: 900
    running: mock.ready
    onTriggered: {
      if (win.out === "") {
        console.warn("snapshot: give an output directory with FLUX_SNAPSHOT or -- <dir>")
        Qt.quit()
        return
      }
      win.next()
    }
  }

}
