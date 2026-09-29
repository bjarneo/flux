/// FluxProto — pure-Swift KDE Connect packet format, identity, and
/// certificate helpers.
///
/// Source of truth: `internal/proto/packet.go`, `internal/proto/identity.go`,
/// `internal/proto/cert.go`, and Android `protocol/Packet.kt`,
/// `protocol/Identity.kt`, `protocol/Certificates.kt`.
///
/// Wire rules (do not "improve"):
/// - One JSON object + `\n` per packet over TLS.
/// - `MaxPacketSize = 16 MiB`; identity lines capped at 8 KiB on send.
/// - `id` accepts number, numeric string, or float (truncated).
/// - `flux.tunnel` inverts classic payload direction: phone listens,
///   desktop connects.
public enum FluxProto {
    /// KDE Connect protocol version Flux speaks.
    public static let protocolVersion = 8
    /// Largest packet Flux reads. Larger lines drop the link.
    public static let maxPacketSize = 16 << 20
    /// Largest identity line Flux sends or reads.
    public static let maxIdentityLine = 8192
}
