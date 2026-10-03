import QtQuick
import QtTest
import "../qml"
import "../qml/components"
import "../qml/tools"

// Checks of the shared views with the mock backend. To run them from the
// repository root:
//   make test-gui
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

  // The first visible item with item[prop] === value, or null. Each
  // message of a thread has a hidden "Sending…" line.
  function findVisibleBy(item, prop, value) {
    if (!item || !item.visible) return null
    if (item[prop] === value) return item
    for (var i = 0; i < item.children.length; i++) {
      var r = findVisibleBy(item.children[i], prop, value)
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
    name: "Theme"

    // Stock Omarchy themes with low contrast: 2 light themes and a dark
    // theme.
    readonly property var themes: ({
      "rose-pine": 'background = "#faf4ed"\ndark_background = "#ede7e1"\nselection = "#dfdad9"\nforeground = "#575279"\naccent = "#56949f"\ngreen = "#286983"\nyellow = "#ea9d34"\nred = "#b4637a"\nmagenta = "#907aa9"\n',
      "catppuccin-latte": 'background = "#eff1f5"\ndark_background = "#e3e4e8"\nselection = "#ccd0da"\nforeground = "#4c4f69"\naccent = "#1e66f5"\ngreen = "#40a02b"\nyellow = "#df8e1d"\nred = "#d20f39"\nmagenta = "#ea76cb"\n',
      "miasma": 'background = "#222222"\ndark_background = "#191919"\nselection = "#383838"\nforeground = "#c2c2b0"\naccent = "#78824b"\ngreen = "#5f875f"\nyellow = "#b36d43"\nred = "#685742"\nmagenta = "#bb7744"\n'
    })

    function cleanup() {
      Theme.load("")
    }

    function atLeast(name, what, c, against, need) {
      var r = Theme.contrast(c, against)
      verify(r >= need, name + ": " + what + " " + c + " on " + against + " is " + r.toFixed(2) + ", needs " + need)
    }

    // Checks each role pair of the contrast rules in Theme.qml.
    function checkRules(name) {
      var T = Theme
      var i
      var surfaces = [T.bg, T.bg2]
      for (i = 0; i < 3; i++) atLeast(name, "fg", T.fg, [T.bg, T.bg2, T.bg3][i], 4.5)
      atLeast(name, "fg", T.fg, T.dim, 1.4)
      for (i = 0; i < 2; i++) atLeast(name, "dim", T.dim, surfaces[i], 4.5)
      atLeast(name, "dim", T.dim, T.bg3, 3)
      var fills = ["accent", "ok", "warn", "err", "alt"]
      for (var k = 0; k < fills.length; k++) {
        var c = T[fills[k]]
        for (i = 0; i < 2; i++) atLeast(name, fills[k], c, surfaces[i], 4.5)
        atLeast(name, fills[k], c, T.mix(T.bg2, c, 0.18), 3)
        atLeast(name, fills[k], c, T.mix(T.bg, c, 0.16), 3)
      }
      atLeast(name, "accent", T.accent, T.mix(T.bg2, T.accent, 0.18), 4.5)
      for (i = 0; i < 2; i++) atLeast(name, "edge", T.edge, surfaces[i], 3)
    }

    function test_defaultsMeetTheRules() {
      Theme.load("")
      checkRules("Tokyo Night")
      // A color that meets its needs stays as it is.
      verify(Qt.colorEqual(Theme.accent, "#7aa2f7"))
      verify(Qt.colorEqual(Theme.ok, "#9ece6a"))
      verify(Qt.colorEqual(Theme.bg3, "#292e42"))
    }

    function test_lowContrastThemesMeetTheRules() {
      for (var name in themes) {
        Theme.load(themes[name])
        checkRules(name)
      }
    }

    function test_guardKeepsTheSurfacesAndPassingColors() {
      Theme.load(themes["miasma"])
      // The surfaces come from the theme without a change.
      verify(Qt.colorEqual(Theme.bg, "#222222"))
      verify(Qt.colorEqual(Theme.bg2, "#191919"))
      verify(Qt.colorEqual(Theme.bg3, "#383838"))
      // The foreground passes, so it stays.
      verify(Qt.colorEqual(Theme.fg, "#c2c2b0"))
      // The red of miasma fails, and the guard makes it lighter.
      verify(Theme.luminance(Theme.err) > Theme.luminance("#685742"))
      Theme.load(themes["rose-pine"])
      // In a light theme, the guard makes a color darker.
      verify(Theme.luminance(Theme.warn) < Theme.luminance("#ea9d34"))
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

    // fluxd keeps the outbox, so a sent message keeps its state when the
    // user opens another tab and comes back.
    function test_outboxStaysAfterTabChange() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded })
      var p = page(view)
      compare(p.selected.thread, 1)
      findBy(p, "placeholder", "Text message via Pixel 8").text = "On my way"
      p.send()
      var sent = requestsOf("sms.send")
      compare(sent.length, 1)
      compare(sent[0].params.addresses, ["+4791234567"])
      tryVerify(function () { return !!findVisibleBy(p, "text", "Sending…") })
      compare(p.outbox.length, 1)
      compare(p.outbox[0].thread, 1)

      // The phone does not report the message, and fluxd marks it as failed.
      mock.updateDevice(top.pixel, function (d) {
        d.outbox[0].pending = false
        d.outbox[0].failed = true
        return d
      })
      view.tab = "notifications"
      tryVerify(function () { return !!page(view) && page(view) !== p })
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded && page(view).selected.thread === 1 })
      p = page(view)
      tryVerify(function () { return !!findVisibleBy(p, "text", "Not sent") })
      compare(p.shown[p.shown.length - 1].body, "On my way")

      // A state event that changes no entry keeps the list of the page.
      var before = p.outbox
      mock.updateDevice(top.pixel, function (d) {
        d.battery = { charge: 12, charging: false }
        return d
      })
      verify(p.outbox === before)

      // The phone reports the message, and fluxd removes the entry.
      mock.updateDevice(top.pixel, function (d) {
        d.outbox = []
        return d
      })
      compare(p.outbox.length, 0)
      tryVerify(function () { return !findVisibleBy(p, "text", "Not sent") })
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
      view.drawerOpen = false
      // Both devices withdraw, and 1 of them asks again.
      withdraw("c0ffee0000000000000000000000beef")
      withdraw("c0ffee0000000000000000000000cafe")
      request("c0ffee0000000000000000000000beef", "9999AAAABBBBCCCC")
      verify(!view.drawerOpen)
      // After 5 minutes, the request counts as new again.
      withdraw("c0ffee0000000000000000000000beef")
      var shown = view.requestShown
      shown["c0ffee0000000000000000000000beef"].until = Date.now() - view.requestQuiet - 1000
      view.requestShown = shown
      request("c0ffee0000000000000000000000beef", "DDDDEEEEFFFF0000")
      verify(view.drawerOpen)
    }

    function withdraw(id) {
      mock.setState(function (s) { s.devices = s.devices.filter(function (d) { return d.id !== id }) })
    }

    // The desktop started the pairing, and the device accepted. The card
    // offers Confirm with the delay of Accept, and each answer names the
    // key of the pairing.
    function test_confirmCard() {
      var view = createTemporaryObject(viewComponent, top)
      tryVerify(function () { return view.allDevices.length > 0 })
      var confirm = mock.fixture.pairing.confirm
      mock.updateDevice(confirm.id, function () { return JSON.parse(JSON.stringify(confirm)) })
      compare(view.pairRequest.id, confirm.id)
      verify(!view.discoveredRows.some(function (d) { return d.id === confirm.id }))
      var card = findBy(view, "armKey", confirm.id + ":" + confirm.pairKey)
      verify(!!card && card.visible && card.confirm)
      verify(!!findBy(card, "text", "Confirm the pairing with OnePlus 12"))
      var button = findBy(card, "text", "Confirm")
      verify(!!button)
      verify(!card.armed)
      tryCompare(card, "armed", true, 3000)
      button.clicked()
      var accepts = requestsOf("pair.accept")
      compare(accepts.length, 1)
      compare(accepts[0].params.device, confirm.id)
      compare(accepts[0].params.key, confirm.pairKey)
      card.reject()
      compare(requestsOf("pair.reject")[0].params.key, confirm.pairKey)
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

  TestCase {
    name: "Errors"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.failures = {}
      mock.requests = []
    }

    function cleanup() {
      mock.failures = {}
    }

    function test_smsSendErrorShowsAtField() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded })
      var p = page(view)
      var msg = "The message has 1700 characters. Send at most 1600"
      mock.failures = { "sms.send": { code: "bad_params", message: msg } }
      var draft = findBy(p, "placeholder", "Text message via Pixel 8")
      draft.text = "A long message"
      p.send()
      tryCompare(p, "sendError", msg)
      var line = findBy(p, "text", msg)
      verify(!!line && line.visible)
      // The draft stays for a change, and nothing shows as sent.
      compare(draft.text, "A long message")
      compare(p.outbox.length, 0)
      draft.text = "A short message"
      compare(p.sendError, "")
      verify(!line.visible)
    }

    function test_smsSendErrorInOtherThreadShowsInToast() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded })
      var p = page(view)
      var msg = "The message has 1700 characters. Send at most 1600"
      mock.failures = { "sms.send": { code: "bad_params", message: msg } }
      findBy(p, "placeholder", "Text message via Pixel 8").text = "A long message"
      var sent = p.selected.thread
      p.send()
      // The user opens a different thread before fluxd answers.
      p.open(p.convos.filter(function (c) { return c.thread !== sent })[0])
      tryVerify(function () { var t = findBy(view, "message", msg); return !!t && t.visible })
      compare(p.sendError, "")
    }

    function test_smsSendErrorAfterPageShowsInToast() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "messages"
      tryVerify(function () { return !!page(view) && page(view).loaded })
      var p = page(view)
      var msg = "The message has 1700 characters. Send at most 1600"
      mock.failures = { "sms.send": { code: "bad_params", message: msg } }
      findBy(p, "placeholder", "Text message via Pixel 8").text = "A long message"
      p.send()
      // The user opens a different tab before fluxd answers.
      view.tab = "notifications"
      tryVerify(function () { var t = findBy(view, "message", msg); return !!t && t.visible })
    }

    function test_clipboardErrorShowsInToast() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      tryVerify(function () { return view.devOnline })
      var msg = "The text has 1048577 bytes. Flux shares at most 1 MiB of text"
      mock.failures = { "clipboard.send": { code: "too_large", message: msg } }
      view.sendClipboard()
      compare(requestsOf("clipboard.send").length, 1)
      tryVerify(function () { var t = findBy(view, "message", msg); return !!t && t.visible })
    }
  }

  TestCase {
    name: "Limits"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.requests = []
    }

    function test_notificationShowsAtMost8Actions() {
      var actions = []
      for (var i = 0; i < 12; i++) actions.push("Action " + i)
      mock.updateDevice(top.pixel, function (d) {
        d.notifications = [
          { id: "many", app: "Mail", title: "Many actions", text: "", time: 1, dismissable: true, actions: actions },
          { id: "number", app: "Mail", title: "Number actions", text: "", time: 1, dismissable: true, actions: 1000 }
        ]
        return d
      })
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "notifications"
      tryVerify(function () { return !!page(view) && !!findBy(page(view), "text", "Many actions") })
      verify(!!findBy(page(view), "text", "Action 7"))
      verify(!findBy(page(view), "text", "Action 8"))
      compare(findBy(page(view), "actionsText", JSON.stringify(actions.slice(0, 8))).actions.length, 8)
      // Actions that are not a list give no buttons.
      var card = findBy(page(view), "text", "Number actions")
      while (card && !card.hasOwnProperty("actionsText")) card = card.parent
      verify(!!card)
      compare(card.actionsText, "[]")
      compare(card.actions.length, 0)
    }

    function test_cameraShowsAtMost16Chips() {
      mock.setState(function (s) {
        var aspects = []
        var resolutions = []
        for (var i = 0; i < 40; i++) {
          aspects.push(i + ":1")
          resolutions.push(100 + i)
        }
        s.webcam.caps.aspects = aspects
        s.webcam.caps.resolutions = resolutions
        s.webcam.caps.cameras = 100000
        s.webcam.caps.whiteBalance = "auto"
      })
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "overview"
      var card = null
      tryVerify(function () { card = findBy(page(view), "objectName", "cameraCard"); return !!card })
      compare(card.aspects.length, 16)
      compare(card.resolutions.length, 16)
      compare(card.cameras.length, 0)
      compare(card.whiteBalances.length, 0)
      // An empty list gives the default formats.
      mock.setState(function (s) { s.webcam.caps.aspects = [] })
      compare(card.aspects, ["16:9", "4:3", "1:1", "9:16"])
    }

    function test_overviewShowsBrowseSessions() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "overview"
      var card = null
      tryVerify(function () { card = findBy(page(view), "objectName", "browseCard"); return !!card })
      verify(!card.visible)
      mock.setState(function (s) { s.browse = [{ device: top.pixel, name: "Pixel 8", since: 1790000000 }] })
      verify(card.visible)
      compare(card.title, "Pixel 8 browses this computer")
      card.stop()
      compare(requestsOf("browse.stop").length, 1)
      verify(!card.visible)
    }

    function test_overviewShowsFingerprint() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "overview"
      var line = null
      tryVerify(function () { line = findBy(page(view), "objectName", "fingerprint"); return !!line })
      verify(line.visible)
      verify(!!findBy(line, "text", "5EE6 825F 974E D59A"))
      mock.updateDevice(top.pixel, function (d) { d.fingerprint = ""; return d })
      verify(!line.visible)
    }
  }

  TestCase {
    name: "StreamStart"
    when: mock.ready

    function init() {
      mock.state = mock.fixTimes(mock.fixture.state)
      mock.requests = []
      mock.failures = {}
      mock.setState(function (s) { s.webcam = null; s.mic = null })
    }

    function cleanup() {
      mock.failures = {}
    }

    function canAsk(on) {
      mock.updateDevice(top.pixel, function (d) {
        d.plugins = d.plugins.filter(function (p) { return p !== "streamrequest" })
        if (on) d.plugins.push("streamrequest")
        return d
      })
    }

    function cards(view) {
      var camera = null
      var mic = null
      tryVerify(function () {
        camera = findBy(page(view), "objectName", "cameraCard")
        mic = findBy(page(view), "objectName", "micCard")
        return !!camera && !!mic
      })
      return { camera: camera, mic: mic }
    }

    function overview() {
      var view = createTemporaryObject(viewComponent, top)
      view.selectedId = top.pixel
      view.tab = "overview"
      return view
    }

    // A device that does not list streamrequest gets no Start, and the
    // cards stay hidden without a stream.
    function test_noStartWithoutTheFeature() {
      var c = cards(overview())
      verify(!c.camera.visible)
      verify(!c.mic.visible)
      canAsk(true)
      verify(c.camera.visible)
      verify(c.mic.visible)
      mock.updateDevice(top.pixel, function (d) { d.online = false; return d })
      verify(!c.camera.visible)
      verify(!c.mic.visible)
    }

    function test_startAsksTheDevice() {
      canAsk(true)
      var view = overview()
      var c = cards(view)
      var start = findBy(c.camera, "objectName", "startButton")
      verify(c.camera.idle)
      verify(start.visible)
      compare(c.camera.idleTitle, "The webcam is off")
      start.clicked()
      compare(requestsOf("webcam.start").length, 1)
      compare(requestsOf("webcam.start")[0].params.device, top.pixel)
      tryCompare(c.camera, "note", "Confirm on Pixel 8.")
      compare(c.camera.idleTitle, "Asked Pixel 8 to start the webcam")
      tryVerify(function () { var t = findBy(view, "message", "Asked Pixel 8 to start the webcam. Confirm on Pixel 8."); return !!t && t.visible })

      // The stream starts on the phone after the tap. The card then has no
      // Start button and no note.
      mock.setState(function (s) { s.webcam = JSON.parse(JSON.stringify(mock.fixture.state.webcam)) })
      verify(!start.visible)
      compare(c.camera.note, "")

      var micStart = findBy(c.mic, "objectName", "startButton")
      verify(micStart.visible)
      c.mic.start()
      compare(requestsOf("mic.start").length, 1)
      compare(requestsOf("mic.start")[0].params.device, top.pixel)
      tryCompare(c.mic, "note", "Confirm on Pixel 8.")
      compare(c.mic.idleTitle, "Asked Pixel 8 to start the mic")
      mock.setState(function (s) { s.mic = JSON.parse(JSON.stringify(mock.fixture.state.mic)) })
      verify(!micStart.visible)
    }

    // A stream that failed ended, so Start shows next to the error.
    function test_startAfterAnError() {
      canAsk(true)
      var c = cards(overview())
      mock.setState(function (s) { s.mic = { error: "pw-cat is not installed", source: "Flux Microphone" } })
      verify(c.mic.failed)
      verify(findBy(c.mic, "objectName", "startButton").visible)
      mock.setState(function (s) { s.webcam = { error: "The v4l2loopback module is not loaded", label: "Flux Camera" } })
      verify(c.camera.failed)
      verify(findBy(c.camera, "objectName", "startButton").visible)
    }

    // An error of fluxd shows in a toast, and the card does not wait.
    function test_startErrorShowsInToast() {
      canAsk(true)
      var view = overview()
      var c = cards(view)
      var msg = "Pixel 8 got a request for the mic less than 3 seconds ago. Wait, then ask again"
      mock.failures = { "mic.start": { code: "too_soon", message: msg } }
      c.mic.start()
      tryVerify(function () { var t = findBy(view, "message", msg); return !!t && t.visible })
      compare(c.mic.note, "")
      // fluxd sent no request, so Start is active again at once.
      verify(findBy(c.mic, "objectName", "startButton").active)
    }

    // A start that fails at once comes only as an error state. The error
    // then removes the note. A change of other state keeps it.
    function test_failureRemovesTheNote() {
      canAsk(true)
      var c = cards(overview())
      c.camera.start()
      tryCompare(c.camera, "note", "Confirm on Pixel 8.")
      mock.updateDevice(top.pixel, function (d) { d.battery.charge = 12; return d })
      compare(c.camera.note, "Confirm on Pixel 8.")
      mock.setState(function (s) { s.webcam = { error: "ffmpeg is not installed on the computer", label: "Flux Camera" } })
      verify(c.camera.failed)
      compare(c.camera.note, "")
      compare(c.camera.idleTitle, "The webcam is off")

      c.mic.start()
      tryCompare(c.mic, "note", "Confirm on Pixel 8.")
      mock.setState(function (s) { s.mic = { error: "pw-cat is not installed", source: "Flux Microphone" } })
      verify(c.mic.failed)
      compare(c.mic.note, "")
    }

    // A request next to an old error keeps the note while the state stays
    // the same. A stream that starts removes the note.
    function test_noteNextToAnError() {
      canAsk(true)
      var c = cards(overview())
      mock.setState(function (s) { s.webcam = { error: "The v4l2loopback module is not loaded", label: "Flux Camera" } })
      c.camera.start()
      tryCompare(c.camera, "note", "Confirm on Pixel 8.")
      mock.setState(function (s) { s.webcam = { error: "The v4l2loopback module is not loaded", label: "Flux Camera" } })
      compare(c.camera.note, "Confirm on Pixel 8.")
      mock.setState(function (s) { s.webcam = JSON.parse(JSON.stringify(mock.fixture.state.webcam)) })
      compare(c.camera.note, "")
    }

    // fluxd refuses a second request of the kind to the device in 3
    // seconds. A double click therefore sends 1 request, and Start is
    // inactive until the 3 seconds end.
    function test_doubleClickSendsOneRequest() {
      canAsk(true)
      var view = overview()
      var c = cards(view)
      var start = findBy(c.camera, "objectName", "startButton")
      verify(start.active)
      // The window must show before it gets mouse events.
      tryVerify(function () { return windowShown })
      waitForRendering(view)
      mouseDoubleClickSequence(start)
      tryCompare(c.camera, "note", "Confirm on Pixel 8.")
      compare(requestsOf("webcam.start").length, 1)
      verify(!start.active)
      c.camera.start()
      compare(requestsOf("webcam.start").length, 1)
      tryVerify(function () { return start.active }, 4000)
      start.clicked()
      compare(requestsOf("webcam.start").length, 2)
    }
  }
}
