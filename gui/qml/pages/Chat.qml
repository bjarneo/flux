import QtQuick
import QtQuick.Controls
import ".."
import "../components"

// The chat of the selected device: the clips, links, and files between the
// device and this computer, with the newest entry at the bottom. What the
// device sent is on the left. What this computer sent is on the right. The
// dock sends a text, a link, the clipboard, or files. Files dropped on the
// page go to the device too.
Item {
  id: root
  property var view
  property bool fillHeight: true
  readonly property var dev: view ? view.dev : null
  readonly property string devId: dev ? dev.id : ""
  readonly property bool online: !!dev && !!dev.online
  readonly property string devName: view ? view.devName : "the device"

  // The whole clipboard history, for the search and Clear.
  readonly property var allClips: view && view.backend ? (view.backend.clipboard || []) : []
  // The clips of this device: what it sent, what this computer sent to it,
  // and the copies on this computer that clipboard sync sent to it.
  readonly property var clips: allClips.filter(function (e) {
    if (e.device) return e.device === root.devId
    return e.dir === "out" && Array.isArray(e.to) && e.to.indexOf(root.devId) >= 0
  })
  readonly property var transfers: (view && view.backend ? (view.backend.transfers || []) : []).filter(function (t) {
    return t.device === root.devId
  })

  property bool savedOnly: false
  readonly property string query: search.text.trim()
  // The IDs of the clips that match the search. fluxd searches the full
  // text, also of a long clip that the state holds only in part.
  property var matches: []
  readonly property bool filtered: savedOnly || query !== ""

  // The entries, newest first. The list grows from the bottom, so the
  // newest entry is at the bottom. Each entry is {key, at, clip} or
  // {key, at, file}. Entries of the same second keep the order of fluxd.
  // Saved shows the saved clips of every device, because they are 1 set
  // of snippets.
  readonly property var items: {
    var out = []
    var q = query.toLowerCase()
    var list = savedOnly ? allClips.filter(function (e) { return e.pinned }) : clips
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (q !== "" && matches.indexOf(e.id) < 0) continue
      out.push({ key: "c" + e.id, at: e.time || 0, n: i, clip: e })
    }
    for (var j = 0; j < transfers.length && !savedOnly; j++) {
      var t = transfers[j]
      if (q !== "" && String(t.name || "").toLowerCase().indexOf(q) < 0) continue
      out.push({ key: "t" + t.id, at: t.time || 0, n: j, file: t })
    }
    out.sort(function (a, b) { return b.at - a.at || a.n - b.n })
    return out
  }

  // The error of the last send, or "". It shows above the dock, and the
  // draft stays.
  property string sendError: ""
  property bool sending: false
  readonly property bool canSend: online && !sending && composer.text.trim() !== ""
  // A narrow page shows the dock buttons with icons only.
  readonly property bool compact: width < 560

  onDevIdChanged: sendError = ""
  onAllClipsChanged: if (query !== "") searchDelay.restart()

  // A reply can arrive after the page is gone. The callbacks check this
  // object, which lives outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  Timer {
    id: searchDelay
    interval: 150
    onTriggered: {
      var q = root.query
      if (q === "") {
        root.matches = []
        return
      }
      var life = root.life
      root.view.call("clipboard.search", { text: q }, function (result) {
        if (life.alive && root.query === q) root.matches = (result || []).map(function (e) { return e.id })
      })
    }
  }

  // i writes a message, and / searches.
  function handleKey(event) {
    if (event.text === "i") {
      focusComposer("")
      event.accepted = true
    } else if (event.text === "/") {
      search.input.forceActiveFocus()
      event.accepted = true
    }
  }

  // Puts the cursor in the dock. text fills an empty draft and is selected,
  // so the next key replaces it.
  function focusComposer(text) {
    if (text && composer.text.trim() === "") {
      composer.text = text
      composer.input.selectAll()
    } else {
      composer.input.cursorPosition = composer.input.length
    }
    composer.input.forceActiveFocus()
  }

  // Sends the draft: a web link opens in a notification on the device, and
  // any other text goes to the clipboard of the device.
  function send() {
    var text = composer.text.replace(/^\s*\n/, "").replace(/\n\s*$/, "")
    if (text.trim() === "" || !dev || sending) return
    if (!online) {
      view.toast(devName + " is offline")
      return
    }
    var v = view
    var life = root.life
    var id = dev.id
    var name = devName
    var link = Fmt.webLink(text)
    sending = true
    sendError = ""
    var done = function () {
      if (!life.alive) return
      root.sending = false
      if (root.devId === id) composer.clear()
    }
    var fail = function (err) {
      var msg = err.message || err.code || "Error"
      if (!life.alive) {
        v.toast(msg)
        return
      }
      root.sending = false
      if (root.devId === id) root.sendError = msg
      else v.toast(msg)
    }
    if (link !== "") {
      v.call("share.url", { device: id, url: link }, function () {
        done()
        v.toast("Link sent. Open its notification on " + name + ".")
      }, fail)
    } else {
      v.call("clipboard.send", { device: id, text: text }, done, fail)
    }
  }

  // Sends files to the device. skipped is the number of dropped items that
  // are not files on this computer. fluxd keeps the files in the outbox
  // until the device connects.
  function sendFiles(paths, skipped) {
    if (!dev) return
    if (paths.length === 0) {
      if (skipped > 0) view.toast("Flux sends only files on this computer.")
      return
    }
    var v = view
    var name = devName
    var note = skipped === 1 ? " 1 item is not a file on this computer."
      : (skipped > 1 ? " " + skipped + " items are not files on this computer." : "")
    v.call("share.files", { device: dev.id, paths: paths }, function () {
      v.toast((paths.length === 1 ? "Queued 1 file for " : "Queued " + paths.length + " files for ") + name + "." + note)
    })
  }

  property bool picking: false

  // Puts an image from the clipboard on its way to the device: the host
  // writes the clipboard image to a file, and share.files sends it. The
  // host answers later, so this captures the device and the page lifetime
  // first, like pick does. The composer calls this only when the host
  // reports an image, so a text paste still reaches the field.
  function pasteImage() {
    var v = view
    if (!v || !v.backend || !dev || !v.backend.pasteFile) return false
    var id = dev.id
    var name = devName
    var life = root.life
    var wasOnline = online
    v.backend.pasteFile(function (path) {
      if (!life.alive || !path) {
        if (life.alive) v.toast("The paste did not produce an image file.")
        return
      }
      if (wasOnline) {
        v.call("share.files", { device: id, paths: [path] }, function () {
          if (life.alive) v.toast("Queued the pasted image for " + name + ".")
        }, function (err) {
          if (life.alive) v.toast(err.message || err.code || "Error")
        })
      } else {
        v.toast(name + " is offline. The image did not go out.")
      }
    })
    return true
  }

  // Opens the file chooser of the desktop. The chooser can close after the
  // page is gone, so the callback uses only values outside the page.
  function pick() {
    if (picking || !view || !view.backend || !dev) return
    picking = true
    var life = root.life
    var v = view
    var id = dev.id
    var name = devName
    v.backend.pickFiles("Send to " + name, function (paths) {
      if (life.alive) root.picking = false
      if (!paths || paths.length === 0) return
      v.call("share.files", { device: id, paths: paths }, function () {
        v.toast((paths.length === 1 ? "Queued 1 file for " : "Queued " + paths.length + " files for ") + name + ".")
      })
    })
  }

  // Search, saved clips, and Clear.
  Item {
    id: toolbar
    width: parent.width
    height: search.implicitHeight

    Field {
      id: search
      width: Math.min(320, parent.width - savedButton.width - clearButton.width - 24)
      padY: 6
      placeholder: "Search the chat"
      onTextChanged: searchDelay.restart()
      onEscaped: {
        search.clear()
        root.view.forceActiveFocus()
      }
    }
    OutlineButton {
      id: savedButton
      anchors.left: search.right
      anchors.leftMargin: 8
      anchors.verticalCenter: search.verticalCenter
      icon: root.savedOnly ? "pin" : "pin-outline"
      text: root.compact ? "" : "Saved"
      fontSize: 12
      padY: 6
      selected: root.savedOnly
      textColor: root.savedOnly ? Theme.accent : Theme.fg
      onClicked: root.savedOnly = !root.savedOnly
    }
    OutlineButton {
      id: clearButton
      anchors.right: parent.right
      anchors.verticalCenter: search.verticalCenter
      // Clear empties the history of every device. Saved clips stay,
      // unless the list shows only saved clips.
      visible: root.savedOnly ? root.allClips.some(function (e) { return e.pinned }) : root.allClips.some(function (e) { return !e.pinned })
      icon: "trash"
      text: root.compact ? "" : (root.savedOnly ? "Clear saved" : "Clear history")
      fontSize: 12
      padY: 6
      onClicked: {
        var v = root.view
        if (root.savedOnly) v.call("clipboard.clear", { all: true }, function () { v.toast("Saved clips cleared") })
        else v.call("clipboard.clear", {}, function () { v.toast("Clipboard history cleared. Saved clips stay.") })
      }
    }
  }

  // The entries follow the items by key, so a progress event of a file
  // changes only its card.
  KeyedModel {
    id: rows
    values: root.items
    keyField: "key"
    scope: root.devId
  }

  ListView {
    id: list
    objectName: "chatList"
    anchors.top: toolbar.bottom
    anchors.topMargin: 14
    anchors.bottom: errorLine.visible ? errorLine.top : dock.top
    anchors.bottomMargin: 12
    width: parent.width
    clip: true
    model: rows
    spacing: 10
    verticalLayoutDirection: ListView.BottomToTop
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {
      policy: list.contentHeight > list.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
      contentItem: Rectangle { implicitWidth: 6; color: Theme.bg3 }
      background: Item {}
    }

    delegate: Column {
      id: row
      required property string key
      required property int index
      readonly property var item: rows.byId[key] || ({})
      // The entry above this one. A new day starts a rule.
      readonly property var older: {
        var k = rows.rowKeys[index + 1]
        return k !== undefined ? rows.byId[k] : null
      }
      readonly property string day: Fmt.day(item.at)
      width: list.width - 14
      spacing: 10

      Item {
        visible: !row.older || Fmt.day(row.older.at) !== row.day
        width: parent.width
        height: dayText.implicitHeight + 4
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, (parent.width - dayText.width) / 2 - 12)
          height: 1
          color: Theme.bg3
        }
        Txt {
          id: dayText
          anchors.centerIn: parent
          text: row.day
          color: Theme.dim
          font.pixelSize: 11
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          width: Math.max(0, (parent.width - dayText.width) / 2 - 12)
          height: 1
          color: Theme.bg3
        }
      }

      ChatEntry {
        width: parent.width
        view: root.view
        entry: row.item
        maxWidth: Math.max(280, Math.min(640, list.width * 0.78))
      }
    }
  }

  // No entries yet, or none that match.
  Column {
    objectName: "chatEmpty"
    anchors.centerIn: list
    width: Math.min(460, list.width - 32)
    spacing: 10
    visible: rows.count === 0 && !drop.containsDrag

    Icon {
      anchors.horizontalCenter: parent.horizontalCenter
      name: root.filtered ? (root.savedOnly ? "pin-outline" : "search") : "forum"
      size: 30
      color: Theme.dim
    }
    Txt {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.query !== "" ? "No entries match this search"
        : root.savedOnly ? "No saved clips"
        : "Nothing between " + root.devName + " and this computer yet"
      font.pixelSize: 15
      font.weight: Font.DemiBold
    }
    Txt {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.query !== "" ? "The search looks at the text of clips and at file names."
        : root.savedOnly ? "Select the pin on a clip to save it. Saved clips stay after a restart."
        : "Type a text or a link below to send it. Drop files on this page to send them. Clips, links, and files from " + root.devName + " show here too."
      color: Theme.dim
    }
  }

  // Files over the page.
  Rectangle {
    anchors.fill: list
    visible: drop.containsDrag
    color: Theme.alpha(Theme.accent, 0.08)
    DashedRect {
      anchors.fill: parent
      lineWidth: 1.5
      color: Theme.accent
    }
    Column {
      anchors.centerIn: parent
      width: Math.min(420, parent.width - 32)
      spacing: 8
      Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: "tray-up"
        size: 34
        color: Theme.accent
      }
      Txt {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: "Drop to send to " + root.devName
        font.pixelSize: 16
        font.weight: Font.DemiBold
      }
      Txt {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: root.online ? "Folders go as ZIP archives." : "Folders go as ZIP archives. The files wait in the outbox until " + root.devName + " connects."
        color: Theme.dim
      }
    }
  }

  // The error of the last send from fluxd.
  Txt {
    id: errorLine
    objectName: "chatError"
    visible: root.sendError !== ""
    anchors.bottom: dock.top
    anchors.bottomMargin: 8
    width: parent.width
    text: root.sendError
    color: Theme.err
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }

  // The dock: the draft, then the tools and Send.
  Rectangle {
    id: dock
    anchors.bottom: parent.bottom
    width: parent.width
    height: composer.implicitHeight + tools.height + 8
    color: Theme.bg2
    border.width: 1
    border.color: composer.input.activeFocus ? Theme.accent : Theme.edge

    Composer {
      id: composer
      objectName: "chatDraft"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 1
      placeholder: root.online ? "Text or a link for " + root.devName
        : root.devName + " is offline. Files wait in the outbox."
      onAccepted: root.send()
      onEscaped: root.view.forceActiveFocus()
      onTextChanged: root.sendError = ""
      // An image on the clipboard goes to the device as a file, so the
      // phone shows it in the chat and can open it. The check is the
      // composite: the host reports an image, then the chat takes it.
      pasteTaker: function () {
        var b = root.view ? root.view.backend : null
        if (!b || !b.hasClipboardImage || !b.hasClipboardImage()) return false
        return root.pasteImage()
      }
    }

    Item {
      id: tools
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 8
      height: sendButton.implicitHeight

      Row {
        id: toolRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        OutlineButton {
          icon: "paste"
          text: root.compact ? "" : "Send clipboard"
          fontSize: 12
          padX: 10
          padY: 5
          active: root.online
          onClicked: root.view.sendClipboard()
        }
        OutlineButton {
          icon: "paperclip"
          text: root.compact ? "" : "Attach files"
          fontSize: 12
          padX: 10
          padY: 5
          active: !root.picking
          onClicked: root.pick()
        }
      }

      Txt {
        anchors.left: toolRow.right
        anchors.leftMargin: 14
        anchors.right: sendButton.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        visible: composer.input.activeFocus && !root.compact
        text: "Enter sends. Shift+Enter adds a line."
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideLeft
      }

      AccentButton {
        id: sendButton
        objectName: "chatSend"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        icon: "send"
        text: root.sending ? "Sending…" : "Send"
        fontSize: 12
        padX: 12
        padY: 6
        active: root.canSend
        onClicked: root.send()
      }
    }
  }

  // Files from the file manager go to the device. A web link from the
  // browser goes into the draft, so Enter opens it on the device.
  DropArea {
    id: drop
    anchors.fill: parent
    keys: ["text/uri-list"]
    onDropped: function (event) {
      var paths = []
      var links = []
      var skipped = 0
      for (var i = 0; i < event.urls.length; i++) {
        var u = String(event.urls[i])
        var path = Fmt.urlToPath(u)
        if (path !== "") paths.push(path)
        else if (Fmt.webLink(u) !== "") links.push(Fmt.webLink(u))
        else skipped++
      }
      event.acceptProposedAction()
      if (paths.length === 0 && links.length > 0) {
        root.focusComposer(links[0])
        return
      }
      root.sendFiles(paths, skipped + links.length)
    }
  }
}
