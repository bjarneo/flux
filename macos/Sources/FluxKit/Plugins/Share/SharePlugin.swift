#if os(macOS)
import AppKit
import CoreServices
#endif
import Foundation
import NIOConcurrencyHelpers
import UserNotifications

/// File, text, and link sharing: flux.share.request in both
/// directions. A file from the computer comes through a Flux tunnel. A file
/// to the computer goes out on a payload port that this device opens.
///
/// This device never opens a received file or link by itself. The user
/// opens a file from its notification or the Share card, and a link from
/// its notification.
public final class SharePlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: ShareModel
    /// Opens a received file after the user asks for it. On macOS, nil
    /// opens it with the default app. On iOS the app sets it, for example
    /// to Quick Look.
    @MainActor public var openFile: (@MainActor @Sendable (URL) -> Void)?
    /// Opens a received link after a click on its notification. On macOS,
    /// nil opens it in the default browser. On iOS the app sets it. Without
    /// it the link is not opened.
    @MainActor public var openLink: (@MainActor @Sendable (URL) -> Void)?

    /// The transfer streams that run, so that an unpair ends them.
    private let streams = NIOLockedValueBox<[UUID: (deviceId: String, stream: TLSStream)]>([:])
    /// The space that a received file leaves free on the volume, in bytes.
    static let freeSpaceReserve: Int64 = 256 << 20

    static let fileCategory = "share.file"
    static let linkCategory = "share.link"
    static let folderKey = "share.downloadFolder"

    @MainActor
    public init() {
        model = ShareModel(downloadFolder: Self.defaultFolder)
    }

    public let incoming = [PacketType.share, PacketType.shareUpdate]
    public let outgoing = [PacketType.share, PacketType.shareUpdate, PacketType.fluxTunnel]

    public func attach(core: FluxCore) {
        self.core = core
        let folder = downloadFolder
        ui { $0.downloadFolder = folder }
        #if os(macOS)
        let open = UNNotificationAction(identifier: "open", title: "Open")
        let fileActions = [open, UNNotificationAction(identifier: "reveal", title: "Show in Finder")]
        #else
        // Without .foreground, iOS runs the action in the background, where
        // Flux cannot show a file or open a link.
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let fileActions = [open]
        #endif
        Notifier.shared.register(category: Self.fileCategory, actions: fileActions) { [weak self] action, info, _ in
            guard let path = info["path"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    #if os(macOS)
                    if action == "reveal" {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        return
                    }
                    #endif
                    self?.openReceivedFile(url)
                }
            }
        }
        Notifier.shared.register(category: Self.linkCategory, actions: [open]) { [weak self] _, info, _ in
            guard let link = info["url"] as? String, let url = ShareWire.webURL(link) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.openReceivedLink(url) } }
        }
    }

    /// Opens a file through openFile, or with the default app on macOS.
    @MainActor
    private func openReceivedFile(_ url: URL) {
        if let openFile {
            openFile(url)
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Opens a link through openLink, or in the default browser on macOS.
    @MainActor
    private func openReceivedLink(_ url: URL) {
        if let openLink {
            openLink(url)
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: Settings

    static var defaultFolder: URL { FluxFolders.downloads }

    /// The name of a folder in messages. The default folder has the name
    /// that users know: Downloads on macOS, Files on iOS, where the Files
    /// app shows the Documents folder of the app.
    static func placeName(_ folder: URL) -> String {
        folder.standardizedFileURL == FluxFolders.downloads.standardizedFileURL ? FluxFolders.downloadsName : folder.lastPathComponent
    }

    /// The folder for received files. The default is ~/Downloads on macOS
    /// and the app's Documents folder on iOS.
    public var downloadFolder: URL {
        guard let path = core?.defaults.string(forKey: Self.folderKey), !path.isEmpty else { return Self.defaultFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @MainActor
    public func setDownloadFolder(_ url: URL) {
        core?.defaults.set(url.path, forKey: Self.folderKey)
        model.downloadFolder = url
    }

    // MARK: Receive

    /// Text goes on the clipboard, a web link waits in a notification, and a
    /// file goes to the download folder. A share.request.update only
    /// announces a batch, so it needs no action. The core lock is held.
    public func handle(_ packet: Packet, from device: Device) {
        guard let core, packet.type == PacketType.share, let request = ShareRequest(packet) else { return }
        let from = device.name
        switch request {
        case .text(let text):
            core.plugin(ClipboardPlugin.self)?.putFromComputer(text, from: device.id)
            core.toast("Text from \(from) is on the clipboard")
        case .url(let web):
            core.toast("Link from \(from)")
            // The links share the notification limit of the computer, so
            // that a computer cannot bury the other notifications.
            guard NotificationLimit.allowsNow(device.id) else {
                FluxLog.plugin.info("link notification dropped: too many from \(from, privacy: .public)")
                return
            }
            // The link opens only after a click on the notification, like
            // in the Android app. The links count toward the delivered
            // notifications of the computer.
            let id = DeliveredNotifications.linkId(deviceId: device.id)
            DeliveredNotifications.post(id: id, deviceId: device.id)
            Notifier.shared.post(id: id, category: Self.linkCategory,
                                 title: "Link from \(from)", body: web.absoluteString, userInfo: ["url": web.absoluteString])
        case .file(let name, let lastModified):
            guard let token = packet.payloadTunnel, let cert = device.certificate else { return }
            guard packet.payloadSize > 0 else {
                device.send(Tunnel.failed(token: token, error: "the file has no size"))
                return
            }
            core.toast("Receiving \(name)")
            let job = Download(deviceId: device.id, from: from, token: token, cert: cert, packet: packet,
                               name: name, lastModified: lastModified)
            Task.detached { [self] in await download(job) }
        }
    }

    /// An unpair ends the transfers of the device. A link that only drops
    /// leaves them, because they have their own connections.
    public func onDisconnected(_ device: Device) {
        guard !device.paired else { return }
        let id = device.id
        let ended = streams.withLockedValue { all -> [TLSStream] in
            let mine = all.filter { $0.value.deviceId == id }
            for key in mine.keys { all[key] = nil }
            return mine.values.map { $0.stream }
        }
        ended.forEach { $0.channel.channel.close(promise: nil) }
    }

    /// Keeps a stream until its transfer ends. It returns false when the
    /// device is no longer paired, for example after an unpair during the
    /// wait for the computer. The core lock comes first, as in an unpair.
    private func register(_ stream: TLSStream, id: UUID, deviceId: String) -> Bool {
        core?.withDevice(deviceId) { d -> Bool in
            guard d.paired else { return false }
            streams.withLockedValue { $0[id] = (deviceId, stream) }
            return true
        } ?? false
    }

    private func unregister(_ id: UUID) {
        streams.withLockedValue { $0[id] = nil }
    }

    /// 1 file that the computer offers.
    private struct Download: Sendable {
        let deviceId: String
        let from: String
        /// The tunnel that the payload comes through.
        let token: String
        let cert: [UInt8]
        let packet: Packet
        let name: String
        let lastModified: Int64?
    }

    /// Reports whether a file of the size fits on the volume of the folder
    /// with the reserve left free. It is true when the volume does not tell.
    static func fits(_ size: Int64, in folder: URL) -> Bool {
        guard let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return fits(size, free: free)
    }

    static func fits(_ size: Int64, free: Int64) -> Bool {
        size >= 0 && size <= free - freeSpaceReserve
    }

    #if os(macOS)
    /// Marks a received file as a download, so that Gatekeeper checks it
    /// when the user opens it. The app has no sandbox, so macOS does not
    /// mark the files that it writes.
    static func quarantine(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Flux",
        ]
        var file = url
        do {
            try file.setResourceValues(values)
        } catch {
            FluxLog.plugin.error("cannot mark \(url.lastPathComponent, privacy: .private(mask: .hash)) as a download: \(String(describing: error), privacy: .public)")
        }
    }
    #endif

    private func download(_ job: Download) async {
        guard let core else { return }
        let folder = downloadFolder
        let transfer = FileTransfer(id: UUID(), deviceId: job.deviceId, name: job.name, incoming: true, size: job.packet.payloadSize)
        ui { $0.start(transfer) }
        let part: (url: URL, handle: FileHandle)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard Self.fits(job.packet.payloadSize, in: folder) else {
                throw FluxError("there is not enough free space in \(Self.placeName(folder))")
            }
            part = try Self.createExclusive(in: folder, name: job.name + ".part")
        } catch {
            core.toast("Cannot save \(job.name): \(error.localizedDescription)")
            core.send(Tunnel.failed(token: job.token, error: "cannot save the file"), to: job.deviceId)
            ui { $0.finish(transfer.id, file: nil, error: error) }
            return
        }
        do {
            // Listen and let the computer connect.
            let stream = try await Tunnel.accept(tls: core.tls, expected: job.cert, token: job.token) { [weak core] p in
                core?.send(p, to: job.deviceId)
            }
            guard register(stream, id: transfer.id, deviceId: job.deviceId) else {
                await stream.discard()
                throw FluxError("\(job.from) is not paired")
            }
            defer { unregister(transfer.id) }
            try await stream.receive(into: part.handle, size: job.packet.payloadSize, progress: progress(transfer.id))
            try part.handle.close()
            let saved = try Self.moveExclusive(part.url, in: folder, name: job.name)
            #if os(macOS)
            Self.quarantine(saved)
            #endif
            if let ms = job.lastModified, ms > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(ms) / 1000)], ofItemAtPath: saved.path)
            }
            ui { $0.finish(transfer.id, file: saved, error: nil) }
            Notifier.shared.post(id: "share-\(transfer.id.uuidString)", category: Self.fileCategory,
                                 title: "Received \(saved.lastPathComponent)",
                                 body: "From \(job.from), saved in \(Self.placeName(folder))",
                                 userInfo: ["path": saved.path])
            core.toast("Saved \(saved.lastPathComponent) in \(Self.placeName(folder))")
        } catch {
            try? part.handle.close()
            try? FileManager.default.removeItem(at: part.url)
            FluxLog.plugin.error("receive \(job.name, privacy: .private(mask: .hash)) failed: \(String(describing: error), privacy: .public)")
            ui { $0.finish(transfer.id, file: nil, error: error) }
            core.toast("Receiving \(job.name) failed")
        }
    }

    /// Creates a new file for writing, "name", "name (2)", and so on. It
    /// never opens a file that exists.
    static func createExclusive(in folder: URL, name: String) throws -> (url: URL, handle: FileHandle) {
        while true {
            let url = ShareWire.uniqueURL(in: folder, name: name) { FileManager.default.fileExists(atPath: $0.path) }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 { return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true)) }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// Renames the file to "name", "name (2)", and so on in the folder. It
    /// never replaces a file.
    static func moveExclusive(_ file: URL, in folder: URL, name: String) throws -> URL {
        while true {
            let url = ShareWire.uniqueURL(in: folder, name: name) { FileManager.default.fileExists(atPath: $0.path) }
            if renamex_np(file.path, url.path, UInt32(RENAME_EXCL)) == 0 { return url }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    // MARK: Send

    /// Sends files to a computer, one at a time. A folder does not go out.
    public func send(files: [URL], to deviceId: String) {
        guard let core else { return }
        var list: [URL] = []
        for url in files {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                core.toast("\(url.lastPathComponent) is a folder. Send the files inside it")
            } else {
                list.append(url)
            }
        }
        guard !list.isEmpty else { return }
        guard let peer = peer(deviceId) else {
            core.toast("Not connected. Try again in a moment")
            return
        }
        Task.detached { [self] in await sendBatch(list, to: peer) { _, _ in } }
    }

    /// Sends files to a connected computer in 1 batch, like `send(files:to:)`,
    /// and returns after the batch ends. `result` gets each file with nil
    /// once the computer received it, or with the error. It throws when the
    /// computer is not connected, and then no file goes out.
    public func sendAndWait(files: [URL], to deviceId: String, result: @escaping @Sendable (URL, Error?) -> Void) async throws {
        guard let peer = peer(deviceId) else { throw FluxError("Not connected") }
        await sendBatch(files, to: peer, result: result)
    }

    private func sendBatch(_ urls: [URL], to peer: Peer, result: @Sendable (URL, Error?) -> Void) async {
        guard let core else { return }
        let files: [(url: URL, size: Int64)] = urls.compactMap { url in
            guard let size = Self.fileSize(url) else {
                core.toast("Cannot read \(url.lastPathComponent)")
                result(url, FluxError("cannot read \(url.lastPathComponent)"))
                return nil
            }
            return (url, size)
        }
        guard !files.isEmpty else { return }
        let total = files.reduce(0) { $0 + $1.size }
        core.send(ShareWire.update(count: files.count, total: total), to: peer.id)
        var sent: [String] = []
        for file in files {
            let name = file.url.lastPathComponent
            do {
                try await offer(file.url, size: file.size, to: peer) { port in
                    ShareWire.file(name: name, count: files.count, total: total, size: file.size, port: port)
                }
                sent.append(name)
                result(file.url, nil)
            } catch {
                FluxLog.plugin.error("send \(name, privacy: .private(mask: .hash)) failed: \(String(describing: error), privacy: .public)")
                core.toast("Sending \(name) failed")
                result(file.url, error)
            }
        }
        if sent.count == 1 {
            core.toast("Sent \(sent[0])")
        } else if sent.count > 1 {
            core.toast("Sent \(sent.count) files to \(peer.name)")
        }
    }

    /// Sends 1 captured file, such as a photo or a screenshot. The body gets
    /// the extra fields, for example "photo" or "scan". It returns after the
    /// transfer ends.
    public func sendCapture(file: URL, name: String, extra: [String: Any?], to deviceId: String) async throws {
        guard let peer = peer(deviceId) else { throw FluxError("Not connected") }
        guard let size = Self.fileSize(file) else { throw FluxError("cannot read \(file.path)") }
        let fields = extra.mapValues { JSONValue($0) }
        try await offer(file, size: size, name: name, to: peer) { port in
            ShareWire.capture(name: name, extra: fields, size: size, port: port)
        }
    }

    /// Sends text that the camera read. The "scan" flag makes the computer
    /// save it in a file. It returns false when the computer is not connected.
    public func sendScan(text: String, to deviceId: String) -> Bool {
        core?.send(ShareWire.scan(text), to: deviceId) ?? false
    }

    /// The largest text or link that `send(text:to:)` sends. The computer
    /// reads 1 packet as 1 line and closes the link after a line over its
    /// limit.
    public static let maxText = 1 << 20

    /// Sends text, or a link when the text is 1 URL. It returns false when
    /// the text did not go out.
    @discardableResult
    public func send(text: String, to deviceId: String) -> Bool {
        guard text.utf8.count <= Self.maxText else {
            core?.toast("The text is larger than 1 MB. Send it as a file")
            return false
        }
        guard let core, let peer = peer(deviceId) else {
            core?.toast("Not connected. Try again in a moment")
            return false
        }
        let p = ShareWire.text(text)
        guard core.send(p, to: deviceId) else {
            core.toast("Not connected. Try again in a moment")
            return false
        }
        core.toast(p.has("url") ? "Link sent to \(peer.name)" : "Text sent to \(peer.name)")
        return true
    }

    /// The fields of a connected, paired computer that a transfer needs.
    private struct Peer: Sendable {
        let id: String
        let name: String
        let cert: [UInt8]
    }

    private func peer(_ id: String) -> Peer? {
        core?.withDevice(id) { d in
            d.paired && d.online ? d.certificate.map { Peer(id: d.id, name: d.name, cert: $0) } : nil
        } ?? nil
    }

    /// Offers 1 file on a payload port and streams it to the computer, which
    /// connects as the TLS client and must present the paired certificate.
    private func offer(_ url: URL, size: Int64, name: String? = nil, to peer: Peer, packet: @Sendable (Int) -> Packet) async throws {
        guard let core else { throw FluxError("Flux stopped") }
        let transfer = FileTransfer(id: UUID(), deviceId: peer.id, name: name ?? url.lastPathComponent, incoming: false, size: size, file: url)
        ui { $0.start(transfer) }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let server = try await PayloadServer.open(tls: core.tls, expected: peer.cert)
            guard core.send(packet(server.port), to: peer.id) else {
                server.close()
                throw FluxError("Not connected")
            }
            let stream = try await server.accept()
            guard register(stream, id: transfer.id, deviceId: peer.id) else {
                await stream.discard()
                throw FluxError("\(peer.name) is not paired")
            }
            defer { unregister(transfer.id) }
            try await stream.send(from: handle, size: size, progress: progress(transfer.id))
            ui { $0.finish(transfer.id, file: nil, error: nil) }
        } catch {
            ui { $0.finish(transfer.id, file: nil, error: error) }
            throw error
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: UI state

    private func progress(_ id: UUID) -> @Sendable (Int64) -> Void {
        { [weak self] bytes in self?.ui { $0.progress(id, bytes: bytes) } }
    }

    /// Changes the model on the main queue, in the order of the calls.
    private func ui(_ change: @escaping @MainActor (ShareModel) -> Void) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { change(model) } }
    }
}
