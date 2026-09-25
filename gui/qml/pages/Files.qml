import QtQuick
import ".."
import "../components"

// A drop zone to send files, and the list of transfers for the device.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var transfers: {
    var all = view && view.backend ? (view.backend.transfers || []) : []
    if (!dev) return all
    return all.filter(t => !t.device || t.device === dev.id)
  }

  implicitHeight: col.implicitHeight

  function send(paths) {
    if (!dev || paths.length === 0) return
    if (!online) {
      view.toast(view.devName + " is offline")
      return
    }
    view.call("share.files", { device: dev.id, paths: paths }, function () {
      root.view.toast(paths.length === 1 ? "Sending 1 file to " + root.view.devName : "Sending " + paths.length + " files to " + root.view.devName)
    })
  }

  property bool picking: false

  // The host opens the desktop file chooser. An empty list means that the
  // user canceled.
  // The chooser can close after the page is gone, so the callback uses
  // only values that live outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  function pick() {
    if (picking || !view || !view.backend || !dev) return
    picking = true
    var life = root.life
    var v = view
    var id = dev.id
    var name = view.devName
    v.backend.pickFiles("Send to " + name, function (paths) {
      if (life.alive) root.picking = false
      if (!paths || paths.length === 0) return
      v.call("share.files", { device: id, paths: paths }, function () {
        v.toast(paths.length === 1 ? "Sending 1 file to " + name : "Sending " + paths.length + " files to " + name)
      })
    })
  }

  function stateText(t) {
    var pct = t.size > 0 ? Math.floor(100 * (t.done || 0) / t.size) : 0
    if (t.state === "active") return pct + "%" + (t.rate > 0 ? " · " + Fmt.rate(t.rate) : "")
    if (t.state === "done") return t.dir === "out" ? "sent" : "done"
    return t.state || ""
  }

  function stateColor(t) {
    if (t.state === "active") return Theme.accent
    if (t.state === "done") return Theme.ok
    if (t.state === "failed") return Theme.err
    return Theme.dim
  }

  Column {
    id: col
    width: parent.width
    spacing: 0

    DashedRect {
      id: zone
      width: parent.width
      height: 170
      lineWidth: 1.5
      color: drop.containsDrag ? Theme.accent : Theme.dim
      fill: drop.containsDrag ? Theme.alpha(Theme.accent, 0.08) : "transparent"

      Column {
        anchors.centerIn: parent
        spacing: 6
        Txt {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Drop files to send to " + (root.view ? root.view.devName : "")
          font.pixelSize: 16
          font.weight: Font.DemiBold
        }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          Txt { text: "or "; color: Theme.dim }
          Txt {
            text: "browse this computer"
            color: Theme.accent
            font.underline: browseArea.containsMouse
            MouseArea {
              id: browseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pick()
            }
          }
        }
      }

      DropArea {
        id: drop
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: function (event) {
          var paths = []
          for (var i = 0; i < event.urls.length; i++) paths.push(Fmt.urlToPath(event.urls[i]))
          root.send(paths)
          event.acceptProposedAction()
        }
      }
    }

    Item { width: 1; height: 22 }

    Txt {
      visible: root.transfers.length === 0
      text: "No transfers yet."
      color: Theme.dim
    }

    Column {
      width: parent.width
      spacing: 10
      Repeater {
        model: root.transfers
        delegate: Card {
          id: row
          required property var modelData
          readonly property bool incoming: modelData.dir !== "out"
          // Columns: 28 px, name, a bar of 80 to 260 px, 110 px, 16 px gaps.
          readonly property real inner: width - 38
          readonly property real barWidth: Math.max(80, Math.min(260, inner - 28 - 110 - 48 - 120))
          width: col.width
          implicitHeight: nameCol.implicitHeight + 26

          Txt {
            x: 19
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            text: row.incoming ? "↓" : "↑"
            color: row.incoming ? Theme.ok : Theme.accent
          }
          Column {
            id: nameCol
            x: 19 + 28 + 16
            width: row.inner - 28 - 16 - row.barWidth - 16 - 16 - 110
            anchors.verticalCenter: parent.verticalCenter
            Txt { width: parent.width; text: modelData.name || ""; elide: Text.ElideMiddle }
            Txt { width: parent.width; text: Fmt.bytes(modelData.size); color: Theme.dim; font.pixelSize: 11 }
          }
          Bar {
            x: nameCol.x + nameCol.width + 16
            anchors.verticalCenter: parent.verticalCenter
            width: row.barWidth
            height: 5
            value: modelData.size > 0 ? (modelData.done || 0) / modelData.size : (modelData.state === "done" ? 1 : 0)
          }
          Txt {
            anchors.right: parent.right
            anchors.rightMargin: 19
            anchors.verticalCenter: parent.verticalCenter
            width: 110
            horizontalAlignment: Text.AlignRight
            text: root.stateText(modelData)
            color: root.stateColor(modelData)
            font.pixelSize: 12
            elide: Text.ElideLeft
          }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            enabled: modelData.state === "active" || modelData.state === "queued"
            onClicked: root.view.call("transfer.cancel", { id: modelData.id }, function () { root.view.toast("Canceled " + modelData.name) })
          }
        }
      }
    }
  }
}
