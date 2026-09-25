pragma Singleton
import QtQuick

// Text helpers for sizes, rates, times, and device labels.
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

  // Media position in ms, for example 3:12.
  function duration(ms) {
    if (!ms || ms < 0) return "0:00"
    var s = Math.floor(ms / 1000)
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var r = s % 60
    return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(r)
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

  // The icon name for a file, from Fmt.kindOf.
  function fileIcon(name, dir) {
    var k = kindOf(name, dir)
    var map = { "folder": "folder", "image": "file-image", "video": "file-video", "audio": "file-audio", "pdf": "file-pdf",
                "text": "file-text", "archive": "file-archive" }
    return map[k] || "file"
  }

  // The icon name for a phone app, or a bell for an app with no icon.
  readonly property var appIcons: ({
    "messages": "message", "sms": "message", "phone": "phone", "calendar": "calendar", "clock": "clock",
    "github": "github", "slack": "slack", "bank": "bank", "mail": "mail", "gmail": "mail", "email": "mail",
    "signal": "chat", "telegram": "chat", "discord": "chat", "whatsapp": "whatsapp", "spotify": "spotify",
    "firefox": "firefox", "chrome": "chrome"
  })

  function appIcon(app) {
    return appIcons[(app || "").toLowerCase()] || "bell"
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

  function signal(s) {
    if (!s || !s.type) return ""
    var bars = "▂▄▆█"
    var n = Math.max(0, Math.min(4, s.strength || 0))
    var out = ""
    for (var i = 0; i < 4; i++) out += i < n ? bars.charAt(i) : "_"
    return s.type + " " + out
  }

  // A stable color token name for an app, so each app keeps one color.
  readonly property var appTokens: ({
    "messages": "ok", "whatsapp": "ok", "phone": "ok", "calendar": "warn", "clock": "warn",
    "github": "alt", "slack": "alt", "discord": "alt", "bank": "accent", "mail": "accent",
    "gmail": "err", "signal": "err", "youtube": "err"
  })

  function appToken(app) {
    var known = appTokens[(app || "").toLowerCase()]
    if (known) return known
    var tokens = ["ok", "warn", "alt", "accent", "err"]
    var h = 0
    var s = app || ""
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 9973
    return tokens[h % tokens.length]
  }

  function kindOf(name, dir) {
    if (dir) return "folder"
    var m = (name || "").toLowerCase().match(/\.([a-z0-9]+)$/)
    var ext = m ? m[1] : ""
    if (["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "svg", "avif"].indexOf(ext) >= 0) return "image"
    if (["mp4", "mov", "mkv", "webm", "avi", "3gp", "m4v"].indexOf(ext) >= 0) return "video"
    if (["mp3", "flac", "ogg", "opus", "m4a", "wav", "aac"].indexOf(ext) >= 0) return "audio"
    if (ext === "pdf") return "pdf"
    if (["md", "txt", "log", "csv", "json"].indexOf(ext) >= 0) return "text"
    if (["zip", "tar", "gz", "xz", "zst", "7z", "rar"].indexOf(ext) >= 0) return "archive"
    if (ext === "iso") return "iso"
    if (ext === "apk") return "apk"
    return "file"
  }

  // Converts a file:// URL to a local path.
  function urlToPath(u) {
    var s = u.toString()
    if (s.indexOf("file://") === 0) s = s.slice(7)
    try { return decodeURIComponent(s) } catch (e) { return s }
  }
}
