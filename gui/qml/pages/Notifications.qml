import QtQuick
import ".."
import "../components"

// Notifications from the device. A row can be dismissed, and a row with a
// reply ID has a reply field.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property var notifs: dev && dev.notifications ? dev.notifications : []

  implicitHeight: list.implicitHeight

  Column {
    id: list
    width: Math.min(parent.width, 760)
    spacing: 10

    Txt {
      visible: root.notifs.length === 0
      width: parent.width
      text: "No notifications from " + (root.view ? root.view.devName : "the device") + "."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Repeater {
      model: root.notifs
      delegate: Card {
        id: card
        required property var modelData
        readonly property bool replyable: !!modelData.replyId
        property bool replying: false
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
            visible: card.replyable || (modelData.actions && modelData.actions.length > 0)
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
              model: modelData.actions || []
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
