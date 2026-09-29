import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import NIOTLS

/// TLS for Flux links. Both sides present a self-signed certificate.
/// The handshake accepts any certificate. The link code checks the peer
/// certificate against the device ID and the pinned certificate after the
/// handshake.
public final class FluxTLS: Sendable {
    private let serverContext: NIOSSLContext
    private let clientContext: NIOSSLContext
    public let local: LocalCertificate

    public init(local: LocalCertificate) throws {
        self.local = local
        let cert = try NIOSSLCertificate(bytes: local.certificateDER, format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(local.privateKeyPEM.utf8), format: .pem)

        // The Flux apps use only TLS 1.2, and fluxd accepts it.
        var server = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        server.minimumTLSVersion = .tlsv12
        server.maximumTLSVersion = .tlsv12
        // Any mode other than .none makes the server ask for the client certificate.
        server.certificateVerification = .noHostnameVerification

        var client = TLSConfiguration.makeClientConfiguration()
        client.certificateChain = [.certificate(cert)]
        client.privateKey = .privateKey(key)
        client.minimumTLSVersion = .tlsv12
        client.maximumTLSVersion = .tlsv12
        client.certificateVerification = .noHostnameVerification

        serverContext = try NIOSSLContext(configuration: server)
        clientContext = try NIOSSLContext(configuration: client)
    }

    /// A handler for the side that acts as the TLS server.
    public func serverHandler() -> NIOSSLServerHandler {
        NIOSSLServerHandler(context: serverContext, customVerificationCallback: { _, promise in
            promise.succeed(.certificateVerified)
        })
    }

    /// A handler for the side that acts as the TLS client.
    public func clientHandler() throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: clientContext, serverHostname: nil, customVerificationCallback: { _, promise in
            promise.succeed(.certificateVerified)
        })
    }
}

/// The longest line that a link reads. The core raises it after pairing,
/// from another thread than the one of the decoder.
final class LineLimit: Sendable {
    private let box: NIOLockedValueBox<Int>

    init(_ value: Int) { box = NIOLockedValueBox(value) }

    var value: Int { box.withLockedValue { $0 } }

    func set(_ value: Int) { box.withLockedValue { $0 = value } }
}

/// Splits the byte stream into lines without the newline.
final class LineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let limit: LineLimit
    /// The readable bytes that hold no newline. The next read searches only
    /// the bytes after them, so a long line costs no repeated scans.
    private var scanned = 0

    init(max: Int) { limit = LineLimit(max) }

    init(limit: LineLimit) { self.limit = limit }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let max = limit.value
        let view = buffer.readableBytesView
        let from = view.index(view.startIndex, offsetBy: min(scanned, view.count))
        if let newline = view[from...].firstIndex(of: 0x0A) {
            scanned = 0
            let length = view.distance(from: view.startIndex, to: newline)
            if length > max { throw FluxError("packet too large") }
            let line = buffer.readSlice(length: length)!
            buffer.moveReaderIndex(forwardBy: 1)
            context.fireChannelRead(wrapInboundOut(line))
            return .continue
        }
        scanned = view.count
        if buffer.readableBytes > max { throw FluxError("packet too large") }
        return .needMoreData
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}

extension Channel {
    /// The DER bytes of the certificate that the TLS peer presented.
    func peerCertificateDER() -> [UInt8]? {
        guard let handler = try? pipeline.syncOperations.handler(type: NIOSSLHandler.self),
              let cert = handler.peerCertificate else { return nil }
        return try? cert.toDERBytes()
    }
}
