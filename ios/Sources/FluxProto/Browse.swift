import Foundation

/// D1 browse types: SFTP folder-listing entries. Android `core/Model.kt`
/// (`BrowseEntry`: name/path/dir/size — mtime dropped there too) + Go
/// `BrowseEntry`/`fileKind` (`internal/core/sftp.go`) parity.
///
/// The SSH session (`FluxCore.BrowseSession`) feeds raw SFTP attrs through
/// `buildBrowseList`; only `Sendable` values cross isolation boundaries.
public struct BrowseEntry: Sendable, Equatable, Hashable {
    public var name: String
    public var path: String
    public var dir: Bool
    public var size: Int64

    public init(name: String, path: String, dir: Bool, size: Int64) {
        self.name = name
        self.path = path
        self.dir = dir
        self.size = size
    }
}

/// One raw SFTP `ls` row: what the client library reports before mapping.
/// `permissions` is the SFTP attrs permission word (nil when the server
/// omits it); `longname` is the `ls -l`-style string (nil when absent).
public struct RawBrowseEntry: Sendable {
    public var name: String
    public var path: String
    public var permissions: UInt32?
    public var longname: String?
    public var size: UInt64

    public init(name: String, path: String, permissions: UInt32?, longname: String?, size: UInt64) {
        self.name = name
        self.path = path
        self.permissions = permissions
        self.longname = longname
        self.size = size
    }
}

/// Maps raw SFTP rows to the UI list (Android `Browse.list` parity):
/// drops dotfiles (including `.`/`..`), detects folders, sorts
/// folders-first then case-insensitive by name.
public func buildBrowseList(_ raw: [RawBrowseEntry]) -> [BrowseEntry] {
    raw
        .filter { !$0.name.hasPrefix(".") }
        .map { r in
            BrowseEntry(
                name: r.name, path: r.path,
                dir: isBrowseDir(permissions: r.permissions, longname: r.longname),
                size: r.size > UInt64(Int64.max) ? Int64.max : Int64(r.size))
        }
        .sorted {
            if $0.dir != $1.dir { return $0.dir }
            return $0.name.lowercased() < $1.name.lowercased()
        }
}

/// Folder detection. SFTP v3 attrs carry no file-type field (sshj reads
/// `FileMode`, Citadel exposes none), so: the permission word's `S_IFMT`
/// bits decide when present (authoritative — a stale longname never
/// overrides them); otherwise the `ls -l` leading `d` is the fallback,
/// and anything else is a plain file.
public func isBrowseDir(permissions: UInt32?, longname: String?) -> Bool {
    if let permissions {
        let fmt = permissions & 0o170000
        if fmt != 0 { return fmt == 0o040000 }
    }
    if let longname, longname.first == "d" { return true }
    return false
}

/// Parent folder for browse up-navigation (Android `BrowseScreen` parity:
/// trims trailing slashes, drops the last component, floors at `/`).
public func browseParentPath(_ path: String) -> String {
    var t = path
    while t.hasSuffix("/") && t.count > 1 { t.removeLast() }
    guard let slash = t.lastIndex(of: "/") else { return "/" }
    let parent = String(t[..<slash])
    return parent.isEmpty ? "/" : parent
}

/// UI kind for an entry (Go `fileKind` parity, same extensions + folder).
public enum BrowseKind: String, Sendable {
    case folder, image, video, audio, pdf, text, archive, apk, iso, file
}

public func browseKind(name: String, dir: Bool) -> BrowseKind {
    if dir { return .folder }
    switch URL(fileURLWithPath: name).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "avif": return .image
    case "mp4", "mkv", "mov", "webm", "3gp": return .video
    case "mp3", "flac", "ogg", "opus", "m4a", "wav": return .audio
    case "pdf": return .pdf
    case "txt", "md", "json", "csv", "log": return .text
    case "zip", "tar", "gz", "7z", "rar": return .archive
    case "apk": return .apk
    case "iso", "img": return .iso
    default: return .file
    }
}
