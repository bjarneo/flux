import Foundation

/// What a kdeconnect.share.request packet from the computer carries. Text
/// wins over a URL, and a URL over a file, like in Flux for Android.
public enum ShareRequest: Equatable, Sendable {
    case text(String)
    case url(String)
    /// A file that comes as the payload of the packet. `open` asks this
    /// device to open the file once it arrives. `lastModified` is in
    /// milliseconds.
    case file(name: String, open: Bool, lastModified: Int64?)

    /// Reads a share packet. It returns nil for a packet without text, URL,
    /// or payload. `now` names a file that comes without a name.
    public init?(_ p: Packet, now: Int64 = Packet.now()) {
        if let text = p.string("text") {
            self = .text(text)
        } else if let url = p.string("url") {
            self = .url(url)
        } else if p.hasPayload {
            self = .file(name: ShareWire.safeName(p.string("filename") ?? "file-\(now)"),
                         open: p.bool("open") ?? false, lastModified: p.long("lastModified"))
        } else {
            return nil
        }
    }
}

/// The share packets that this device sends, with the fields of Flux for
/// Android.
public enum ShareWire {
    /// Reports whether shared text is a link: a scheme, "://", and no space.
    public static func isURL(_ text: String) -> Bool {
        text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://\S+$"#, options: .regularExpression) != nil
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
    /// characters, so that the file stays in the download folder.
    public static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let base = last.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? last
        let clean = String(String.UnicodeScalarView(base.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        if clean.trimmingCharacters(in: .whitespaces).isEmpty || clean == "." || clean == ".." { return "file" }
        return clean
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
