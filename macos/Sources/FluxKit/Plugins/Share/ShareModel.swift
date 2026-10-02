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

/// The share state that the UI shows: the transfers, newest first, and the
/// download folder.
@MainActor
@Observable
public final class ShareModel {
    /// The number of transfers that the list keeps.
    static let maxTransfers = 50

    public private(set) var transfers: [FileTransfer] = []
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

    /// Removes the transfers that ended.
    public func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    private func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }
}
