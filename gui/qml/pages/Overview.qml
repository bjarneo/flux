import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// Battery and device facts, quick actions, the latest notifications, and
// the player on the device.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var media: dev && dev.media ? dev.media : null
  readonly property var notifs: dev && dev.notifications ? dev.notifications.slice(0, 3) : []
  // The phone camera as a webcam on this computer. Null when it is not used.
  readonly property var webcam: view && view.backend && view.backend.state ? (view.backend.state.webcam || null) : null

  implicitHeight: grid.implicitHeight

  // The media position moves forward while the player plays.
  property real mediaBase: media ? (media.position || 0) : 0
  property real mediaStamp: Date.now()
  property real now: Date.now()
  property string mediaKey: ""
  onMediaChanged: {
    var k = media ? [media.player, media.title, media.position, media.playing].join("|") : ""
    if (k === mediaKey) return
    mediaKey = k
    mediaBase = media ? (media.position || 0) : 0
    mediaStamp = Date.now()
    now = mediaStamp
  }
  readonly property real position: {
    if (!media) return 0
    var p = mediaBase + (media.playing ? now - mediaStamp : 0)
    return media.length > 0 ? Math.min(p, media.length) : p
  }
  Timer {
    interval: 1000
    repeat: true
    running: !!root.media && !!root.media.playing
    onTriggered: root.now = Date.now()
  }

  GridLayout {
    id: grid
    width: parent.width
    columns: Math.max(1, Math.floor((width + 18) / (320 + 18)))
    columnSpacing: 18
    rowSpacing: 18
    uniformCellWidths: true

    // Battery and device facts
    Card {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: Math.max(batteryCol.implicitHeight, facts.implicitHeight) + 46

      Column {
        id: batteryCol
        x: 23
        anchors.verticalCenter: parent.verticalCenter
        width: 110
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
          height: 8
          fill: Theme.ok
          value: root.dev && root.dev.battery ? (root.dev.battery.charge || 0) / 100 : 0
        }
        Row {
          spacing: 4
          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: Fmt.batteryIcon(root.dev ? root.dev.battery : null)
            size: 13
            color: Theme.dim
          }
          Txt { anchors.verticalCenter: parent.verticalCenter; text: "battery"; color: Theme.dim; font.pixelSize: 11 }
        }
      }

      Column {
        id: facts
        anchors.left: batteryCol.right
        anchors.leftMargin: 22
        anchors.right: parent.right
        anchors.rightMargin: 23
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4
        Txt {
          width: parent.width
          text: root.dev ? root.dev.name : ""
          font.pixelSize: 22
          font.weight: Font.Bold
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          text: root.dev ? Fmt.typeName(root.dev.type) + (root.dev.pairedAt ? " · paired " + root.dev.pairedAt : "") : ""
          color: Theme.dim
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          readonly property var b: root.dev ? root.dev.battery : null
          text: "● " + (root.online ? "connected" : "offline") + (root.online && b ? " · " + (b.charging ? "charging" : "discharging") : "")
          color: root.online ? Theme.ok : Theme.dim
          elide: Text.ElideRight
        }
        Txt {
          width: parent.width
          visible: text !== ""
          text: root.dev ? Fmt.signal(root.dev.signal) : ""
          color: Theme.dim
          elide: Text.ElideRight
        }
      }
    }

    // Quick actions
    GridLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      columns: 2
      columnSpacing: 10
      rowSpacing: 10
      uniformCellWidths: true

      Tile {
        Layout.fillWidth: true
        icon: "bell-ring"
        label: "Ring " + Fmt.noun(root.dev ? root.dev.type : "")
        active: root.online
        onClicked: root.view.ring()
      }
      Tile {
        Layout.fillWidth: true
        icon: "upload"
        label: "Send file"
        onClicked: root.view.go("files")
      }
      Tile {
        Layout.fillWidth: true
        icon: "browse"
        label: "Browse storage"
        active: root.view ? root.view.has("sftp") : true
        onClicked: root.view.go("browse")
      }
      Tile {
        Layout.fillWidth: true
        icon: "music"
        label: "Media"
        onClicked: root.view.go("media")
      }
    }

    // Latest notifications
    Card {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: notifCol.implicitHeight + 38

      Column {
        id: notifCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 19
        spacing: 12
        SectionLabel { text: "LATEST NOTIFICATIONS" }
        Txt {
          visible: root.notifs.length === 0
          text: "No notifications"
          color: Theme.dim
        }
        Repeater {
          model: root.notifs
          delegate: Item {
            required property var modelData
            width: notifCol.width
            height: nCol.implicitHeight
            Icon {
              y: 1
              name: Fmt.appIcon(modelData.app)
              size: 15
              color: Theme[Fmt.appToken(modelData.app)]
            }
            Column {
              id: nCol
              x: 26
              width: parent.width - 26
              Txt {
                width: parent.width
                text: (modelData.app || "") + " · " + (modelData.title || "")
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              Txt {
                width: parent.width
                text: (modelData.text || "").replace(/\n/g, " ")
                color: Theme.dim
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }

    // Now playing
    Card {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      implicitHeight: playCol.implicitHeight + 38

      Column {
        id: playCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 19
        spacing: 12
        SectionLabel { text: "NOW PLAYING" }
        Item {
          width: parent.width
          height: 64

          Item {
            id: art
            width: 64
            height: 64
            IconBox { anchors.fill: parent; icon: "music"; visible: artImage.status !== Image.Ready }
            Image {
              id: artImage
              anchors.fill: parent
              source: root.media && root.media.art ? "file://" + root.media.art : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              visible: status === Image.Ready
            }
          }

          Column {
            anchors.left: art.right
            anchors.leftMargin: 14
            anchors.right: playButton.left
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            Txt {
              width: parent.width
              text: root.media && root.media.title ? root.media.title : "Nothing playing"
              font.weight: Font.Bold
              elide: Text.ElideRight
            }
            Txt {
              width: parent.width
              text: root.media && root.media.artist ? root.media.artist : "—"
              color: Theme.dim
              elide: Text.ElideRight
            }
            Item { width: 1; height: 10 }
            Bar {
              width: parent.width
              height: 4
              value: root.media && root.media.length > 0 ? root.position / root.media.length : 0
            }
          }

          Rectangle {
            id: playButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            height: 40
            color: Theme.accent
            opacity: root.media && root.online ? 1 : 0.4
            Icon {
              anchors.centerIn: parent
              name: root.media && root.media.playing ? "pause" : "play"
              size: 22
              color: Theme.bg
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!root.media || !root.online) return
                root.view.call("media.action", { device: root.dev.id, player: root.media.player, action: "PlayPause" })
              }
            }
          }
        }
      }
    }

    // Phone camera, with its settings. The card spans the grid while the
    // settings are open.
    CameraCard {
      objectName: "cameraCard"
      visible: !!root.webcam
      view: root.view
      webcam: root.webcam
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 320
      Layout.columnSpan: settingsOpen ? grid.columns : 1
    }
  }
}
