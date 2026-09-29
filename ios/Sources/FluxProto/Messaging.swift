import Foundation

/// M2 messaging primitives: packet builders + parsers for ping, battery,
/// clipboard, share, connectivity, find-my-phone, and notifications.
///
/// Sources of truth: `internal/core/handlers.go` (`handlePing`,
/// `handleBattery`, `handleConnectivity`, `handleFindMyPhone`),
/// `internal/core/clipboard.go`, `internal/core/share.go`,
/// `internal/core/telephony.go` (`SendNotification`), Android
/// `core/Plugins.kt` (battery/clipboard/ping handling),
/// `core/Share.kt` (share receive + `sanitize`), and
/// `core/ComputerNotification.kt` (desktop→phone render model).
///
/// Direction notes (do not "improve" the wire):
/// - `kdeconnect.ping` carries `{"message"}`; a missing message means "Ping"
///   (Go `handlePing`, Android `Plugins`).
/// - `kdeconnect.battery` carries `currentCharge`/`isCharging`/`thresholdEvent`.
///   A negative charge means "no battery" (Go sets `battery = nil`, Android
///   drops the value). `thresholdEvent == 1` is the ≤15% low-battery flag.
/// - `kdeconnect.clipboard` carries `{"content"}`; `clipboard.connect`
///   additionally carries `{"timestamp"}` (ms). A connect packet older than
///   the last local change is stale and only stored, never applied
///   (Go `handleClipboard`, Android `receiveClipboard`).
/// - `kdeconnect.share.request` carries text, a URL, or a payload
///   (`payloadSize` + `payloadTransferInfo.port/tunnel`). Payload bytes are
///   fetched in M3; M2 only parses + queues (`ShareFile`).
/// - `kdeconnect.notification` desktop→phone renders; phone→desktop carries
///   Flux-internal + CallKit events only (no global mirror on iOS).
/// - `kdeconnect.findmyphone.request` has an empty body and toggles
///   (a second request stops the ring, like Android `Ringer`).

// MARK: - Ping

/// `kdeconnect.ping`. Mirrors Go `handlePing` + Android `Plugins.PING`.
public enum PingMessage {
    /// Builds a ping. An empty message is omitted (the receiver says "Ping").
    public static func packet(message: String) -> Packet {
        message.isEmpty
            ? Packet(type: PacketType.ping)
            : Packet.of(PacketType.ping, ("message", message))
    }

    /// Reads the display message ("Ping" when the body has none).
    public static func message(_ p: Packet) -> String? {
        guard p.type == PacketType.ping else { return nil }
        let m = p.string("message") ?? ""
        return m.isEmpty ? "Ping" : m
    }
}

// MARK: - Battery

/// `kdeconnect.battery`. Level nil = no battery (`currentCharge < 0`).
public struct BatteryState: Sendable, Equatable {
    public var level: Int?
    public var charging: Bool
    public var thresholdEvent: Int

    public init(level: Int?, charging: Bool, thresholdEvent: Int? = nil) {
        self.level = level
        self.charging = charging
        if let thresholdEvent {
            self.thresholdEvent = thresholdEvent
        } else if let level, level <= 15, !charging {
            self.thresholdEvent = 1
        } else {
            self.thresholdEvent = 0
        }
    }

    /// Builds the packet. A nil level encodes as -1 (Go reads it as
    /// "no battery", Android drops it).
    public func packet() -> Packet {
        Packet.of(
            PacketType.battery,
            ("currentCharge", level ?? -1),
            ("isCharging", charging),
            ("thresholdEvent", thresholdEvent)
        )
    }

    /// Parses a received battery packet. Returns nil for other types
    /// (including `battery.request`, which the router answers).
    public static func parse(_ p: Packet) -> BatteryState? {
        guard p.type == PacketType.battery else { return nil }
        let level = p.int("currentCharge").flatMap { $0 >= 0 ? $0 : nil }
        return BatteryState(
            level: level,
            charging: p.bool("isCharging") ?? false,
            thresholdEvent: p.int("thresholdEvent") ?? 0
        )
    }

    /// Change-only gate (Android sends on change; Go polls every 60 s and
    /// skips unchanged). Nil previous always reports.
    public func shouldReport(previous: BatteryState?) -> Bool {
        guard let previous else { return true }
        return level != previous.level || charging != previous.charging
    }
}

// MARK: - Clipboard

