import Foundation
import FluxProto

/// Stream session state machines. Ports of the Android session status
/// logic: `mic/MicSession.kt` (`Phase`, `Status`, `onPacket`), the packet
/// half of `webcam/WebcamSession.kt` (`onPacket`, announce/stop rules),
/// and `screen/ScreenSession.kt` (`Phase`, `Status`, `onPacket`).
///
/// Transport (listener, TLS accept, byte pump) lives in
/// `FluxCore/StreamEngine`; the app/harness drives these sessions from
/// `LinkRunner` stream events and injects `send` for the packets.
///
/// Rules ported exactly:
/// - Replies apply only to the device the session streams to.
/// - `live` applies only while the session is active.
/// - `error`/`stop` from the desktop end the session without notifying
///   (the computer already knows).
/// - `stop(notify:)` sends the kind's stop packet only when a stream ran
///   (listener open or bytes flowing — Android `sock != null || srv !=
///   null`).
/// - Webcam `config` from the desktop returns an apply action; the app
///   merges it into `WebcamConfig` (`applyRemote`: reset first, then the
///   partial) and restarts the stream on a frame-size change.

/// Session phase (Android `MicSession.Phase` / `ScreenSession.Phase`).
public enum StreamPhase: String, Sendable, Equatable {
    case idle, connecting, starting, live, error
}

/// Session status for the Mic/Camera UI + harness logs.
public struct StreamStatus: Sendable, Equatable {
    public var phase: StreamPhase
    public var message: String
    public var deviceId: String?

    public init(phase: StreamPhase = .idle, message: String = "", deviceId: String? = nil) {
        self.phase = phase
        self.message = message
        self.deviceId = deviceId
    }

    public var active: Bool {
        phase == .connecting || phase == .starting || phase == .live
    }
}

/// What the app must do for a desktop `config` packet (webcam only).
public struct StreamConfigAction: Sendable, Equatable {
    public var partial: [String: JSONValue]?
    public var reset: Bool
}

/// One phone→desktop stream session (webcam, mic, or screen).
public final class StreamSession: @unchecked Sendable {
    public let kind: StreamKind

    private let lock = NSLock()
    private var status = StreamStatus()
    private var deviceId: String?
    private var hadStream = false
    private var attempt = 0

    /// Sends a packet to the desktop (the app wires `LinkSender.send`).
    public var send: ((Packet) -> Bool)?

    /// Observes status changes (UI + harness logs).
    public var onStatus: ((StreamStatus) -> Void)?

    public init(kind: StreamKind) {
        self.kind = kind
    }

    public var current: StreamStatus {
        lock.withLock { status }
    }

    /// Generation counter: bumped on every `start` and `stop`. The app
    /// records it when offering a live stream and ignores later events
    /// from older generations (a replaced/killed stream's desktop error
    /// must not tear down its replacement).
    public var generation: Int {
        lock.withLock { attempt }
    }

    /// Starts a stream to `deviceId`. A running stream stops first
    /// (Android `start` calls `stop(notify:)` first).
    public func start(deviceId: String, waiting message: String) {
        stop(notify: true)
        lock.withLock {
            attempt += 1
            self.deviceId = deviceId
        }
        set(StreamStatus(phase: .connecting, message: message, deviceId: deviceId))
    }

    /// Marks the listener accepted / bytes flowing (Android `Starting`).
    public func connected(message: String) {
        lock.withLock { hadStream = true }
        if let id = lock.withLock({ deviceId }) {
            set(StreamStatus(phase: .starting, message: message, deviceId: id))
        }
    }

    /// Marks the desktop `live` answer. The app maps parsed `LinkRunner`
    /// live events here (no raw packet reaches the app — the runner keeps
    /// it), with the same guards as the packet path: this device only,
    /// active session only.
    public func markLive(deviceId: String, message: String) {
        let mine = lock.withLock { self.deviceId == deviceId }
        guard mine, current.active else { return }
        set(StreamStatus(phase: .live, message: message, deviceId: deviceId))
    }

    /// Stops the stream. With `notify`, the desktop gets the kind's stop
    /// packet — but only when a stream actually ran.
    public func stop(notify: Bool, status next: StreamStatus = StreamStatus()) {
        let (target, had, sender): (String?, Bool, ((Packet) -> Bool)?) = lock.withLock {
            attempt += 1
            let r = (deviceId, hadStream, send)
            deviceId = nil
            hadStream = false
            return r
        }
        if notify, target != nil, had {
            _ = sender?(kind.stopPacket())
        }
        set(next)
    }

    /// Handles a desktop packet for this kind. Returns a config action for
    /// webcam `config` packets (the app applies it); everything else folds
    /// into status. Packets for another device, or for no session, are
    /// ignored (nil, no status change).
    @discardableResult
    public func onPacket(deviceId: String, packet: Packet) -> StreamConfigAction? {
        let mine = lock.withLock { self.deviceId == deviceId }
        guard mine else { return nil }
        let name = deviceId
        switch kind {
        case .webcam:
            guard let reply = WebcamReply.parse(packet) else { return nil }
            switch reply {
            case .live(let device, let label):
                if current.active {
                    set(StreamStatus(phase: .live, message: "Live on \(name) as \(label)", deviceId: deviceId))
                }
                _ = device
            case .failed(let message):
                stop(notify: false, status: StreamStatus(phase: .error, message: message, deviceId: deviceId))
            case .stop:
                stop(notify: false, status: StreamStatus(phase: .idle, message: "Stopped on \(name)", deviceId: deviceId))
            case .config(let partial, let reset):
                return StreamConfigAction(partial: partial, reset: reset)
            }
        case .mic:
            guard let reply = MicReply.parse(packet) else { return nil }
            switch reply {
            case .live(let source):
                if current.active {
                    set(StreamStatus(phase: .live, message: "Live on \(name) as \(source)", deviceId: deviceId))
                }
            case .failed(let message):
                stop(notify: false, status: StreamStatus(phase: .error, message: message, deviceId: deviceId))
            case .stop:
                stop(notify: false, status: StreamStatus(phase: .idle, message: "Stopped on \(name)", deviceId: deviceId))
            }
        case .screen:
            guard let reply = ScreenReply.parse(packet) else { return nil }
            switch reply {
            case .live:
                if current.active {
                    set(StreamStatus(phase: .live, message: "Mirrors to \(name)", deviceId: deviceId))
                }
            case .failed(let message):
                stop(notify: false, status: StreamStatus(phase: .error, message: message, deviceId: deviceId))
            case .stop:
                stop(notify: false, status: StreamStatus(phase: .idle, message: "Stopped on \(name)", deviceId: deviceId))
            }
        }
        return nil
    }

    private func set(_ next: StreamStatus) {
        lock.withLock { status = next }
        onStatus?(next)
    }
}

/// The "also send the microphone with the webcam" flag (Android
/// `MicSettings.withWebcam`, `flux-mic` prefs). The webcam session reads
/// it when `goLive` starts; the desktop mixes nothing — both streams run,
/// one H.264 + one PCM listener.
public struct MicPreferences: Sendable {
    private static let withWebcamKey = "org.omarchy.flux.mic.withWebcam"

    public var withWebcam: Bool

    public init(withWebcam: Bool = false) {
        self.withWebcam = withWebcam
    }

    public static func load(store: UserDefaults = .standard) -> MicPreferences {
        MicPreferences(withWebcam: store.bool(forKey: withWebcamKey))
    }

    public func save(store: UserDefaults = .standard) {
        store.set(withWebcam, forKey: Self.withWebcamKey)
    }
}
