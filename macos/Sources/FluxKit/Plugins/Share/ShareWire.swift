import Foundation

/// What a flux.share.request packet from the computer carries. Text
/// wins over a URL, and a URL over a file, like in Flux for Android.
public enum ShareRequest: Equatable, Sendable {
    case text(String)
    /// A web link: http or https with a host.
    case url(URL)
    /// A file that comes as the payload of the packet. `lastModified` is in
    /// milliseconds. The "open" field of the packet does nothing: this
    /// device never opens a received file by itself.
    case file(name: String, lastModified: Int64?)

    /// Reads a share packet. It returns nil for a packet without text, URL,
    /// or payload. `now` names a file that comes without a name. A "url"
    /// that is not a web link is text, like in fluxd, because another
    /// scheme can start an app.
    public init?(_ p: Packet, now: Int64 = Packet.now()) {
        if let text = p.string("text") {
            self = .text(text)
        } else if let url = p.string("url") {
            self = ShareWire.webURL(url).map { .url($0) } ?? .text(url)
        } else if p.hasPayload {
            self = .file(name: ShareWire.safeName(p.string("filename") ?? "file-\(now)"), lastModified: p.long("lastModified"))
        } else {
            return nil
        }
    }
}

/// The share packets that this device sends, with the fields of Flux for
/// Android.
public enum ShareWire {
    /// Reports whether shared text is a web link: http or https, "://", a
    /// host, and no space. Other schemes and file paths are text, like in
    /// fluxd and Flux for Android.
    public static func isURL(_ text: String) -> Bool { webURL(text) != nil }

    /// The web link in the text, or nil when the text is not 1 http or https
    /// URL with a host.
    public static func webURL(_ text: String) -> URL? {
        guard text.range(of: #"^[hH][tT][tT][pP][sS]?://\S+$"#, options: .regularExpression) != nil,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Text or a link from the share sheet. A link goes as "url", so that the
    /// computer opens it.
    public static func text(_ text: String) -> Packet {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Packet(PacketType.share, isURL(trimmed) ? ["url": trimmed] : ["text": text])
    }

    /// Text that the camera read. The "scan" flag makes the computer save it
    /// in a file.
    public static func scan(_ text: String) -> Packet {
        Packet(PacketType.share, ["text": text, "scan": true])
    }

    /// Announces a batch of files before the first file.
    public static func update(count: Int, total: Int64) -> Packet {
        Packet(PacketType.shareUpdate, ["numberOfFiles": count, "totalPayloadSize": total])
    }

    /// 1 file of a batch, offered on a payload port.
    public static func file(name: String, count: Int, total: Int64, size: Int64, port: Int) -> Packet {
        Packet(PacketType.share, ["filename": name, "open": false, "numberOfFiles": count, "totalPayloadSize": total],
               payloadSize: size, payloadPort: port)
    }

    /// 1 captured file with extra fields, for example "photo" or "scan",
    /// offered on a payload port.
    public static func capture(name: String, extra: [String: JSONValue], size: Int64, port: Int) -> Packet {
        var body: [String: JSONValue] = ["filename": .string(name), "open": .bool(false)]
        body.merge(extra) { _, new in new }
        return Packet(type: PacketType.share, json: body, payloadSize: size, payloadPort: port)
    }

    /// Keeps only the last element of a received file name, without control
    /// characters and bidirectional controls, so that the file stays in the
    /// download folder and its name shows its real extension.
    public static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let base = last.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? last
        let clean = visibleName(base)
        if clean.trimmingCharacters(in: .whitespaces).isEmpty || clean == "." || clean == ".." { return "file" }
        return clean
    }

    /// Removes the scalars that hide or reorder the text of a file name:
    /// control characters and bidirectional controls such as U+202E, which
    /// can show "exe.txt" for a name that ends in ".exe".
    public static func visibleName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { !hidesText($0) }))
    }

    static func hidesText(_ s: Unicode.Scalar) -> Bool {
        if s.properties.generalCategory == .control { return true }
        switch s.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// Returns dir/name, or dir/"name (2).ext", "name (3).ext", and so on,
    /// the first that does not exist.
    public static func uniqueURL(in dir: URL, name: String, exists: (URL) -> Bool) -> URL {
        let first = dir.appendingPathComponent(name)
        if !exists(first) { return first }
        var ext = (name as NSString).pathExtension
        if ext.count + 1 >= name.count { ext = "" }
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !exists(candidate) { return candidate }
            i += 1
        }
    }
}
