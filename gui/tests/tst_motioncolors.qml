import QtQuick
import QtTest
import "../omarchy/MotionColors.js" as MotionColors

// Checks of the motion cue colors. To run them from the repository root:
//   make test-gui
TestCase {
  name: "MotionColors"

  function test_contrast() {
    compare(Math.round(MotionColors.contrast("#000000", "#ffffff")), 21)
    compare(MotionColors.contrast("#777777", "#777777"), 1)
    compare(MotionColors.contrast("nope", "#ffffff"), 0)
    // An alpha byte is ignored.
    compare(MotionColors.contrast("#ff000000", "#ffffff"), MotionColors.contrast("#000000", "#ffffff"))
  }

  function test_accentWinsWithContrast() {
    // tokyo-night: a light blue accent on a dark background.
    var c = MotionColors.pick("#7aa2f7", "#a9b1d6", "", "#1a1b26")
    compare(c.fill, "#7aa2f7")
  }

  function test_lowContrastAccentFallsBack() {
    // A dark accent on a dark background: the foreground wins.
    var c = MotionColors.pick("#2a2a3a", "#e0e0e0", "#ffffff", "#1a1a1a")
    compare(c.fill, "#ffffff")
    // A light theme with a pale accent: the dark foreground wins.
    c = MotionColors.pick("#f0e0a0", "#333333", "", "#fdf6e3")
    compare(c.fill, "#333333")
  }

  function test_badColors() {
    var c = MotionColors.pick("", "", "", "")
    compare(c.fill, "#ffffff")
    c = MotionColors.pick("x", "y", "z", "#ffffff")
    compare(c.fill, "#000000")
  }

  function test_hexOf() {
    compare(MotionColors.hexOf(Qt.color("#7aa2f7")), "#7aa2f7")
    compare(MotionColors.hexOf(Qt.rgba(1, 0, 0, 0.5)).length, 7)
  }
}
