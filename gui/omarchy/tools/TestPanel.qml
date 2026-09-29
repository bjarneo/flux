import QtQuick
import ".."

// Test wrapper for the offscreen test. It adds snapshot("<page>:<path>"),
// which selects a screen and saves the window as a PNG, and probe(). Call
// them with:
//   qs -p <shell> ipc call shell call flux snapshot overview:/tmp/panel.png
//   qs -p <shell> ipc call shell call flux probe ring
Panel {
  id: panel

  function snapshot(arg) {
    var s = String(arg || "")
    var i = s.indexOf(":")
    var page = i > 0 ? s.slice(0, i) : ""
    var path = i > 0 ? s.slice(i + 1) : s
    if (!panel.opened) panel.open("{}")
    if (page !== "" && panel.viewLoader.item) panel.viewLoader.item.showPage(page)
    shot.path = path
    shot.restart()
    return "scheduled"
  }

  // probe("<method>") calls a fluxd method with no parameters. The log gets
  // 1 line each time the callback runs, so a test can check that the
  // callback runs once, also when the connection to fluxd closes.
  function probe(method) {
    var m = String(method || "")
    if (!panel.flux) return "no service"
    panel.flux.backend.call(m, {}, function (err, result) {
      console.log("flux test: probe", m, err ? err.code : "ok")
    })
    return "sent"
  }

  Timer {
    id: shot
    property string path: ""
    interval: 700
    onTriggered: {
      var p = path
      // The content item of a window is not a QML item, so grab the loader.
      panel.viewLoader.grabToImage(function (result) {
        result.saveToFile(p)
        console.log("flux test: saved", p)
      })
    }
  }
}
