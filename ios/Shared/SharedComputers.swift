import Foundation

/// A paired computer as the share extension shows it.
struct SharedComputer: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// The device type, for example "laptop", for the symbol.
    var type: String
    /// Whether the app was connected to it when it wrote the list. The
    /// extension cannot know more, so it shows `lastOnline`.
    var online: Bool
    /// When the app last saw it connected, or nil if it never did.
    var lastOnline: Date?
}

/// The paired computers, which the app writes to the App Group for the
/// share extension.
enum SharedComputers {
    /// A paired computer in the app's state.
    struct Current: Equatable, Sendable {
        var id: String
        var name: String
        var type: String
        var online: Bool
    }

    static let fileName = "computers.json"

    /// The list for the computers of now. A connected computer is online
    /// now, and one that was connected in the last list was online until
    /// now. Others keep their time.
    static func next(previous: [SharedComputer], current: [Current], now: Date) -> [SharedComputer] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return current.map { c in
            let old = before[c.id]
            let seen = c.online || old?.online == true ? now : old?.lastOnline
            return SharedComputer(id: c.id, name: c.name, type: c.type, online: c.online, lastOnline: seen)
        }
    }

    /// The list that the app wrote last, or an empty list.
    static func read(root: URL) -> [SharedComputer] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([SharedComputer].self, from: data)) ?? []
    }

    /// Writes the list when it changed. It returns true when it wrote it.
    @discardableResult
    static func write(_ computers: [SharedComputer], root: URL) throws -> Bool {
        guard computers != read(root: root) else { return false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(computers).write(to: root.appendingPathComponent(fileName), options: .atomic)
        return true
    }

    /// The computer that the extension picks first: the one used last, or
    /// the only one. With several and none used yet, the user picks.
    static func defaultChoice(_ computers: [SharedComputer], lastUsed: String?) -> String? {
        if let lastUsed, computers.contains(where: { $0.id == lastUsed }) { return lastUsed }
        return computers.count == 1 ? computers[0].id : nil
    }
}
