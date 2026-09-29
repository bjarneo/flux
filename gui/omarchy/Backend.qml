import QtQuick
import Quickshell
import Quickshell.Io

// The Flux backend for omarchy-shell. It talks to fluxd over its IPC socket
// and follows the backend contract in Flux/README.md. Each message is one
// JSON object on one line. After subscribe, fluxd sends the full state after
// each change.
Scope {
  id: root

  // The same path as fluxd and flux-cli: $FLUX_SOCKET, or
  // $XDG_RUNTIME_DIR/flux/fluxd.sock, or /run/user/<uid>/flux/fluxd.sock.
  // There is no /tmp fallback, because another user can make a folder there
  // first.
  readonly property string socketPath: {
    var override = Quickshell.env("FLUX_SOCKET") || ""
    if (override !== "") return override
    var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
    if (runtime === "") runtime = "/run/user/" + uid()
    return runtime + "/flux/fluxd.sock"
  }

  // The user ID of this process, from /proc/self/status.
  function uid() {
    var m = /^Uid:\s+(\d+)/m.exec(procStatus.text())
    return m ? m[1] : ""
  }

  FileView {
    id: procStatus
    path: "/proc/self/status"
    blockAllReads: true
    printErrors: false
  }

  // A line from fluxd above this number of characters is dropped. Normal
  // state events are much smaller, and a very large line blocks the shell
  // while it parses.
  readonly property int maxLine: 32 * 1024 * 1024

  readonly property bool connected: !!sock && sock.connected
  // True after the first connection attempt ends, so the window does not
  // show "fluxd is not running" while the first attempt is open.
  property bool attempted: false
  property var state: ({})

  readonly property var devices: state.devices || []
  readonly property var clipboard: state.clipboard || []
  readonly property var transfers: state.transfers || []
  readonly property var commands: state.commands || []
  readonly property var settings: state.settings || ({})
  readonly property var selfDevice: state.self || ({})

  signal toast(string text)

  property int nextId: 1
  property var pending: ({})

  // The Socket of Quickshell 0.3 does not connect again after a failed
  // attempt, so each attempt uses a new Socket.
  property Socket sock: null

  // The wait before the next connection attempt while fluxd is down. It
  // starts at 2 seconds and doubles after each failed attempt, up to 60
  // seconds.
  readonly property int minRetryDelay: 2000
  readonly property int maxRetryDelay: 60000
  property int retryDelay: minRetryDelay

  // Connects at once when the connection is down, and starts the wait again
  // at 2 seconds. The panel calls this when it opens.
  function retryNow() {
    retryDelay = minRetryDelay
    connectNow()
  }

  function connectNow() {
    if (sock && sock.connected) return
    if (sock) sock.destroy()
    // The socket connects after sock is set, so its handlers know that it
    // is the current socket.
    sock = socketComponent.createObject(root)
    sock.connected = true
  }

  // The handlers of the socket call this before connected changes, so read
  // the socket itself.
  function call(method, params, cb) {
    if (!sock || !sock.connected) {
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
      var paths = code === 0 ? chooserPaths(String(text || "")) : []
      try { cb(paths) } catch (e) {}
    }
    proc.running = true
  }

  // Reads the output of omarchy file select: 1 absolute path on each line.
  // A file name can have a newline, so a line that does not start with "/"
  // continues the path before it. The lines are not trimmed, because a file
  // name can start or end with a space.
  function chooserPaths(text) {
    if (text.endsWith("\n")) text = text.slice(0, -1)
    if (text === "") return []
    var paths = []
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith("/") || paths.length === 0) paths.push(lines[i])
      else paths[paths.length - 1] += "\n" + lines[i]
    }
    return paths.filter(function (p) { return p.startsWith("/") })
  }

  // Starts the fluxd user service. cb gets true when systemctl succeeds.
  function startDaemon(cb) {
    var proc = pickerComponent.createObject(root, {
      // The button turns fluxd on, so it removes the marker of `flux-cli off` first.
      command: ["sh", "-c", 'rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/flux/off"; systemctl --user start fluxd']
    })
    proc.done = function (code, text) {
      var ok = code === 0
      if (ok) root.retryNow()
      try { cb(ok, ok ? "" : "systemctl could not start fluxd. Run: journalctl --user -u fluxd") } catch (e) {}
    }
    proc.running = true
  }

  function handle(line) {
    if (!line || line.length === 0) return
    if (line.length > maxLine) {
      console.warn("flux: dropped a line of " + line.length + " characters from fluxd")
      return
    }
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

  // Runs each waiting callback once with an offline error. fluxd closed
  // the connection, so no answer comes.
  function failPending() {
    var waiting = pending
    pending = ({})
    for (var id in waiting) {
      try { waiting[id]({ code: "offline", message: "fluxd is not running" }, null) } catch (e) {}
    }
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

  Component {
    id: socketComponent
    Socket {
      id: socket
      path: root.socketPath
      parser: SplitParser {
        onRead: data => root.handle(data)
      }
      // A socket from an earlier attempt can report after it is replaced.
      onConnectedChanged: {
        if (socket !== root.sock) return
        root.attempted = true
        if (connected) {
          root.retryDelay = root.minRetryDelay
          root.call("subscribe", {}, null)
        } else {
          root.failPending()
        }
      }
      onError: root.attempted = true
    }
  }

  Component.onCompleted: connectNow()

  // A new interval starts the timer again, so retryNow() also cuts a long
  // wait short.
  Timer {
    interval: root.retryDelay
    repeat: true
    running: !root.connected
    onTriggered: {
      root.attempted = true
      root.retryDelay = Math.min(root.retryDelay * 2, root.maxRetryDelay)
      root.connectNow()
    }
  }

  Timer {
    interval: 800
    running: true
    onTriggered: root.attempted = true
  }
}