/// `kdeconnect.clipboard` / `kdeconnect.clipboard.connect`.
public struct ClipboardMessage: Sendable, Equatable {
    public var content: String
    /// Send timestamp (ms) for `.connect` packets; nil for plain clipboard.
    public var timestampMs: Int64?
    public var isConnect: Bool

    public init(content: String, timestampMs: Int64? = nil, isConnect: Bool = false) {
        self.content = content
        self.timestampMs = timestampMs
        self.isConnect = isConnect
    }

    public func packet() -> Packet {
        if isConnect {
            return Packet.of(
                PacketType.clipboardConnect,
                ("content", content),
                ("timestamp", timestampMs ?? 0)
            )
        }
        return Packet.of(PacketType.clipboard, ("content", content))
    }

    /// Parses a clipboard packet. Returns nil for other types or empty content
    /// (Go drops empty content; Android drops null-or-empty).
    public static func parse(_ p: Packet) -> ClipboardMessage? {
        switch p.type {
        case PacketType.clipboard:
            guard let c = p.string("content"), !c.isEmpty else { return nil }
            return ClipboardMessage(content: c)
        case PacketType.clipboardConnect:
            guard let c = p.string("content"), !c.isEmpty else { return nil }
            return ClipboardMessage(content: c, timestampMs: p.long("timestamp"), isConnect: true)
        default:
            return nil
        }
    }

    /// A `clipboard.connect` packet older than the last local change is stale:
    /// stored, never applied. Mirrors Go (`timestamp <= lastLocalClip`) and
    /// Android (`timestamp in 1...clipboardTimestamp`). Plain clipboard
    /// packets are never stale.
    public func isStale(againstLocalMs localMs: Int64) -> Bool {
        guard isConnect, let ts = timestampMs, ts > 0 else { return false }
        return ts <= localMs
    }
}

// MARK: - Share

/// A `kdeconnect.share.request` file announcement. Payload bytes are fetched
/// in M3 (`Payload.receive` / `flux.tunnel`); M2 only queues this record.
public struct ShareFile: Sendable, Equatable {
    public var filename: String
    public var open: Bool
    public var scan: Bool
    public var photo: Bool
    public var screenshot: Bool
    public var payloadSize: Int64
    public var payloadPort: Int
    public var payloadTunnel: String?
    public var numberOfFiles: Int?
    public var totalPayloadSize: Int64?

    public init(
        filename: String, open: Bool = false, scan: Bool = false,
        photo: Bool = false, screenshot: Bool = false,
        payloadSize: Int64 = 0, payloadPort: Int = 0,
        payloadTunnel: String? = nil, numberOfFiles: Int? = nil,
        totalPayloadSize: Int64? = nil
    ) {
        self.filename = filename
        self.open = open
        self.scan = scan
        self.photo = photo
        self.screenshot = screenshot
        self.payloadSize = payloadSize
        self.payloadPort = payloadPort
        self.payloadTunnel = payloadTunnel
        self.numberOfFiles = numberOfFiles
        self.totalPayloadSize = totalPayloadSize
    }
}

/// One parsed `kdeconnect.share.request` packet. Field precedence mirrors Go
/// `handleShare` (URL, then scanned text, then plain text, then payload) and
/// Android `Share.receive` (text, then URL, then payload).
public enum ShareContent: Sendable, Equatable {
    case text(String, scan: Bool)
    case url(String)
    case file(ShareFile)
    case none
}

/// `kdeconnect.share.request` (+ `.update`). Mirrors Go `handleShare`,
/// `SendFiles`/`ShareText`, and Android `Share`.
public enum ShareMessage {
    /// Builds a text/URL share (Go `ShareText`: key is "text" or "url").
    public static func textPacket(_ text: String, scan: Bool = false) -> Packet {
        scan
            ? Packet.of(PacketType.share, ("text", text), ("scan", true))
            : Packet.of(PacketType.share, ("text", text))
    }

    public static func urlPacket(_ url: String) -> Packet {
        Packet.of(PacketType.share, ("url", url))
    }

    /// Builds the multi-file preamble (Go `SendFiles`, Android `sendFiles`).
    public static func updatePacket(numberOfFiles: Int, totalPayloadSize: Int64) -> Packet {
        Packet.of(
            PacketType.shareUpdate,
            ("numberOfFiles", numberOfFiles),
            ("totalPayloadSize", totalPayloadSize)
        )
    }

