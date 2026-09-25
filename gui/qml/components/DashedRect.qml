import QtQuick
import QtQuick.Shapes
import ".."

// A rectangle with a dashed border, like a CSS dashed border.
Item {
  id: root
  property color color: Theme.bg3
  property real lineWidth: 1
  property color fill: "transparent"

  Rectangle { anchors.fill: parent; color: root.fill }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.color
      strokeWidth: root.lineWidth
      strokeStyle: ShapePath.DashLine
      dashPattern: [3, 3]
      fillColor: "transparent"
      capStyle: ShapePath.FlatCap
      joinStyle: ShapePath.MiterJoin
      startX: root.lineWidth / 2; startY: root.lineWidth / 2
      PathLine { x: root.width - root.lineWidth / 2; y: root.lineWidth / 2 }
      PathLine { x: root.width - root.lineWidth / 2; y: root.height - root.lineWidth / 2 }
      PathLine { x: root.lineWidth / 2; y: root.height - root.lineWidth / 2 }
      PathLine { x: root.lineWidth / 2; y: root.lineWidth / 2 }
    }
  }
}
