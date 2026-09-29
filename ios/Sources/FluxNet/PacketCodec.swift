import Foundation
import FluxProto

/// Newline-delimited JSON framing over a TLS stream.
/// Mirrors `readLine` in `internal/lan/link.go`: one `\n`-terminated line,
/// CR/LF trimmed, capped at `FluxProto.maxPacketSize`.
public enum PacketCodec {
    public enum CodecError: Error, Equatable {
        case lineTooLong
        case notAPacket
    }

    /// Splits a byte stream into packet lines (without newlines).
    /// Throws `lineTooLong` when a line exceeds `maxPacketSize`.
    public static func splitLines(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        var current = Data()
        for byte in data {
            current.append(byte)
            if byte == 0x0A {
                if current.count > FluxProto.maxPacketSize + 1 { throw CodecError.lineTooLong }
                lines.append(trim(current))
                current = Data()
            }
            if current.count > FluxProto.maxPacketSize + 1 { throw CodecError.lineTooLong }
        }
        return lines
    }

    /// Decodes one line into a packet.
    public static func decode(_ line: Data) throws -> Packet {
        guard let p = Packet.parse(line) else { throw CodecError.notAPacket }
        return p
    }

    /// Encodes one packet as a wire line.
    public static func encode(_ packet: Packet) throws -> Data {
        try packet.serialize()
    }

    private static func trim(_ line: Data) -> Data {
        var d = line
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        return d
    }
}

/// UDP discovery payload helpers.
///
/// - Broadcasts carry `tcpPort` (unlike post-TLS identities).
/// - Plain-text TCP identities carry `targetDeviceId` + `targetProtocolVersion`.
/// - Port source of truth: `Lan.udpPort` (1716); TCP listener is the first
///   free port in `1716...1764`.
public enum Discovery {
    /// Builds a UDP broadcast identity line for the given TCP listener port.
    public static func broadcastLine(identity: Identity, tcpPort: Int) throws -> Data {
        var id = identity
        id.tcpPort = tcpPort
        return try id.toPacket(withPort: true).serialize()
    }

    /// Parses a received UDP identity. Returns nil for own ID, invalid IDs,
    /// non-identity packets, or broadcasts without `tcpPort`.
    public static func parseBroadcast(_ line: Data, ownId: String) -> Identity? {
        guard let p = Packet.parse(line),
              let id = Identity.from(p),
              id.deviceId != ownId,
              id.tcpPort > 0
        else { return nil }
        return id
    }
}
