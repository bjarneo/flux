import QtQuick
import ".."

// An icon: a Material Design glyph from the Nerd Font in the monospace
// font of Omarchy, the same icons as the Omarchy shell. It takes a color
// like text. The box is square, so that icons line up in rows.
Text {
  id: root
  property string name: ""
  property int size: 16

  // The codepoints in the Nerd Fonts "md" range, by glyph name.
  readonly property var codes: ({
    "dashboard": 0xF0A1D, "clipboard": 0xF0A38, "transfers": 0xF1A96, "bell": 0xF009C,
    "bell-ring": 0xF009F, "bell-off": 0xF0A91, "music": 0xF075A, "message": 0xF036A,
    "browse": 0xF0969, "console": 0xF018D,

    "phone": 0xF011C, "laptop": 0xF0322, "monitor": 0xF0379, "tablet": 0xF04F6, "tv": 0xF0502,
    "phone-off": 0xF0950, "link": 0xF0339, "unlink": 0xF033A, "key": 0xF030B,

    "battery": 0xF0079, "battery-90": 0xF0082, "battery-80": 0xF0081, "battery-70": 0xF0080,
    "battery-60": 0xF007F, "battery-50": 0xF007E, "battery-40": 0xF007D, "battery-30": 0xF007C,
    "battery-20": 0xF007B, "battery-10": 0xF007A, "battery-empty": 0xF008E,
    "battery-charging": 0xF0084, "battery-unknown": 0xF0091,
    "signal-1": 0xF08BC, "signal-2": 0xF08BD, "signal-3": 0xF08BE, "signal-off": 0xF08BF,
    "wifi": 0xF05A9, "wifi-off": 0xF05AA,

    "paste": 0xF0192, "copy": 0xF018F, "send": 0xF048A, "upload": 0xF0552, "download": 0xF01DA,
    "tray-up": 0xF011D, "tray-down": 0xF0120, "arrow-in": 0xF0042, "arrow-out": 0xF005C,
    "arrow-down": 0xF0045, "arrow-up": 0xF005D, "reply": 0xF045A, "snooze": 0xF068E,
    "open": 0xF03CC, "refresh": 0xF0450, "plus": 0xF0415, "close": 0xF0156, "check": 0xF012C,
    "check-circle": 0xF05E1, "error": 0xF015A, "alert": 0xF05D6, "info": 0xF02FD,
    "trash": 0xF0A7A, "tune": 0xF1542, "cog": 0xF08BB, "search": 0xF0349, "chevron": 0xF0142,
    "more": 0xF01D9, "clock": 0xF0150, "power": 0xF0425, "play-circle": 0xF040D,

    "play": 0xF040A, "pause": 0xF03E4, "previous": 0xF04AE, "next": 0xF04AD, "stop": 0xF04DB,
    "camera": 0xF0D5D, "webcam": 0xF05A0, "video": 0xF0BDC, "record": 0xF044B,
    "switch-camera": 0xF084A, "rotate": 0xF0467,

    "folder": 0xF024B, "folder-outline": 0xF0256, "file": 0xF0224, "file-text": 0xF09EE,
    "file-image": 0xF0EB0, "file-video": 0xF0E2C, "file-audio": 0xF0E2A, "file-pdf": 0xF0226,
    "file-archive": 0xF07B9, "file-code": 0xF0169, "home": 0xF06A1, "disk": 0xF02CA,

    "calendar": 0xF0B67, "github": 0xF02A4, "bank": 0xF0E80, "chat": 0xF0EDE, "mail": 0xF01F0,
    "account": 0xF0B55, "whatsapp": 0xF05A3, "slack": 0xF04B1, "spotify": 0xF04C7,
    "firefox": 0xF0239, "chrome": 0xF02AF, "web": 0xF059F
  })

  text: codes[name] !== undefined ? String.fromCodePoint(codes[name]) : ""
  color: Theme.fg
  font.family: Theme.font
  font.pixelSize: size
  textFormat: Text.PlainText
  horizontalAlignment: Text.AlignHCenter
  verticalAlignment: Text.AlignVCenter
  width: Math.round(size * 1.25)
  height: size
}
