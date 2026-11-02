import QtQuick
import Quickshell
import Quickshell.Wayland
import "MotionColors.js" as MotionColors

// The motion cues: flat dots at the edges of each screen that move against
// the motion of the vehicle. fluxd sends the targets in motion events, and
// this overlay only animates toward them. The windows take no clicks and no
// keyboard focus. docs/motion-cues.md describes the feature.
Scope {
  id: root

  // The motion event of fluxd: active, offsetX, offsetY, flowX, flowY,
  // density, and size.
  property var motion: ({})
  property color fill: "#ffffff"

  readonly property bool active: motion.active === true
  readonly property real dotSize: motion.size === "small" ? 10 : motion.size === "large" ? 20 : 14

  // The number of dots that always show while the cues run, and of dots
  // that show with the density, in groups of 4.
  readonly property int baseDots: 12
  readonly property int extraDots: 20
  readonly property real fillOpacity: 0.85
  // The space between the screen edge and a strip. It is the largest
  // offset of fluxd, so a moved dot stays on the screen and off the bar.
  readonly property real margin: 48

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      visible: root.active || field.opacity > 0.001
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "flux-motion-cues"
      // An empty input region: every click goes to the window below.
      mask: Region {}

      Item {
        id: field
        anchors.fill: parent
        opacity: root.active ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

        // The smoothed values. The model of fluxd already smooths; this
        // only fills the frames between 2 events.
        property real offX: 0
        property real offY: 0
        property real flowX: 0
        property real flowY: 0
        property real density: 0
        // The drift of the dots along their strips, in pixels.
        property real driftX: 0
        property real driftY: 0

        // The width of each edge strip.
        readonly property real strip: Math.max(root.dotSize * 4, Math.min(width, height) * 0.08)

        readonly property bool settled: Math.abs(offX) < 0.1 && Math.abs(offY) < 0.1
            && Math.abs(flowX) < 0.5 && Math.abs(flowY) < 0.5 && density < 0.002

        FrameAnimation {
          running: win.visible && (root.active || !field.settled)
          onTriggered: {
            var dt = Math.min(frameTime, 0.1)
            var k = 1 - Math.exp(-dt / 0.06)
            var m = root.active ? root.motion : ({})
            field.offX += ((m.offsetX || 0) - field.offX) * k
            field.offY += ((m.offsetY || 0) - field.offY) * k
            field.flowX += ((m.flowX || 0) - field.flowX) * k
            field.flowY += ((m.flowY || 0) - field.flowY) * k
            field.density += ((m.density || 0) - field.density) * k
            field.driftX += field.flowX * dt
            field.driftY += field.flowY * dt
          }
        }

        Repeater {
          model: root.baseDots + root.extraDots

          Rectangle {
            id: dot
            required property int index

            // A deterministic random number from 0 to 1 for seed n.
            function rand(n) {
              var x = Math.sin(n * 12.9898 + 78.233) * 43758.5453
              return x - Math.floor(x)
            }

            // Each dot lives in 1 of the 4 edge strips. Dots in the side
            // strips drift up and down, dots in the top and bottom strips
            // drift left and right.
            readonly property int side: index % 4
            readonly property bool vertical: side < 2
            readonly property real across: dot.rand(index * 3 + 1)
            readonly property real along: dot.rand(index * 3 + 2)
            readonly property real length: vertical ? field.height : field.width
            readonly property real drift: vertical ? field.driftY : field.driftX
            // The position along the strip, from 0 to 1, after the drift.
            readonly property real pos: {
              var p = along + drift / Math.max(1, length)
              return p - Math.floor(p)
            }
            // The number of wraps so far. Each wrap gives the dot a new size.
            readonly property int lap: Math.floor(along + drift / Math.max(1, length))
            readonly property real scaleNow: 0.85 + 0.3 * dot.rand(index * 7 + lap * 131)
            // Fade in and out at the ends of the strip, so a wrap does not pop.
            readonly property real edgeFade: Math.min(1, pos / 0.06, (1 - pos) / 0.06)
            readonly property real groupOpacity: index < root.baseDots ? 1
                : Math.max(0, Math.min(1, field.density * 5 - Math.floor((index - root.baseDots) / 4)))

            readonly property real inset: root.margin + across * Math.max(0, field.strip - root.dotSize)
            // Dots in the side strips run between the top and bottom strips,
            // and dots in the top and bottom strips between the side strips.
            readonly property real span: vertical ? field.height - 2 * root.margin : field.width - 2 * root.margin
            readonly property real cx: side === 0 ? inset
                : side === 1 ? field.width - inset - root.dotSize
                : root.margin + pos * span
            readonly property real cy: vertical ? root.margin + pos * span
                : side === 2 ? inset
                : field.height - inset - root.dotSize

            width: root.dotSize
            height: root.dotSize
            radius: width / 2
            x: cx + field.offX
            y: cy + field.offY
            scale: scaleNow
            color: Qt.rgba(root.fill.r, root.fill.g, root.fill.b, root.fillOpacity)
            opacity: groupOpacity * edgeFade
            visible: opacity > 0.01
            antialiasing: true
          }
        }
      }
    }
  }
}
