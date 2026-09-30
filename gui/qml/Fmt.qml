pragma Singleton
import QtQuick

// Text helpers for sizes, rates, times, device labels, and icons.
QtObject {
  function bytes(n) {
    if (n === undefined || n === null || n < 0) return ""
    if (n < 1000) return n + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var v = n
    var i = -1
    do { v = v / 1000; i++ } while (v >= 1000 && i < units.length - 1)
    return (v >= 100 ? Math.round(v) : Math.round(v * 10) / 10) + " " + units[i]
  }

  function rate(n) {
    if (!n || n <= 0) return ""
    if (n >= 1000000) return Math.round(n / 1000000) + " MB/s"
    if (n >= 1000) return Math.round(n / 1000) + " KB/s"
    return n + " B/s"
  }

  function pad(n) { return n < 10 ? "0" + n : "" + n }

  // Clock time, for example 14:31.
  function clock(sec) {
    if (!sec) return ""
    var d = new Date(sec * 1000)
    return pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  // Clock time today, otherwise a short date.
  function when(sec) {
    if (!sec) return ""
    var d = new Date(sec * 1000)
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return clock(sec)
    return Qt.formatDate(d, "MMM d")
  }

  // Age, for example 2m, 1h, or 3d.
  function age(sec) {
    if (!sec) return ""
    var s = Math.max(0, Math.floor(Date.now() / 1000 - sec))
    if (s < 60) return "now"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Math.floor(s / 86400) + "d"
  }

  function lastSeen(sec) {
    if (!sec) return "unknown"
    var d = new Date(sec * 1000)
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return "today at " + clock(sec)
    return Qt.formatDate(d, "yyyy-MM-dd")
  }

  function kindShort(type) {
    if (type === "tablet") return "TAB"
    if (type === "tv") return "TV"
    if (type === "laptop" || type === "desktop") return "PC"
    return "PH"
  }

  // The icon name for a device type, for Icon.
  function kindIcon(type) {
    if (type === "tablet") return "tablet"
    if (type === "tv") return "tv"
    if (type === "laptop") return "laptop"
    if (type === "desktop") return "monitor"
    return "phone"
  }

  // The battery icon for a battery object, in steps of 10%.
  function batteryIcon(b) {
    if (!b || b.charge === undefined || b.charge === null || b.charge < 0) return "battery-unknown"
    if (b.charging) return "battery-charging"
    if (b.charge >= 95) return "battery"
    if (b.charge < 5) return "battery-empty"
    return "battery-" + Math.max(10, Math.floor(b.charge / 10) * 10)
  }

  // The icon name for a phone app, or a bell for an app with no icon.
  readonly property var appIcons: ({
    "messages": "message", "sms": "message", "phone": "phone", "calendar": "calendar", "clock": "clock",
    "github": "github", "slack": "slack", "bank": "bank", "mail": "mail", "gmail": "mail", "email": "mail",
    "signal": "chat", "telegram": "chat", "discord": "chat", "whatsapp": "whatsapp", "spotify": "spotify",
    "firefox": "firefox", "chrome": "chrome"
  })

  function appIcon(app) {
    return lookup(appIcons, (app || "").toLowerCase()) || "bell"
  }

  // The value of key in table, or undefined. It ignores the members of
  // Object.prototype, so an app name such as "constructor" finds nothing.
  function lookup(table, key) {
    return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : undefined
  }

  function typeName(type) {
    if (!type) return "Device"
    return type.charAt(0).toUpperCase() + type.slice(1)
  }

  // The word for the device in button labels, for example "Ring phone".
  function noun(type) {
    if (type === "phone" || type === "tablet") return type
    if (type === "laptop" || type === "desktop") return "PC"
    return "device"
  }

  function battery(b) {
    if (!b || b.charge === undefined || b.charge === null || b.charge < 0) return "—"
    return b.charge + "%"
  }

  // A stable color token name for an app, so each app keeps one color.
  readonly property var appTokens: ({
    "messages": "ok", "whatsapp": "ok", "phone": "ok", "calendar": "warn", "clock": "warn",
    "github": "alt", "slack": "alt", "discord": "alt", "bank": "accent", "mail": "accent",
    "gmail": "err", "signal": "err", "youtube": "err"
  })

  function appToken(app) {
    var known = lookup(appTokens, (app || "").toLowerCase())
    if (known) return known
    var tokens = ["ok", "warn", "alt", "accent", "err"]
    var h = 0
    var s = app || ""
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 9973
    return tokens[h % tokens.length]
  }

  // The codepoints of the icons in the Nerd Fonts "md" range, by name. Icon
  // reads this 1 table, so each icon does not make its own copy.
  readonly property var icons: ({
    "dashboard": 0xF0A1D, "clipboard": 0xF0A38, "transfers": 0xF1A96, "bell": 0xF009C,
    "bell-ring": 0xF009F, "bell-off": 0xF0A91, "music": 0xF075A, "message": 0xF036A,
    "console": 0xF018D,

    "phone": 0xF011C, "laptop": 0xF0322, "monitor": 0xF0379, "tablet": 0xF04F6, "tv": 0xF0502,
    "phone-off": 0xF0950, "link": 0xF0339, "unlink": 0xF033A, "key": 0xF030B,

    "battery": 0xF0079, "battery-90": 0xF0082, "battery-80": 0xF0081, "battery-70": 0xF0080,
    "battery-60": 0xF007F, "battery-50": 0xF007E, "battery-40": 0xF007D, "battery-30": 0xF007C,
    "battery-20": 0xF007B, "battery-10": 0xF007A, "battery-empty": 0xF008E,
    "battery-charging": 0xF0084, "battery-unknown": 0xF0091,
    "wifi": 0xF05A9, "wifi-off": 0xF05AA,

    "paste": 0xF0192, "copy": 0xF018F, "send": 0xF048A, "upload": 0xF0552, "download": 0xF01DA,
    "tray-up": 0xF011D, "tray-down": 0xF0120, "arrow-in": 0xF0042, "arrow-out": 0xF005C,
    "arrow-down": 0xF0045, "arrow-up": 0xF005D, "reply": 0xF045A, "snooze": 0xF068E,
    "open": 0xF03CC, "folder": 0xF024B, "refresh": 0xF0450, "plus": 0xF0415, "close": 0xF0156, "check": 0xF012C,
    "check-circle": 0xF05E1, "error": 0xF015A, "alert": 0xF05D6, "info": 0xF02FD,
    "trash": 0xF0A7A, "tune": 0xF1542, "cog": 0xF08BB, "search": 0xF0349, "chevron": 0xF0142,
    "more": 0xF01D9, "menu": 0xF035C, "arrow-left": 0xF004D, "clock": 0xF0150, "power": 0xF0425, "play-circle": 0xF040D,

    "play": 0xF040A, "pause": 0xF03E4, "previous": 0xF04AE, "next": 0xF04AD, "stop": 0xF04DB,
    "camera": 0xF0D5D, "webcam": 0xF05A0, "video": 0xF0BDC, "record": 0xF044B,
    "switch-camera": 0xF084A, "rotate": 0xF0467,
    "mic": 0xF036C, "mic-off": 0xF036D, "screen-share": 0xF1483,

    "calendar": 0xF0B67, "github": 0xF02A4, "bank": 0xF0E80, "chat": 0xF0EDE, "mail": 0xF01F0,
    "account": 0xF0B55, "whatsapp": 0xF05A3, "slack": 0xF04B1, "spotify": 0xF04C7,
    "firefox": 0xF0239, "chrome": 0xF02AF, "web": 0xF059F
  })

  // The text of an icon, or an empty string for an unknown name.
  function glyph(name) {
    var code = lookup(icons, name)
    return code !== undefined ? String.fromCodePoint(code) : ""
  }

  // Converts a local file URL to a path. It returns "" for another scheme
  // and for a URL with a host, for example trash:///a or file://server/a,
  // because fluxd sends only files on this computer.
  function urlToPath(u) {
    var m = /^file:(\/\/[^\/?#]*)?(\/[^?#]*)$/i.exec(String(u))
    if (!m) return ""
    var host = m[1] ? m[1].slice(2).toLowerCase() : ""
    if (host !== "" && host !== "localhost") return ""
    try {
      var path = decodeURIComponent(m[2])
      return path.indexOf("\u0000") < 0 ? path : ""
    } catch (e) {
      return ""
    }
  }

  // A verification key or a fingerprint in groups of 4 digits, for example
  // "5EE6 825F 974E D59A".
  function hexGroups(key) {
    var s = String(key || "").replace(/\s/g, "").toUpperCase()
    var groups = []
    for (var i = 0; i < s.length; i += 4) groups.push(s.slice(i, i + 4))
    return groups.join(" ")
  }

  // A pattern for the control characters, the bidi controls, and the line
  // separators. A name can use them to hide its real order, for example
  // "invoice\u202Efdp.exe", which shows as "invoiceexe.pdf".
  function controlChars() {
    return /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/g
  }

  // Shows each control character of text as its code, for example
  // "invoice[U+202E]fdp.exe". Use it for names from a phone.
  function showControls(text) {
    return String(text || "").replace(controlChars(), function (c) {
      var hex = c.charCodeAt(0).toString(16).toUpperCase()
      return "[U+" + "0000".slice(hex.length) + hex + "]"
    })
  }

  // The form of a device name that the duplicate check compares: no
  // control characters, no zero-width characters, 1 space between words,
  // and no case.
  function nameKey(name) {
    return String(name || "").replace(controlChars(), "").replace(/[\u200b-\u200d\ufeff]/g, "")
      .replace(/\s+/g, " ").trim().toLowerCase()
  }
}
