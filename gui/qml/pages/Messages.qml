import QtQuick
import ".."
import "../components"

// SMS conversations of an Android phone and the selected thread.
Item {
  id: root
  property var view
  property bool fillHeight: true
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var convos: dev && dev.conversations ? dev.conversations : []

  property var selected: null
  property var messages: []
  property bool loading: false
  property string loadedFor: ""

  implicitHeight: 480

  // A reply can arrive after the page is gone. The callbacks check this
  // object, which lives outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  function addresses(c) {
    if (!c) return []
    if (c.addresses && c.addresses.length) return c.addresses
    if (c.address) return [c.address]
    return [c.name]
  }

  function load(c) {
    if (!c || !dev) return
    selected = c
    loading = loadedFor !== dev.id + ":" + c.thread
    var life = root.life
    view.call("sms.thread", { device: dev.id, thread: c.thread }, function (result) {
      if (!life.alive) return
      root.messages = result.messages || []
      root.loading = false
      root.loadedFor = root.dev.id + ":" + c.thread
      Qt.callLater(function () { thread.positionViewAtEnd() })
    })
  }

  function send() {
    var text = draft.text.trim()
    if (text === "" || !selected || !dev) return
    if (!online) {
      view.toast(view.devName + " is offline")
      return
    }
    var c = selected
    var life = root.life
    view.call("sms.send", { device: dev.id, addresses: addresses(c), body: text }, function () {
      if (life.alive) refreshTimer.restart()
    })
    var next = messages.slice()
    next.push({ body: text, time: Math.floor(Date.now() / 1000), outgoing: true })
    messages = next
    draft.clear()
    Qt.callLater(function () { thread.positionViewAtEnd() })
  }

  Timer {
    id: refreshTimer
    interval: 1500
    onTriggered: root.load(root.selected)
  }

  onConvosChanged: {
    if (convos.length === 0) return
    if (!selected) {
      load(convos[0])
      return
    }
    for (var i = 0; i < convos.length; i++) {
      if (convos[i].thread === selected.thread) {
        if (convos[i].time !== selected.time) load(convos[i])
        else selected = convos[i]
        return
      }
    }
  }

  Component.onCompleted: {
    if (dev && online) view.call("sms.refresh", { device: dev.id })
    if (!selected && convos.length > 0) load(convos[0])
  }

  // Conversations
  ListView {
    id: convoList
    width: 280
    height: parent.height
    spacing: 6
    clip: true
    model: root.convos
    boundsBehavior: Flickable.StopAtBounds
    delegate: Rectangle {
      required property var modelData
      readonly property bool sel: !!root.selected && root.selected.thread === modelData.thread
      width: convoList.width
      height: cCol.implicitHeight + 24
      color: sel ? Theme.bg2 : (cArea.containsMouse ? Theme.alpha(Theme.bg2, 0.5) : "transparent")
      Column {
        id: cCol
        x: 14
        y: 12
        width: parent.width - 28
        Item {
          width: parent.width
          height: cName.implicitHeight
          Txt {
            id: cName
            anchors.left: parent.left
            anchors.right: cTime.left
            anchors.rightMargin: 8
            text: modelData.name || modelData.address || ""
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }
          Txt {
            id: cTime
            anchors.right: parent.right
            anchors.verticalCenter: cName.verticalCenter
            text: Fmt.when(modelData.time)
            color: Theme.dim
            font.pixelSize: 11
          }
        }
        Txt {
          width: parent.width
          text: (modelData.last || "").replace(/\n/g, " ")
          color: Theme.dim
          font.pixelSize: 12
          elide: Text.ElideRight
        }
      }
      MouseArea {
        id: cArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.load(modelData)
      }
    }

    Txt {
      visible: root.convos.length === 0
      width: parent.width
      text: root.online ? "No conversations yet." : "Conversations appear when the phone connects."
      color: Theme.dim
      wrapMode: Text.Wrap
    }
  }

  // Thread
  Card {
    id: pane
    anchors.left: convoList.right
    anchors.leftMargin: 18
    anchors.right: parent.right
    height: parent.height

    Txt {
      id: threadName
      x: 19
      y: 19
      width: parent.width - 38
      text: root.selected ? (root.selected.name || root.selected.address || "") : "Messages"
      font.weight: Font.Bold
      elide: Text.ElideRight
    }

    ListView {
      id: thread
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: threadName.bottom
      anchors.bottom: inputRow.top
      anchors.leftMargin: 19
      anchors.rightMargin: 19
      anchors.topMargin: 10
      anchors.bottomMargin: 10
      spacing: 10
      clip: true
      model: root.messages
      boundsBehavior: Flickable.StopAtBounds
      delegate: Item {
        required property var modelData
        width: thread.width
        height: bubble.height
        Rectangle {
          id: bubble
          anchors.right: modelData.outgoing ? parent.right : undefined
          anchors.left: modelData.outgoing ? undefined : parent.left
          width: Math.min(msg.implicitWidth, thread.width * 0.7 - 26) + 26
          height: msg.implicitHeight + 18
          color: modelData.outgoing ? Theme.accent : Theme.bg3
          Txt {
            id: msg
            x: 13
            y: 9
            width: Math.min(implicitWidth, thread.width * 0.7 - 26)
            text: modelData.body || ""
            color: modelData.outgoing ? Theme.bg : Theme.fg
            wrapMode: Text.Wrap
          }
        }
      }

      Txt {
        visible: root.loading
        text: "Loading messages…"
        color: Theme.dim
      }
    }

    Row {
      id: inputRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 19
      spacing: 10
      Field {
        id: draft
        width: parent.width - sendButton.width - 10
        placeholder: "Text message via " + (root.view ? root.view.devName : "")
        onAccepted: root.send()
      }
      AccentButton {
        id: sendButton
        anchors.verticalCenter: draft.verticalCenter
        text: "Send"
        padX: 16
        padY: 10
        active: root.online && !!root.selected
        onClicked: root.send()
      }
    }
  }
}
