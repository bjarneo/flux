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
            (kind, type) = (.text, t)
        } else if let t = first(.data) {
            (kind, type) = (.file, t)
        } else {
            return nil
        }
    }

    var isFile: Bool { kind == .photo || kind == .video || kind == .file }

    /// The items that go out, like the share screen of Flux for Android:
    /// files when the share has any, else links, else text. Safari, for
    /// example, adds the page title as text next to the link.
    static func sendable(_ items: [SharedItem]) -> [SharedItem] {
        let files = items.filter(\.isFile)
        if !files.isEmpty { return files }
        let links = items.filter { $0.kind == .link }
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

    /// The text of a link or a text item.
    func loadText() async throws -> String {
        if kind == .link { return try await loadURL().absoluteString }
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text { done.resume(returning: text) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { done.resume(returning: url) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
