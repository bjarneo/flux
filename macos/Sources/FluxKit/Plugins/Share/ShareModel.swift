import Foundation
import Observation

/// 1 file that moves between this Mac and a computer.
public struct FileTransfer: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case done
        case failed(String)
    }

    public let id: UUID
    public let deviceId: String
    public var name: String
    public let incoming: Bool
    /// The size in bytes, or a negative number when it is unknown.
    public let size: Int64
    public var bytes: Int64 = 0
    public var state = State.running
    /// The file on this Mac: the saved file, or the file that goes out.
    public var file: URL?
    /// The start time and the end time. `ended` is nil while the transfer runs.
    public var started: Date
    public var ended: Date?

    // The init is in the struct body, so that it replaces the memberwise
    // init. In an extension, both inits would match the calls in SharePlugin.
    public init(id: UUID = UUID(), deviceId: String, name: String, incoming: Bool, size: Int64, bytes: Int64 = 0,
                state: State = .running, file: URL? = nil, started: Date = Date(), ended: Date? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.incoming = incoming
        self.size = size
        self.bytes = bytes
        self.state = state
        self.file = file
        self.started = started
        self.ended = ended
    }

    /// The part that is done, from 0 to 1, or nil when the size is unknown.
    public var fraction: Double? {
        size > 0 ? min(1, Double(bytes) / Double(size)) : nil
    }
}

/// 1 link, text, or clip that this device sent to a computer, for the Send
/// thread. The files are in `ShareModel.transfers`. `clipStamp` is the
/// pasteboard change count of a clip that went out, or 0.
public struct SentItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A text scan of the camera. The computer saves it as a text file in its scan folder.
        case link, text, scan, clip, clipImage
    }

    /// The most characters of a text or a link that an item keeps.
    public static let maxText = 400

    public let id: UUID
    public let deviceId: String
    public let kind: Kind
    public let text: String
    public let at: Date
    public let clipStamp: Int

    /// Makes an item. A text with more than `maxText` characters keeps its start and ends with "…".
    public init(id: UUID = UUID(), deviceId: String, kind: Kind, text: String, at: Date = Date(), clipStamp: Int = 0) {
        self.id = id
        self.deviceId = deviceId
        self.kind = kind
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = t.count > Self.maxText ? String(t.prefix(Self.maxText - 1)) + "…" : t
        self.at = at
        self.clipStamp = clipStamp
    }
}

/// The share state that the UI shows: the transfers, newest first, the
/// links, texts, and clips that went out, oldest first, and the download
/// folder. The sent items stay in memory only.
@MainActor
@Observable
public final class ShareModel {
    /// The number of transfers that the list keeps.
    static let maxTransfers = 50

    public private(set) var transfers: [FileTransfer] = []
    /// The links, texts, and clips that went out, oldest first, at most `maxSent`.
    public private(set) var sent: [SentItem] = []

    /// The number of sent items that the list keeps.
    public nonisolated static let maxSent = 60
    public internal(set) var downloadFolder: URL

    init(downloadFolder: URL) {
        self.downloadFolder = downloadFolder
    }

    func start(_ t: FileTransfer) {
        transfers.insert(t, at: 0)
        if transfers.count > Self.maxTransfers { transfers.removeLast(transfers.count - Self.maxTransfers) }
    }

    func progress(_ id: UUID, bytes: Int64) {
        update(id) { t in
            if t.state == .running { t.bytes = max(t.bytes, bytes) }
        }
    }

    func finish(_ id: UUID, file: URL?, error: Error?) {
        update(id) { t in
            if let error {
                t.state = .failed(String(describing: error))
            } else {
                t.state = .done
                if t.size > 0 { t.bytes = t.size }
            }
            if let file {
                t.file = file
                t.name = file.lastPathComponent
            }
            t.ended = Date()
        }
    }

    /// Adds a link, a text, or a clip that went out.
    func record(_ item: SentItem) {
        sent = Self.appending(sent, item)
    }

    /// The list with `item` at the end, without the oldest items above `max`.
    nonisolated static func appending(_ list: [SentItem], _ item: SentItem, max: Int = maxSent) -> [SentItem] {
        Array((list + [item]).suffix(max))
    }

    /// Removes the transfers that ended.
    public func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    private func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }
}
