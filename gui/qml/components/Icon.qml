import QtQuick
import ".."

// An icon: a Material Design glyph from the Nerd Font in the monospace
// font of Omarchy, the same icons as the Omarchy shell. It takes a color
// like text. The box is square, so that icons line up in rows.
Text {
  id: root
  property string name: ""
  property int size: 16

  text: Fmt.glyph(name)
  color: Theme.fg
  font.family: Theme.font
  font.pixelSize: size
  textFormat: Text.PlainText
  horizontalAlignment: Text.AlignHCenter
  verticalAlignment: Text.AlignVCenter
  width: Math.round(size * 1.25)
  height: size
}
