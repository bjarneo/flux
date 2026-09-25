import QtQuick
import ".."

// A 45 degree striped placeholder, like repeating-linear-gradient(45deg).
Item {
  id: root
  property color c1: Theme.bg3
  property color c2: Theme.bg2
  property real band: 6
  property string label: ""
  property int labelSize: 11
  clip: true

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = root.c2
      ctx.fillRect(0, 0, width, height)
      ctx.save()
      ctx.rotate(Math.PI / 4)
      ctx.fillStyle = root.c1
      var len = (width + height) * 1.5
      for (var y = -len; y < len; y += root.band * 2)
        ctx.fillRect(-len, y, len * 2, root.band)
      ctx.restore()
    }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }
  onC1Changed: canvas.requestPaint()
  onC2Changed: canvas.requestPaint()

  Txt {
    anchors.centerIn: parent
    visible: root.label !== ""
    text: root.label
    color: Theme.dim
    font.pixelSize: root.labelSize
  }
}
