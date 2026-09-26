import Foundation

/// The flux.webcam extension. This Mac opens a TLS listener, sends "start"
/// with its port, and writes a raw H.264 Annex-B stream to the computer that
/// connects. The computer answers "live", "error", or "stop". Both sides send
/// "config" to change the settings.
public enum WebcamPackets {
    public static let fps = 30

    static func start(port: Int, width: Int, height: Int) -> Packet {
        Packet(PacketType.fluxWebcam, [
            "state": "start", "port": port,
            "width": width, "height": height,
            "fps": fps, "codec": "h264",
        ])
    }

    static func stop() -> Packet { Packet(PacketType.fluxWebcam, ["state": "stop"]) }

    /// The full settings and what the camera supports. This Mac sends it
    /// after "start" and after each change.
    static func config(_ config: WebcamConfig, _ caps: WebcamCaps) -> Packet {
        Packet(PacketType.fluxWebcam, ["state": "config", "config": JSONValue.object(config.json), "caps": JSONValue.object(caps.json)])
    }
}

/// An answer from the computer.
enum WebcamReply: Equatable {
    /// Frames reach the virtual camera device, named label.
    case live(device: String, label: String)
    case failed(String)
    /// The user stopped the camera on the computer.
    case stop
    /// The computer changes settings. reset sets the neutral image values
    /// first, and partial then sets the fields that it names.
    case config(partial: [String: JSONValue]?, reset: Bool)

    /// Parses a flux.webcam packet. It returns nil for other packets and
    /// unknown states.
    static func parse(_ p: Packet) -> WebcamReply? {
        guard p.type == PacketType.fluxWebcam else { return nil }
        switch p.string("state") {
        case "live":
            return .live(device: p.string("device") ?? "", label: p.string("label").nonEmpty ?? "Flux Camera")
        case "error":
            return .failed(p.string("message").nonEmpty ?? "The computer could not start the camera")
        case "stop":
            return .stop
        case "config":
            let partial = p.object("config")
            let reset = p.bool("reset") == true
            return partial != nil || reset ? .config(partial: partial, reset: reset) : nil
        default:
            return nil
        }
    }
}

/// The flux.screen extension. This Mac opens a TLS listener, sends "start"
/// with its port and the frame size, and writes a raw H.264 Annex-B stream of
/// a display to the computer that connects. The computer answers "live",
/// "error", or "stop". The computer only shows the screen.
enum ScreenPackets {
    static func start(port: Int, width: Int, height: Int) -> Packet {
        Packet(PacketType.fluxScreen, ["state": "start", "port": port, "width": width, "height": height, "codec": "h264"])
    }

    static func stop() -> Packet { Packet(PacketType.fluxScreen, ["state": "stop"]) }
}

/// An answer from the computer.
enum ScreenReply: Equatable {
    /// The computer shows the stream in player.
    case live(player: String)
    case failed(String)
    /// The user closed the window or stopped the mirror on the computer.
    case stop

    /// Parses a flux.screen packet. It returns nil for other packets and
    /// unknown states.
    static func parse(_ p: Packet) -> ScreenReply? {
        guard p.type == PacketType.fluxScreen else { return nil }
        switch p.string("state") {
        case "live": return .live(player: p.string("player") ?? "")
        case "error": return .failed(p.string("message").nonEmpty ?? "The computer could not show the screen")
        case "stop": return .stop
        default: return nil
        }
    }
}

/// The frame size of the screen mirror.
enum MirrorSize {
    /// The longest side of the stream, in pixels.
    static let maxLong = 1080

    /// Returns the encoder size for a screen of width x height pixels: the
    /// same shape, at most maxLong pixels on the long side, and both sides a
    /// multiple of align, as hardware encoders want. It returns nil for a
    /// size that is not positive.
    static func fit(width: Int, height: Int, maxLong: Int = maxLong, align: Int = 16) -> (width: Int, height: Int)? {
        guard width > 0 && height > 0 else { return nil }
        let scale = min(1.0, Double(maxLong) / Double(max(width, height)))
        func down(_ v: Int) -> Int { max(align, Int(Double(v) * scale) / align * align) }
        return (down(width), down(height))
    }

    /// Returns the bitrate for a frame size. Screen text needs more bits than
    /// a camera image.
    static func bitrate(width: Int, height: Int) -> Int { max(2_000_000, width * height * 8) }
}

private extension Optional where Wrapped == String {
    /// The string, or nil when it is nil or empty.
    var nonEmpty: String? {
        guard let s = self, !s.isEmpty else { return nil }
        return s
    }
}
