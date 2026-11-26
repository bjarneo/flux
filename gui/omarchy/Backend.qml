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

  // The image MIME types that Flux syncs, and the file extension of each.
  // The clipboard probe picks the first type that the clipboard offers.
  readonly property var pasteTypes: [
    { mime: "image/png", ext: "png" },
    { mime: "image/jpeg", ext: "jpg" },
    { mime: "image/webp", ext: "webp" },
    { mime: "image/gif", ext: "gif" },
  ]

  // The types that the clipboard offered when the probe last ran. "" until
  // the first probe answers, so a Ctrl+V before then does not take the
  // event.
  property string pasteTypesSeen: ""
  property bool pasteProbing: false

  // A slow probe does not block the next one.
  function refreshPasteTypes() {
    if (pasteProbing) return
    pasteProbing = true
    var proc = pasteProbeComponent.createObject(root, {
      command: ["sh", "-c", "wl-paste --list-types 2>/dev/null"],
    })
    proc.done = function (code, text) {
      pasteTypesSeen = code === 0 ? String(text || "") : ""
      pasteProbing = false
      try { proc.destroy() } catch (e) {}
    }
    proc.running = true
  }

  // hasClipboardImage reports whether the clipboard held an image MIME
  // type at the last probe. The probe runs at startup, after each failed
  // paste, and once a second while a paste probe is idle.
  function hasClipboardImage() {
    if (pasteTypesSeen === "") return false
    for (var i = 0; i < pasteTypes.length; i++)
      if (pasteTypesSeen.indexOf(pasteTypes[i].mime) >= 0) return true
    return false
  }

  // pasteFile writes the image on the clipboard to a file in the runtime
  // folder. cb gets the absolute path, or null when the clipboard holds no
  // image. The magic check is the first 8 bytes of a PNG; it uses base64,
  // because ANSI-C quoting is not POSIX and /bin/sh can be dash.
  function pasteFile(cb) {
    var pick = null
    for (var i = 0; i < pasteTypes.length; i++) {
      if (pasteTypesSeen.indexOf(pasteTypes[i].mime) >= 0) {
        pick = pasteTypes[i]
        break
      }
    }
    if (!pick) {
      cb(null)
      return
    }
    var path = (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + uid()) +
      "/flux/paste-" + Date.now() + "-" + (++pasteSerial) + "." + pick.ext
    var proc = pasteComponent.createObject(root, {
      command: ["sh", "-c",
        'mkdir -p "$(dirname "$1")" && wl-paste --type "$2" --no-newline > "$1" 2>/dev/null; ' +
        'if [ -s "$1" ] && [ "$(head -c 8 "$1" | base64)" = "iVBORw0KGgo=" ]; then printf \'%s\' "$1"; ' +
        'else rm -f "$1"; fi',
        "flux-paste", path, pick.mime],
    })
    proc.done = function (code, text) {
      var p = code === 0 && text.startsWith("/") ? text : null
      // A paste that fails leaves the types stale. The probe runs again.
      if (p === null) pasteTypesSeen = ""
      try { cb(p) } catch (e) {}
      try { proc.destroy() } catch (e) {}
      // fluxd snapshots the file when share.files runs, so it goes before
      // the runtime folder fills up.
      if (p !== null) {
        var cleaner = cleanerComponent.createObject(root, {
          command: ["sh", "-c", "sleep 120; rm -f \"$1\"; true", "flux-paste-clean", p],
        })
        cleaner.running = true
      }
    }
    proc.running = true
  }
  property int pasteSerial: 0

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
    id: pasteComponent
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      onExited: function (code) {
        if (proc.done) proc.done(code, out.text)
        else proc.destroy()
      }
    }
  }

  Component {
    id: pasteProbeComponent
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      onExited: function (code) {
        if (proc.done) proc.done(code, out.text)
        else proc.destroy()
      }
    }
  }

  Component {
    id: cleanerComponent
    Process {
      id: proc
      onExited: proc.destroy()
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

  Component.onCompleted: {
    connectNow()
    refreshPasteTypes()
  }

  // The clipboard of Wayland can change at any time. A probe that answers
  // after a paste keeps the types fresh for the next Ctrl+V. The probe is
  // cheap (1 wl-paste call), so a slow timer is enough.
  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.refreshPasteTypes()
  }

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
