import QtQuick
import ".."
import "../components"

// The player on the device: album art, title, position, and controls.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online
  readonly property var media: dev && dev.media ? dev.media : null
  readonly property bool usable: !!media && online

  implicitHeight: col.implicitHeight + 10

  property real base: media ? (media.position || 0) : 0
  property real stamp: Date.now()
  property real now: Date.now()
  property string mediaKey: ""
  onMediaChanged: {
    var k = media ? [media.player, media.title, media.position, media.playing].join("|") : ""
    if (k === mediaKey) return
    mediaKey = k
    base = media ? (media.position || 0) : 0
    stamp = Date.now()
    now = stamp
  }
  readonly property real position: {
    if (!media) return 0
    var p = base + (media.playing ? now - stamp : 0)
    return media.length > 0 ? Math.min(p, media.length) : p
  }
  Timer {
    interval: 500
    repeat: true
    running: !!root.media && !!root.media.playing
    onTriggered: root.now = Date.now()
  }

  function act(action) {
    if (!usable) return
    view.call("media.action", { device: dev.id, player: media.player, action: action })
  }

  Column {
    id: col
    y: 10
    width: parent.width
    spacing: 14

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 300
      height: 300
      IconBox {
        anchors.fill: parent
        color: Theme.bg2
        border.width: 1
        border.color: Theme.bg3
        icon: "music"
        iconSize: 96
        fg: Theme.alpha(Theme.accent, 0.7)
        visible: art.status !== Image.Ready
      }
      Image {
        id: art
        anchors.fill: parent
        source: root.media && root.media.art ? "file://" + root.media.art : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: status === Image.Ready
      }
    }

    Txt {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(implicitWidth, parent.width)
      text: root.media && root.media.title ? root.media.title : "Nothing playing"
      font.pixelSize: 24
      font.weight: Font.Bold
      elide: Text.ElideRight
    }

    Txt {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(implicitWidth, parent.width)
      text: root.media
        ? (root.media.artist ? root.media.artist + " · " : "") + (root.media.player || "player") + " on " + root.view.devName
        : "Start a player on " + (root.view ? root.view.devName : "the device") + "."
      color: Theme.dim
      elide: Text.ElideRight
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 420
      spacing: 12
      Txt { id: pos; text: Fmt.duration(root.position); color: Theme.dim; font.pixelSize: 12 }
      Item {
        width: 420 - pos.width - len.width - 24
        height: pos.height
        Bar {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: 5
          value: root.media && root.media.length > 0 ? root.position / root.media.length : 0
        }
        MouseArea {
          anchors.fill: parent
          anchors.topMargin: -6
          anchors.bottomMargin: -6
          enabled: root.usable && root.media.canSeek !== false && root.media.length > 0
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: function (mouse) {
            var ms = Math.round(root.media.length * mouse.x / width)
            root.view.call("media.seek", { device: root.dev.id, player: root.media.player, position: ms })
            root.base = ms
            root.stamp = Date.now()
            root.now = root.stamp
          }
        }
      }
      Txt { id: len; text: Fmt.duration(root.media ? root.media.length : 0); color: Theme.dim; font.pixelSize: 12 }
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 18
      opacity: root.usable ? 1 : 0.4

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 44
        height: 44
        color: prevArea.containsMouse && root.usable ? Theme.alpha(Theme.fg, 0.06) : "transparent"
        border.width: 1
        border.color: Theme.bg3
        Icon { anchors.centerIn: parent; name: "previous"; size: 22 }
        MouseArea { id: prevArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.act("Previous") }
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 60
        height: 60
        color: Theme.accent
        Icon {
          anchors.centerIn: parent
          name: root.media && root.media.playing ? "pause" : "play"
          size: 30
          color: Theme.bg
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.act("PlayPause") }
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 44
        height: 44
        color: nextArea.containsMouse && root.usable ? Theme.alpha(Theme.fg, 0.06) : "transparent"
        border.width: 1
        border.color: Theme.bg3
        Icon { anchors.centerIn: parent; name: "next"; size: 22 }
        MouseArea { id: nextArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.act("Next") }
      }
    }
  }
}
