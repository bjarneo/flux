import QtQuick
import ".."
import "../components"

// Clipboard history. Incoming entries have a down arrow, outgoing entries
// have an up arrow. An image entry shows the image.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var allEntries: view && view.backend ? (view.backend.clipboard || []) : []
  readonly property var entries: allEntries.filter(e =>
    (!savedOnly || e.pinned) && (search.text === "" || matches.indexOf(e.id) >= 0))
  property bool savedOnly: false
  property var matches: []
  onAllEntriesChanged: if (search.text !== "") searchDelay.restart()
  Timer {
    id: searchDelay
    interval: 150
    onTriggered: {
      var query = search.text
      root.view.call("clipboard.search", { text: query }, function(result) {
        if (search.text === query) root.matches = result.map(e => e.id)
      })
    }
  }

  implicitHeight: list.implicitHeight

  function source(e) {
    if (e.dir === "out") return "this pc"
    if (e.deviceName) return e.deviceName
    var devs = view ? view.allDevices : []
    for (var i = 0; i < devs.length; i++) if (devs[i].id === e.device) return devs[i].name
    return "phone"
  }

  // The rows follow the entries by ID, so a new entry adds only its row.
  KeyedModel { id: rows; values: root.entries }

  Column {
    id: list
    width: parent.width
    spacing: 10

    Field { id: search; width: parent.width; placeholder: "Search clipboard entries"; onTextChanged: searchDelay.restart() }
    Row {
      spacing: 8
      OutlineButton { text: root.savedOnly ? "Show all" : "Saved snippets"; onClicked: root.savedOnly = !root.savedOnly }
    }
    Txt { width: parent.width; text: "Saved snippets stay after a restart."; color: Theme.dim; font.pixelSize: 11; wrapMode: Text.Wrap }

    Txt {
      visible: root.entries.length === 0
      width: parent.width
      text: search.text !== "" ? "No entries match this search." : root.savedOnly ? "No saved snippets. Select Save beside a clipboard entry." : "No clipboard entries yet. Copy text or an image on this computer or on the phone."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    Repeater {
      model: rows
      delegate: Card {
        required property string key
        readonly property var modelData: rows.byId[key] || ({})
        readonly property bool incoming: modelData.dir !== "out"
        width: list.width
        implicitHeight: Math.max(textCol.implicitHeight, actions.implicitHeight) + 30

        // The direction: from the device, or from this computer.
        Icon {
          id: arrow
          x: 17
          anchors.verticalCenter: parent.verticalCenter
          name: parent.incoming ? "arrow-in" : "arrow-out"
          size: 18
          color: parent.incoming ? Theme.ok : Theme.accent
        }
        Column {
          id: textCol
          anchors.left: arrow.right
          anchors.leftMargin: 16
          anchors.right: actions.left
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: modelData.image ? 6 : 0
          // The row shows 1 line, so it needs only the start of the text.
          Txt {
            visible: !modelData.image
            width: parent.width
            text: (modelData.text || "").slice(0, 300).replace(/\s*\n\s*/g, " ")
            elide: Text.ElideRight
          }
          Image {
            visible: !!modelData.image
            width: parent.width
            height: visible ? 72 : 0
            source: modelData.image ? "file://" + modelData.image : ""
            sourceSize.height: 144
            fillMode: Image.PreserveAspectFit
            horizontalAlignment: Image.AlignLeft
            asynchronous: true
          }
          Txt {
            width: parent.width
            text: (modelData.pinned ? "Saved · " : "") + root.source(modelData) + " · " + Fmt.clock(modelData.time)
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
        }
        Column {
          id: actions
          anchors.right: parent.right
          anchors.rightMargin: 19
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          OutlineButton {
            text: modelData.pinned ? "Unsave" : "Save"
            fontSize: 12
            padX: 12
            padY: 5
            onClicked: root.view.call(modelData.pinned ? "clipboard.unpin" : "clipboard.pin", { id: modelData.id })
          }
          OutlineButton {
            id: copy
          icon: "copy"
          text: "Copy"
          padX: 12
          padY: 5
          fontSize: 12
          // fluxd copies the full text or the image of the entry. The row
          // can have only the start of a long text.
          onClicked: root.view.call("clipboard.copy", { id: modelData.id }, function () { root.view.toast("Copied to the clipboard") })
          }
        }
      }
    }
  }
}
