import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat

/// One SSH session with the SFTP subsystem. A browse window keeps 1 session
/// for its lifetime. A tunnel carries 1 session, so the next window asks the
/// computer for a new one.
final class BrowseSession: @unchecked Sendable {
    /// Bytes per SFTP read. OpenSSH and Go's pkg/sftp serve at most 32 KiB.
    private static let chunk = 32 * 1024
    /// SFTP reads in flight during a download.
    private static let window = 16

    private let ssh: SSHClient
    private let sftp: SFTPClient
    private let bridge: LoopbackBridge?

    private init(ssh: SSHClient, sftp: SFTPClient, bridge: LoopbackBridge?) {
        self.ssh = ssh
        self.sftp = sftp
        self.bridge = bridge
    }

    /// Connects with the offer. When the computer blocks incoming
    /// connections, it connects to this Mac through a tunnel, and a loopback
    /// bridge feeds the TLS stream to the SSH client. `address` is the IP of
    /// the link, for an offer without an IP. `onClose` runs when the SSH
    /// connection ends for any reason.
    static func open(
        _ offer: SftpOffer,
        tls: FluxTLS,
        certificate: [UInt8]?,
        address: String?,
        announce: @escaping @Sendable (Packet) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> BrowseSession {
        if offer.viaTunnel, let token = offer.tunnel {
            guard let certificate else { throw FluxError("the link is not ready") }
            let stream = try await Tunnel.accept(tls: tls, expected: certificate, token: token, announce: announce)
            let bridge = try await LoopbackBridge.open(stream)
            return try await connect(host: bridge.host, port: bridge.port, offer: offer, bridge: bridge, onClose: onClose)
        }
        guard let host = offer.ip ?? address, !host.isEmpty else { throw FluxError("no address") }
        return try await connect(host: host, port: offer.port, offer: offer, bridge: nil, onClose: onClose)
    }

    private static func connect(
        host: String,
        port: Int,
        offer: SftpOffer,
        bridge: LoopbackBridge?,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> BrowseSession {
        let user = offer.user, password = offer.password
        // The computer makes a new host key for each session. The password
        // comes over the paired TLS link, so the key is not pinned.
        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { .passwordBased(username: user, password: password) },
            hostKeyValidator: .acceptAnything()
        )
        settings.connectTimeout = .seconds(8)
        do {
            let ssh = try await SSHClient.connect(to: settings)
            do {
                let sftp = try await ssh.openSFTP()
                ssh.onDisconnect(perform: onClose)
                return BrowseSession(ssh: ssh, sftp: sftp, bridge: bridge)
            } catch {
                try? await ssh.close()
                throw error
            }
        } catch {
            bridge?.close()
            throw error
        }
    }

    /// The entries of a folder, as the browser shows them.
    func list(_ path: String) async throws -> [BrowseEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        let entries = names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { c in
                BrowseEntry(folder: path, name: c.filename, permissions: c.attributes.permissions, size: c.attributes.size,
                            modified: c.attributes.accessModificationTime?.modificationTime)
            }
        return BrowseEntry.listing(entries)
    }

    /// Copies a remote file into the handle and reports the bytes written so
    /// far, at most 10 times per second and once at the end. Several reads
    /// stay in flight, so the round trip time does not limit the speed.
    func download(_ path: String, into handle: FileHandle, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await sftp.withFile(filePath: path, flags: .read) { file in
            var offset: UInt64 = 0
            var throttle = ProgressThrottle()
            while true {
                try Task.checkCancellation()
                let start = offset
                let chunks = try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
                    for i in 0..<Self.window {
                        group.addTask {
                            (i, try await file.read(from: start + UInt64(i * Self.chunk), length: UInt32(Self.chunk)))
                        }
                    }
                    var out = Array(repeating: ByteBuffer(), count: Self.window)
                    for try await (i, data) in group { out[i] = data }
                    return out
                }
                // A short read ends the batch. The next batch continues
                // after it, and an empty read is the end of the file.
                var end = false
                for data in chunks {
                    if data.readableBytes == 0 {
                        end = true
                        break
                    }
                    try handle.write(contentsOf: data.readableBytesView)
                    offset += UInt64(data.readableBytes)
                    if data.readableBytes < Self.chunk { break }
                }
                if end || throttle.due() { progress(Int64(offset)) }
                if end { return }
            }
        }
    }

    /// Ends the SFTP channel, the SSH connection, and the tunnel.
    func close() async {
        try? await sftp.close()
        try? await ssh.close()
        bridge?.close()
    }

    /// A short reason for the user.
    static func describe(_ error: Error) -> String {
        if let status = error as? SFTPMessage.Status, !status.message.isEmpty { return status.message }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}
