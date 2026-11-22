import QtQuick
import QtQuick.Layouts
import ".."

// What the device can do on this computer. Each switch is the rule of the
// device. A feature that is off on this computer is off for every device,
// and the line under the switch says "Off on this computer". Remote desktop, remote input, and Agent control
// also turn on and off for every device here. fluxd saves each change in
// config.toml.
Card {
  id: root
  property var view: null
  property var dev: null
  readonly property var settings: view && view.backend ? (view.backend.settings || ({})) : ({})
  readonly property var rules: dev && settings.deviceRules ? (settings.deviceRules[dev.id] || {}) : ({})
  readonly property string devName: dev ? (dev.name || "the device") : "the device"

  // global is the setting of this computer. computer is true for a feature
  // that this card can turn on and off for every device.
  readonly property var features: [
    { key: "clipboard", label: "Clipboard sync", global: "autoClipboard" },
    { key: "notifications", label: "Notifications", global: "notifications" },
    { key: "shareHome", label: "Shared folders", global: "shareHome" },
    { key: "remoteDesktop", label: "Remote desktop", global: "remoteDesktop", computer: true },
    { key: "remoteInput", label: "Remote input", global: "remoteInput", computer: true },
    { key: "herdr", label: "Agent output", global: "herdr" },
    { key: "herdrControl", label: "Agent control", global: "herdrControl", computer: true, confirmOn: true },
    { key: "herdrTerminals", label: "Agent terminals", global: "herdrTerminals" }
  ]

  implicitHeight: col.implicitHeight + 36

  function setGlobal(key, on) {
    if (view) view.call("settings.set", { key: key, value: on })
  }

  // Agent control lets each paired device run any command, so Turn on asks
  // first. Turn off asks nothing.
  function toggleGlobal(feature) {
    var on = root.settings[feature.global] !== true
    if (on && feature.confirmOn && view && view.confirm) {
      view.confirm("Turn on Agent control?",
        "Each paired device can then run any command as your user through an agent.",
        "Turn on", function () { root.setGlobal(feature.global, true) })
      return
    }
    root.setGlobal(feature.global, on)
  }

  Column {
    id: col
    x: 18
    y: 18
    width: parent.width - 36
    spacing: 14

    Column {
      width: parent.width
      spacing: 4
      CardTitle { icon: "key"; text: "Access" }
      Txt {
        width: parent.width
        text: "What " + root.devName + " can do on this computer."
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

    GridLayout {
      width: parent.width
      columns: width >= 520 ? 2 : 1
      columnSpacing: 18
      rowSpacing: 12
      uniformCellWidths: true

      Repeater {
        model: root.features
        delegate: Column {
          id: feature
          required property var modelData
          objectName: "access-" + modelData.key
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          spacing: 3
          readonly property bool needsAgents: modelData.key === "herdrControl" || modelData.key === "herdrTerminals"
          readonly property bool setOn: root.settings[modelData.global] === true
          readonly property bool globalOn: setOn && (!needsAgents || root.settings.herdr === true)
            && (modelData.key !== "herdrTerminals" || root.settings.herdrControl === true)
          readonly property string note: {
            if (!globalOn) return "Off on this computer."
            if (needsAgents && root.rules.herdr === false) return "Needs Agent output."
            if (modelData.key === "herdrTerminals" && root.rules.herdrControl === false) return "Needs Agent control."
            if (modelData.computer) return "Allowed on this computer."
            return ""
          }

          Toggle {
            objectName: "toggle-" + feature.modelData.key
            text: feature.modelData.label
            active: !!root.dev
            checked: root.rules[feature.modelData.key] !== false
            onToggled: function (value) { root.view.call("device.settings.set", { device: root.dev.id, key: feature.modelData.key, value: value }) }
          }
          Flow {
            visible: feature.note !== ""
            x: 44
            width: parent.width - x
            spacing: 8
            Txt {
              text: feature.note
              color: Theme.dim
              font.pixelSize: 11
              width: Math.min(implicitWidth, parent.width)
              wrapMode: Text.Wrap
            }
            TextAction {
              objectName: "computer-" + feature.modelData.key
              visible: !!feature.modelData.computer
              text: feature.setOn ? "Turn off" : "Turn on"
              font.pixelSize: 11
              onClicked: root.toggleGlobal(feature.modelData)
            }
          }
        }
      }
    }
  }
}
