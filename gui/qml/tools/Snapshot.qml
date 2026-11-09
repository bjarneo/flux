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
  readonly property string laptop: "d9c3a7e1f5b24c8e0a6d2f9b3c1e5a74"

  // Each step prepares the view. The harness waits, then saves a PNG.
  property var steps: [
    // The chat of a phone: clips, links, and files in both directions,
    // with an image clip and a received photo. The image files are in the
    // repository, so only a harness that runs from the files shows them.
    ["01-chat", function () {
      var icon = Qt.resolvedUrl("../../../macos/App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png").toString()
      var photo = Qt.resolvedUrl("../../../site/img/og.png").toString()
      mock.setState(function (s) {
        if (icon.indexOf("file://") === 0)
          s.clipboard.splice(2, 0, { id: "c0", text: "", image: icon.substring(7), dir: "in", device: pixel, time: Math.floor(Date.now() / 1000) - 500 })
        if (photo.indexOf("file://") === 0)
          s.transfers.forEach(function (t) { if (t.id === "t3") { t.name = "og.png"; t.path = photo.substring(7) } })
        s.clipboard[0].pinned = true
      })
      view.selectedId = pixel
      view.tab = "chat"
    }],
    ["02-chat-compose", function () { view.tab = "chat" }, function () {
      pageItem().focusComposer("")
      findBy(pageItem(), "placeholder", "Text or a link for Pixel 8").text = "Running 10 minutes late.\nStart without me."
    }],
    ["03-chat-search", function () { view.forceActiveFocus(); view.tab = "chat" }, function () {
      findBy(pageItem(), "placeholder", "Search the chat").text = "omarchy"
    }, 700],
    ["04-chat-saved", function () { view.tab = "chat" }, function () {
      findBy(pageItem(), "placeholder", "Search the chat").text = ""
      pageItem().savedOnly = true
    }],
    ["05-chat-error", function () {
      pageItem().savedOnly = false
      mock.failures = { "clipboard.send": { code: "disabled", message: "Clipboard access is off for this device" } }
    }, function () {
      findBy(pageItem(), "placeholder", "Text or a link for Pixel 8").text = "Gate B14"
      pageItem().send()
    }],
    ["06-chat-narrow", function () {
      mock.failures = {}
      view.anchors.fill = undefined
      view.width = 560
      view.height = 760
    }],
    ["07-chat-empty", function () {
      view.anchors.fill = win.contentItem
      view.selectedId = tablet
      view.tab = "chat"
    }],
    // The top of the chat, with the rule of the day before.
    ["08-chat-top", function () { view.selectedId = pixel; view.tab = "chat" }, function () {
      findBy(pageItem(), "objectName", "chatList").positionViewAtEnd()
    }],
    ["10-device", function () { view.selectedId = pixel; view.tab = "device" }],
    ["11-camera-starting", function () { mock.setState(function (s) { s.webcam.active = false }) }, function () { scrollTo(camera()) }],
    ["12-camera-error", function () { mock.setState(function (s) { s.webcam.error = "The v4l2loopback module is not loaded. Run: sudo modprobe v4l2loopback" }) }, function () { scrollTo(camera()) }],
    ["13-camera-settings", function () { mock.setState(function (s) { s.webcam = mock.fixture.state.webcam }) }, function () { camera().settingsOpen = true; scrollTo(camera()) }],
    ["14-camera-settings-changed", function () {
      var c = camera()
      c.setKey("zoom", 2.5)
      c.setKey("exposure", 0.666)
      c.setKey("warmth", 0.3)
      c.setKey("whiteBalance", "daylight")
      c.setKey("mirror", true)
    }, function () { scrollTo(camera()) }],
    ["15-camera-restarting", function () { camera().setKey("aspect", "4:3") }, function () { scrollTo(camera()) }, 300],
    ["16-camera-restarted", function () {}, function () { scrollTo(camera()) }, 1500],
    ["17-camera-narrow", function () { view.anchors.fill = undefined; view.width = 900; view.height = 760 }, function () { scrollTo(camera()) }],
    ["18-camera-closed", function () { view.anchors.fill = win.contentItem; camera().settingsOpen = false }, function () { scrollTo(camera()) }],
    ["19-camera-stopped", function () { mock.call("webcam.stop", {}, null) }, function () { scrollTo(findBy(pageItem(), "objectName", "micCard")) }],
    ["20-streams-error", function () {
      mock.setState(function (s) { s.mic = { error: "pw-cat is not installed on the computer. Install it with: sudo pacman -S pipewire", source: "Flux Microphone" } })
    }, function () { scrollTo(findBy(pageItem(), "objectName", "micCard")) }],
    ["21-streams-stopped", function () { mock.call("mic.stop", {}, null); mock.call("screen.stop", {}, null) }],
    ["22-commands", function () { view.tab = "device" }, function () { scrollTo(commands()) }],
    ["23-commands-form", function () { view.tab = "device" }, function () {
      commands().openForm()
      setField("Name", "Screenshot")
      setField("omarchy-system-lock", "omarchy-capture-screenshot fullscreen save")
      scrollTo(commands())
    }],
    ["24-commands-empty", function () { commands().cancel(); mock.setState(function (s) { s.commands = [] }) }, function () { scrollTo(commands()) }],
    ["25-notifications", function () {
      mock.setState(function(s) {
        s.settings.notificationRules = [
          { id: "rule1", app: "A notification app with a long display name", mode: "mute", until: Math.floor(Date.now() / 1000) + 3600 },
          { id: "rule2", app: "Calendar", mode: "silent", until: Math.floor(Date.now() / 1000) - 1 }
        ]
      })
      view.tab = "notifications"
    }],
    ["26-messages", function () { view.tab = "messages" }],
    // The tablet is offline and lists no features.
    ["27-offline", function () {
      mock.state = mock.fixTimes(mock.fixture.state)
      view.selectedId = tablet
      view.tab = "device"
    }],
    // "overview" is the key of the page before Phone. It still opens the page.
    ["28-pair-list", function () { view.tab = "overview"; view.pairMode = true }],
    ["29-pair-requested", function () {
      mock.updateDevice(oneplus, function (d) { d.pairState = "requested"; d.pairKey = "4F21A9C3E08B7D52"; return d })
    }],
    // The phone accepted, and this computer confirms the key.
    ["30-pair-confirm", function () {
      mock.updateDevice(oneplus, function () { return JSON.parse(JSON.stringify(mock.fixture.pairing.confirm)) })
    }],
    ["31-paired", function () {
      mock.updateDevice(oneplus, function (d) { d.pairState = "paired"; d.paired = true; d.pairedAt = "2026-09-25"; d.battery = { charge: 91, charging: false }; return d })
    }],
    ["32-pair-incoming", function () {
      mock.setState(function (s) {
        s.devices.push({ id: "c0ffee0000000000000000000000beef", name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: "9B03E7D16A2FC048", fingerprint: "71C0E5A93B2D8F46", plugins: [], notifications: [], conversations: [] })
      })
      view.selectedId = pixel
    }],
    ["33-iphone", function () {
      mock.setState(function (s) { s.devices = s.devices.filter(function (d) { return d.pairState !== "incoming" }) })
      view.selectedId = iphone; view.tab = "device"
    }],
    ["34-iphone-chat", function () { view.tab = "chat" }],
    ["35-offline-chat", function () { view.selectedId = tablet; view.tab = "chat" }],
    ["36-toast", function () { view.selectedId = pixel; view.tab = "chat"; view.toast("Clipboard sent to Pixel 8") }],
    // A paired computer does not list findmyphone, so its page has no Ring button.
    ["37-computer", function () {
      view.toast("")
      mock.setState(function (s) {
        s.devices.push({ id: laptop, name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: true, online: true, pairState: "paired", pairedAt: "2026-09-20", battery: { charge: 64, charging: true }, plugins: ["battery", "clipboard", "share", "notification", "runcommand"], notifications: [], conversations: [] })
      })
      view.selectedId = laptop
      view.tab = "device"
    }],
    ["38-notif-reply", function () {
      mock.setState(function (s) { s.devices = s.devices.filter(function (d) { return d.id !== laptop }) })
      view.selectedId = pixel; view.tab = "notifications"
    }, function () { replyFirst() }],
    ["39-empty", function () { mock.setState(function (s) { s.devices = [] }) }],
    ["40-not-running", function () { mock.connected = false }],
    // Sidebar overflow at the 640 px minimum height: 6 paired devices, a pair
    // request, and the list of discovered devices.
    ["41-sidebar-640-top", function () {
      mock.connected = true
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.setState(function (s) {
        s.devices.forEach(function (d) { if (d.id === oneplus) { d.paired = true; d.pairState = "paired"; d.pairedAt = "2026-09-25"; d.battery = { charge: 91, charging: false } } })
        s.devices.push({ id: "a0000000000000000000000000000001", name: "Pixel 7a", type: "phone", ip: "192.168.1.80", paired: true, online: true, pairState: "paired", pairedAt: "2026-01-02", battery: { charge: 55, charging: false }, plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000002", name: "Living room TV", type: "tv", ip: "", paired: true, online: false, pairState: "paired", pairedAt: "2025-11-30", battery: null, plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000003", name: "Nothing Phone 2", type: "phone", ip: "192.168.1.90", fingerprint: "0E4A7C21D95B3F68", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "a0000000000000000000000000000004", name: "Galaxy S25", type: "phone", ip: "192.168.1.91", fingerprint: "B8F3260D4E1A9C57", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "c0ffee0000000000000000000000beef", name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: "9B03E7D16A2FC048", fingerprint: "71C0E5A93B2D8F46", plugins: [], notifications: [], conversations: [] })
      })
      view.anchors.fill = undefined
      view.width = 1180
      view.height = 640
      view.selectedId = pixel
      view.tab = "chat"
      view.pairMode = true
    }],
    ["42-sidebar-640-bottom", function () { view.sidebarFlick.contentY = view.sidebarFlick.contentHeight - view.sidebarFlick.height }],
    ["43-sidebar-640-select-last", function () { view.sidebarFlick.contentY = 0; view.selectedId = "a0000000000000000000000000000002"; view.tab = "chat" }],
    ["44-sidebar-640-moving", function () { view.sidebarFlick.contentY = 0 }, function () { view.sidebarFlick.flick(0, -1200) }, 60],
    // The drawer of the rail and the narrow layouts, and 1 open thread of a narrow Messages page.
    ["45-drawer", function () {
      view.anchors.fill = win.contentItem
      mock.state = mock.fixTimes(mock.fixture.state)
      view.pairMode = false
      view.selectedId = pixel
      view.tab = "chat"
      view.drawerOpen = true
    }],
    ["46-messages-thread", function () { view.drawerOpen = false; view.tab = "messages" }, function () { pageItem().threadOpen = true }],
    // A group thread with a message that the phone could not send, then the New message form.
    ["47-messages-group", function () { view.tab = "messages" }, function () {
      var p = pageItem()
      p.open(p.convos.filter(function (c) { return c.thread === 4 })[0])
    }],
    ["48-messages-new", function () { view.tab = "messages" }, function () {
      pageItem().compose()
      setField("Phone number", "+47 912 34 567")
      setField("Text message via Pixel 8", "Running 10 minutes late")
    }],
    // An update replaced flux-gui while its window is open.
    ["49-app-updated", function () { view.tab = "chat"; view.appReplaced = true }],
    // A new release, while this computer has an earlier version.
    ["50-update-available", function () {
      view.appReplaced = false
      mock.setState(function (s) {
        s.self.version = "0.6.0"
        s.update = { enabled: true, latest: "0.7.0", available: true, url: "https://github.com/bjarneo/flux/releases/tag/v0.7.0", apk: "", checkedAt: 0, error: "" }
      })
    }],
    // A phone with an earlier Android app, and a computer with the latest release.
    ["51-phone-update", function () {
      mock.setState(function (s) {
        s.self.version = "0.7.0"
        s.update = { enabled: true, latest: "0.7.0", available: false, url: "", apk: "", checkedAt: 0, error: "" }
        for (var i = 0; i < s.devices.length; i++) {
          if (s.devices[i].id === pixel) {
            s.devices[i].app = "android"
            s.devices[i].appVersion = "0.6.0"
            s.devices[i].appUpdate = "0.7.0"
          }
        }
      })
    }],
    // The access card with remote desktop and remote input on for every
    // device, then a phone that shows this screen, then Stop.
    ["52-remote-on", function () {
      mock.state = mock.fixTimes(mock.fixture.state)
      view.selectedId = pixel
      view.tab = "device"
    }, function () {
      access().setGlobal("remoteDesktop", true)
      access().setGlobal("remoteInput", true)
    }],
    ["53-remote-live", function () {
      mock.setState(function (s) { s.desktop = { active: true, to: pixel, toName: "Pixel 8", monitor: "DP-1", width: 2560, height: 1440 } })
    }, function () { scrollTo(findBy(pageItem(), "objectName", "desktopCard")) }],
    ["54-remote-off", function () {
      mock.call("desktop.stop", {}, null)
      access().setGlobal("remoteDesktop", false)
      access().setGlobal("remoteInput", false)
    }, function () { scrollTo(access()) }],
    // A device on the network with the name of a paired phone.
    ["55-pair-twin", function () {
      mock.setState(function (s) {
        s.devices.push({ id: "a0000000000000000000000000000005", name: "pixel  8", type: "phone", ip: "192.168.1.66", fingerprint: "E7A10C5F2B98D364", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
      })
      view.pairMode = true
    }],
    // 2 pair requests: 1 card, and a line for the other request.
    ["56-pair-requests", function () {
      view.pairMode = false
      mock.setState(function (s) {
        s.devices = s.devices.filter(function (d) { return d.id !== "a0000000000000000000000000000005" })
        s.devices.push({ id: "c0ffee0000000000000000000000beef", name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: "9B03E7D16A2FC048", fingerprint: "71C0E5A93B2D8F46", plugins: [], notifications: [], conversations: [] })
        s.devices.push({ id: "c0ffee0000000000000000000000cafe", name: "Pixel\u202E8", type: "phone", ip: "192.168.1.71", paired: false, online: true, pairState: "incoming", pairKey: "2D7E9A04C61B5F83", fingerprint: "94B2F07E3C18A5D6", plugins: [], notifications: [], conversations: [] })
      })
    }, null, 1500],
    // A thread that the phone did not send.
    ["57-messages-error", function () {
      mock.setState(function (s) { s.devices = s.devices.filter(function (d) { return d.pairState !== "incoming" }) })
      mock.failures = { "sms.thread": { code: "timeout", message: "Pixel 8 did not send the conversation" } }
      view.selectedId = pixel
      view.tab = "messages"
    }, function () {
      var p = pageItem()
      p.open(p.convos.filter(function (c) { return c.thread === 2 })[0])
    }],
    // Another phone with SMS: the page shows its conversations and no
    // thread of the first phone.
    ["58-messages-other-phone", function () {
      mock.failures = {}
      mock.setState(function (s) {
        s.devices.push({ id: "a0000000000000000000000000000006", name: "Pixel 7a", type: "phone", ip: "192.168.1.80", fingerprint: "6A0D3E8C91F27B45", paired: true, online: true, pairState: "paired", pairedAt: "2026-01-02", battery: { charge: 55, charging: false }, plugins: ["sms"], notifications: [], conversations: [
          { thread: 7, name: "Kari", address: "+4790011223", addresses: ["+4790011223"], last: "See you at 6", time: Math.floor(Date.now() / 1000) - 600 }
        ] })
      })
      view.selectedId = "a0000000000000000000000000000006"
    }],
    // A message that fluxd refuses. The error shows above the field, and
    // the draft stays.
    ["59-messages-send-error", function () {
      mock.failures = { "sms.send": { code: "bad_params", message: "The message has 1700 characters. Send at most 1600" } }
      view.selectedId = pixel
      view.tab = "messages"
    }, function () {
      setField("Text message via Pixel 8", "See you at the station at 6")
      pageItem().send()
    }],
    // The confirm dialog of Unpair on the page of the phone.
    ["60-unpair-confirm", function () {
      view.selectedId = pixel
      view.tab = "device"
      view.unpair()
    }, function () { scrollToEnd() }],
    // A phone that can start its camera and its mic when this computer
    // asks. No stream runs, so both cards show Start.
    ["61-stream-start", function () {
      view.unpairTarget = null
      mock.setState(function (s) {
        s.webcam = null
        s.mic = null
        for (var i = 0; i < s.devices.length; i++)
          if (s.devices[i].id === pixel) s.devices[i].plugins = s.devices[i].plugins.concat(["streamrequest"])
      })
      view.selectedId = pixel
      view.tab = "device"
    }, function () { scrollTo(camera()) }],
    // After Start, the camera card tells the user to confirm on the phone.
    ["62-stream-asked", function () {}, function () {
      findBy(camera(), "objectName", "startButton").clicked()
      scrollTo(camera())
    }],
    // 2 sent messages in the outbox of fluxd: 1 that the phone did not
    // report in 60 seconds, and 1 on its way. The wait lets the toast of
    // the step before go.
    ["63-messages-outbox", function () {
      var now = Math.floor(Date.now() / 1000)
      mock.setState(function (s) {
        for (var i = 0; i < s.devices.length; i++)
          if (s.devices[i].id === pixel) s.devices[i].outbox = [
            { thread: 1, address: "+4791234567", body: "Yes, we come at 5", time: now - 90, outgoing: true, pending: false, failed: true },
            { thread: 1, address: "+4791234567", body: "Do you need anything from the shop?", time: now - 5, outgoing: true, pending: true, failed: false }
          ]
      })
      view.selectedId = pixel
      view.tab = "messages"
    }, function () {
      var p = pageItem()
      p.open(p.convos.filter(function (c) { return c.thread === 1 })[0])
    }, 2500],
    // o opens Chat with the link of the clipboard in the draft.
    ["64-open-link", function () {
      view.selectedId = pixel
      view.tab = "device"
      view.openLink()
    }],
    // The phone plays the audio of this computer, and fluxd muted the
    // speakers of this computer for it.
    ["65-speaker-live", function () {
      mock.setState(function (s) {
        s.speaker = { active: true, to: pixel, toName: "Pixel 8", rate: 48000, channels: 2, mute: true, muted: "Laptop Speakers" }
        for (var i = 0; i < s.devices.length; i++)
          if (s.devices[i].id === pixel) s.devices[i].plugins = s.devices[i].plugins.concat(["speaker"])
      })
      view.selectedId = pixel
      view.tab = "device"
    }, function () { scrollTo(findBy(pageItem(), "objectName", "speakerCard")) }]
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
  function access() { return findBy(pageItem(), "objectName", "accessCard") }
  function commands() { return findBy(pageItem(), "objectName", "commandList") }

  // Scrolls the content area to the end.
  function scrollToEnd() {
    var f = findBy(view, "objectName", "contentFlick")
    if (f) f.contentY = Math.max(0, f.contentHeight - f.height)
  }

  // Scrolls the content area so that item starts near the top.
  function scrollTo(item) {
    var f = findBy(view, "objectName", "contentFlick")
    if (!f || !item) return
    var y = item.mapToItem(f.contentItem, 0, 0).y - 24
    f.contentY = Math.max(0, Math.min(y, f.contentHeight - f.height))
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
