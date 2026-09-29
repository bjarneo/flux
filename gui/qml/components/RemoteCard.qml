import QtQuick
import ".."

// The 2 settings that give a paired device access to this computer: the
// remote desktop and remote input. fluxd saves each change in config.toml.
// While a device shows this screen, the card names it and shows Stop.
Card {
  id: root
  property var view: null
  // state.settings and state.desktop from fluxd.
  property var settings: ({})
  property var desktop: null

  readonly property bool shown: !!desktop && !desktop.error
  readonly property bool live: shown && !!desktop.active

  implicitHeight: col.implicitHeight + 38

  function set(key, on) {
    if (view) view.call("settings.set", { key: key, value: on })
  }

  Column {
    id: col
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 19
    spacing: 14

    Row {
      spacing: 8
      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: "monitor"
        size: 14
        color: root.live ? Theme.err : Theme.dim
      }
      SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: root.live ? "REMOTE ACCESS · LIVE" : "REMOTE ACCESS" }
    }

    Setting {
      objectName: "remoteDesktopToggle"
      text: "Remote desktop"
      detail: "A paired phone or Mac can show this screen."
      checked: !!root.settings.remoteDesktop
      onToggled: function (checked) { root.set("remoteDesktop", checked) }
    }

    Setting {
      objectName: "remoteInputToggle"
      text: "Remote input"
      detail: "A paired phone or Mac can move the pointer and type."
      checked: !!root.settings.remoteInput
      onToggled: function (checked) { root.set("remoteInput", checked) }
    }

    // The device that shows this screen now.
    Item {
      visible: root.shown
      width: parent.width
      height: Math.max(sessionText.implicitHeight, stopButton.implicitHeight)

      Txt {
        id: sessionText
        anchors.left: parent.left
        anchors.right: stopButton.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        readonly property var d: root.desktop || ({})
        text: root.live
          ? (d.toName || "A device") + " shows " + (d.monitor || "this screen") + (d.width ? " · " + d.width + "×" + d.height : "")
          : (d.toName || "A device") + " is starting…"
        font.weight: root.live ? Font.Bold : Font.Normal
        color: root.live ? Theme.fg : Theme.dim
        wrapMode: Text.Wrap
      }

      OutlineButton {
        id: stopButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        icon: "stop"
        text: "Stop"
        onClicked: root.view.call("desktop.stop", {})
      }
    }
  }

  // A toggle with 1 line of explanation below its label.
  component Setting: Column {
    id: setting
    property alias text: toggle.text
    property alias checked: toggle.checked
    property alias detail: detailText.text
    signal toggled(bool checked)
    width: parent ? parent.width : 0
    spacing: 4
    Toggle {
      id: toggle
      onToggled: function (checked) { setting.toggled(checked) }
    }
    Txt {
      id: detailText
      x: 44
      width: parent.width - x
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
  }
}