    public static func parseUpdate(_ p: Packet) -> (numberOfFiles: Int, totalPayloadSize: Int64)? {
        guard p.type == PacketType.shareUpdate else { return nil }
        guard let n = p.int("numberOfFiles") else { return nil }
        return (n, p.long("totalPayloadSize") ?? 0)
    }

    public static func parse(_ p: Packet) -> ShareContent? {
        guard p.type == PacketType.share else { return nil }
        if let url = p.string("url"), !url.isEmpty { return .url(url) }
        if let text = p.string("text"), !text.isEmpty {
            return .text(text, scan: p.bool("scan") ?? false)
        }
        guard p.hasPayload else { return .none }
        return .file(ShareFile(
            filename: sanitize(p.string("filename") ?? ""),
            open: p.bool("open") ?? false,
            scan: p.bool("scan") ?? false,
            photo: p.bool("photo") ?? false,
            screenshot: p.bool("screenshot") ?? false,
            payloadSize: p.payloadSize,
            payloadPort: p.payloadPort,
            payloadTunnel: p.payloadTunnel,
            numberOfFiles: p.int("numberOfFiles"),
            totalPayloadSize: p.long("totalPayloadSize")
        ))
    }

    /// Keeps only the last path element, strips ASCII control characters, and
    /// falls back to "file". Mirrors Android `sanitize` + Go `safeName`.
    public static func sanitize(_ name: String) -> String {
        let base = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let stripped = String(String.UnicodeScalarView(base.unicodeScalars.filter { $0.value >= 0x20 }))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "file" }
        return trimmed
    }
}

// MARK: - Connectivity

/// `kdeconnect.connectivity_report`. iOS sends reachability
/// (`NWPathMonitor`: wifi/cellular); the desktop keeps the strongest signal
/// (Go `handleConnectivity`).
public enum ConnectivityReport {
    /// Builds a report from `(key, networkType, signalStrength)` signals.
    /// Keys are free-form ("wifi", "cell"); strength follows the KDE Connect
    /// 0–4 scale.
    public static func packet(signals: [(key: String, networkType: String, signalStrength: Int)]) -> Packet {
        var dict: [String: JSONValue] = [:]
        for s in signals {
            dict[s.key] = .object([
                "networkType": .string(s.networkType),
                "signalStrength": .integer(Int64(s.signalStrength)),
            ])
        }
        return Packet(type: PacketType.connectivity, body: ["signalStrengths": .object(dict)])
    }
}

// MARK: - Find my phone

/// `kdeconnect.findmyphone.request` (empty body). Toggles: a second request
/// while ringing stops it, so the desktop can silence a ring nobody can
/// reach (Android `Ringer.start`, Go `handleFindMyPhone` + 2-minute cap).
public enum FindMyPhone {
    public static func packet() -> Packet {
        Packet(type: PacketType.findMyPhone)
    }

    public static func isRingRequest(_ p: Packet) -> Bool {
        p.type == PacketType.findMyPhone
    }
}

// MARK: - Notifications

/// `kdeconnect.notification*` packets.
///
/// - Desktop→phone `kdeconnect.notification` renders (see
///   `ComputerNotification`); cancel arrives as `notification.request`
///   `{"cancel": id}`, a full-list request as `{"request": true}`
///   (answered with nothing: no global mirror on iOS).
/// - Desktop→phone `notification.reply`/`notification.action` answer the
///   phone's own notifications; with no mirror they are logged and dropped.
/// - Phone→desktop `kdeconnect.notification` carries Flux-internal +
///   CallKit missed-call events only (M4 sends; the builder lives here).
public enum NotificationPackets {
    /// Builds a phone→desktop notification (mirrors Android
    /// `NotificationSync.toPacket` fields).
    public static func outgoing(
        id: String, appName: String, title: String, text: String,
        timeMs: Int64, clearable: Bool = true, silent: Bool = false,
        replyId: String? = nil, actions: [String] = []
    ) -> Packet {
        let ticker = title.isEmpty ? text : (text.isEmpty ? title : "\(title): \(text)")
        var body: [String: JSONValue] = [
            "id": .string(id),
            "appName": .string(appName),
            "title": .string(title),
            "text": .string(text),
            "ticker": .string(ticker),
            "time": .string(String(timeMs)),
            "isClearable": .bool(clearable),
        ]
        if silent { body["silent"] = .bool(true) }
        if let replyId { body["requestReplyId"] = .string(replyId) }
        if !actions.isEmpty { body["actions"] = .array(actions.map { .string($0) }) }
        return Packet(type: PacketType.notification, body: body)
    }

