import Foundation

/// One entry of a folder on the computer.
public struct BrowseEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var dir: Bool
    public var size: Int64
    /// The last change of the entry, when the computer reports it.
    public var modified: Date?

    public var id: String { path }

    public init(name: String, path: String, dir: Bool, size: Int64, modified: Date? = nil) {
        self.name = name
        self.path = path
        self.dir = dir
        self.size = size
        self.modified = modified
    }

    /// The entry `name` in `folder` from its SFTP attributes.
    init(folder: String, name: String, permissions: UInt32?, size: UInt64?, modified: Date?) {
        self.init(name: name, path: BrowsePath.join(folder, name), dir: Self.isDirectory(permissions: permissions),
                  size: Int64(clamping: size ?? 0), modified: modified)
    }

    /// The entries of a folder as the browser shows them: no hidden files,
    /// folders first, then by name without regard to case.
    public static func listing(_ entries: [BrowseEntry]) -> [BrowseEntry] {
        entries
            .filter { !$0.name.hasPrefix(".") }
            .sorted {
                if $0.dir != $1.dir { return $0.dir }
                return $0.name.lowercased() < $1.name.lowercased()
            }
    }

    /// True when SFTP permission bits name a directory.
    public static func isDirectory(permissions: UInt32?) -> Bool {
        guard let permissions else { return false }
        return permissions & 0o170000 == 0o040000
    }
}

/// Remote paths of a browse session. Paths use "/" and are absolute.
public enum BrowsePath {
    /// The path of name inside dir.
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// The folder that contains path. The parent of "/" is "/".
    public static func parent(_ path: String) -> String {
        let trimmed = trim(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// The root that contains path. When roots nest, like Home and
    /// Home/Downloads, the deepest root wins.
    public static func root(of path: String, in roots: [BrowseRoot]) -> BrowseRoot? {
        let p = trim(path)
        return roots
            .filter { contains(trim($0.path), p) }
            .max { trim($0.path).count < trim($1.path).count }
    }

    /// True when path is one of the roots, so there is nothing above it to open.
    public static func isRoot(_ path: String, in roots: [BrowseRoot]) -> Bool {
        roots.contains { trim($0.path) == trim(path) }
    }

    /// The folders from the root down to path, for a path bar. The first
    /// crumb has the name of the root. A path outside every root starts at "/".
    public static func crumbs(_ path: String, roots: [BrowseRoot]) -> [BrowseRoot] {
        let p = trim(path)
        let root = root(of: p, in: roots).map { BrowseRoot(name: $0.name, path: trim($0.path)) } ?? BrowseRoot(name: "/", path: "/")
        var crumbs = [root]
        var current = root.path
        for part in p.dropFirst(root.path.count).split(separator: "/") {
            current = join(current, String(part))
            crumbs.append(BrowseRoot(name: String(part), path: current))
        }
        return crumbs
    }

    /// True when path is base or lies inside it.
    private static func contains(_ base: String, _ path: String) -> Bool {
        path == base || base == "/" || path.hasPrefix(base + "/")
    }

    /// Removes trailing slashes, but keeps "/".
    private static func trim(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
