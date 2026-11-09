import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// The page of a device: the battery and the device facts with Ring, what
// the device can do on this computer, the streams between them, the
// commands that the phone can run, and Unpair.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property string devName: view ? view.devName : "the device"
  readonly property var state: view && view.backend && view.backend.state ? view.backend.state : ({})
  // The streams of this device. A stream of another device shows on the
  // page of that device. A stream with no device, such as an error before
  // the start, shows on every page.
  function own(stream, field) {
    return stream && (!stream[field] || stream[field] === (dev ? dev.id : "")) ? stream : null
  }
  // The phone camera as a webcam on this computer. Null when it is not used.
  readonly property var webcam: own(state.webcam || null, "from")
  // The phone microphone and the phone screen mirror. Null when not used.
  readonly property var mic: own(state.mic || null, "from")
  readonly property var screen: own(state.screen || null, "from")
  // The remote desktop of this computer on the device. Null when not used.
  readonly property var desktop: own(state.desktop || null, "to")
  // The device as a speaker of this computer. Null when not used.
  readonly property var speaker: own(state.speaker || null, "to")
  // The Browse computer session of the device. An earlier fluxd sends no
  // list.
  readonly property var browse: (state.browse || []).filter(function (b) { return !!dev && b.device === dev.id })
  // The device can start its camera and its microphone when this computer
  // asks. The device asks its user first. An earlier fluxd or app does not
  // list streamrequest.
  readonly property bool canAsk: online && !!dev.paired && Array.isArray(dev.plugins) && dev.plugins.indexOf("streamrequest") >= 0
  // The device can also play the audio of this computer when this computer
  // asks. An earlier fluxd or app does not list speaker.
  readonly property bool canAskSpeaker: canAsk && dev.plugins.indexOf("speaker") >= 0
  // The ID of the device that got the last request of this window for the
  // webcam and for the mic, or "". The card then tells the user to confirm
  // on the device. The device removes its notification after 60 seconds,
  // and the card then removes its note too. The next change of the stream
  // state of the kind also removes the note, for example a stream that
  // starts or a start that fails at once.
  property string webcamAsked: ""
  property string micAsked: ""
  property string speakerAsked: ""
  // The stream state of the kind at the time of the request, as JSON. fluxd
  // sends at most 1 state every 100 ms, so a start that fails at once can
  // come only as an error. A comparison with this value finds that change.
  property string webcamSeen: ""
  property string micSeen: ""
  property string speakerSeen: ""
  // The ID of the device that got a request of this window for the kind in
  // the last 3 seconds, or "". fluxd refuses a second request in that time,
  // so Start is inactive for that device. An error of the request makes
  // Start active again at once.
  property string webcamSent: ""
  property string micSent: ""
  property string speakerSent: ""
  // streamRequestGap in internal/core/streamrequest.go, in milliseconds.
  readonly property int requestGap: 3000

  onWebcamChanged: if (webcamAsked !== "" && JSON.stringify(webcam) !== webcamSeen) webcamAsked = ""
  onMicChanged: if (micAsked !== "" && JSON.stringify(mic) !== micSeen) micAsked = ""
  onSpeakerChanged: if (speakerAsked !== "" && JSON.stringify(speaker) !== speakerSeen) speakerAsked = ""

  Timer { id: webcamWait; interval: 60000; onTriggered: root.webcamAsked = "" }
  Timer { id: micWait; interval: 60000; onTriggered: root.micAsked = "" }
  Timer { id: webcamGap; interval: root.requestGap; onTriggered: root.webcamSent = "" }
  Timer { id: micGap; interval: root.requestGap; onTriggered: root.micSent = "" }
  Timer { id: speakerWait; interval: 60000; onTriggered: root.speakerAsked = "" }
  Timer { id: speakerGap; interval: root.requestGap; onTriggered: root.speakerSent = "" }

  // Asks the device to start its camera or its mic, or to play the audio
  // of this computer. kind is "webcam", "mic", or "speaker". The toast and
  // the card tell the user to confirm on the device. A second request of
  // the kind to the device in requestGap does nothing.
  function askStream(kind) {
    if (!view || !dev) return
    // The view outlives this page, so the replies use it.
    var v = view
    var id = dev.id
    var name = dev.name || "the device"
    var gap = kind === "mic" ? micGap : kind === "speaker" ? speakerGap : webcamGap
    if (root[kind + "Sent"] === id) return
    root[kind + "Sent"] = id
    gap.restart()
    v.call(kind + ".start", { device: id }, function () {
      // The gap of fluxd starts before this reply. A restart here keeps
      // Start inactive until that gap ends.
      gap.restart()
      root[kind + "Asked"] = id
      root[kind + "Seen"] = JSON.stringify(root[kind])
      if (kind === "mic") micWait.restart()
      else if (kind === "speaker") speakerWait.restart()
      else webcamWait.restart()
      v.toast("Asked " + name + " to " + askWhat(kind) + ". Confirm on " + name + ".")
    }, function (err) {
      if (root[kind + "Sent"] === id) root[kind + "Sent"] = ""
      v.toast(err.message || err.code || "Error")
    })
  }

  // What a request of kind asks the device to do.
  function askWhat(kind) {
    if (kind === "speaker") return "play the audio of this computer"
    return "start " + (kind === "mic" ? "the mic" : "the webcam")
  }

  // True when Start can send a request to the device. sent is webcamSent
  // or micSent.
  function canSend(sent) {
    return !dev || sent !== dev.id
  }

  // The line under an idle card: the device to confirm on, or "".
  function confirmNote(asked) {
    return asked !== "" && !!dev && asked === dev.id ? "Confirm on " + (dev.name || "the device") + "." : ""
  }

  // The title of an idle card: the request that waits, or that no stream
  // of the kind runs. what is "the webcam" or "the mic".
  function idleTitle(asked, what) {
    if (confirmNote(asked) !== "") return "Asked " + (dev.name || "the device") + " to start " + what
    return what.charAt(0).toUpperCase() + what.slice(1) + " is off"
  }

  implicitHeight: col.implicitHeight

  // The cards of the streams that show now.
  readonly property bool anyStream: !!webcam || !!mic || !!screen || !!speaker || browse.length > 0 || desktopShown || canAsk
  readonly property bool desktopShown: !!desktop && !desktop.error

  Column {
    id: col
    width: parent.width
    spacing: 30

    // Battery and device facts, with Ring.
    Card {
      objectName: "deviceCard"
      width: parent.width
      readonly property bool stacked: width < 600
      implicitHeight: (stacked ? batteryCol.implicitHeight + 18 + facts.implicitHeight : Math.max(batteryCol.implicitHeight, facts.implicitHeight)) + 44

      Column {
        id: batteryCol
        x: 22
        y: parent.stacked ? 22 : (parent.height - implicitHeight) / 2
        width: 120
        spacing: 8
        Txt {
          text: Fmt.battery(root.dev ? root.dev.battery : null)
          font.pixelSize: 30
          font.weight: Font.Bold
          lineHeightMode: Text.FixedHeight
          lineHeight: 30
        }
        Bar {
          width: parent.width
          height: 6
          fill: Theme.ok
          value: root.dev && root.dev.battery ? (root.dev.battery.charge || 0) / 100 : 0
        }
        Row {
          spacing: 4
          readonly property var b: root.dev ? root.dev.battery : null
          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: Fmt.batteryIcon(parent.b)
            size: 13
            color: Theme.dim
          }
          Txt {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.b && parent.b.charging ? "Charging" : "Battery"
            color: Theme.dim
            font.pixelSize: 11
          }
        }
      }

      Column {
        id: facts
        x: parent.stacked ? 22 : batteryCol.x + batteryCol.width + 28
        y: parent.stacked ? batteryCol.y + batteryCol.implicitHeight + 18 : (parent.height - implicitHeight) / 2
        width: parent.width - x - 22 - (ringButton.visible && !parent.stacked ? ringButton.width + 18 : 0)
        spacing: 4
        Txt {
          width: parent.width
          text: root.dev ? root.dev.name : ""
          font.pixelSize: 20
          font.weight: Font.Bold
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          text: root.dev ? Fmt.typeName(root.dev.type) + (root.dev.pairedAt ? " · paired " + root.dev.pairedAt : "") : ""
          color: Theme.dim
          elide: Text.ElideRight
        }
        // The Flux app of the device and its version. An earlier app sends
        // no version.
        Txt {
          width: parent.width
          visible: text !== ""
          text: root.dev && root.dev.appVersion ? "Flux " + root.dev.appVersion + (root.dev.appUpdate ? " · " + root.dev.appUpdate + " is available" : "") : ""
          color: root.dev && root.dev.appUpdate ? Theme.warn : Theme.dim
          elide: Text.ElideRight
        }
        Row {
          spacing: 6
          readonly property var b: root.dev ? root.dev.battery : null
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 3.5
            color: root.online ? Theme.ok : Theme.dim
          }
          Txt {
            text: root.online ? "Connected" + (root.dev && root.dev.ip ? " · " + root.dev.ip : "") : "Offline"
            color: root.online ? Theme.ok : Theme.dim
          }
        }
        // The fingerprint of the certificate of the device, as the pair mode
        // and flux-cli unpair show it. The groups go to the next line as 1
        // part, so that no group is cut.
        Flow {
          objectName: "fingerprint"
          width: parent.width
          visible: fingerprintText.text !== ""
          topPadding: 2
          spacing: 6
          Txt { text: "Certificate"; color: Theme.dim; font.pixelSize: 11 }
          Txt {
            id: fingerprintText
            text: Fmt.hexGroups(root.dev ? root.dev.fingerprint : "")
            color: Theme.dim
            font.pixelSize: 11
          }
        }
      }

      // Flux rings only phones. A computer does not list findmyphone.
      OutlineButton {
        id: ringButton
        objectName: "ringButton"
        visible: root.view ? root.view.has("findmyphone") : true
        anchors.right: parent.right
        anchors.rightMargin: 22
        y: parent.stacked ? 22 : (parent.height - height) / 2
        icon: "bell-ring"
        text: "Ring " + Fmt.noun(root.dev ? root.dev.type : "")
        active: root.online
        onClicked: root.view.ring()
      }
    }

    AccessCard {
      objectName: "accessCard"
      width: parent.width
      view: root.view
      dev: root.dev
    }

    // The streams between the device and this computer.
    Column {
      width: parent.width
      spacing: 12
      visible: root.anyStream

      SectionLabel { text: "Streams"; font.pixelSize: 14 }

      GridLayout {
        id: grid
        width: parent.width
        columns: Math.max(1, Math.floor((width + 18) / (340 + 18)))
        columnSpacing: 18
        rowSpacing: 18
        uniformCellWidths: true

        // Phone camera, with its settings. The card spans the grid while
        // the settings are open.
        CameraCard {
          objectName: "cameraCard"
          visible: !!root.webcam || root.canAsk
          view: root.view
          webcam: root.webcam
          canStart: root.canAsk
          note: root.confirmNote(root.webcamAsked)
          idleTitle: root.idleTitle(root.webcamAsked, "the webcam")
          startActive: root.canSend(root.webcamSent)
          onStart: root.askStream("webcam")
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          Layout.columnSpan: settingsOpen ? grid.columns : 1
        }

        // Phone microphone
        StreamCard {
          objectName: "micCard"
          visible: !!root.mic || root.canAsk
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          icon: "mic"
          heading: "Phone microphone"
          stream: root.mic || ({})
          title: root.mic ? (root.mic.fromName || "The phone") + " is live as " + (root.mic.source || "Flux Microphone") : ""
          detail: root.mic ? Math.round((root.mic.rate || 48000) / 1000) + " kHz · " + (root.mic.channels === 2 ? "stereo" : "mono") : ""
          onStop: root.view.call("mic.stop", {})
          idle: !root.mic
          canStart: root.canAsk
          note: root.confirmNote(root.micAsked)
          idleTitle: root.idleTitle(root.micAsked, "the mic")
          startActive: root.canSend(root.micSent)
          onStart: root.askStream("mic")
        }

        // The device as a speaker of this computer.
        StreamCard {
          objectName: "speakerCard"
          visible: !!root.speaker || root.canAskSpeaker
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          icon: "cellphone-sound"
          heading: "Phone speaker"
          readonly property var s: root.speaker || ({})
          stream: root.speaker || ({})
          title: (s.toName || "The phone") + " plays the audio of this computer"
          // The muted output tells why this computer is silent.
          detail: s.muted ? s.muted + " is muted" : Math.round((s.rate || 48000) / 1000) + " kHz · " + (s.channels === 1 ? "mono" : "stereo")
          onStop: root.view.call("speaker.stop", {})
          idle: !root.speaker
          canStart: root.canAskSpeaker
          note: root.confirmNote(root.speakerAsked)
          idleTitle: root.confirmNote(root.speakerAsked) !== "" ? "Asked " + (root.dev.name || "the device") + " to play the audio of this computer" : "The phone speaker is off"
          startActive: root.canSend(root.speakerSent)
          onStart: root.askStream("speaker")
        }

        // The remote desktop of this computer on a device.
        StreamCard {
          objectName: "desktopCard"
          visible: root.desktopShown
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          icon: "monitor"
          heading: "Remote desktop"
          readonly property var d: root.desktop || ({})
          stream: ({ active: !!d.active })
          title: (d.toName || "A device") + (d.extend ? " extends this screen as " : " shows ") + (d.monitor || "this screen")
          detail: d.width ? d.width + "×" + d.height : ""
          onStop: root.view.call("desktop.stop", {})
        }

        // The devices that browse the files of this computer
        StreamCard {
          objectName: "browseCard"
          visible: root.browse.length > 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          icon: "folder"
          heading: "Browse PC"
          stream: ({ active: true })
          title: root.browse.map(function (b) { return b.name || "A device" }).join(", ") + (root.browse.length > 1 ? " browse" : " browses") + " this computer"
          detail: root.browse.length > 0 ? "Since " + Qt.formatTime(new Date(root.browse[0].since * 1000), "hh:mm") + " · read-only" : ""
          onStop: root.view.call("browse.stop", {})
        }

        // Phone screen mirror
        StreamCard {
          objectName: "screenCard"
          visible: !!root.screen
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 340
          icon: "screen-share"
          heading: "Phone screen"
          stream: root.screen || ({})
          title: root.screen ? (root.screen.fromName || "The phone") + " shows its screen in " + (root.screen.player || "a window") : ""
          detail: root.screen && root.screen.width ? root.screen.width + "×" + root.screen.height + " · close the window to stop" : ""
          onStop: root.view.call("screen.stop", {})
        }
      }
    }

    // The commands that the phone can run on this computer.
    Column {
      width: parent.width
      spacing: 12
      visible: root.view ? root.view.has("runcommand") : true

      Column {
        width: parent.width
        spacing: 4
        SectionLabel { text: "Commands"; font.pixelSize: 14 }
        Txt {
          width: parent.width
          text: root.devName + " lists these commands under Run commands. A tap on the phone runs the command on this computer."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }

      CommandList {
        objectName: "commandList"
        width: parent.width
        view: root.view
      }
    }

    // Unpair, the 1 action on this page that ends something.
    Card {
      objectName: "unpairCard"
      width: parent.width
      implicitHeight: Math.max(unpairText.implicitHeight, unpairButton.implicitHeight) + 36

      Column {
        id: unpairText
        x: 18
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - x - 18 - unpairButton.width - 18
        spacing: 3
        Txt {
          width: parent.width
          text: "Unpair " + root.devName
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          text: "This removes the device from Flux on this computer and on the device. You can pair it again later."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
      OutlineButton {
        id: unpairButton
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.verticalCenter: parent.verticalCenter
        icon: "unlink"
        text: "Unpair"
        textColor: Theme.err
        onClicked: root.view.unpair()
      }
    }
  }
}
