import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// The largest packet line that Flux reads.
public let maxLine = 16 * 1024 * 1024

/// An open TLS link to one device.
public final class Link: @unchecked Sendable {
    public let identity: Identity
    public let peerCertificate: [UInt8]
    /// The IP address of the peer.
    public let address: String
    let channel: Channel
    private struct State {
        var closed = false
        var started = false
        var pending: [Packet] = []
        var onPacket: ((Packet) -> Void)?
        var onClose: (() -> Void)?
    }
    private let state = NIOLockedValueBox(State())

    init(channel: Channel, identity: Identity, peerCertificate: [UInt8]) {
        self.channel = channel
        self.identity = identity
        self.peerCertificate = peerCertificate
        self.address = channel.remoteAddress?.ipAddress ?? ""
    }

    /// Starts delivering packets, first those that arrived before this call.
    /// Both callbacks run on the link's event loop, except that the packets
    /// that were already queued run on the caller's thread.
    func start(onPacket: @escaping (Packet) -> Void, onClose: @escaping () -> Void) {
        let (queued, closedAlready) = state.withLockedValue { s -> ([Packet], Bool) in
            s.onPacket = onPacket
            s.onClose = onClose
            s.started = true
            defer { s.pending = [] }
            return (s.pending, s.closed)
        }
        queued.forEach(onPacket)
        if closedAlready { onClose() }
    }

    func deliver(_ p: Packet) {
        let callback = state.withLockedValue { s -> ((Packet) -> Void)? in
            if !s.started { s.pending.append(p) }
            return s.onPacket
        }
        callback?(p)
    }

    func didClose() {
        let callback = state.withLockedValue { s -> (() -> Void)? in
            if s.closed { return nil }
            s.closed = true
            return s.started ? s.onClose : nil
        }
        callback?()
    }

    /// Sends a packet. Writes keep their order.
    public func send(_ p: Packet) {
        guard isOpen else { return }
        let data = p.serialize()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer).whenFailure { [weak self] _ in self?.close() }
    }

    public var isOpen: Bool { !state.withLockedValue { $0.closed } && channel.isActive }

    public func close() {
        channel.close(promise: nil)
    }
}

/// Delivers the packets of an established link.
final class LinkHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let link: Link

    init(link: Link) { self.link = link }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        guard line.readableBytes > 0, let p = Packet.parse(Data(line.readableBytesView)) else { return }
        link.deliver(p)
    }

    func channelInactive(context: ChannelHandlerContext) {
        link.didClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FluxLog.net.info("link to \(self.link.identity.deviceName, privacy: .public) ended: \(String(describing: error), privacy: .public)")
        context.close(promise: nil)
    }
}
