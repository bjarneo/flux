import Foundation

/// The answer of the computer to 1 search: the search body of flux.sftp.
/// The computer ranks the results, the best match first.
public struct BrowseFound: Sendable, Equatable {
    /// The ID of the search that this answer belongs to.
    public var id: Int64
    public var results: [BrowseEntry]
    /// True when more names match than the answer holds.
    public var more: Bool
    /// True when the search stopped at its time limit before it read each folder.
    public var partial: Bool
    public var error: String?

    public init(id: Int64, results: [BrowseEntry] = [], more: Bool = false, partial: Bool = false, error: String? = nil) {
        self.id = id
        self.results = results
        self.more = more
        self.partial = partial
        self.error = error
    }

    /// Parses the search body of flux.sftp. It returns nil for a packet
    /// without a search body or without an ID. It skips a result without
    /// an absolute path.
    public static func parse(_ p: Packet) -> BrowseFound? {
        guard p.type == PacketType.sftp, let body = p.object("search"), let id = body["id"]?.int64 else { return nil }
        let results = (body["results"]?.array ?? []).compactMap { value -> BrowseEntry? in
            guard let o = value.object, let path = o["path"]?.string, path.hasPrefix("/"),
                  let name = path.split(separator: "/").last.map(String.init) else { return nil }
            let seconds = o["modified"]?.int64 ?? 0
            return BrowseEntry(name: name, path: path, dir: o["dir"]?.bool ?? false, size: max(0, o["size"]?.int64 ?? 0),
                               modified: seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil)
        }
        let error = body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return BrowseFound(id: id, results: results, more: body["more"]?.bool ?? false,
                           partial: body["partial"]?.bool ?? false, error: error)
    }
}

/// The search of Get files. The computer searches the names in its shared
/// folders and answers with `BrowseFound`.
public enum BrowseSearch {
    /// The longest query in bytes that the computer accepts.
    public static let maxQuery = 200

    /// The flux.sftp.request of a search. An empty path searches each
    /// shared folder.
    public static func request(id: Int64, query: String, path: String) -> Packet {
        Packet(type: PacketType.sftpRequest, json: [
            "search": .object(["id": .int(id), "query": .string(query), "path": .string(path)]),
        ])
    }

    /// The text of a search without the spaces around it, cut to `maxQuery` bytes.
    public static func query(_ text: String) -> String {
        var q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while q.utf8.count > maxQuery { q.removeLast() }
        return q
    }

    /// The folder that a search reads. At the top of the first root, which
    /// is Home, it is empty, so that the search reads each shared folder.
    /// Else it is the folder on screen.
    public static func scope(path: String, roots: [BrowseRoot]) -> String {
        guard let first = roots.first, !path.isEmpty else { return "" }
        return BrowsePath.isRoot(path, in: [first]) ? "" : path
    }

    /// The place of a result for a list: the root name, then the folders
    /// down to the folder that holds the result, such as "Home/Documents".
    public static func location(of path: String, roots: [BrowseRoot]) -> String {
        let parent = BrowsePath.parent(path)
        guard BrowsePath.root(of: parent, in: roots) != nil else { return parent }
        return BrowsePath.crumbs(parent, roots: roots).map(\.name).joined(separator: "/")
    }
}
