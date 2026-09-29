import Foundation

/// M5 camera/mic/screen packets: `flux.webcam` start/stop/config, `flux.mic`
/// start/stop, and `flux.screen` start/stop, plus the desktop replies to each.
///
/// Sources of truth: `internal/core/webcam.go` (`webcamStart` states
/// start/stop/config/error, `ConfigureWebcam` reset/partial shapes),
/// `internal/core/mic.go` (`micStart` + `check` defaults, `StopMic`),
/// `internal/core/screen.go` (`screenStart`, `StopScreen`), Android
/// `webcam/WebcamProtocol.kt` (`WebcamPackets`, `WebcamReply`),
/// `mic/MicProtocol.kt` (`MicPackets`, `MicReply`), and
/// `screen/ScreenProtocol.kt` (`ScreenPackets`, `ScreenReply`).
///
/// Direction notes (do not "improve" the wire):
/// - Phone→desktop `start` opens a TLS listener and sends its port; the
///   desktop dials in (`DialPeer`), pins the paired phone cert, and pipes
///   the raw bytes (H.264 Annex B for webcam/screen, s16le PCM for mic).
/// - Phone→desktop `config` carries the full settings + caps after `start`
///   and after each change (webcam only). The desktop stores them for the
///   PHONE CAMERA card (`flux webcam` shows them).
/// - Phone→desktop `stop`/`error` end the session with the desktop.
/// - Desktop→phone packets are the answers: `live` (with the v4l2
///   device/label, PipeWire source, or player name), `error`, `stop`
///   (the user stopped the stream on the computer), and — webcam only —
///   `config` (a partial change, or `reset` for the neutral image values).

// MARK: - Stream kinds

/// The three phone-to-desktop streams. All three ride `flux.*` packets and
/// a pinned-TLS byte listener (`StreamEngine`, Android `PinnedStream`).
public enum StreamKind: String, Sendable, CaseIterable {
    case webcam, mic, screen

    /// The packet type that starts this stream.
    public var packetType: String {
        switch self {
        case .webcam: return PacketType.fluxWebcam
        case .mic: return PacketType.fluxMic
        case .screen: return PacketType.fluxScreen
        }
    }

    /// Builds the user-stop packet for this stream (phone→desktop,
    /// Android `MicPackets.stop` / `WebcamPackets.stop` / `ScreenPackets.stop`).
    public func stopPacket() -> Packet {
        switch self {
        case .webcam: return WebcamPackets.stop()
        case .mic: return MicPackets.stop()
        case .screen: return ScreenPackets.stop()
        }
    }
}

// MARK: - Webcam (flux.webcam)

/// `flux.webcam` builders (phone→desktop). Port of Android `WebcamPackets`.
public enum WebcamPackets {
    /// Encoder frame rate (Android `WebcamPackets.FPS`; Go defaults
    /// `FPS <= 0` to 30, so the value is always explicit here).
    public static let fps = 30
    /// The only codec `fluxd` accepts (Go `runWebcam` rejects the rest).
    public static let codec = "h264"

    /// Announces the listener: `{"state":"start","port","width","height",
    /// "fps","codec"}` (Go `webcamStart`, Android `WebcamPackets.start`).
    public static func start(port: Int, width: Int, height: Int) -> Packet {
        Packet.of(
            PacketType.fluxWebcam,
            ("state", "start"), ("port", port),
            ("width", width), ("height", height),
            ("fps", fps), ("codec", codec)
        )
    }

    /// Ends the stream from the phone.
    public static func stop() -> Packet {
        Packet.of(PacketType.fluxWebcam, ("state", "stop"))
    }

    /// Reports an encoder/camera failure to the desktop (Go logs `message`).
    public static func error(_ message: String) -> Packet {
        Packet.of(PacketType.fluxWebcam, ("state", "error"), ("message", message))
    }

    /// Sends the full settings + caps after `start` and after each change
    /// (Android `WebcamSession` sends it right after `start`; the desktop
    /// stores both for the PHONE CAMERA card).
    public static func config(config: [String: JSONValue], caps: [String: JSONValue]) -> Packet {
        Packet(type: PacketType.fluxWebcam, body: [
            "state": .string("config"),
            "config": .object(config),
            "caps": .object(caps),
        ])
    }
}

/// A desktop answer to `flux.webcam`. Port of Android `WebcamReply`.
public enum WebcamReply: Sendable, Equatable {
    /// Frames reach the virtual camera `device`, named `label`.
    case live(device: String, label: String)
    case failed(message: String)
    /// The user stopped the camera on the computer.
    case stop
    /// The computer changes settings. `reset` restores the neutral image
    /// values first; `partial` then sets the fields it names (Go
    /// `ConfigureWebcam`, Android `WebcamSettings.applyRemote`).
    case config(partial: [String: JSONValue]?, reset: Bool)

    /// The virtual-camera name when the desktop sends no label.
    public static let defaultLabel = "Flux Camera"

    /// Parses a `flux.webcam` packet. Nil for other types and unknown
    /// states (a `start` arriving phone-side parses to nil, like Android).
    public static func parse(_ p: Packet) -> WebcamReply? {
        guard p.type == PacketType.fluxWebcam else { return nil }
        switch p.string("state") {
        case "live":
            let device = p.string("device") ?? ""
            let label = (p.string("label") ?? "").isEmpty ? defaultLabel : p.string("label")!
            return .live(device: device, label: label)
        case "error":
            let message = p.string("message") ?? ""
            return .failed(message: message.isEmpty ? "The computer could not start the camera" : message)
        case "stop":
            return .stop
        case "config":
            let partial = p.obj("config")
            let reset = p.bool("reset") == true
            guard partial != nil || reset else { return nil }
            return .config(partial: partial, reset: reset)
        default:
            return nil
        }
    }
}

