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

/// Splits the byte stream into lines without the newline.
final class LineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let max: Int

    init(max: Int) { self.max = max }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        if let newline = view.firstIndex(of: 0x0A) {
            let length = view.distance(from: view.startIndex, to: newline)
            if length > max { throw FluxError("packet too large") }
            let line = buffer.readSlice(length: length)!
            buffer.moveReaderIndex(forwardBy: 1)
            context.fireChannelRead(wrapInboundOut(line))
            return .continue
        }
        if buffer.readableBytes > max { throw FluxError("packet too large") }
        return .needMoreData
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}

/// Fulfills a promise when the TLS handshake completes.
final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(FluxError("connection closed during the TLS handshake"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
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
