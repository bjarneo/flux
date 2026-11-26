import QtQuick
import ".."

// A text field of 1 or more lines, for the dock of the chat. Enter emits
// accepted, and Shift+Enter adds a line. The field grows up to maxLines,
// then it scrolls. The owner draws the frame.
Item {
  id: root
  property alias text: edit.text
  property alias input: edit
  property string placeholder: ""
  property int maxLines: 6
  signal accepted()
  // Esc takes the focus from the field.
  signal escaped()
  // The owner's clipboard-image check, or null. It returns true when the
  // clipboard holds an image and the owner takes it. The field skips its
  // own paste then, so a text paste still reaches the field.
  property var pasteTaker: null

  readonly property real lineHeight: metrics.height
  implicitHeight: Math.max(lineHeight, Math.min(edit.contentHeight, lineHeight * maxLines)) + 20
  implicitWidth: 200

  function clear() { edit.text = "" }

  FontMetrics {
    id: metrics
    font.family: Theme.font
    font.pixelSize: Theme.size
  }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.leftMargin: 12
    anchors.rightMargin: 12
    anchors.topMargin: 10
    anchors.bottomMargin: 10
    contentWidth: width
    contentHeight: edit.contentHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    // Keeps the cursor in view while the text scrolls.
    function follow(r) {
      if (contentY > r.y) contentY = r.y
      else if (contentY + height < r.y + r.height) contentY = r.y + r.height - height
    }

    TextEdit {
      id: edit
      width: flick.width
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      color: Theme.fg
      font.family: Theme.font
      font.pixelSize: Theme.size
      selectionColor: Theme.alpha(Theme.accent, 0.4)
      selectedTextColor: Theme.fg
      selectByMouse: true
      activeFocusOnTab: true
      Accessible.role: Accessible.EditableText
      Accessible.name: root.placeholder
      onCursorRectangleChanged: flick.follow(cursorRectangle)

      // The handlers run before the field. A key that they do not accept,
      // such as Shift+Enter, reaches the field and adds a line.
      function send(event) {
        if (event.modifiers & Qt.ShiftModifier) {
          event.accepted = false
          return
        }
        event.accepted = true
        root.accepted()
      }
      Keys.onReturnPressed: function (event) { send(event) }
      Keys.onEnterPressed: function (event) { send(event) }
      Keys.onEscapePressed: {
        focus = false
        root.escaped()
      }
      // Ctrl+V: the owner checks the clipboard for an image first. The
      // handler accepts the event only when the owner took an image, so a
      // text paste still reaches the field.
      Keys.onShortcutOverride: function (event) {
        if ((event.key === Qt.Key_V) && (event.modifiers & Qt.ControlModifier) && root.pasteTaker && root.pasteTaker()) {
          event.accepted = true
        }
      }
    }
  }

  Txt {
    anchors.left: flick.left
    anchors.right: flick.right
    anchors.top: flick.top
    visible: edit.text.length === 0 && edit.preeditText.length === 0
    text: root.placeholder
    color: Theme.dim
    elide: Text.ElideRight
  }

  // A click on the empty part of the field puts the cursor at the end.
  MouseArea {
    anchors.fill: parent
    z: -1
    cursorShape: Qt.IBeamCursor
    onPressed: {
      edit.forceActiveFocus()
      edit.cursorPosition = edit.length
    }
  }
}
