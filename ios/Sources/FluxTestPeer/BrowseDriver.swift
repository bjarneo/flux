import Foundation
import CryptoKit
import FluxProto
import FluxCore

/// `--exercise-browse` driver: takes established browse tunnels and runs
/// the production `BrowseSession` over them (connect + list + download),
/// printing machine-checkable lines that `test_peer.py --browse-ssh`
/// asserts server-side (auth + readdir + file reads) and by transcript
/// (names + sha256 vs. the fixture).
///
/// The event closure is built before the runner exists, so the runner +
/// offers are stashed here like `LiveRunnerRef` (app parity: the app will
/// stash offers per tunnel the same way).
final class BrowseDriver: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var runner: LinkRunner?
    private nonisolated(unsafe) var offers: [String: SftpOffer] = [:]
    /// Idle seconds between list and download (repro harness: the device
    /// download died after ~20 s idle — pace or exonerate the idle).
    var idleSeconds: UInt64 = 0

    func set(_ r: LinkRunner) {
        lock.withLock { runner = r }
    }

    func noteOffer(_ offer: SftpOffer) {
        guard let tunnel = offer.tunnel else { return }
        lock.withLock { offers[tunnel] = offer }
    }

    /// Starts the session drive for an established tunnel (no-op when the
    /// offer is unknown — the tunnel was never asked for here).
    func driveIfReady(tunnel: String) {
        let (current, offer): (LinkRunner?, SftpOffer?) = lock.withLock { (runner, offers[tunnel]) }
        guard let current, let offer else {
            print("flux-test-peer: BROWSE NOT READY \(tunnel) runner=\(current != nil) offer=\(offer != nil)", flush: true)
            return
        }
        lock.withLock { offers.removeValue(forKey: tunnel) }
        Task { await drive(runner: current, tunnel: tunnel, offer: offer) }
    }

    private func drive(runner: LinkRunner, tunnel: String, offer: SftpOffer) async {
        print("flux-test-peer: BROWSE TAKE \(tunnel)", flush: true)
        guard let conn = runner.takeBrowseTunnel(tunnel) else {
            print("flux-test-peer: BROWSE TAKE FAILED \(tunnel)", flush: true)
            return
        }
        print("flux-test-peer: BROWSE TAKEN \(tunnel), connecting", flush: true)
        let session = BrowseSession(onLog: { print("flux-test-peer: BROWSE RELAY \($0)", flush: true) })
        do {
            try await session.connect(tunnel: conn, user: offer.user, password: offer.password)
        } catch {
            print("flux-test-peer: BROWSE CONNECT FAILED \(tunnel): \(error)", flush: true)
            return
        }
        print("flux-test-peer: BROWSE CONNECTED \(tunnel)", flush: true)
        do {
            guard let root = offer.roots.first else {
                print("flux-test-peer: BROWSE FAILED \(tunnel): offer has no roots", flush: true)
                return
            }
            let entries = try await session.list(path: root.1)
            print("flux-test-peer: BROWSE LIST \(root.1) \(entries.count) entries: \(entries.map(\.name).joined(separator: ","))", flush: true)
            if idleSeconds > 0 {
                print("flux-test-peer: BROWSE IDLE \(idleSeconds)s", flush: true)
                try? await Task.sleep(for: .seconds(idleSeconds))
            }
            let downloads = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flux-browse-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            for entry in entries where !entry.dir {
                let dest = downloads.appendingPathComponent(entry.name)
                let bytes = try await session.download(remotePath: entry.path, to: dest)
                let data = try Data(contentsOf: dest)
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                print("flux-test-peer: BROWSE FILE \(entry.name) \(bytes) bytes sha256=\(sha)", flush: true)
            }
            if let sub = entries.first(where: { $0.dir }) {
                let subEntries = try await session.list(path: sub.path)
                print("flux-test-peer: BROWSE LIST \(sub.path) \(subEntries.count) entries: \(subEntries.map(\.name).joined(separator: ","))", flush: true)
            }
            print("flux-test-peer: BROWSE DONE \(tunnel)", flush: true)
        } catch {
            print("flux-test-peer: BROWSE FAILED \(tunnel): \(error)", flush: true)
        }
        await session.close()
    }
}
