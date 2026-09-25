import QtQuick
import QtQuick.Layouts
import ".."

// The phone camera as a webcam on this computer, and its settings. The
// values come from state.webcam.config, so the panel follows changes that
// are made on the phone. Each change sends only the changed key.
Card {
  id: root
  property var view: null
  property var webcam: null
  property bool settingsOpen: false

  readonly property var cam: webcam || ({})
  readonly property var config: cam.config || ({})
  readonly property var caps: cam.caps || ({})
  readonly property bool failed: !!cam.error
  readonly property bool live: !!cam.active && !failed

  implicitHeight: col.implicitHeight + 38

  // A Format or Resolution change restarts the stream on the phone, because
  // the frame size changes. "Restarting…" shows until the stream is live
  // again. A Camera change is live.
  property bool restarting: false
  property bool sawInactive: false
  property double restartedAt: 0
  readonly property var restartKeys: ["aspect", "resolution"]

  onLiveChanged: {
    if (!restarting) return
    if (!live) sawInactive = true
    else if (sawInactive || Date.now() - restartedAt > 1500) restarting = false
  }

  Timer {
    // The phone can restart so fast that the state never shows it stopped.
    interval: 1500
    running: root.restarting
    onTriggered: if (root.live && !root.sawInactive) root.restarting = false
  }

  Timer {
    interval: 10000
    running: root.restarting
    onTriggered: root.restarting = false
  }

  function send(params) {
    if (!view) return
    view.call("webcam.config", params)
  }

  function setKey(key, value) {
    var c = {}
    c[key] = value
    if (restartKeys.indexOf(key) >= 0) {
      restarting = true
      sawInactive = false
      restartedAt = Date.now()
    }
    send({ config: c })
  }

  // Sliders send at most 10 changes a second. The last value goes out when
  // the timer fires, and the final value goes out on release.
  property var pending: ({})
  Timer {
    id: throttle
    interval: 100
    onTriggered: {
      var keys = Object.keys(root.pending)
      if (keys.length === 0) return
      var c = root.pending
      root.pending = ({})
      root.send({ config: c })
      restart()
    }
  }

  function slide(key, value) {
    if (!throttle.running) {
      var c = {}
      c[key] = value
      send({ config: c })
      throttle.start()
      return
    }
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[key] = value
    pending = next
  }

  function slideDone(key, value) {
    var next = {}
    for (var k in pending) if (k !== key) next[k] = pending[k]
    pending = next
    setKey(key, value)
  }

  function num(v, fallback) { return typeof v === "number" && isFinite(v) ? v : fallback }
  function signed(v, digits) { return (v > 0 ? "+" : "") + v.toFixed(digits) }
  function title(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1) }

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 19
    spacing: 12
    SectionLabel { text: "PHONE CAMERA" }

    Item {
      width: parent.width
      height: Math.max(camText.implicitHeight, buttons.implicitHeight)

      Column {
        id: camText
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        Txt {
          width: parent.width
          visible: root.live && !root.restarting
          text: (root.cam.fromName || "The phone") + " is live as " + (root.cam.label || "a webcam")
          font.weight: Font.Bold
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          visible: root.live && !root.restarting
          text: {
            var c = root.cam
            var parts = [c.device || ""]
            if (c.width && c.height) parts.push(c.width + "×" + c.height)
            if (c.fps) parts.push(c.fps + " fps")
            return parts.filter(function (p) { return p !== "" }).join(" · ")
          }
          color: Theme.dim
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          visible: !root.failed && (root.restarting || !root.cam.active)
          text: root.restarting ? "Restarting…" : "Starting…"
          color: Theme.dim
        }
        Txt {
          width: parent.width
          visible: root.failed
          text: root.cam.error || ""
          color: Theme.err
          wrapMode: Text.Wrap
        }
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        OutlineButton {
          visible: !root.failed
          text: root.settingsOpen ? "Close" : "Settings"
          onClicked: root.settingsOpen = !root.settingsOpen
        }
        OutlineButton {
          visible: root.live
          text: "Stop"
          onClicked: root.view.call("webcam.stop", {})
        }
      }
    }

    // Settings
    Rectangle {
      visible: root.settingsOpen && !root.failed
      width: parent.width
      height: 1
      color: Theme.bg3
    }

    GridLayout {
      id: settings
      visible: root.settingsOpen && !root.failed
      width: parent.width
      columns: width >= 640 ? 2 : 1
      columnSpacing: 32
      rowSpacing: 16

      // Chips and the mirror switch
      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: 300
        spacing: 16

        Group {
          label: "FORMAT"
          Repeater {
            model: root.caps.aspects && root.caps.aspects.length ? root.caps.aspects : ["16:9", "4:3", "1:1", "9:16"]
            delegate: Chip {
              required property var modelData
              text: modelData
              selected: root.config.aspect === modelData
              onClicked: root.setKey("aspect", modelData)
            }
          }
        }

        Group {
          label: "RESOLUTION"
          Repeater {
            model: root.caps.resolutions && root.caps.resolutions.length ? root.caps.resolutions : [720, 1080]
            delegate: Chip {
              required property var modelData
              text: modelData + "p"
              selected: Number(root.config.resolution) === Number(modelData)
              onClicked: root.setKey("resolution", Number(modelData))
            }
          }
        }

        Group {
          label: "CAMERA"
          visible: !!root.caps.cameras && root.caps.cameras.length > 0
          Repeater {
            model: root.caps.cameras || []
            delegate: Chip {
              required property var modelData
              text: root.title(modelData)
              selected: root.config.camera === modelData
              onClicked: root.setKey("camera", modelData)
            }
          }
        }

        Group {
          label: "WHITE BALANCE"
          visible: !!root.caps.whiteBalance && root.caps.whiteBalance.length > 0
          Repeater {
            model: root.caps.whiteBalance || []
            delegate: Chip {
              required property var modelData
              text: root.title(modelData)
              selected: root.config.whiteBalance === modelData
              onClicked: root.setKey("whiteBalance", modelData)
            }
          }
        }

        Toggle {
          text: "Mirror the image"
          checked: !!root.config.mirror
          onToggled: function (checked) { root.setKey("mirror", checked) }
        }
      }

      // Sliders
      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: 300
        spacing: 14

        ValueSlider {
          width: parent.width
          text: "Zoom"
          from: 1
          to: Math.max(1, root.num(root.caps.zoomMax, 1))
          stepSize: 0.1
          active: to > 1
          value: root.num(root.config.zoom, 1)
          format: function (v) { return v.toFixed(1) + "×" }
          onMoved: function (v) { root.slide("zoom", v) }
          onReleased: function (v) { root.slideDone("zoom", v) }
        }
        ValueSlider {
          width: parent.width
          text: "Exposure"
          from: root.num(root.caps.exposureMin, -2)
          to: root.num(root.caps.exposureMax, 2)
          stepSize: root.num(root.caps.exposureStep, 0.1)
          value: root.num(root.config.exposure, 0)
          format: function (v) { return root.signed(v, 1) + " EV" }
          onMoved: function (v) { root.slide("exposure", v) }
          onReleased: function (v) { root.slideDone("exposure", v) }
        }
        ValueSlider {
          width: parent.width
          text: "Brightness"
          from: -1
          to: 1
          stepSize: 0.05
          value: root.num(root.config.brightness, 0)
          format: function (v) { return root.signed(v, 2) }
          onMoved: function (v) { root.slide("brightness", v) }
          onReleased: function (v) { root.slideDone("brightness", v) }
        }
        ValueSlider {
          width: parent.width
          text: "Contrast"
          from: 0
          to: 2
          stepSize: 0.05
          value: root.num(root.config.contrast, 1)
          format: function (v) { return v.toFixed(2) }
          onMoved: function (v) { root.slide("contrast", v) }
          onReleased: function (v) { root.slideDone("contrast", v) }
        }
        ValueSlider {
          width: parent.width
          text: "Saturation"
          from: 0
          to: 2
          stepSize: 0.05
          value: root.num(root.config.saturation, 1)
          format: function (v) { return v.toFixed(2) }
          onMoved: function (v) { root.slide("saturation", v) }
          onReleased: function (v) { root.slideDone("saturation", v) }
        }
        ValueSlider {
          width: parent.width
          text: "Warmth"
          from: -1
          to: 1
          stepSize: 0.05
          value: root.num(root.config.warmth, 0)
          format: function (v) { return root.signed(v, 2) }
          onMoved: function (v) { root.slide("warmth", v) }
          onReleased: function (v) { root.slideDone("warmth", v) }
        }
      }
    }

    Item {
      visible: root.settingsOpen && !root.failed
      width: parent.width
      height: Math.max(resetButton.implicitHeight, note.implicitHeight)
      OutlineButton {
        id: resetButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Reset"
        onClicked: root.send({ reset: true })
      }
      Txt {
        id: note
        anchors.left: resetButton.right
        anchors.leftMargin: 14
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "A Format, Resolution, or Camera change restarts the stream on the phone."
        color: Theme.dim
        font.pixelSize: 11
        wrapMode: Text.Wrap
      }
    }
  }

  // A labeled row of chips.
  component Group: Column {
    property string label: ""
    default property alias chips: chipRow.data
    width: parent ? parent.width : 300
    spacing: 8
    Txt { text: parent.label; color: Theme.dim; font.pixelSize: 11 }
    Flow {
      id: chipRow
      width: parent.width
      spacing: 6
    }
  }
}
