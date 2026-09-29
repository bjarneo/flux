import QtQuick
import ".."
import "../components"

// SMS conversations of an Android phone and the selected thread. The New
// message form sends a text message to a phone number.
Item {
  id: root
  property var view
  property bool fillHeight: true
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var convos: dev && dev.conversations ? dev.conversations : []

  property var selected: null
  // A narrow page shows 1 pane: the conversations, or 1 thread with a back
  // button.
  readonly property bool single: width < 620
  property bool threadOpen: false
  property var messages: []
  property bool loading: false
  property string loadedFor: ""
  // The New message form shows in place of the thread. sentTo is the
  // number of its last message, until that conversation appears.
  property bool composing: false
  property string sentTo: ""
  // The sent messages that the phone has not reported yet:
  // {thread, address, body, time, outgoing, pending, failed}. A new
  // conversation has thread -1.
  property var outbox: []
  // The phone sends a text message to 1 address, so a group gets no reply.
  readonly property bool group: !composing && addresses(selected).length > 1
  readonly property var shown: {
    var extra = outbox.filter(function (e) {
      if (composing) return e.thread < 0 && samePhone(e.address, sentTo)
      return inThread(e, selected)
    })
    return composing ? extra : messages.concat(extra)
  }

  implicitHeight: 480

  // A reply can arrive after the page is gone. The callbacks check this
  // object, which lives outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  function addresses(c) {
    if (!c) return []
    if (c.addresses && c.addresses.length) return c.addresses
    if (c.address) return [c.address]
    return c.name ? [c.name] : []
  }

  // Phone numbers match on their last 8 digits, so that +47 912 34 567
  // matches 91234567. Other addresses match without case.
  function samePhone(a, b) {
    a = String(a || "")
    b = String(b || "")
    var da = a.replace(/\D/g, "")
    var db = b.replace(/\D/g, "")
    var phone = /^[0-9+\-(). ]+$/
    if (da.length < 3 || db.length < 3 || !phone.test(a) || !phone.test(b)) return a.toLowerCase() === b.toLowerCase()
    return da.slice(-8) === db.slice(-8)
  }

  function inThread(e, c) {
    if (!c) return false
    if (e.thread >= 0) return e.thread === c.thread
    var a = addresses(c)
    return a.length === 1 && samePhone(a[0], e.address)
  }

  // True when 2 objects of 1 conversation show the same name and addresses.
  function sameConvo(a, b) {
    return a.name === b.name && a.address === b.address && addresses(a).join("\n") === addresses(b).join("\n")
  }

  // The conversation with only this address, or null.
  function findConvo(address) {
    for (var i = 0; i < convos.length; i++) {
      var a = addresses(convos[i])
      if (a.length === 1 && samePhone(a[0], address)) return convos[i]
    }
    return null
  }

  function load(c) {
    if (!c || !dev) return
    selected = c
    loading = loadedFor !== dev.id + ":" + c.thread
    var life = root.life
    var devId = dev.id
    view.call("sms.thread", { device: devId, thread: c.thread }, function (result) {
      if (!life.alive) return
      var msgs = result.messages || []
      root.confirm(c, msgs)
      // The user can open another thread before the answer comes.
      if (!root.dev || root.dev.id !== devId || !root.selected || root.selected.thread !== c.thread) return
      root.messages = msgs
      root.loading = false
      root.loadedFor = devId + ":" + c.thread
    })
  }

  // Removes the sent messages that the phone now reports in the thread.
  function confirm(c, msgs) {
    var keep = outbox.filter(function (e) {
      if (!inThread(e, c)) return true
      for (var i = 0; i < msgs.length; i++) {
        var m = msgs[i]
        // The clocks of the phone and the computer can differ a little.
        if (m.outgoing && m.body === e.body && m.time >= e.time - 120) return false
      }
      return true
    })
    if (keep.length !== outbox.length) outbox = keep
  }

  function compose() {
    composing = true
    threadOpen = true
    sentTo = ""
    to.clear()
    Qt.callLater(function () { to.input.forceActiveFocus() })
  }

  function open(c) {
    composing = false
    load(c)
    threadOpen = true
  }

  function send() {
    var text = draft.text.trim()
    if (text === "" || !dev || group) return
    if (!online) {
      view.toast(view.devName + " is offline")
      return
    }
    var target = composing ? to.text.trim() : ""
    if (composing && target === "") {
      view.toast("Enter a phone number")
      return
    }
    // A number of a known conversation goes to that conversation.
    if (composing && findConvo(target)) open(findConvo(target))
    var c = composing ? null : selected
    if (!composing && !c) return
    var list = c ? addresses(c) : [target]
    var entry = { thread: c ? c.thread : -1, address: list[0], body: text, time: Math.floor(Date.now() / 1000), outgoing: true, pending: true, failed: false }
    var life = root.life
    view.call("sms.send", { device: dev.id, addresses: list, body: text }, function () {
      if (!life.alive) return
      if (entry.thread < 0) root.sentTo = entry.address
      root.outbox = root.outbox.concat([entry])
      draft.clear()
      refreshTimer.restart()
    })
  }

  // The phone reports each new message. This is a second check for a
  // phone that does not.
  Timer {
    id: refreshTimer
    interval: 4000
    onTriggered: {
      if (!root.dev || !root.online) return
      if (root.composing) root.view.call("sms.refresh", { device: root.dev.id })
      else root.load(root.selected)
    }
  }

  // A sent message that the phone does not report in 60 seconds shows as
  // not sent.
  Timer {
    interval: 5000
    repeat: true
    running: root.outbox.some(function (e) { return !e.failed })
    onTriggered: {
      var now = Math.floor(Date.now() / 1000)
      var changed = false
      var next = root.outbox.map(function (e) {
        if (e.failed || now - e.time < 60) return e
        changed = true
        return Object.assign({}, e, { pending: false, failed: true })
      })
      if (changed) root.outbox = next
    }
  }

  onShownChanged: Qt.callLater(function () { thread.positionViewAtEnd() })

  onConvosChanged: {
    if (composing) {
      // The first message to a new number makes a conversation.
      var made = sentTo !== "" ? findConvo(sentTo) : null
      if (made) {
        sentTo = ""
        open(made)
      }
      return
    }
    if (convos.length === 0) return
    if (!selected) {
      load(convos[0])
      return
    }
    for (var i = 0; i < convos.length; i++) {
      var c = convos[i]
      if (c.thread !== selected.thread) continue
      // A new message, or a new state of the last message, loads the thread.
      if (c.time !== selected.time || c.last !== selected.last || !!c.pending !== !!selected.pending || !!c.failed !== !!selected.failed) load(c)
      // Each state event gives a new object for the same conversation. Keep
      // the old object when nothing that the page shows changed. A new
      // object makes the thread list build again and scroll to the end
      // while the outbox has a message, for example 1 that was not sent.
      else if (!sameConvo(c, selected)) selected = c
      return
    }
  }

  onOnlineChanged: {
    if (!online || !dev) return
    view.call("sms.refresh", { device: dev.id })
    if (selected && !composing) load(selected)
  }

  Component.onCompleted: {
    if (dev && online) view.call("sms.refresh", { device: dev.id })
    if (!selected && convos.length > 0) load(convos[0])
  }

  // Conversations
  Item {
    id: convoPane
    width: root.single ? parent.width : 280
    height: parent.height
    visible: !root.single || !root.threadOpen

    OutlineButton {
      id: newButton
      width: parent.width
      icon: "plus"
      text: "New message"
      active: root.online
      onClicked: root.compose()
    }

    ListView {
      id: convoList
      anchors.top: newButton.bottom
      anchors.topMargin: 12
      anchors.bottom: parent.bottom
      width: parent.width
      spacing: 6
      clip: true
      model: root.convos
      boundsBehavior: Flickable.StopAtBounds
      delegate: Rectangle {
        required property var modelData
        readonly property bool sel: !root.composing && !!root.selected && root.selected.thread === modelData.thread
        readonly property bool unread: !!modelData.unread
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
              anchors.right: unread ? cDot.left : cTime.left
              anchors.rightMargin: 8
              text: modelData.name || modelData.address || ""
              font.weight: unread ? Font.Bold : Font.DemiBold
              elide: Text.ElideRight
            }
            // An unread conversation has a dot before its time.
            Rectangle {
              id: cDot
              visible: unread
              anchors.right: cTime.left
              anchors.rightMargin: 6
              anchors.verticalCenter: cTime.verticalCenter
              width: 7
              height: 7
              radius: 3.5
              color: Theme.accent
            }
            Txt {
              id: cTime
              anchors.right: parent.right
              anchors.verticalCenter: cName.verticalCenter
              text: Fmt.when(modelData.time)
              color: unread ? Theme.fg : Theme.dim
              font.pixelSize: 11
            }
          }
          Txt {
            width: parent.width
            text: (modelData.failed ? "Not sent: " : (modelData.outgoing ? "You: " : "")) + (modelData.last || "").replace(/\n/g, " ")
            color: modelData.failed ? Theme.err : (unread ? Theme.fg : Theme.dim)
            font.pixelSize: 12
            elide: Text.ElideRight
          }
        }
        MouseArea {
          id: cArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.open(modelData)
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
  }

  // Thread
  Card {
    id: pane
    anchors.left: root.single ? parent.left : convoPane.right
    anchors.leftMargin: root.single ? 0 : 18
    anchors.right: parent.right
    height: parent.height
    visible: !root.single || root.threadOpen

    OutlineButton {
      id: backButton
      visible: root.single
      x: 19
      anchors.verticalCenter: threadName.verticalCenter
      icon: "arrow-left"
      padX: 8
      padY: 4
      onClicked: {
        root.threadOpen = false
        root.composing = false
      }
    }
    Txt {
      id: threadName
      x: root.single ? backButton.x + backButton.width + 10 : 19
      y: 19
      width: parent.width - x - 19
      text: root.composing ? "New message" : (root.selected ? (root.selected.name || root.selected.address || "") : "Messages")
      font.weight: Font.Bold
      elide: Text.ElideRight
    }
    Field {
      id: to
      visible: root.composing
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: threadName.bottom
      anchors.leftMargin: 19
      anchors.rightMargin: 19
      anchors.topMargin: 12
      placeholder: "Phone number"
      onAccepted: draft.input.forceActiveFocus()
      onEscaped: root.composing = false
    }

    ListView {
      id: thread
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: root.composing ? to.bottom : threadName.bottom
      anchors.bottom: inputRow.top
      anchors.leftMargin: 19
      anchors.rightMargin: 19
      anchors.topMargin: 10
      anchors.bottomMargin: 10
      spacing: 10
      clip: true
      model: root.shown
      boundsBehavior: Flickable.StopAtBounds
      delegate: Item {
        required property var modelData
        // In a group, each received message names its sender.
        readonly property bool named: root.group && !modelData.outgoing && !!(modelData.name || modelData.address)
        width: thread.width
        height: bCol.height
        Column {
          id: bCol
          anchors.right: modelData.outgoing ? parent.right : undefined
          anchors.left: modelData.outgoing ? undefined : parent.left
          spacing: 4
          Txt {
            visible: named
            text: modelData.name || modelData.address || ""
            color: Theme.dim
            font.pixelSize: 11
          }
          Rectangle {
            id: bubble
            anchors.right: modelData.outgoing ? parent.right : undefined
            width: Math.min(msg.implicitWidth, thread.width * 0.7 - 26) + 26
            height: msg.implicitHeight + 18
            color: modelData.outgoing ? Theme.accent : Theme.bg3
            opacity: modelData.pending ? 0.6 : 1
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
          Txt {
            visible: !!modelData.pending || !!modelData.failed
            anchors.right: modelData.outgoing ? parent.right : undefined
            text: modelData.failed ? "Not sent" : "Sending…"
            color: modelData.failed ? Theme.err : Theme.dim
            font.pixelSize: 11
          }
        }
      }

      Txt {
        visible: root.loading && !root.composing
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
        enabled: !root.group
        opacity: enabled ? 1 : 0.6
        placeholder: root.group ? "Reply to group messages on the phone" : "Text message via " + (root.view ? root.view.devName : "")
        onAccepted: root.send()
      }
      AccentButton {
        id: sendButton
        anchors.verticalCenter: draft.verticalCenter
        icon: "send"
        text: "Send"
        padX: 16
        padY: 10
        active: root.online && !root.group && (root.composing ? to.text.trim() !== "" : !!root.selected)
        onClicked: root.send()
      }
    }
  }
}
