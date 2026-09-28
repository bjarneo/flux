import Foundation
import Observation

/// What happened to 1 request.
public enum ApproveOutcome: Sendable, Equatable {
    case open
    case approved
    case enrolled
    case denied
    /// This Mac could not sign, and told the computer.
    case failed(String)
    /// This Mac refused the request without asking the user.
    case refused(String)
    /// The computer ended the request.
    case cancelled
    /// The wait of the computer ended.
    case expired

    public var text: String {
        switch self {
        case .open: return "Waiting"
        case .approved: return "Approved"
        case .enrolled: return "Enrolled"
        case .denied: return "Denied"
        case .failed(let m): return "Failed: \(m)"
        case .refused(let m): return "Refused: \(m)"
        case .cancelled: return "Cancelled by the computer"
        case .expired: return "Timed out"
        }
    }
}

/// 1 entry of the recent requests.
public struct ApproveRecord: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public var requestId: String
    public var computerId: String
    public var kind: ApproveRequest.Kind
    /// The question of the request, or a note for a request that is not valid.
    public var summary: String
    public var received: Date
    public var outcome: ApproveOutcome
}

/// Whether this device can approve.
public enum ApproveAvailability: Sendable, Equatable {
    case ready
    /// The device has no Secure Enclave, such as the simulator. Nothing fixes it.
    case noSecureEnclave(String)
    /// The biometry is not set up, locked, or not available now.
    case biometry(String)
}

/// The state of the approval prompt.
public enum ApprovePhase: Sendable, Equatable {
    /// The prompt asks the user.
    case ask
    /// Touch ID and the Secure Enclave run.
    case working
    /// The enrollment is done. The prompt shows the key code.
    case enrolled(code: String)
    /// The request failed. The computer asks for the password.
    case failed(String)
}

/// The UI state of approvals. `ApprovePlugin` changes it on the main actor.
@MainActor
@Observable
public final class ApproveModel {
    static let historyLimit = 20

    /// The open request, or nil. This Mac has at most 1 open request.
    public internal(set) var current: ApproveRequest?
    /// When the open request expires.
    public internal(set) var deadline: Date?
    /// The request that the prompt shows. It stays after an enrollment or a
    /// failure, so that the prompt can show the result.
    public internal(set) var shown: ApproveRequest?
    public internal(set) var phase = ApprovePhase.ask
    /// The recent requests, newest first.
    public internal(set) var history: [ApproveRecord] = []
    /// The enrolled keys, by computer ID.
    public internal(set) var keys: [String: ApproveKeyInfo] = [:]

    /// Brings the prompt to the front. The app sets it.
    @ObservationIgnored public var present: (@MainActor () -> Void)?

    public init() {}

    func record(_ r: ApproveRecord) {
        history.insert(r, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    func resolve(_ requestId: String, _ outcome: ApproveOutcome) {
        guard let i = history.firstIndex(where: { $0.requestId == requestId && $0.outcome == .open }) else { return }
        history[i].outcome = outcome
    }
}
