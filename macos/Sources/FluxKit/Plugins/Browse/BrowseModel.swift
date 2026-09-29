import Foundation
import Observation

/// One file that the browser saves in Downloads.
public struct BrowseDownload: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case done(URL)
        case failed(String)
    }

    public let id: UUID
    /// The name in Downloads, which can differ from the remote name.
    public let name: String
    public let size: Int64
    public internal(set) var received: Int64 = 0
    public internal(set) var state = State.running

    /// The part done, or nil when the size is unknown.
    public var fraction: Double? { size > 0 ? min(1, Double(received) / Double(size)) : nil }

    /// A remote name as a local file name: the last path component, or
    /// "download" for a name without one.
    public static func safeName(_ name: String) -> String {
        let base = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        return base.isEmpty || base == "." || base == ".." ? "download" : base
    }

    /// The first free URL for the name in the folder: "a.txt", then
    /// "a (2).txt", "a (3).txt", and so on.
    public static func uniqueURL(for name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let first = folder.appendingPathComponent(name)
        if !exists(first) { return first }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for i in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return first
    }
}

/// The state of one browse window. The window keeps 1 SSH session to the
/// computer until it closes or the computer disconnects.
@MainActor
@Observable
public final class BrowseModel {
    public let deviceId: String
    public private(set) var deviceName: String
    public private(set) var loading = true
    public private(set) var error: String?
    public private(set) var roots: [BrowseRoot] = []
    /// The folder on screen. It changes when a listing starts.
    public private(set) var path = ""
    public private(set) var entries: [BrowseEntry] = []
    public private(set) var downloads: [BrowseDownload] = []

    /// How long the computer has to answer flux.sftp.request.
    static let answerTimeout: Duration = .seconds(10)

    @ObservationIgnored private let core: FluxCore
    @ObservationIgnored private var session: BrowseSession?
    /// Counts starts, so that the answer to an older request is ignored.
    @ObservationIgnored private var attempt = 0
    /// Counts listings, so that only the latest one shows.
    @ObservationIgnored private var listing = 0
    @ObservationIgnored private var awaitingOffer = false
    /// True after the link closed, so that the next link starts again.
    @ObservationIgnored private var lostLink = false
    @ObservationIgnored private var transfers: [UUID: Task<Void, Never>] = [:]

    init(core: FluxCore, deviceId: String) {
        self.core = core
        self.deviceId = deviceId
        deviceName = core.device(deviceId)?.name ?? "The computer"
    }

    /// True when a folder above the current one is inside a root.
    public var canGoUp: Bool { session != nil && !path.isEmpty && !BrowsePath.isRoot(path, in: roots) }

    /// The folders from the root down to the current one.
    public var crumbs: [BrowseRoot] { path.isEmpty ? [] : BrowsePath.crumbs(path, roots: roots) }

    /// The root that holds the current folder.
    public var root: BrowseRoot? { BrowsePath.root(of: path, in: roots) }

    public var activeDownloads: Int { downloads.filter { $0.state == .running }.count }

