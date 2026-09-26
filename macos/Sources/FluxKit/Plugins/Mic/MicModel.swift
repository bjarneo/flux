import Foundation
import Observation

/// The UI state of the microphone stream.
@MainActor
@Observable
public final class MicModel {
    public enum Phase: Sendable {
        case idle, connecting, starting, live, error
    }

    public struct Status: Equatable, Sendable {
        public var phase = Phase.idle
        public var message = ""
        public var deviceId: String?

        public init(_ phase: Phase = .idle, _ message: String = "", deviceId: String? = nil) {
            self.phase = phase
            self.message = message
            self.deviceId = deviceId
        }

        public var active: Bool { phase == .connecting || phase == .starting || phase == .live }
    }

    public internal(set) var status = Status()
    /// The peak input level, from 0 to 1, about 15 times per second.
    public internal(set) var level: Float = 0
    /// The audio inputs of this Mac.
    public internal(set) var inputs: [MicInput] = []
    /// The chosen input ID. Empty means the system default input.
    public internal(set) var input = ""
    public internal(set) var permission = MicPermission.current

    init() {}
}
