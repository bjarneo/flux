/// The state of the webcam or the screen mirror, for the UI.
public struct StreamStatus: Equatable, Sendable {
    public enum Phase: Sendable {
        case idle
        /// Waiting for the computer to connect.
        case connecting
        /// Connected, waiting for the computer to report that it shows the frames.
        case starting
        case live
        case error
    }

    public var phase: Phase = .idle
    public var message = ""
    /// The computer of the current or the last stream.
    public var deviceId: String?

    public init(_ phase: Phase = .idle, _ message: String = "", deviceId: String? = nil) {
        self.phase = phase
        self.message = message
        self.deviceId = deviceId
    }

    public var active: Bool { phase == .connecting || phase == .starting || phase == .live }

    /// True while a stream to the device runs or starts.
    public func active(for deviceId: String) -> Bool { active && self.deviceId == deviceId }
}
