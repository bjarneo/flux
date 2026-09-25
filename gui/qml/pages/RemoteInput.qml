import QtQuick
import ".."
import "../components"

// Forwards this keyboard and mouse to the device while the area captures.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  property bool capturing: false

  implicitHeight: 380

  // Pointer motion is summed and sent at about 60 Hz.
  property real accX: 0
  property real accY: 0
  property real lastX: -1
  property real lastY: -1

  // Keys with a KDE Connect special key code.
  readonly property var specials: ({
    [Qt.Key_Backspace]: 1, [Qt.Key_Tab]: 2, [Qt.Key_Left]: 4, [Qt.Key_Up]: 5,
    [Qt.Key_Right]: 6, [Qt.Key_Down]: 7, [Qt.Key_PageUp]: 8, [Qt.Key_PageDown]: 9,
    [Qt.Key_Home]: 10, [Qt.Key_End]: 11, [Qt.Key_Return]: 12, [Qt.Key_Enter]: 12,
    [Qt.Key_Delete]: 13, [Qt.Key_F1]: 21, [Qt.Key_F2]: 22, [Qt.Key_F3]: 23,
    [Qt.Key_F4]: 24, [Qt.Key_F5]: 25, [Qt.Key_F6]: 26, [Qt.Key_F7]: 27,
    [Qt.Key_F8]: 28, [Qt.Key_F9]: 29, [Qt.Key_F10]: 30, [Qt.Key_F11]: 31, [Qt.Key_F12]: 32
  })

  function start() {
    if (!online) {
      view.toast(view.devName + " is offline")
      return
    }
    capturing = true
    lastX = -1
    area.forceActiveFocus()
  }

  function stop() {
    capturing = false
    accX = 0
    accY = 0
    root.view.forceActiveFocus()
  }

  function send(method, params) {
    params.device = dev.id
    view.backend.call(method, params, function (err) {
      if (err) {
        root.view.toast(err.message || err.code)
        root.stop()
      }
    })
  }

  onOnlineChanged: if (!online && capturing) stop()

  Timer {
    interval: 16
    repeat: true
    running: root.capturing
    onTriggered: {
      if (root.accX === 0 && root.accY === 0) return
      root.send("input.pointer", { dx: root.accX, dy: root.accY })
      root.accX = 0
      root.accY = 0
    }
  }

  Rectangle {
    id: surface
    anchors.fill: parent
    color: root.capturing ? Theme.mix(Theme.bg, Theme.accent, 0.10) : "transparent"
    border.width: 1.5
    border.color: root.capturing ? Theme.accent : Theme.bg3

    Column {
      anchors.centerIn: parent
      width: parent.width - 40
      spacing: 8
      Txt {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.capturing ? "capturing input → " + root.view.devName : "remote input idle"
        color: root.capturing ? Theme.accent : Theme.fg
        font.pixelSize: 18
        font.weight: Font.Bold
      }
      Txt {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.capturing
          ? "keyboard + mouse forwarded · press Esc to release"
          : "click or press [i] to control " + (root.view ? root.view.devName : "the device") + " with this keyboard and mouse"
        color: Theme.dim
        wrapMode: Text.Wrap
      }
    }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: root.capturing ? Qt.BlankCursor : Qt.PointingHandCursor
    focus: root.capturing

    onPositionChanged: function (mouse) {
      if (!root.capturing) return
      if (root.lastX >= 0) {
        root.accX += mouse.x - root.lastX
        root.accY += mouse.y - root.lastY
      }
      root.lastX = mouse.x
      root.lastY = mouse.y
    }
    onExited: root.lastX = -1
    onClicked: function (mouse) {
      if (!root.capturing) {
        root.start()
        return
      }
      var b = mouse.button === Qt.RightButton ? "right" : (mouse.button === Qt.MiddleButton ? "middle" : "left")
      root.send("input.click", { button: b })
    }
    onWheel: function (wheel) {
      if (!root.capturing) return
      root.send("input.scroll", { dy: wheel.angleDelta.y / 120 })
    }

    Keys.onPressed: function (event) {
      if (!root.capturing) return
      event.accepted = true
      if (event.key === Qt.Key_Escape) {
        root.stop()
        return
      }
      var mods = {
        shift: !!(event.modifiers & Qt.ShiftModifier),
        ctrl: !!(event.modifiers & Qt.ControlModifier),
        alt: !!(event.modifiers & Qt.AltModifier)
      }
      var code = root.specials[event.key]
      if (code) {
        root.send("input.key", Object.assign({ special: code }, mods))
        return
      }
      var text = event.text
      if ((mods.ctrl || mods.alt) && event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
        text = String.fromCharCode(event.key).toLowerCase()
      if (!text || text.length === 0 || text.charCodeAt(0) < 32) return
      root.send("input.key", Object.assign({ key: text }, mods))
    }
  }

  // Starts the capture when the "i" shortcut reaches the view.
  function handleKey(event) {
    if (event.text === "i" && !capturing) {
      start()
      event.accepted = true
    }
  }
}
