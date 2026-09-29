import Foundation

/// 1 item that waits in the share queue for its computer.
struct QueuedShare: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case text
        case link
    }

    /// The name of the item's folder in the queue.
    var id: String
    var computerId: String
    var kind: Kind
    /// The file name of a file.
    var name: String?
    /// The text of a text or a link.
    var text: String?
    var created: Date
    /// The place of the item among the items of 1 share.
    var order: Int
    /// Why the last try failed, or nil before a try.
    var failure: String?
}

/// 1 send of the plan: files of 1 computer in 1 batch, or 1 text or link.
/// The items are named by id.
enum ShareStep: Equatable, Sendable {
    case files(String, [String])
    case text(String, String)
}

/// The queue of shared items in the App Group. The share extension adds
/// items, and the app sends them when their computer connects.
///
/// Each item has a folder in `Queue/` with its file, if any, and
/// `entry.json`. The entry is written last, so a folder without one is an
/// item that the extension still copies, or one that it left.
struct ShareQueue: Sendable {
    let root: URL

    var folder: URL { root.appendingPathComponent("Queue", isDirectory: true) }

    static let entryName = "entry.json"

    /// The items, oldest share first, and in their order within a share.
    func items() -> [QueuedShare] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return folders.compactMap { dir -> QueuedShare? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.entryName)),
                  var item = try? decoder.decode(QueuedShare.self, from: data) else { return nil }
            item.id = dir.lastPathComponent
            return item
        }
        .sorted { ($0.created, $0.order, $0.id) < ($1.created, $1.order, $1.id) }
    }

    /// Copies a file into the queue. `name` is the name that the computer
    /// gets, the file's own name by default.
    @discardableResult
    func add(file source: URL, computerId: String, created: Date, order: Int, name: String? = nil) throws -> QueuedShare {
        let id = UUID().uuidString
        let dir = try newFolder(id)
        let clean = Self.safeName(name ?? source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(clean))
            let item = QueuedShare(id: id, computerId: computerId, kind: .file, name: clean, text: nil, created: created, order: order)
            try write(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Adds a text or a link.
    @discardableResult
    func add(text: String, kind: QueuedShare.Kind, computerId: String, created: Date, order: Int) throws -> QueuedShare {
        let id = UUID().uuidString
        let dir = try newFolder(id)
        let item = QueuedShare(id: id, computerId: computerId, kind: kind, name: nil, text: text, created: created, order: order)
        do {
            try write(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// The copy of a file item.
    func file(of item: QueuedShare) -> URL? {
        guard item.kind == .file, let name = item.name, let dir = itemFolder(item.id) else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// Removes an item and its copy.
    func remove(_ id: String) {
        guard let dir = itemFolder(id) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Keeps a failed item with the reason, for the next try.
    func markFailed(_ id: String, message: String) throws {
        guard let dir = itemFolder(id), var item = items().first(where: { $0.id == id }) else { return }
        item.failure = message
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent(Self.entryName), options: .atomic)
    }

    /// Removes folders without an entry that are older than `olderThan`
    /// seconds: copies that an extension started and did not finish.
    func removeAbandoned(now: Date, olderThan: TimeInterval) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for dir in folders where !fm.fileExists(atPath: dir.appendingPathComponent(Self.entryName).path) {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > olderThan { try? fm.removeItem(at: dir) }
        }
    }

    /// Removes the items of computers that are no longer paired.
    func removeItems(notFor computers: Set<String>) {
        for item in items() where !computers.contains(item.computerId) { remove(item.id) }
    }

    /// The sends for the connected computers, in the order of the queue.
    /// Files of 1 computer that follow each other go in 1 batch, like files
    /// that the Share screen sends together.
    static func plan(_ items: [QueuedShare], connected: Set<String>) -> [ShareStep] {
        var steps: [ShareStep] = []
        for item in items where connected.contains(item.computerId) {
            if item.kind == .file {
                if case .files(let computer, let ids) = steps.last, computer == item.computerId {
                    steps[steps.count - 1] = .files(computer, ids + [item.id])
                } else {
                    steps.append(.files(item.computerId, [item.id]))
                }
            } else {
                steps.append(.text(item.computerId, item.id))
            }
        }
        return steps
    }

    /// The last element of a name, without control characters, so that the
    /// copy stays in its folder.
    static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        let trimmed = clean.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed == Self.entryName { return "file" }
        return clean
    }

    private func itemFolder(_ id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return nil }
        return folder.appendingPathComponent(id, isDirectory: true)
    }

    private func newFolder(_ id: String) throws -> URL {
        let dir = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ item: QueuedShare) throws {
        guard let dir = itemFolder(item.id) else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent(Self.entryName), options: .atomic)
    }
}

/// The count of each kind of item in a share, for the extension's summary.
struct ShareSummary: Equatable, Sendable {
    var photos = 0
    var videos = 0
    var files = 0
    var links = 0
    var texts = 0

    var count: Int { photos + videos + files + links + texts }

    /// For example "2 photos and 1 video".
    static func text(_ s: ShareSummary) -> String {
        let parts = [
            (s.photos, "photo"), (s.videos, "video"), (s.files, "file"), (s.links, "link"), (s.texts, "text"),
        ]
        .filter { $0.0 > 0 }
        .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        switch parts.count {
        case 0: return "Nothing to send"
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}
