import QtQuick

// A stand-in for a host backend that serves state from fixture.json. The
// snapshot harness uses it. It follows the backend contract in README.md.
// A negative "time", "lastSeen", or "mtime" value means that many seconds
// before now. Loading the fixture needs QML_XHR_ALLOW_FILE_READ=1.
QtObject {
  id: root

  property bool connected: true
  property bool attempted: true
  property var state: ({})
  property var fixture: ({})
  property bool ready: false
  property var calls: []

  readonly property var devices: state.devices || []
  readonly property var clipboard: state.clipboard || []
  readonly property var transfers: state.transfers || []
  readonly property var commands: state.commands || []
  readonly property var settings: state.settings || ({})
  readonly property bool ringing: !!state.ringing
  readonly property var selfDevice: state.self || ({})

  signal toast(string text)

  function fixTimes(v) {
    var now = Math.floor(Date.now() / 1000)
    if (Array.isArray(v)) return v.map(fixTimes)
    if (v && typeof v === "object") {
      var out = {}
      for (var k in v) {
        var x = v[k]
        if ((k === "time" || k === "lastSeen" || k === "mtime") && typeof x === "number" && x < 0) out[k] = now + x
        else out[k] = fixTimes(x)
      }
      return out
    }
    return v
  }

  // Replaces one device in the state with fn(device).
  function updateDevice(id, fn) {
    var s = JSON.parse(JSON.stringify(state))
    for (var i = 0; i < s.devices.length; i++) if (s.devices[i].id === id) s.devices[i] = fn(s.devices[i])
    state = s
  }

  function setState(fn) {
    var s = JSON.parse(JSON.stringify(state))
    fn(s)
    state = s
  }

  function call(method, params, cb) {
    calls.push(method)
    var result = {}
    if (method === "browse.open") result = { roots: fixture.roots }
    else if (method === "browse.list") result = { entries: fixTimes((fixture.dirs || {})[params.path] || []) }
    else if (method === "sms.thread") result = { messages: fixTimes((fixture.threads || {})[String(params.thread)] || []) }
    else if (method === "webcam.stop") setState(function (s) { s.webcam = null })
    else if (method === "commands.add") {
      var id = "c" + Date.now()
      setState(function (s) { s.commands = (s.commands || []).concat([{ id: id, name: params.name, command: params.command }]) })
      result = { id: id }
    } else if (method === "commands.remove") {
      setState(function (s) { s.commands = (s.commands || []).filter(function (c) { return c.id !== params.id }) })
    }
    if (cb) Qt.callLater(function () { try { cb(null, result) } catch (e) {} })
  }

  // The file chooser returns 2 sample paths.
  function pickFiles(title, cb) {
    calls.push("pickFiles")
    Qt.callLater(function () { try { cb(["/home/user/Pictures/kanagawa.png", "/home/user/notes.md"]) } catch (e) {} })
  }

  function startDaemon(cb) {
    calls.push("startDaemon")
    connected = true
    Qt.callLater(function () { try { cb(true, "") } catch (e) {} })
  }

  Component.onCompleted: {
    var x = new XMLHttpRequest()
    x.open("GET", Qt.resolvedUrl("fixture.json"), false)
    x.send()
    if (!x.responseText) {
      console.warn("MockBackend: cannot read fixture.json. Set QML_XHR_ALLOW_FILE_READ=1.")
      return
    }
    fixture = JSON.parse(x.responseText)
    state = fixTimes(fixture.state)
    ready = true
  }
}
