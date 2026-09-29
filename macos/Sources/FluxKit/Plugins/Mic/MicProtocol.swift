import Foundation

/// The flux.mic packets. This Mac opens a TLS listener, sends "start" with
/// its port and the audio format, and writes raw PCM to the computer that
/// connects. The computer answers "live", "error", or "stop".
public enum MicPackets {
    public static let rate = 48_000
    public static let channels = 1
    public static let format = "s16le"

    public static func start(port: Int) -> Packet {
        Packet(PacketType.fluxMic, ["state": "start", "port": port, "rate": rate, "channels": channels, "format": format])
    }

    public static func stop() -> Packet { Packet(PacketType.fluxMic, ["state": "stop"]) }
}

/// An answer from the computer.
public enum MicReply: Equatable, Sendable {
    /// The audio reaches the virtual source with this name.
    case live(source: String)
    case failed(String)
    /// The user stopped the microphone on the computer.
    case stop

    /// Parses a flux.mic packet. It returns nil for other packets and unknown states.
    public static func parse(_ p: Packet) -> MicReply? {
        guard p.type == PacketType.fluxMic else { return nil }
        switch p.string("state") {
        case "live": return .live(source: nonEmpty(p.string("source")) ?? "Flux Microphone")
        case "error": return .failed(nonEmpty(p.string("message")) ?? "The computer could not start the microphone")
        case "stop": return .stop
        default: return nil
        }
    }

    private static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
}

/// Helpers for 16-bit PCM.
public enum Pcm {
    /// Writes the samples to out in little-endian order, 2 bytes each. out
    /// holds at least 2 bytes per sample.
    public static func toLittleEndian(_ samples: UnsafeBufferPointer<Int16>, into out: UnsafeMutableRawBufferPointer) {
        precondition(out.count >= samples.count * 2, "the output is too small")
        for (i, s) in samples.enumerated() {
            out.storeBytes(of: s.littleEndian, toByteOffset: 2 * i, as: Int16.self)
        }
    }

    /// Returns the peak of the samples, from 0 for silence to 1 for full scale.
    public static func peak(_ samples: UnsafeBufferPointer<Int16>) -> Float {
        var m = 0
        for s in samples { m = max(m, abs(Int(s))) }
        return min(max(Float(m) / 32768, 0), 1)
    }
}
