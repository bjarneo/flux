import QtQuick
import Quickshell
import ".."

// Test wrapper for the offscreen test. Every 3 seconds it saves the widget
// as a PNG file in FLUX_TEST_SHOTS and logs the label and the tooltip text.
BarWidget {
  id: widget
  readonly property string out: Quickshell.env("FLUX_TEST_SHOTS") || ""
  property int shots: 0

  Timer {
    interval: 3000
    repeat: true
    running: widget.out !== ""
    onTriggered: {
      var n = ++widget.shots
      console.log("flux test: bar label", JSON.stringify(widget.label), "tooltip", JSON.stringify(widget.tooltip))
      widget.grabToImage(function (r) { r.saveToFile(widget.out + "/bar-widget-" + n + ".png") })
    }
  }
}
