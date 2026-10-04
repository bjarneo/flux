import QtQuick
import ".."
import "../components"

// Notifications from the device. A row can be dismissed, and a row with a
// reply ID has a reply field. Clear all dismisses each row that can be
// dismissed.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var notifs: dev && dev.notifications ? dev.notifications : []
  readonly property int clearable: notifs.filter(function (n) { return n.dismissable !== false }).length
  // A card shows at most this number of action buttons. fluxd keeps the
  // same number of actions, so each action that it keeps has a button.
  readonly property int maxActions: 8
  property double now: Date.now() / 1000
  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = Date.now() / 1000 }

  function ruleText(rule) {
    var text = rule.app + ": " + rule.mode
    if (rule.until) text += rule.until <= now ? " · Expired" : " · Until " + new Date(rule.until * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat)
    if (rule.start && rule.end) text += " · " + rule.start + " to " + rule.end
    return text
  }

  implicitHeight: list.implicitHeight

  // The cards follow the notifications by ID. A new notification adds 1
  // card, and the other cards keep their state, such as a reply that the
  // user types. Another device gets new cards, so a reply does not go to a
  // notification of that device with the same ID.
  KeyedModel { id: rows; values: root.notifs; scope: root.dev ? root.dev.id : "" }

  Column {
    id: list
    width: Math.min(parent.width, 760)
    spacing: 10

    Repeater {
      model: root.view && root.view.backend && root.view.backend.state.settings ?
        (root.view.backend.state.settings.notificationRules || []).filter(r => !r.device || (root.dev && r.device === root.dev.id)) : []
      delegate: Row {
        required property var modelData
        width: list.width
        spacing: 8
        Txt { width: Math.max(0, parent.width - removeRule.width - parent.spacing); anchors.verticalCenter: parent.verticalCenter; text: root.ruleText(modelData); color: Theme.dim; wrapMode: Text.Wrap }
        OutlineButton { id: removeRule; anchors.verticalCenter: parent.verticalCenter; text: "Remove rule"; fontSize: 11; onClicked: root.view.call("notification.rule.remove", { id: modelData.id }) }
      }
    }

    Item {
      visible: root.clearable > 0
      width: parent.width
      height: clearAll.implicitHeight
      Txt {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.notifs.length === 1 ? "1 notification" : root.notifs.length + " notifications"
        color: Theme.dim
        font.pixelSize: 12
      }
      OutlineButton {
        id: clearAll
        anchors.right: parent.right
        icon: "close"
        text: "Clear all"
        active: root.online
        onClicked: root.view.call("notification.dismissAll", { device: root.dev.id })
      }
    }

    Txt {
      visible: root.notifs.length === 0
      width: parent.width
      text: "No notifications from " + (root.view ? root.view.devName : "the device") + "."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Repeater {
      model: rows
      delegate: Card {
        id: card
        required property string key
        readonly property var modelData: rows.byId[key] || ({})
        readonly property bool replyable: !!modelData.replyId
        property bool replying: false
        // The action buttons. The text changes only when the actions
        // change, so a state event does not build the buttons again.
        readonly property string actionsText: JSON.stringify(Array.isArray(modelData.actions) ? modelData.actions.slice(0, root.maxActions) : [])
        readonly property var actions: JSON.parse(actionsText)
        width: list.width
        implicitHeight: Math.max(36, body.implicitHeight) + 30

        Rectangle {
          id: badge
          x: 19
          y: 15
          width: 36
          height: 36
          color: Theme.alpha(Theme[Fmt.appToken(modelData.app)], 0.18)
          Icon {
            anchors.centerIn: parent
            name: Fmt.appIcon(modelData.app)
            size: 20
            color: Theme[Fmt.appToken(modelData.app)]
          }
        }

        Column {
          id: body
          anchors.left: badge.right
          anchors.leftMargin: 14
          anchors.right: parent.right
          anchors.rightMargin: 19
          y: 15
          spacing: 2

          Item {
            width: parent.width
            height: appLine.implicitHeight
            Txt {
              id: appLine
              anchors.left: parent.left
              anchors.right: meta.left
              anchors.rightMargin: 12
              text: modelData.app || ""
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
            Row {
              id: meta
              anchors.right: parent.right
              spacing: 10
              Txt { text: Fmt.age(modelData.time); color: Theme.dim; font.pixelSize: 11 }
              Txt {
                visible: modelData.dismissable !== false
                text: "×"
                color: closeArea.containsMouse ? Theme.fg : Theme.dim
                font.pixelSize: 11
                MouseArea {
                  id: closeArea
                  anchors.fill: parent
                  anchors.margins: -4
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.view.call("notification.dismiss", { device: root.dev.id, id: modelData.id })
                }
              }
            }
          }
          Txt {
            width: parent.width
            text: modelData.title || ""
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
            visible: text !== ""
          }
          Txt {
            width: parent.width
            text: modelData.text || ""
            color: Theme.dim
            wrapMode: Text.Wrap
            visible: text !== ""
          }

          Flow {
            width: parent.width
            spacing: 8
            topPadding: 8
            visible: true
            OutlineButton {
              text: "Mute app for 1 hour"
              fontSize: 11
              padY: 4
              onClicked: root.view.call("notification.rule.add", { config: { device: root.dev.id, app: modelData.app, mode: "mute", until: Math.floor(Date.now() / 1000) + 3600 } })
            }
            OutlineButton {
              visible: card.replyable && !card.replying
              icon: "reply"
              text: "Reply"
              padX: 10
              padY: 4
              fontSize: 11
              onClicked: {
                card.replying = true
                reply.input.forceActiveFocus()
              }
            }
            Repeater {
              model: card.actions
              delegate: OutlineButton {
                required property var modelData
                text: modelData
                padX: 10
                padY: 4
                fontSize: 11
                onClicked: root.view.call("notification.action", { device: root.dev.id, id: card.modelData.id, action: modelData })
              }
            }
          }

          Row {
            width: parent.width
            spacing: 10
            topPadding: 8
            visible: card.replying
            Field {
              id: reply
              width: parent.width - send.width - 10
              padY: 7
              placeholder: "Reply to " + (card.modelData.title || card.modelData.app || "")
              onAccepted: send.clicked()
            }
            AccentButton {
              id: send
              icon: "send"
              text: "Send"
              padY: 8
              onClicked: {
                var msg = reply.text.trim()
                if (msg === "") return
                root.view.call("notification.reply", { device: root.dev.id, id: card.modelData.id, message: msg }, function () {
                  reply.clear()
                  card.replying = false
                  root.view.toast("Reply sent")
                })
              }
            }
          }
        }
      }
    }
  }
}
