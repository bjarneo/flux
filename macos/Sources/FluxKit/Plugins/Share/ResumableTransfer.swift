import CryptoKit
import Foundation

/// Private file chunks survive a lost link and an app restart.
actor ResumableTransfer {
    private var active: Set<String> = []
    private struct Record: Codable {
        let name: String
        let size: Int64
        let hash: String
        var path: String?
    }

    static func valid(id: String, name: String, size: Int64, hash: String) -> Bool {
        id.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil &&
            hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
            size >= 0 && size <= 1 << 40 && !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { $0.value < 32 })
    }

    func receive(_ p: Packet, device: String, certificate: [UInt8], core: FluxCore, folder: URL) async throws -> URL? {
        guard let id = p.string("id"), let name = p.string("name"), let hash = p.string("hash"),
              Self.valid(id: id, name: name, size: p.long("size") ?? 0, hash: hash) else { throw FluxError("Invalid transfer metadata") }
        let size = p.long("size") ?? 0
        let key = SHA256.hash(data: Data((device + ":" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        guard active.insert(key).inserted else { throw FluxError("The transfer is busy") }
        defer { active.remove(key) }
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        if p.string("action") == "offer", let old = try? fm.contentsOfDirectory(at: root.appendingPathComponent("Flux/incoming"), includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old where !active.contains(url.lastPathComponent) {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date < Date().addingTimeInterval(-7 * 24 * 60 * 60) { try? fm.removeItem(at: url) }
            }
        }
        let dir = root.appendingPathComponent("Flux/incoming/" + key, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        let state = dir.appendingPathComponent("state.json"), part = dir.appendingPathComponent("data")
        var record = Record(name: name, size: size, hash: hash)
        if fm.fileExists(atPath: state.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: state))
            guard record.name == name && record.size == size && record.hash == hash else { throw FluxError("Transfer metadata changed") }
        } else { try JSONEncoder().encode(record).write(to: state, options: .atomic) }
        func reply(_ action: String, _ offset: Int64) {
            core.send(Packet(PacketType.fluxTransfer, ["id": id, "action": action, "offset": offset]), to: device)
        }
        if record.path != nil { reply("done", size); return nil }
        if !fm.fileExists(atPath: part.path) {
            guard fm.createFile(atPath: part.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw FluxError("Cannot create the partial file") }
        }
        let file = try FileHandle(forUpdating: part)
        defer { try? file.close() }
        var offset = Int64(try file.seekToEnd())
        guard offset <= size else { throw FluxError("Partial file exceeds the transfer size") }
        if p.string("action") == "chunk" {
            guard p.long("offset") == offset, p.payloadSize > 0, p.payloadSize <= min(1 << 20, size-offset),
                  let token = p.payloadTunnel else { throw FluxError("Invalid transfer chunk") }
            let stream = try await Tunnel.accept(tls: core.tls, expected: certificate, token: token) { core.send($0, to: device) }
            try await stream.receive(into: file, size: p.payloadSize)
            try file.synchronize()
            offset = Int64(try file.seekToEnd())
        }
        guard offset == size else { reply("offset", offset); return nil }
        try file.seek(toOffset: 0)
        var sum = SHA256()
        while let data = try file.read(upToCount: 65536), !data.isEmpty { sum.update(data: data) }
        guard sum.finalize().map({ String(format: "%02x", $0) }).joined() == hash else {
            try file.truncate(atOffset: 0)
            throw FluxError("The file checksum does not match")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = try SharePlugin.createExclusive(in: folder, name: name + ".part")
        do {
            try file.seek(toOffset: 0)
            while let data = try file.read(upToCount: 65536), !data.isEmpty { try staging.handle.write(contentsOf: data) }
            try staging.handle.synchronize()
            try staging.handle.close()
            let saved = try SharePlugin.moveExclusive(staging.url, in: folder, name: name)
            record.path = saved.path
            do { try JSONEncoder().encode(record).write(to: state, options: .atomic) }
            catch { try? fm.removeItem(at: saved); throw error }
            try? fm.removeItem(at: part)
            reply("done", size)
            return saved
        } catch {
            try? staging.handle.close()
            try? fm.removeItem(at: staging.url)
            throw error
        }
    }
}
