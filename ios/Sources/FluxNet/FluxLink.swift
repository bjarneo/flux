import Foundation
import Network
import FluxProto

/// TLS link + discovery (M0 framing/M1 pairing landed; live socket wiring is
/// M1b). Full `NWListener`/`NWConnection` data path is still open: the
/// acceptor must read the plaintext identity *before* the TLS handshake
/// (then act as TLS client), which `Network.framework` TLS listeners do not
/// do natively — the M1b spike must solve that STARTTLS-style upgrade first.
/// Until then, pairing runs through `PairingSession` + `TrustValidation`
/// (both unit-verified) and `ios/tools/test_peer.py`.
///
/// Connection direction: desktop dials the phone's advertised `tcpPort`.
/// Plain-text `kdeconnect.identity` (with `targetDeviceId`) precedes TLS;
/// the TLS-phase identity must not carry `tcpPort`.
@available(macOS 14, iOS 17, *)
public actor FluxLink {
    public enum State: Sendable { case idle, listening(port: Int), connected(peer: String) }

    public private(set) var state: State = .idle

    /// Validates a plaintext pre-TLS identity per `provider.go accept()`.
    public static func validatesPreTLS(_ packet: Packet, ownId: String) -> Identity? {
        guard packet.type == PacketType.identity,
              let id = Identity.from(packet),
              id.deviceId != ownId,
              validDeviceId(id.deviceId)
        else { return nil }
        if let target = packet.string("targetDeviceId"), !target.isEmpty, target != ownId { return nil }
        if let v = packet.int("targetProtocolVersion"), v != FluxProto.protocolVersion { return nil }
        return id
    }
}
