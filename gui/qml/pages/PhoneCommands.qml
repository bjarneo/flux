import QtQuick
import QtQuick.Layouts
import ".."
import "../components"

// The commands that the phone lists under Run commands. The user adds and
// removes them here. A tap on the phone runs the command on this computer.
// This screen does not run commands.
Item {
  id: root
  property var view
  property bool fillHeight: false
  readonly property var commands: view && view.backend ? (view.backend.commands || []) : []
  property bool adding: false
  property bool saving: false

  implicitHeight: col.implicitHeight

  // A reply can arrive after the page is gone. The callbacks check this
  // object, which lives outside the page.
  readonly property var life: ({ alive: true })
  Component.onDestruction: life.alive = false

  readonly property bool canSave: !saving && nameField.text.trim() !== "" && commandField.text.trim() !== ""

  function openForm() {
    adding = true
    Qt.callLater(function () { nameField.input.forceActiveFocus() })
  }

  function cancel() {
    nameField.clear()
    commandField.clear()
    adding = false
    saving = false
    root.view.forceActiveFocus()
  }

  function save() {
    if (!canSave) return
    saving = true
    var life = root.life
    var name = nameField.text.trim()
    view.backend.call("commands.add", { name: name, command: commandField.text.trim() }, function (err) {
      if (!life.alive) return
      root.saving = false
      if (err) {
        root.view.toast(err.message || err.code || "Flux could not add the command")
        return
      }
      root.cancel()
      root.view.toast("Added " + name)
    })
  }

  function remove(c) {
    view.call("commands.remove", { id: c.id }, function () {
      root.view.toast("Removed " + c.name)
    })
  }

  Column {
    id: col
    width: parent.width
    spacing: 18

    Txt {
      width: parent.width
      text: "Your phone lists these commands under Run commands. A tap on the phone runs the command on this computer."
      color: Theme.dim
      wrapMode: Text.Wrap
    }

    GridLayout {
      id: grid
      width: parent.width
      // Like CSS auto-fill with minmax(220px, 1fr): empty tracks keep their width.
      columns: Math.max(1, Math.floor((width + 12) / (220 + 12)))
      readonly property real cell: (width - 12 * (columns - 1)) / columns
      columnSpacing: 12
      rowSpacing: 12

      Txt {
        Layout.columnSpan: grid.columns
        Layout.preferredWidth: grid.width
        visible: root.commands.length === 0
        text: "No commands yet. Add a command that your phone can run on this computer."
        color: Theme.dim
        wrapMode: Text.Wrap
      }

      Repeater {
        model: root.commands
        delegate: Card {
          required property var modelData
          Layout.preferredWidth: grid.cell
          Layout.fillHeight: true
          implicitHeight: cCol.implicitHeight + 34

          Column {
            id: cCol
            x: 17
            y: 17
            width: parent.width - 34
            spacing: 8
            Txt {
              width: parent.width
              text: modelData.name
              font.weight: Font.Bold
              elide: Text.ElideRight
            }
            Txt {
              width: parent.width
              text: "$ " + modelData.command
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
            Item {
              width: removeButton.width
              height: removeButton.height + 6
              OutlineButton {
                id: removeButton
                y: 6
                text: "Remove"
                padX: 14
                padY: 6
                onClicked: root.remove(modelData)
              }
            }
          }
        }
      }

      // "+ Add command", or the form to add a command
      Item {
        Layout.preferredWidth: grid.cell
        Layout.fillHeight: true
        implicitHeight: root.adding ? form.implicitHeight + 34 : 60

        DashedRect {
          anchors.fill: parent
          visible: !root.adding
          lineWidth: 1.5
          color: addArea.containsMouse ? Theme.dim : Theme.bg3
          Txt { anchors.centerIn: parent; text: "+ Add command"; color: Theme.dim }
          MouseArea {
            id: addArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openForm()
          }
        }

        Card {
          anchors.fill: parent
          visible: root.adding
          border.color: Theme.accent
          Column {
            id: form
            x: 17
            y: 17
            width: parent.width - 34
            spacing: 8
            Field {
              id: nameField
              width: parent.width
              padY: 7
              placeholder: "Name"
              onAccepted: commandField.input.forceActiveFocus()
              onEscaped: root.cancel()
            }
            Field {
              id: commandField
              width: parent.width
              padY: 7
              placeholder: "omarchy-system-lock"
              onAccepted: root.save()
              onEscaped: root.cancel()
            }
            Row {
              spacing: 8
              topPadding: 4
              AccentButton {
                text: root.saving ? "Saving…" : "Save"
                padX: 12
                padY: 6
                fontSize: 12
                active: root.canSave
                onClicked: root.save()
              }
              OutlineButton {
                text: "Cancel"
                padX: 12
                padY: 6
                fontSize: 12
                onClicked: root.cancel()
              }
            }
          }
        }
      }
    }
  }
}
