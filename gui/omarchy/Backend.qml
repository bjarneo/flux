import QtQuick
import Quickshell
import Quickshell.Io

// The Flux backend for omarchy-shell. It talks to fluxd over its IPC socket
// and follows the backend contract in Flux/README.md. Each message is one
// JSON object on one line. After subscribe, fluxd sends the full state after
// each change.
Scope {
  id: root

  readonly property string socketPath: {
    var override = Quickshell.env("FLUX_SOCKET") || ""
    if (override !== "") return override
    return (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/flux/fluxd.sock"
  }

  readonly property bool connected: sock.connected
  // True after the first connection attempt ends, so the window does not
  // show "fluxd is not running" while the first attempt is open.
  property bool attempted: false
  property var state: ({})

  readonly property var devices: state.devices || []
  readonly property var clipboard: state.clipboard || []
  readonly property var transfers: state.transfers || []
  readonly property var commands: state.commands || []
  readonly property var settings: state.settings || ({})
  readonly property bool ringing: !!state.ringing
  readonly property var selfDevice: state.self || ({})

  signal toast(string text)

  property int nextId: 1
  property var pending: ({})

  function call(method, params, cb) {
    if (!sock.connected) {
      var offline = { code: "offline", message: "fluxd is not running" }
      if (cb) cb(offline, null)
      else toast(offline.message)
      return
    }
    var id = nextId++
    if (cb) pending[id] = cb
    sock.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n")
    sock.flush()
  }

  // Runs the desktop file chooser. cb gets the chosen absolute paths, or an
  // empty list when the user cancels or the chooser fails.
  function pickFiles(title, cb) {
    var proc = pickerComponent.createObject(root, {
      command: ["omarchy", "file", "select", "--title", String(title || "Send files"), "--multiple"]
    })
    proc.done = function (code, text) {
      var paths = code === 0
        ? String(text || "").split("\n").filter(function (p) { return p.length > 0 })
        : []
      try { cb(paths) } catch (e) {}
    }
    proc.running = true
  }

  // Starts the fluxd user service. cb gets true when systemctl succeeds.
  function startDaemon(cb) {
    var proc = pickerComponent.createObject(root, {
      // The button turns fluxd on, so it removes the marker of `flux off` first.
      command: ["sh", "-c", 'rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/flux/off"; systemctl --user start fluxd']
    })
    proc.done = function (code, text) {
      var ok = code === 0
      if (ok) {
        sock.connected = false
        sock.connected = true
      }
      try { cb(ok, ok ? "" : "systemctl could not start fluxd. Run: journalctl --user -u fluxd") } catch (e) {}
    }
    proc.running = true
  }

  function handle(line) {
    if (!line || line.length === 0) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event === "state") {
      state = msg.data || {}
      return
    }
    if (msg.event === "toast") {
      if (msg.data && msg.data.text) toast(msg.data.text)
      return
    }
    if (msg.id === undefined) return
    var cb = pending[msg.id]
    delete pending[msg.id]
    // A callback can belong to a page that is already gone, for example
    // after a tab change. Its error does not matter.
    try {
      if (msg.error) {
        if (cb) cb(msg.error, null)
        else toast(msg.error.message || msg.error.code || "Error")
      } else if (cb) {
        cb(null, msg.result || {})
      }
    } catch (e) {}
  }

  Component {
    id: pickerComponent
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      onExited: function (code) {
        if (proc.done) proc.done(code, out.text)
        proc.destroy()
      }
    }
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser {
      onRead: data => root.handle(data)
    }
    onConnectedChanged: {
      root.attempted = true
      if (connected) root.call("subscribe", {}, null)
      else root.pending = ({})
    }
    onError: root.attempted = true
  }

  Timer {
    interval: 2000
    repeat: true
    running: !sock.connected
    onTriggered: {
      root.attempted = true
      sock.connected = false
      sock.connected = true
    }
  }

  Timer {
    interval: 800
    running: true
    onTriggered: root.attempted = true
  }
}