// MARK: - Microphone (flux.mic)

/// `flux.mic` builders (phone→desktop). Port of Android `MicPackets`.
public enum MicPackets {
    /// Sample rate, channel count, and sample format. `fluxd` fills these
    /// in as defaults (`micStart.check`) and rejects anything else, so the
    /// phone always sends exactly these values.
    public static let rate = 48_000
    public static let channels = 1
    public static let format = "s16le"

    /// Announces the listener: `{"state":"start","port","rate","channels",
    /// "format"}` (Go `micStart`, Android `MicPackets.start`).
    public static func start(port: Int) -> Packet {
        Packet.of(
            PacketType.fluxMic,
            ("state", "start"), ("port", port),
            ("rate", rate), ("channels", channels), ("format", format)
        )
    }

    /// Ends the stream from the phone.
    public static func stop() -> Packet {
        Packet.of(PacketType.fluxMic, ("state", "stop"))
    }

    /// Reports a microphone failure to the desktop (Go logs `message`).
    public static func error(_ message: String) -> Packet {
        Packet.of(PacketType.fluxMic, ("state", "error"), ("message", message))
    }
}

/// Validates a desktop-side `flux.mic` start the way Go `micStart.check`
/// does: fills in the defaults, then rejects streams `fluxd` cannot play.
/// The phone never sends off-spec values, but the check documents the
/// contract both sides honor (Go `stream_test.go` vectors).
public enum MicStartCheck {
    public struct Params: Sendable, Equatable {
        public var port: Int
        public var rate: Int
        public var channels: Int
        public var format: String
    }

    public enum CheckError: Error, Equatable {
        case message(String)
    }

    public static func check(port: Int, format: String, rate: Int, channels: Int) -> Result<Params, CheckError> {
        let f = format.isEmpty ? MicPackets.format : format
        let r = rate == 0 ? MicPackets.rate : rate
        let c = channels == 0 ? MicPackets.channels : channels
        if port <= 0 || port > 65535 {
            return .failure(.message("the port \(port) is not valid"))
        }
        if f != MicPackets.format {
            return .failure(.message("the format \"\(f)\" is not supported. Send s16le"))
        }
        if r < 8000 || r > 96000 {
            return .failure(.message("the rate \(r) Hz is not supported. Send 8000 to 96000 Hz"))
        }
        if c != 1 && c != 2 {
            return .failure(.message("\(c) channels are not supported. Send 1 or 2"))
        }
        return .success(Params(port: port, rate: r, channels: c, format: f))
    }
}

/// A desktop answer to `flux.mic`. Port of Android `MicReply`.
public enum MicReply: Sendable, Equatable {
    /// The audio reaches the virtual source `source`.
    case live(source: String)
    case failed(message: String)
    /// The user stopped the microphone on the computer.
    case stop

    /// Parses a `flux.mic` packet. Nil for other types and unknown states.
    public static func parse(_ p: Packet) -> MicReply? {
        guard p.type == PacketType.fluxMic else { return nil }
        switch p.string("state") {
        case "live":
            let source = p.string("source") ?? ""
            return .live(source: source.isEmpty ? "Flux Microphone" : source)
        case "error":
            let message = p.string("message") ?? ""
            return .failed(message: message.isEmpty ? "The computer could not start the microphone" : message)
        case "stop":
            return .stop
        default:
            return nil
        }
    }
}

// MARK: - Screen (flux.screen)

/// `flux.screen` builders (phone→desktop). Port of Android `ScreenPackets`.
public enum ScreenPackets {
    /// Announces the listener: `{"state":"start","port","width","height",
    /// "codec"}` (Go `screenStart`, Android `ScreenPackets.start`). The
    /// computer only shows the screen; it sends no input back.
    public static func start(port: Int, width: Int, height: Int) -> Packet {
        Packet.of(
            PacketType.fluxScreen,
            ("state", "start"), ("port", port),
            ("width", width), ("height", height),
            ("codec", "h264")
        )
    }

    /// Ends the mirror from the phone.
    public static func stop() -> Packet {
        Packet.of(PacketType.fluxScreen, ("state", "stop"))
    }

    /// Reports a capture failure to the desktop (Go logs `message`).
    public static func error(_ message: String) -> Packet {
        Packet.of(PacketType.fluxScreen, ("state", "error"), ("message", message))
    }
}

/// A desktop answer to `flux.screen`. Port of Android `ScreenReply`.
public enum ScreenReply: Sendable, Equatable {
    /// The computer shows the stream in `player` (`mpv`/`ffplay`).
    case live(player: String)
    case failed(message: String)
    /// The user closed the window or stopped the mirror on the computer.
    case stop

    /// Parses a `flux.screen` packet. Nil for other types and unknown states.
    public static func parse(_ p: Packet) -> ScreenReply? {
        guard p.type == PacketType.fluxScreen else { return nil }
        switch p.string("state") {
        case "live":
            return .live(player: p.string("player") ?? "")
        case "error":
            let message = p.string("message") ?? ""
            return .failed(message: message.isEmpty ? "The computer could not show the screen" : message)
        case "stop":
            return .stop
        default:
            return nil
        }
    }
}