    /// Builds a desktop→phone render packet (test-harness equivalent of Go
    /// `SendNotification`).
    public static func incoming(
        id: String, appName: String, title: String, text: String, timeMs: Int64
    ) -> Packet {
        let ticker = text.isEmpty ? title : "\(title): \(text)"
        return Packet.of(
            PacketType.notification,
            ("id", id),
            ("appName", appName),
            ("title", title),
            ("text", text),
            ("ticker", ticker),
            ("isClearable", true),
            ("time", String(timeMs))
        )
    }

    public static func requestAll() -> Packet {
        Packet.of(PacketType.notificationRequest, ("request", true))
    }

    public static func cancelRequest(id: String) -> Packet {
        Packet.of(PacketType.notificationRequest, ("cancel", id))
    }

    public static func replyPacket(replyId: String, message: String) -> Packet {
        Packet.of(PacketType.notificationReply, ("requestReplyId", replyId), ("message", message))
    }

    public static func actionPacket(key: String, action: String) -> Packet {
        Packet.of(PacketType.notificationAction, ("key", key), ("action", action))
    }

    /// One parsed `kdeconnect.notification.request` packet.
    public enum Request: Sendable, Equatable {
        case requestAll
        case cancel(id: String)
        case unknown
    }

    public static func parseRequest(_ p: Packet) -> Request? {
        guard p.type == PacketType.notificationRequest else { return nil }
        if p.bool("request") == true { return .requestAll }
        if let id = p.string("cancel"), !id.isEmpty { return .cancel(id: id) }
        return .unknown
    }
}

/// A notification a computer sends to this phone. Port of Android
/// `core/ComputerNotification.kt`: the app name shows next to the computer
/// name unless it matches; title falls back to ticker then text.
public struct ComputerNotification: Sendable, Equatable {
    /// Local key: `"<deviceId>:<packet id>"`. Replaces the previous
    /// notification with the same key.
    public var key: String
    public var subText: String
    public var title: String
    public var text: String
    /// Display time (ms since epoch).
    public var timeMs: Int64
    public var clearable: Bool
    public var cancel: Bool

    public init(
        key: String, subText: String, title: String, text: String,
        timeMs: Int64, clearable: Bool, cancel: Bool
    ) {
        self.key = key
        self.subText = subText
        self.title = title
        self.text = text
        self.timeMs = timeMs
        self.clearable = clearable
        self.cancel = cancel
    }

    /// Reads the packet from `computer`. Returns nil for a packet with no ID,
    /// or no text at all (unless it cancels).
    public static func from(
        _ p: Packet, deviceId: String, computer: String, nowMs: Int64
    ) -> ComputerNotification? {
        guard p.type == PacketType.notification else { return nil }
        guard let id = p.string("id"), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let cancel = isTrue(p.body["isCancel"])
        let text = (p.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = (p.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = (p.string("ticker") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !cancel, title.isEmpty, text.isEmpty { return nil }
        let app = (p.string("appName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = app.isEmpty || app.caseInsensitiveCompare(computer) == .orderedSame
            ? computer : "\(app) · \(computer)"
        return ComputerNotification(
            key: "\(deviceId):\(id)",
            subText: sub,
            title: title.isEmpty ? text : title,
            text: title.isEmpty ? "" : text,
            timeMs: p.long("time").flatMap { $0 > 0 ? $0 : nil } ?? nowMs,
            clearable: !isFalse(p.body["isClearable"]),
            cancel: cancel
        )
    }
}

/// Flexible booleans: the wire uses real booleans, but Go `flexString`
/// accepts `"true"`/`"1"` strings for phone-originated packets.
private func isTrue(_ v: JSONValue?) -> Bool {
    switch v {
    case .bool(let b): return b
    case .integer(let i): return i != 0
    case .string(let s):
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "true" || t == "1"
    default: return false
    }
}

private func isFalse(_ v: JSONValue?) -> Bool {
    switch v {
    case .bool(let b): return !b
    case .integer(let i): return i == 0
    case .string(let s):
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "false" || t == "0"
    default: return false
    }
}
