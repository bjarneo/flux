import QtQuick
import ".."
import "../components"

// Storage on the phone over SFTP. A folder tile opens the folder. A file
// tile downloads the file into ~/Downloads.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var dev: view ? view.dev : null
  readonly property bool online: !!dev && !!dev.online

  property var roots: []
  property var root_: null
  property string path: ""
  property var entries: []
  property string status: "idle"
  property string error: ""

  implicitHeight: col.implicitHeight

  property string openedFor: ""
  // A reply can arrive after the page is gone. The callbacks check this
  // object, which lives outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  function open() {
    if (!dev) return
    openedFor = dev.id
    if (!online) {
      status = "error"
      error = view.devName + " is offline."
      return
    }
    status = "opening"
    var life = root.life
    view.backend.call("browse.open", { device: dev.id }, function (err, result) {
      if (!life.alive) return
      if (err) {
        root.status = "error"
        root.error = err.message || err.code
        return
      }
      root.roots = result.roots || []
      if (root.roots.length > 0) root.list(root.roots[0], root.roots[0].path)
      else root.status = "ready"
    })
  }

  function list(r, p) {
    root_ = r
    path = p
    status = "loading"
    var life = root.life
    view.backend.call("browse.list", { device: dev.id, path: p }, function (err, result) {
      if (!life.alive) return
      if (err) {
        root.status = "error"
        root.error = err.message || err.code
        return
      }
      var e = (result.entries || []).slice()
      e.sort(function (a, b) {
        if (!!a.dir !== !!b.dir) return a.dir ? -1 : 1
        return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
      })
      root.entries = e
      root.status = "ready"
    })
  }

  function join(p, name) { return p.replace(/\/+$/, "") + "/" + name }

  function up() {
    if (!root_ || path === root_.path) return
    var p = path.replace(/\/+$/, "")
    p = p.slice(0, p.lastIndexOf("/"))
    list(root_, p.length < root_.path.length ? root_.path : p)
  }

  function relative() {
    if (!root_) return ""
    var rel = path.slice(root_.path.replace(/\/+$/, "").length)
    return root_.name + rel
  }

  function activate(e) {
    if (e.dir) {
      list(root_, join(path, e.name))
      return
    }
    view.call("browse.get", { device: dev.id, path: join(path, e.name) }, function () {
      root.view.toast("Downloading " + e.name)
    })
  }

  readonly property string devId: dev ? dev.id : ""
  Component.onCompleted: if (openedFor !== devId) open()
  onDevIdChanged: {
    if (devId === openedFor) return
    roots = []
    root_ = null
    entries = []
    open()
  }
  onOnlineChanged: if (online && status === "error") open()

  Column {
    id: col
    width: parent.width
    spacing: 0

    Flow {
      width: parent.width
      spacing: 8
      visible: root.roots.length > 0
      Repeater {
        model: root.roots
        delegate: Rectangle {
          required property var modelData
          readonly property bool sel: !!root.root_ && root.root_.path === modelData.path
          width: chip.implicitWidth + 24
          height: chip.implicitHeight + 12
          color: sel ? Theme.accent : Theme.bg2
          Txt { id: chip; anchors.centerIn: parent; text: modelData.name; color: parent.sel ? Theme.bg : Theme.fg }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.list(modelData, modelData.path)
          }
        }
      }
    }

    Item { width: 1; height: root.roots.length > 0 ? 18 : 0 }

    Row {
      spacing: 14
      visible: !!root.root_ && root.path !== root.root_.path
      bottomPadding: 14
      Txt { text: root.relative(); color: Theme.dim }
      OutlineButton {
        anchors.verticalCenter: parent.verticalCenter
        icon: "arrow-up"
        text: "Up"
        padX: 10
        padY: 3
        fontSize: 12
        onClicked: root.up()
      }
    }

    Txt {
      visible: root.status === "opening" || root.status === "loading"
      text: root.status === "opening" ? "Opening storage on " + (root.view ? root.view.devName : "") + "…" : "Loading…"
      color: Theme.dim
      bottomPadding: 14
    }

    Column {
      visible: root.status === "error"
      spacing: 12
      width: parent.width
      Txt { width: parent.width; text: root.error; color: Theme.dim; wrapMode: Text.Wrap }
      OutlineButton { icon: "refresh"; text: "Try again"; onClicked: root.open() }
    }

    Txt {
      visible: root.status === "ready" && root.entries.length === 0 && !!root.root_
      text: "This folder is empty."
      color: Theme.dim
    }

    Grid {
      id: tiles
      width: parent.width
      visible: root.status === "ready" || root.status === "loading"
      // Like CSS auto-fill with minmax(140px, 1fr): empty tracks keep their width.
      columns: Math.max(1, Math.floor((width + 14) / (140 + 14)))
      readonly property real cell: (width - 14 * (columns - 1)) / columns
      columnSpacing: 14
      rowSpacing: 14

      Repeater {
        model: root.entries
        delegate: Item {
          id: tile
          required property var modelData
          width: tiles.cell
          height: width + 6 + tName.implicitHeight + 6 + tMeta.implicitHeight
          readonly property string kind: Fmt.kindOf(modelData.name, modelData.dir)

          IconBox {
            id: thumb
            width: parent.width
            height: parent.width
            color: tArea.containsMouse ? Theme.alpha(Theme.fg, 0.05) : Theme.bg2
            icon: Fmt.fileIcon(modelData.name, modelData.dir)
            iconSize: Math.round(width * 0.36)
            fg: modelData.dir ? Theme.accent : Theme.dim
            Rectangle {
              anchors.fill: parent
              color: "transparent"
              border.width: 1
              border.color: tArea.containsMouse ? Theme.accent : Theme.bg3
            }
          }
          Txt {
            id: tName
            anchors.top: thumb.bottom
            anchors.topMargin: 6
            width: parent.width
            text: modelData.dir ? modelData.name + "/" : modelData.name
            elide: Text.ElideRight
          }
          Txt {
            id: tMeta
            anchors.top: tName.bottom
            anchors.topMargin: 6
            width: parent.width
            text: modelData.dir ? "folder" : Fmt.bytes(modelData.size)
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          MouseArea {
            id: tArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activate(modelData)
          }
        }
      }
    }
  }
}
