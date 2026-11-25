import QtQuick
import QtQuick.Layouts
import ".."

// What the device can do on this computer. Each entry has a switch for this
// device and a line that starts with On. or Off. and says what the device
// can do. A feature that is off on this computer is off for every device.
// For Remote desktop, Remote input, and Agent control, the entry also has
// Turn on or Turn off for all devices. fluxd saves each change in
// config.toml.
Card {
  id: root
  property var view: null
  property var dev: null
  readonly property var settings: view && view.backend ? (view.backend.settings || ({})) : ({})
  // The settings of this device, by feature key. fluxd sends them in the
  // settings of the computer under the key in perDevice.
  readonly property string perDevice: "device" + "Rules"
  readonly property var allowed: dev && settings[perDevice] ? (settings[perDevice][dev.id] || {}) : ({})
  // The name of the device type: phone, tablet, computer, or device.
  readonly property string noun: dev ? Fmt.noun(dev.type) : "device"
  readonly property string devName: dev ? (dev.name || "the device") : "the device"

  // setting is the setting of this computer. computer is true for a feature
  // that this card can turn on and off for every device. can and cannot
  // end the line of the entry. They follow The <device> can and cannot.
  readonly property var features: [
    { key: "clipboard", label: "Clipboard sync", setting: "autoClipboard", can: "share the clipboard" },
    { key: "notifications", label: "Notifications", setting: "notifications", can: "show its notifications" },
    { key: "shareHome", label: "Shared folders", setting: "shareHome", can: "browse files on this computer" },
    { key: "remoteDesktop", label: "Remote desktop", setting: "remoteDesktop", computer: true, can: "see and extend the screen of this computer" },
    { key: "remoteInput", label: "Remote input", setting: "remoteInput", computer: true, can: "type and move the pointer on this computer" },
    { key: "herdr", label: "Agent output", setting: "herdr", can: "read agent panes" },
    { key: "herdrControl", label: "Agent control", setting: "herdrControl", computer: true, confirmOn: true, can: "send keys and commands to agents", only: "only read" },
    { key: "herdrTerminals", label: "Agent terminals", setting: "herdrTerminals", can: "start terminals" }
  ]

  implicitHeight: col.implicitHeight + 36

  function setComputer(key, on) {
    if (view) view.call("settings.set", { key: key, value: on })
  }

  // Agent control lets each paired device run any command, so Turn on asks
  // first. Turn off asks nothing.
  function toggleComputer(feature) {
    var on = root.settings[feature.setting] !== true
    if (on && feature.confirmOn && view && view.confirm) {
      view.confirm("Turn on Agent control?",
        "Each paired device can then run any command as your user through an agent.",
        "Turn on", function () { root.setComputer(feature.setting, true) })
      return
    }
    root.setComputer(feature.setting, on)
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
          readonly property bool setOn: root.settings[modelData.setting] === true
          readonly property bool computerOn: setOn && (!needsAgents || root.settings.herdr === true)
            && (modelData.key !== "herdrTerminals" || root.settings.herdrControl === true)
          readonly property bool deviceOff: root.allowed[modelData.key] === false
          readonly property bool dependencyOff: (needsAgents && root.allowed.herdr === false)
            || (modelData.key === "herdrTerminals" && root.allowed.herdrControl === false)
          readonly property string subject: "The " + root.noun
          // The line starts with On. or Off. and has 1 sentence.
          readonly property string line: {
            var m = modelData
            if (!computerOn) {
              if (m.only) return "Off. " + subject + " can " + m.only + "."
              return "Off. " + subject + " cannot " + m.can + ", because this computer turned it off."
            }
            if (deviceOff) return "Off. " + subject + " " + (m.only ? "can " + m.only : "cannot " + m.can) + "."
            if (dependencyOff) return "Off. " + subject + " cannot " + m.can + " until " + (m.key === "herdrTerminals" ? "Agent control" : "Agent output") + " is on."
            return "On. " + subject + " can " + m.can + "."
          }

          Toggle {
            objectName: "toggle-" + feature.modelData.key
            text: feature.modelData.label
            // The switch is for this device. It shows off and stays dim while
            // this computer has the feature off.
            active: !!root.dev && feature.computerOn
            checked: feature.computerOn && root.allowed[feature.modelData.key] !== false
            onToggled: function (value) { root.view.call("device.settings.set", { device: root.dev.id, key: feature.modelData.key, value: value }) }
          }
          Flow {
            x: 44
            width: parent.width - x
            spacing: 8
            Txt {
              objectName: "line-" + feature.modelData.key
              text: feature.line
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
              onClicked: root.toggleComputer(feature.modelData)
            }
            Txt {
              visible: !!feature.modelData.computer
              text: "for all devices"
              color: Theme.dim
              font.pixelSize: 11
            }
          }
        }
      }
    }
  }
}
