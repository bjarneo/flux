import QtQuick
import QtTest
import "../qml"
import "../qml/components"
import "../qml/tools"

// Checks of the shared views with the mock backend. To run them from the
// repository root:
//   QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 qmltestrunner -input gui/tests
Item {
  id: top
  width: 1180
  height: 760

  readonly property string pixel: "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93"
  readonly property string other: "a0000000000000000000000000000006"

  MockBackend { id: mock }

  Component {
    id: viewComponent
    FluxView { width: 1180; height: 760; backend: mock }
  }

  Component {
    id: keyedComponent
    KeyedModel {}
  }

  // The page item of the view, or null.
  function page(view) {
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

  function findBy(item, prop, value) {
    if (!item) return null
    if (item[prop] === value) return item
    for (var i = 0; i < item.children.length; i++) {
      var r = findBy(item.children[i], prop, value)
      if (r) return r
    }
    return null
  }

  function requestsOf(method) {
    return mock.requests.filter(function (r) { return r.method === method })
  }

  TestCase {
    name: "Fmt"

    function test_tablesIgnorePrototypeMembers() {
      var names = ["Constructor", "__proto__", "hasOwnProperty", "toString", "valueOf"]
      var tokens = ["ok", "warn", "alt", "accent", "err"]
      for (var i = 0; i < names.length; i++) {
        compare(Fmt.appIcon(names[i]), "bell", names[i])
        verify(tokens.indexOf(Fmt.appToken(names[i])) >= 0, names[i])
      }
      compare(Fmt.glyph("constructor"), "")
      compare(Fmt.appIcon("Signal"), "chat")
    }

    function test_urlToPath() {
      compare(Fmt.urlToPath("file:///home/u/a%20b.txt"), "/home/u/a b.txt")
      compare(Fmt.urlToPath("file://localhost/home/u/notes"), "/home/u/notes")
      compare(Fmt.urlToPath("file:/home/u/x"), "/home/u/x")
      compare(Fmt.urlToPath("trash:///notes.txt"), "")
      compare(Fmt.urlToPath("file://server/share/notes.txt"), "")
      compare(Fmt.urlToPath("sftp://host/home/u/notes.txt"), "")
      compare(Fmt.urlToPath("notes.txt"), "")
      compare(Fmt.urlToPath("file:///home/u/%E0%A4%A"), "")
      compare(Fmt.urlToPath("file:///home/u/a%00b"), "")
    }

    function test_hexGroups() {
      compare(Fmt.hexGroups("5EE6825F974ED59A"), "5EE6 825F 974E D59A")
      compare(Fmt.hexGroups("5bb22db11047f34b"), "5BB2 2DB1 1047 F34B")
      compare(Fmt.hexGroups("4F21A9C3"), "4F21 A9C3")
      compare(Fmt.hexGroups(""), "")
    }

    function test_showControls() {
      compare(Fmt.showControls("invoice\u202Efdp.exe"), "invoice[U+202E]fdp.exe")
      compare(Fmt.showControls("a\u2066b\u2069c\u200Fd\nE"), "a[U+2066]b[U+2069]c[U+200F]d[U+000A]E")
      compare(Fmt.showControls("photo 2026.jpg"), "photo 2026.jpg")
    }

    function test_nameKey() {
      compare(Fmt.nameKey(" Pixel  8 "), "pixel 8")
      compare(Fmt.nameKey("Pixel\u202E 8\u200B"), "pixel 8")
    }
  }

  TestCase {
    name: "KeyedModel"

    function test_prototypeKeys() {
      var model = createTemporaryObject(keyedComponent, top)
      var list = [{ id: "__proto__", v: 1 }, { id: "hasOwnProperty", v: 2 }, { id: "constructor", v: 3 }, { id: "a", v: 4 }]
      model.values = list
      compare(model.count, 4)
      compare(model.byId["hasOwnProperty"].v, 2)
      compare(model.byId["__proto__"].v, 1)
      compare(model.byId["constructor"].v, 3)
      // New objects with the same keys keep the rows.
      var removed = 0
      var inserted = 0
      model.rowsRemoved.connect(function () { removed++ })
      model.rowsInserted.connect(function () { inserted++ })
      model.values = list.map(function (o) { return { id: o.id, v: o.v + 10 } })
      compare(removed, 0)
      compare(inserted, 0)
      compare(model.byId["hasOwnProperty"].v, 12)
    }

    function test_duplicateKeys() {
      var model = createTemporaryObject(keyedComponent, top)
      model.values = [{ id: "a" }, { id: "a#1" }, { id: "a" }]
      compare(model.count, 3)
      var keys = [model.get(0).key, model.get(1).key, model.get(2).key]
      compare(keys.filter(function (k, i) { return keys.indexOf(k) === i }).length, 3)
    }

    function test_scopeRebuildsRows() {
      var model = createTemporaryObject(keyedComponent, top)
      model.values = [{ id: "n1" }, { id: "n2" }]
      var removed = 0
      model.rowsRemoved.connect(function () { removed++ })
      model.scope = "other device"
      verify(removed > 0)
      compare(model.count, 2)
    }
  }

  TestCase {
    name: "Messages"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.failures = {}
      mock.requests = []
    }

    function test_deviceSwitchResetsThread() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && !!page(view).selected })
      var p = page(view)
      p.open(p.convos.filter(function (c) { return c.thread === 1 })[0])
      tryCompare(p, "loaded", true)
      verify(p.messages.length > 0)

      mock.setState(function (s) {
        s.devices.push({ id: top.other, name: "Pixel 7a", type: "phone", paired: true, online: true, pairState: "paired", plugins: ["sms"], notifications: [], conversations: [
          { thread: 7, name: "Kari", address: "+4790011223", addresses: ["+4790011223"], last: "See you", time: 1 }
        ] })
      })
      view.selectedId = top.other
      compare(p.devId, top.other)
      // The thread of the first phone is gone at once, and the first
      // conversation of the new phone loads.
      verify(!p.selected || p.selectedDev === top.other)
      compare(p.outbox.length, 0)
      tryVerify(function () { return !!p.selected && p.selected.thread === 7 })
      compare(p.selectedDev, top.other)

      findBy(p, "placeholder", "Text message via Pixel 7a").text = "On my way"
      p.send()
      var sent = requestsOf("sms.send")
      compare(sent.length, 1)
      compare(sent[0].params.device, top.other)
      compare(sent[0].params.addresses, ["+4790011223"])
    }

    function test_sendRefusesThreadOfOtherDevice() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && !!page(view).selected })
      var p = page(view)
      findBy(p, "placeholder", "Text message via Pixel 8").text = "Hello"
      // A thread that the page holds for another device.
      p.selectedDev = "b71c04e9d2a84f3e9c6a5d1b0e8f2c47"
      p.send()
      compare(requestsOf("sms.send").length, 0)
    }

    function test_loadErrorShowsRetry() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded })
      var p = page(view)
      mock.failures = { "sms.thread": { code: "timeout", message: "Pixel 8 did not send the conversation" } }
      p.open(p.convos.filter(function (c) { return c.thread === 2 })[0])
      // The messages of the earlier thread do not show under the new name.
      compare(p.messages.length, 0)
      tryCompare(p, "loading", false)
      compare(p.loadError, "Pixel 8 did not send the conversation")
      var retry = findBy(p, "text", "Retry")
      verify(!!retry && retry.visible)

      mock.failures = {}
      retry.clicked()
      tryCompare(p, "loaded", true)
      compare(p.loadError, "")

      // Thread 2 opens again before thread 3 answers, and its load fails.
      mock.failures = { "sms.thread": { code: "timeout", message: "slow phone" } }
      var two = p.selected
      p.open(p.convos.filter(function (c) { return c.thread === 3 })[0])
      p.open(two)
      compare(p.messages.length, 0)
      verify(p.loading)
      verify(!p.loaded)
      tryCompare(p, "loading", false)
      compare(p.selected.thread, 2)
      compare(p.loadError, "slow phone")
      verify(!p.loaded)
      retry = findBy(p, "text", "Retry")
      verify(!!retry && retry.visible)
      mock.failures = {}
    }
  }

  TestCase {
    name: "PairRequests"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.requests = []
    }

    function request(id, key) {
      mock.setState(function (s) {
        s.devices = s.devices.filter(function (d) { return d.id !== id })
        s.devices.push({ id: id, name: "work-thinkpad", type: "laptop", ip: "192.168.1.70", paired: false, online: true, pairState: "incoming", pairKey: key, plugins: [], notifications: [], conversations: [] })
      })
    }

    function test_drawerOpensOncePerRequest() {
      var view = createTemporaryObject(viewComponent, top)
      view.width = 600
      tryVerify(function () { return view.allDevices.length > 0 })
      request("c0ffee0000000000000000000000beef", "9B03E7D16A2FC048")
      verify(view.drawerOpen)
      view.drawerOpen = false
      // The same request again, with a new key, and an unrelated event.
      request("c0ffee0000000000000000000000beef", "1111222233334444")
      mock.updateDevice(top.pixel, function (d) { d.battery = { charge: 10, charging: false }; return d })
      verify(!view.drawerOpen)
      // A new request opens the drawer again. The card keeps the first.
      request("c0ffee0000000000000000000000cafe", "5555666677778888")
      verify(view.drawerOpen)
      compare(view.pairRequest.id, "c0ffee0000000000000000000000beef")
    }

    function test_acceptArmsAfterDelay() {
      var view = createTemporaryObject(viewComponent, top)
      tryVerify(function () { return view.allDevices.length > 0 })
      request("c0ffee0000000000000000000000beef", "9B03E7D16A2FC048")
      var card = findBy(view, "armKey", "c0ffee0000000000000000000000beef:9B03E7D16A2FC048")
      verify(!!card)
      verify(!card.armed)
      tryCompare(card, "armed", true, 3000)
      // A new key starts the wait again.
      request("c0ffee0000000000000000000000beef", "1111222233334444")
      verify(!card.armed)
      tryCompare(card, "armed", true, 3000)
      // A resend without the address hides a line, which moves Accept.
      mock.setState(function (s) {
        s.devices.forEach(function (d) { if (d.id === "c0ffee0000000000000000000000beef") d.ip = "" })
      })
      // The column lays out its lines before the next frame.
      tryVerify(function () { return !card.armed }, 500)
      tryCompare(card, "armed", true, 3000)
    }

    function test_discoveredTwinIsMarked() {
      var view = createTemporaryObject(viewComponent, top)
      tryVerify(function () { return view.allDevices.length > 0 })
      mock.setState(function (s) {
        s.devices.push({ id: "a0000000000000000000000000000005", name: "pixel  8", type: "phone", ip: "192.168.1.66", fingerprint: "E7A10C5F2B98D364", paired: false, online: true, pairState: "none", plugins: [], notifications: [], conversations: [] })
      })
      var row = view.discoveredRows.find(function (d) { return d.id === "a0000000000000000000000000000005" })
      compare(row.twin, "Same name as a paired device")
      compare(row.fingerprint, "E7A10C5F2B98D364")
      var oneplus = view.discoveredRows.find(function (d) { return d.name === "OnePlus 12" })
      compare(oneplus.twin, "")
    }
  }

  TestCase {
    name: "PhoneText"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.requests = []
    }

    // The tooltip of a rail button, found by its text.
    function findTip(obj, text) {
      if (!obj) return null
      if (obj.delay === 400 && obj.text === text && obj.contentItem !== undefined) return obj
      var kids = obj.data || []
      for (var i = 0; i < kids.length; i++) {
        var r = findTip(kids[i], text)
        if (r) return r
      }
      return null
    }

    function test_railTooltipIsPlainText() {
      mock.updateDevice(top.pixel, function (d) { d.name = "<b>Pixel</b>"; return d })
      var view = createTemporaryObject(viewComponent, top)
      view.width = 800
      var tip = null
      tryVerify(function () { tip = findTip(view, "<b>Pixel</b> · connected"); return !!tip })
      compare(tip.contentItem.textFormat, Text.PlainText)
    }

    function test_notificationWithPrototypeId() {
      mock.updateDevice(top.pixel, function (d) {
        d.notifications = [{ id: "hasOwnProperty", app: "Constructor", title: "Hello", text: "", time: 1, dismissable: true, actions: [] }]
        return d
      })
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "notifications"
      tryVerify(function () { return !!page(view) && !!findBy(page(view), "text", "Hello") })
      var close = findBy(page(view), "text", "×")
      verify(!!close)
      close.children[0].clicked(null)
      var sent = requestsOf("notification.dismiss")
      compare(sent.length, 1)
      compare(sent[0].params.id, "hasOwnProperty")
    }
  }
}
