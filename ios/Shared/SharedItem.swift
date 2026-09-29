import Foundation
import UniformTypeIdentifiers

/// 1 attachment of a share, by what Flux sends for it.
struct SharedItem {
    enum Kind {
        case photo
        case video
        case file
        case link
        case text
    }

    let provider: NSItemProvider
    let kind: Kind
    /// The type that Flux loads the item as.
    let type: UTType

    /// Sorts an attachment. It returns nil for one that Flux cannot send.
    init?(_ provider: NSItemProvider) {
        self.provider = provider
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        func first(_ parent: UTType) -> UTType? { types.first { $0.conforms(to: parent) } }
        if let t = first(.image) {
            (kind, type) = (.photo, t)
        } else if let t = first(.audiovisualContent) {
            (kind, type) = (.video, t)
        } else if let t = first(.fileURL) {
            (kind, type) = (.file, t)
        } else if let t = first(.url) {
            (kind, type) = (.link, t)
        } else if let t = first(.plainText) {
            // A text file from Files or Mail goes as a file with its name.
            (kind, type) = (Self.isFileName(provider.suggestedName) ? .file : .text, t)
        } else if let t = first(.data) {
            (kind, type) = (.file, t)
        } else {
            return nil
        }
    }

    var isFile: Bool { kind == .photo || kind == .video || kind == .file }

    /// True for a text with a file name, such as "notes.txt". A page title
    /// such as "index.html" looks the same.
    var isTextFile: Bool { kind == .file && type.conforms(to: .plainText) }

    /// True when a suggested name ends with the extension of a type that
    /// the system knows, such as "notes.txt". Selected text and a page title
    /// have no name, or a name such as "Swift 5.9 released", whose last part
    /// is no known extension.
    static func isFileName(_ name: String?) -> Bool {
        guard let name else { return false }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 16, let type = UTType(filenameExtension: ext) else { return false }
        return type.isDeclared
    }

    /// The items that go out, like the share screen of Flux for Android:
    /// files when the share has any, else links, else text. Safari, for
    /// example, adds the page title as text next to the link. A title with
    /// a file name is no file, so a text file does not win over a link.
    static func sendable(_ items: [SharedItem]) -> [SharedItem] {
        let links = items.filter { $0.kind == .link }
        let files = items.filter { $0.isFile && !($0.isTextFile && !links.isEmpty) }
        if !files.isEmpty { return files }
        if !links.isEmpty { return links }
        return items.filter { $0.kind == .text }
    }

    static func summary(_ items: [SharedItem]) -> ShareSummary {
        var s = ShareSummary()
        for item in items {
            switch item.kind {
            case .photo: s.photos += 1
            case .video: s.videos += 1
            case .file: s.files += 1
            case .link: s.links += 1
            case .text: s.texts += 1
            }
        }
        return s
    }

    /// The name that the computer gets for a file: the suggested name with
    /// the extension of its type, else the name of the loaded file.
    func fileName(loaded: URL) -> String {
        Self.fileName(suggested: provider.suggestedName, type: type, loaded: loaded)
    }

    private static func fileName(suggested: String?, type: UTType, loaded: URL) -> String {
        guard let suggested, !suggested.isEmpty else { return loaded.lastPathComponent }
        let ext = loaded.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : loaded.pathExtension
        if ext.isEmpty || (suggested as NSString).pathExtension.lowercased() == ext.lowercased() { return suggested }
        return suggested + "." + ext
    }

    /// Copies a file item into the queue. The loaded file exists only in the
    /// callback, so the copy happens there.
    func queueFile(in queue: ShareQueue, computerId: String, created: Date, order: Int, share: String? = nil) async throws -> QueuedShare {
        if kind == .file, type.conforms(to: .fileURL) {
            let url = try await loadURL()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try queue.add(file: url, computerId: computerId, created: created, order: order, share: share)
        }
        let suggested = provider.suggestedName
        let type = type
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<QueuedShare, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    done.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    done.resume(returning: try queue.add(file: url, computerId: computerId, created: created, order: order,
                                                         name: Self.fileName(suggested: suggested, type: type, loaded: url), share: share))
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// The bytes of a text that the preview decodes.
    static let previewBytes = 4096

    /// The text of a link or a text item. A text larger than
    /// `ShareQueue.maxTextBytes` throws `textTooLarge` before Flux decodes
    /// it, so that a large text cannot fill the memory of the extension.
    func loadText() async throws -> String {
        if kind == .link { return try await loadURL().absoluteString }
        let (data, encoding) = try await loadTextData()
        // The UTF-16 form of a text with 1 MB of UTF-8 has up to 2 MB.
        let limit = encoding == .utf8 ? ShareQueue.maxTextBytes : 2 * ShareQueue.maxTextBytes
        if data.count > limit { throw ShareQueueError.textTooLarge }
        guard let text = Self.decode(data, encoding: encoding) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        if text.utf8.count > ShareQueue.maxTextBytes { throw ShareQueueError.textTooLarge }
        return text
    }

    /// The start of a link or a text item, for the preview. It decodes at
    /// most `previewBytes` of a text.
    func loadPreview() async throws -> String {
        if kind == .link { return try await loadURL().absoluteString }
        let (data, encoding) = try await loadTextData()
        return Self.decodeStart(data, encoding: encoding, maxBytes: Self.previewBytes)
    }

    /// Loads the bytes of a text item, as UTF-8 when the item has UTF-8.
    private func loadTextData() async throws -> (Data, TextEncoding) {
        let utf8 = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
        let load = utf8 ? UTType.utf8PlainText : type
        let encoding = utf8 ? TextEncoding.utf8 : TextEncoding(load)
        let data = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: load.identifier) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        return (data, encoding)
    }

    /// The encoding of the bytes of a plain text type.
    enum TextEncoding: Equatable {
        case utf8
        /// UTF-16 in the byte order of the byte order mark, or in the
        /// given order when the text has no mark.
        case utf16(bigEndian: Bool)

        /// UTF-8 unless the type says UTF-16.
        init(_ type: UTType) {
            if type.conforms(to: .utf16ExternalPlainText) {
                self = .utf16(bigEndian: true)
            } else if type.conforms(to: .utf16PlainText) {
                // The byte order of iPhones and Macs.
                self = .utf16(bigEndian: false)
            } else {
                self = .utf8
            }
        }
    }

    /// Decodes a text. Bytes that are not valid UTF-8 show as the
    /// replacement character.
    static func decode(_ data: Data, encoding: TextEncoding) -> String? {
        switch encoding {
        case .utf8:
            return String(decoding: data, as: UTF8.self)
        case .utf16(let bigEndian):
            let mark = [UInt8](data.prefix(2))
            if mark == [0xFF, 0xFE] { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
            if mark == [0xFE, 0xFF] { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
            return String(data: data, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
        }
    }

    /// Decodes the first `maxBytes` of a text. A character that the cut
    /// splits does not show.
    static func decodeStart(_ data: Data, encoding: TextEncoding, maxBytes: Int) -> String {
        guard data.count > maxBytes else { return decode(data, encoding: encoding) ?? "" }
        // An even cut keeps the UTF-16 units whole.
        var text = decode(data.prefix(maxBytes - maxBytes % 2), encoding: encoding) ?? ""
        if text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }

    private func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { done.resume(returning: url) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
