import Foundation

/// Manual pairing decision box. The session thread blocks in `decide`
/// (like Android's pair dialog waits for the Accept tap); `PairView`
/// resolves it from `onAccept`/`onDecline`. A timeout declines without a
/// packet, mirroring `PairingSession.expire` for incoming requests.
///
/// Threading: safe to decide on the blocking session thread and resolve
/// from the main thread. Mutation is guarded by the condition lock.
public final class PairApproval: @unchecked Sendable {
    private let condition = NSCondition()
    private var verdicts: [String: Bool] = [:]

    public init() {}

    /// Blocks until `resolve` or `timeout`. Returns nil on timeout.
    public func decide(peerId: String, timeout: TimeInterval) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while verdicts[peerId] == nil {
            if !condition.wait(until: deadline) { break }
        }
        return verdicts.removeValue(forKey: peerId)
    }

    /// Resolves a waiting decision (true = Accept, false = Decline).
    /// A verdict with nobody waiting is kept until it is collected.
    public func resolve(peerId: String, accept: Bool) {
        condition.lock()
        verdicts[peerId] = accept
        condition.broadcast()
        condition.unlock()
    }
}