    /// Asks the computer for a new SFTP session.
    public func start() {
        closeSession()
        attempt += 1
        let current = attempt
        deviceName = core.device(deviceId)?.name ?? deviceName
        loading = true
        error = nil
        roots = []
        path = ""
        entries = []
        lostLink = false
        guard core.send(Packet(PacketType.sftpRequest, ["startBrowsing": true]), to: deviceId) else {
            awaitingOffer = false
            loading = false
            error = "\(deviceName) is not connected. Try again when it connects."
            return
        }
        awaitingOffer = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.answerTimeout)
            guard let self, self.attempt == current, self.awaitingOffer else { return }
            self.awaitingOffer = false
            self.loading = false
            self.error = "\(self.deviceName) did not answer. Browsing files needs fluxd."
        }
    }

    /// Opens a folder of the session.
    public func open(_ folder: String) {
        guard let session else { return }
        listing += 1
        let current = listing
        loading = true
        path = folder
        Task { [weak self] in
            do {
                let entries = try await session.list(folder)
                guard let self, self.listing == current else { return }
                self.entries = entries
                self.error = nil
                self.loading = false
            } catch {
                guard let self, self.listing == current else { return }
                self.entries = []
                self.loading = false
                self.error = "Cannot open \(folder): \(BrowseSession.describe(error))"
            }
        }
    }

    /// Opens the folder that contains the current one.
    public func goUp() {
        if canGoUp { open(BrowsePath.parent(path)) }
    }

    /// Lists the current folder again, or starts a new session when the
    /// session ended.
    public func retry() {
        if session != nil, !path.isEmpty { open(path) } else { start() }
    }

    /// Enters a folder or downloads a file.
    public func activate(_ entry: BrowseEntry) {
        if entry.dir { open(entry.path) } else { download(entry) }
    }

    /// Saves a file in the downloads folder under a free name.
    public func download(_ entry: BrowseEntry) {
        guard let session, !entry.dir else { return }
        let fm = FileManager.default
        let folder = FluxFolders.downloads
        let dest = BrowseDownload.uniqueURL(for: BrowseDownload.safeName(entry.name), in: folder) {
            fm.fileExists(atPath: $0.path) || fm.fileExists(atPath: $0.path + ".part")
        }
        let part = URL(fileURLWithPath: dest.path + ".part")
        let handle: FileHandle
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fm.createFile(atPath: part.path, contents: nil) else { throw FluxError("cannot create \(part.lastPathComponent)") }
            handle = try FileHandle(forWritingTo: part)
        } catch {
            core.toast("Cannot save \(entry.name): \(BrowseSession.describe(error))")
            return
        }
        let item = BrowseDownload(id: UUID(), name: dest.lastPathComponent, size: entry.size)
        downloads.append(item)
        let id = item.id
        transfers[id] = Task { [weak self, core] in
            let result: BrowseDownload.State
            do {
                try await session.download(entry.path, into: handle) { received in
                    Task { @MainActor in self?.update(id) { $0.received = max($0.received, received) } }
                }
                try handle.close()
                try FileManager.default.moveItem(at: part, to: dest)
                result = .done(dest)
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: part)
                result = .failed(Task.isCancelled ? "Canceled" : BrowseSession.describe(error))
            }
            guard let self else { return }
            self.transfers[id] = nil
            self.update(id) { $0.state = result }
            switch result {
            case .done(let url):
                Notifier.shared.post(id: "browse-\(id.uuidString)", category: BrowsePlugin.downloadCategory,
                                     title: "Downloaded \(url.lastPathComponent)", body: "Saved in \(FluxFolders.downloadsName)",
                                     subtitle: self.deviceName, userInfo: [BrowsePlugin.pathKey: url.path])
                core.toast("Saved \(url.lastPathComponent) in \(FluxFolders.downloadsName)")
            case .failed(let reason):
                if !Task.isCancelled { core.toast("Downloading \(entry.name) failed: \(reason)") }
            case .running:
                break
            }
        }
    }

    /// Stops a running download and deletes its partial file.
    public func cancel(_ id: UUID) {
        transfers[id]?.cancel()
    }

    /// Removes finished and failed downloads from the list.
    public func clearDownloads() {
        downloads.removeAll { $0.state != .running }
    }

    // MARK: Plugin events

    /// Handles flux.sftp from the computer.
    func receive(_ p: Packet, tls: FluxTLS, certificate: [UInt8]?) {
        guard awaitingOffer else { return }
        awaitingOffer = false
        if let message = p.string("errorMessage") {
            loading = false
            error = message
            return
        }
        guard let offer = SftpOffer.parse(p) else {
            loading = false
            error = "\(deviceName) sent no way to connect"
            return
        }
        let current = attempt
        let deviceId = deviceId
        Task { [weak self, core] in
            do {
                let session = try await BrowseSession.open(
                    offer, tls: tls, certificate: certificate,
                    announce: { core.send($0, to: deviceId) },
                    onClose: { Task { @MainActor in self?.sessionEnded(current) } }
                )
                guard let self, self.attempt == current else {
                    await session.close()
                    return
                }
                self.session = session
                self.roots = offer.roots
                self.open(offer.roots[0].path)
            } catch {
                guard let self, self.attempt == current else { return }
                FluxLog.plugin.info("browse connect failed: \(String(describing: error), privacy: .public)")
                self.loading = false
                self.error = "Cannot open files on \(self.deviceName): \(BrowseSession.describe(error))"
            }
        }
    }

    /// The link to the computer closed. The session ends with it.
    func disconnected() {
        closeSession()
        attempt += 1
        awaitingOffer = false
        lostLink = true
        loading = false
        error = "\(deviceName) disconnected. Browsing starts again when it connects."
    }

    /// The link to the computer is back after it closed.
    func connected() {
        if lostLink { start() }
    }

    /// Ends the session for good; the window closed.
    func close() {
        attempt += 1
        awaitingOffer = false
        closeSession()
    }

    // MARK: Private

    /// The SSH connection of start number `ended` closed.
    private func sessionEnded(_ ended: Int) {
        guard ended == attempt, session != nil else { return }
        session = nil
        loading = false
        if error == nil { error = "The session with \(deviceName) ended." }
    }

    private func closeSession() {
        for task in transfers.values { task.cancel() }
        guard let s = session else { return }
        session = nil
        Task { await s.close() }
    }

    private func update(_ id: UUID, _ change: (inout BrowseDownload) -> Void) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[i])
    }
}
