import QtQuick
import ".."

// A slider with a label and the current value. While the user drags, it
// shows the drag position. Otherwise it shows value, so a change from
// elsewhere moves the handle. It sends moved() during the drag and
// released() with the final value.
Item {
  id: root
  property string text: ""
  property real from: 0
  property real to: 1
  property real stepSize: 0.01
  property real value: 0
  property bool active: true
  // Formats a value for the label at the right.
  property var format: function (v) { return v.toFixed(2) }

  readonly property bool pressed: area.pressed
  property real dragValue: 0
  readonly property real shown: pressed ? dragValue : value
  readonly property real ratio: to > from ? Math.max(0, Math.min(1, (shown - from) / (to - from))) : 0

  signal moved(real value)
  signal released(real value)

  implicitWidth: 240
  implicitHeight: header.height + 4 + track.height
  opacity: active ? 1 : 0.4

  function snap(v) {
    var s = stepSize > 0 ? stepSize : 0.01
    var n = from + Math.round((v - from) / s) * s
    n = Math.max(from, Math.min(to, n))
    return Math.round(n * 1000) / 1000
  }

  function valueAt(x) {
    return snap(from + (to - from) * Math.max(0, Math.min(1, (x - handle.width / 2) / (track.width - handle.width))))
  }

  Item {
    id: header
    width: parent.width
    height: nameLabel.implicitHeight
    Txt { id: nameLabel; text: root.text; font.pixelSize: 12 }
    Txt {
      anchors.right: parent.right
      text: root.format(root.shown)
      color: root.pressed ? Theme.accent : Theme.dim
      font.pixelSize: 12
    }
  }

  Item {
    id: track
    anchors.top: header.bottom
    anchors.topMargin: 4
    width: parent.width
    height: 16

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 4
      color: Theme.bg3
      Rectangle {
        width: handle.x + handle.width / 2
        height: parent.height
        color: Theme.accent
      }
    }

    Rectangle {
      id: handle
      anchors.verticalCenter: parent.verticalCenter
      x: root.ratio * (track.width - width)
      width: 12
      height: 12
      color: area.containsMouse || root.pressed ? Theme.fg : Theme.accent
    }

    MouseArea {
      id: area
      anchors.fill: parent
      anchors.topMargin: -4
      anchors.bottomMargin: -4
      enabled: root.active
      hoverEnabled: true
      cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
      preventStealing: true
      onPressed: function (mouse) {
        root.dragValue = root.valueAt(mouse.x)
        root.moved(root.dragValue)
      }
      onPositionChanged: function (mouse) {
        if (!pressed) return
        var v = root.valueAt(mouse.x)
        if (v === root.dragValue) return
        root.dragValue = v
        root.moved(v)
      }
      onReleased: root.released(root.dragValue)
    }
  }
}
