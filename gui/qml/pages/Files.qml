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
  readonly property var pending: transfers.filter(t => ["waiting", "queued", "active"].indexOf(t.state) >= 0)
  readonly property real pendingBytes: pending.reduce((n, t) => n + (t.size || 0), 0)
  readonly property real pendingDone: pending.reduce((n, t) => n + (t.done || 0), 0)

  implicitHeight: col.implicitHeight

  // skipped is the number of dropped items that are not files on this
  // computer.
  function send(paths, skipped) {
    var note = skipped === 1 ? "1 item is not a file on this computer."
      : (skipped > 1 ? skipped + " items are not files on this computer." : "")
    if (!dev) return
    if (paths.length === 0) {
      if (note !== "") view.toast("Flux sends only files on this computer.")
      return
    }
    view.call("share.files", { device: dev.id, paths: paths }, function () {
      var sending = "Queued " + paths.length + " items for " + root.view.devName
      root.view.toast(note !== "" ? sending + ". " + note : sending)
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
        v.toast("Queued " + paths.length + " items for " + name)
      })
    })
  }

  function stateText(t) {
    var pct = t.size > 0 ? Math.floor(100 * (t.done || 0) / t.size) : 0
    if (t.state === "active") return pct + "%" + (t.rate > 0 ? " · " + Fmt.rate(t.rate) : "")
    if (t.state === "done") return t.dir === "out" ? "sent" : "done"
    if (t.state === "waiting") return "waiting"
    return t.state || ""
  }

  function stateColor(t) {
    if (t.state === "active") return Theme.accent
    if (t.state === "done") return Theme.ok
    if (t.state === "failed") return Theme.err
    return Theme.dim
  }

  // Progress events come 4 times a second for each transfer. The rows
  // follow the transfers by ID, so a progress event only updates them.
  KeyedModel { id: rows; values: root.transfers }

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
        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: "tray-up"
          size: 34
          color: drop.containsDrag ? Theme.accent : Theme.dim
        }
        Txt {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(implicitWidth, zone.width - 32)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: "Drop files or folders for " + (root.view ? root.view.devName : "")
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
        // Only local file URLs become paths. A URL of the trash or of a
        // network place has no local path that fluxd can read.
        onDropped: function (event) {
          var paths = []
          var skipped = 0
          for (var i = 0; i < event.urls.length; i++) {
            var path = Fmt.urlToPath(event.urls[i])
            if (path !== "") paths.push(path)
            else skipped++
          }
          root.send(paths, skipped)
          event.acceptProposedAction()
        }
      }
    }

    Item { width: 1; height: 22 }

    Txt {
      width: parent.width
      text: "Folders use ZIP archives. Queued files stay in the outbox until the device connects."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Item { width: 1; height: 12 }

    Txt {
      visible: root.pending.length > 0
      width: parent.width
      text: root.pending.length + " pending · " + Fmt.bytes(root.pendingDone) + " of " + Fmt.bytes(root.pendingBytes)
      color: Theme.dim
    }

    Item { width: 1; height: root.pending.length > 0 ? 12 : 0 }

    Txt {
      visible: root.transfers.length === 0
      text: "No transfers yet."
      color: Theme.dim
    }

    Column {
      width: parent.width
      spacing: 10
      Repeater {
        model: rows
        delegate: Card {
          id: row
          required property string key
          readonly property var modelData: rows.byId[key] || ({})
          readonly property bool incoming: modelData.dir !== "out"
          // Columns: 28 px, name, a bar of 80 to 260 px, 110 px, 16 px gaps.
          // A narrow row puts the bar under the name, so the name keeps room.
          readonly property real inner: width - 38
          readonly property bool compact: inner < 460
          readonly property real statusWidth: compact ? 90 : 110
          readonly property real barWidth: compact ? 0 : Math.max(80, Math.min(260, inner - 28 - 110 - 48 - 120))
          readonly property real progress: modelData.size > 0 ? (modelData.done || 0) / modelData.size : (modelData.state === "done" ? 1 : 0)
          width: col.width
          implicitHeight: nameCol.implicitHeight + 26 + (actions.visible ? actions.implicitHeight + 18 : 0)

          // The direction: received from the device, or sent to it.
          Icon {
            x: 19
            y: 13
            name: row.incoming ? "tray-down" : "tray-up"
            size: 20
            color: row.incoming ? Theme.ok : Theme.accent
          }
          Column {
            id: nameCol
            x: 19 + 28 + 16
            width: row.compact ? row.inner - 28 - 16 - 16 - row.statusWidth : row.inner - 28 - 16 - row.barWidth - 16 - 16 - 110
            y: 13
            spacing: row.compact ? 3 : 0
            // A name from the phone can hide its real extension with bidi
            // controls, so the row shows them as codes.
            Txt { width: parent.width; text: Fmt.showControls(modelData.name); elide: Text.ElideMiddle }
            Txt { width: parent.width; text: Fmt.bytes(modelData.size); color: Theme.dim; font.pixelSize: 11 }
            Txt { visible: !!modelData.error; width: parent.width; text: modelData.error || ""; color: Theme.warn; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
            Bar {
              visible: row.compact
              width: parent.width
              height: 4
              value: row.progress
            }
          }
          Bar {
            visible: !row.compact
            x: nameCol.x + nameCol.width + 16
            y: nameCol.y + nameCol.implicitHeight / 2 - height / 2
            width: row.barWidth
            height: 5
            value: row.progress
          }
          Txt {
            anchors.right: parent.right
            anchors.rightMargin: 19
            y: nameCol.y + nameCol.implicitHeight / 2 - height / 2
            width: row.statusWidth
            horizontalAlignment: Text.AlignRight
            // A narrow row shows the percent and leaves out the rate.
            text: row.compact ? root.stateText(modelData).split(" · ")[0] : root.stateText(modelData)
            color: root.stateColor(modelData)
            font.pixelSize: 12
            elide: Text.ElideLeft
          }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            enabled: modelData.state === "active" || modelData.state === "queued" || modelData.state === "waiting"
            onClicked: root.view.call("transfer.cancel", { id: modelData.id }, function () { root.view.toast("Canceled " + Fmt.showControls(modelData.name)) })
          }
          Row {
            id: actions
            visible: ["waiting", "queued", "active"].indexOf(modelData.state) >= 0
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 12
            spacing: 8
            OutlineButton {
              visible: modelData.state === "waiting"
              text: "Retry now"
              fontSize: 11
              onClicked: root.view.call("transfer.retry", { id: modelData.id })
            }
            OutlineButton {
              text: "Cancel"
              fontSize: 11
              onClicked: root.view.call("transfer.cancel", { id: modelData.id })
            }
          }
        }
      }
    }
  }
}
