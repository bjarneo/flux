import Foundation
import Observation
import Photos

/// The access that Flux has to the photo library.
public enum PhotoAccess: Sendable {
    case notDetermined, denied, restricted, limited, authorized

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }

    /// The access now. Access to selected photos only is not enough, because
    /// new photos are not in the selection.
    public static var current: PhotoAccess { PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }
}

/// The capture watch state that the UI shows.
@MainActor
@Observable
public final class CaptureModel {
    public internal(set) var screenshots = false
    public internal(set) var photos = false
    public internal(set) var photoAccess = PhotoAccess.notDetermined
    #if os(macOS)
    public internal(set) var screenshotFolder: URL

    init(screenshotFolder: URL) {
        self.screenshotFolder = screenshotFolder
    }
    #else
    init() {}
    #endif
}

/// Sends each new screenshot and each new photo to the connected computers,
/// when its switch is on. An image waits until a computer connects.
///
/// On macOS it watches the screenshot folder and the photo library, and
/// `planCapture` decides what goes out, so that no image goes out twice.
/// On iOS both come from the photo library: screenshots are the images with
/// the screenshot subtype. iOS runs Flux only on the screen, so the app calls
/// `catchUp()` when it becomes active, and the images that the library got
/// since the switch turned on and that did not go out yet go out, in the
/// order that they arrived.
public final class CaptureWatchPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: CaptureModel
    private let commands: AsyncStream<Command>.Continuation
    /// Guards the folder watch and the scan timer.
    private let queue = DispatchQueue(label: "org.omarchy.flux.capture")
    private var pendingScan: DispatchWorkItem?
    #if os(macOS)
    private let fixedFolder: URL?
    private var watch: (path: String, source: DispatchSourceFileSystemObject)?
    #endif
    @MainActor private var library: LibraryObserver?

    private enum Command: Sendable {
        case scan
        case set(CaptureKind, Bool)
    }

    /// Where an image of a scan comes from.
    private enum Source {
        case file(URL)
        case asset(String)
    }

    static let screenshotsKey = "capture.screenshots"
    static let photosKey = "capture.photos"
    /// How long the watch waits after a change before it scans, in seconds.
    static let scanDelay: TimeInterval = 1.5
    static let stateKey = "capture.state"
    static let tokenKey = "capture.photoToken"
    static let inboxKey = "capture.photoInbox"
    #if os(macOS)
    /// A file that changed within this time is still being written, in seconds.
    static let quietTime: TimeInterval = 2
    /// The attribute that macOS puts on each screenshot and screen recording.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// `screenshotFolder` replaces the folder of the system screenshot
    /// setting, for example in a test.
    @MainActor
    public init(screenshotFolder: URL? = nil) {
        fixedFolder = screenshotFolder
        model = CaptureModel(screenshotFolder: screenshotFolder ?? Self.systemScreenshotFolder())
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        Task.detached { [weak self] in
            for await command in stream { await self?.run(command) }
        }
    }
    #else
    @MainActor
    public init() {
        model = CaptureModel()
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        Task.detached { [weak self] in
            for await command in stream { await self?.run(command) }
        }
    }
    #endif

    public let incoming: [String] = []
    public let outgoing: [String] = []

    public func attach(core: FluxCore) {
        self.core = core
        #if os(macOS)
        let (shots, photos, folder) = (sendScreenshots, sendPhotos, screenshotFolder)
        onMain { plugin in
            plugin.model.screenshots = shots
            plugin.model.photos = photos
            plugin.model.screenshotFolder = folder
            if photos { plugin.model.photoAccess = .current }
            plugin.refresh()
        }
        #else
        let (shots, photos) = (sendScreenshots, sendPhotos)
        onMain { plugin in
            plugin.model.screenshots = shots
            plugin.model.photos = photos
            if shots || photos { plugin.model.photoAccess = .current }
            plugin.refresh()
        }
        #endif
    }

    /// New images that no computer took yet go out now.
    public func onConnected(_ device: Device) { poke() }

    /// The watch accepts no packets. It sends through `SharePlugin`.
    public func handle(_ packet: Packet, from device: Device) {}

    // MARK: Settings

    /// Sends each new screenshot to the computers. The default is off.
    public var sendScreenshots: Bool { core?.defaults.bool(forKey: Self.screenshotsKey) ?? false }

    /// Sends each new photo to the computers. The default is off.
    public var sendPhotos: Bool { core?.defaults.bool(forKey: Self.photosKey) ?? false }

    #if os(macOS)
    /// The folder of new screenshots: the location of the system screenshot
    /// setting, or the Desktop.
    public var screenshotFolder: URL { fixedFolder ?? Self.systemScreenshotFolder() }

    static func systemScreenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    @MainActor
    public func setSendScreenshots(_ on: Bool) {
        core?.defaults.set(on, forKey: Self.screenshotsKey)
        model.screenshots = on
        model.screenshotFolder = screenshotFolder
        commands.yield(.set(.screenshot, on))
        refresh()
    }
    #else
    /// Turns the screenshot switch on or off. Screenshots come from the
    /// photo library, so on asks for full access to it first.
    @MainActor
    public func setSendScreenshots(_ on: Bool) async {
        if on, await !fullPhotoAccess() { return }
        core?.defaults.set(on, forKey: Self.screenshotsKey)
        model.screenshots = on
        commands.yield(.set(.screenshot, on))
        refresh()
    }

    /// Sends the screenshots and photos that the library got and that did
    /// not go out yet. The app calls it when it becomes active.
    @MainActor
    public func catchUp() {
        commands.yield(.scan)
    }
    #endif

    /// Asks for full access to the photo library when the user did not
    /// answer yet. It returns true with full access, else it tells the user.
    @MainActor
    private func fullPhotoAccess() async -> Bool {
        var access = PhotoAccess.current
        if access == .notDetermined {
            access = PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        }
        model.photoAccess = access
        guard access == .authorized else {
            #if os(macOS)
            core?.toast("Flux needs full access to Photos. Allow it in System Settings > Privacy & Security > Photos")
            #else
            core?.toast("Flux needs full access to Photos. Allow it in Settings > Privacy & Security > Photos")
            #endif
            return false
        }
        return true
    }

    /// Turns the photo switch on or off. On asks for full access to the
    /// photo library first.
    @MainActor
    public func setSendPhotos(_ on: Bool) async {
        if on, await !fullPhotoAccess() { return }
        core?.defaults.set(on, forKey: Self.photosKey)
        model.photos = on
        commands.yield(.set(.photo, on))
        refresh()
    }

    /// Reads the photo access again, for example when the settings appear.
    @MainActor
    public func refreshPhotoAccess() {
        model.photoAccess = .current
        refresh()
    }

    // MARK: Watch

    /// Starts or stops the folder watch and the library observer to match
    /// the switches, then scans.
    @MainActor
    private func refresh() {
        #if os(macOS)
        let folder = sendScreenshots ? screenshotFolder : nil
        queue.async { [self] in rewatch(folder) }
        let observe = sendPhotos && model.photoAccess == .authorized
        #else
        let observe = (sendScreenshots || sendPhotos) && model.photoAccess == .authorized
        #endif
        if observe, library == nil {
            let observer = LibraryObserver { [weak self] in self?.poke() }
            PHPhotoLibrary.shared().register(observer)
            library = observer
        } else if !observe, let observer = library {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            library = nil
        }
        poke()
    }

    #if os(macOS)
    /// Watches the folder for new entries, or nothing when folder is nil. Runs on the queue.
    private func rewatch(_ folder: URL?) {
        if watch?.path == folder?.path { return }
        watch?.source.cancel()
        watch = nil
        guard let folder else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            FluxLog.plugin.error("cannot watch \(folder.path, privacy: .public): errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.poke() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = (folder.path, source)
    }
    #endif

    /// Scans soon. A new file, a library change, or a computer that connects calls it.
    public func poke() {
        queue.async { [self] in
            pendingScan?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.commands.yield(.scan) }
            pendingScan = item
            queue.asyncAfter(deadline: .now() + Self.scanDelay, execute: item)
        }
    }

    // MARK: Worker

    /// Runs 1 command. The commands run one at a time, in order.
    private func run(_ command: Command) async {
        switch command {
        case .scan:
            await scan()
        case .set(let kind, let on):
            #if os(macOS)
            var state = loadState()
            state = on ? state.enable(kind, newest: Self.micros(Date())) : state.disable(kind)
            saveState(state)
            if kind == .photo {
                // Photos start from the library as it is now.
                saveInbox([])
                saveToken(on ? PHPhotoLibrary.shared().currentChangeToken : nil)
            }
            #else
            // Both kinds come from the library. The first switch that turns
            // on starts from the library as it is now, and the last one that
            // turns off forgets it.
            let before = loadState()
            let state = on ? before.enable(kind, newest: Self.micros(Date())) : before.disable(kind)
            saveState(state)
            if before.from.isEmpty != state.from.isEmpty {
                saveInbox([])
                saveToken(state.from.isEmpty ? nil : PHPhotoLibrary.shared().currentChangeToken)
            }
            #endif
        }
    }

    /// Scans the new images and sends the ones that `planCapture` picks.
    private func scan() async {
        guard let core else { return }
        #if os(macOS)
        let shots = sendScreenshots
        let photos = sendPhotos && PhotoAccess.current == .authorized
        #else
        let shots = false
        let photos = (sendScreenshots || sendPhotos) && PhotoAccess.current == .authorized
        #endif
        guard shots || photos else { return }
        let now = Date()
        var state = loadState()
        var items: [CaptureItem] = []
        var sources: [Int64: Source] = [:]
        if photos { readPhotos(state: state, now: now, into: &items, sources: &sources) }
        #if os(macOS)
        if shots {
            let folder = screenshotFolder
            queue.async { [self] in rewatch(folder) }
            onMain { $0.model.screenshotFolder = folder }
            readScreenshots(in: folder, after: state.baseline, now: now, into: &items, sources: &sources)
        }
        #endif
        let plan = planCapture(state, items: items, now: Int64(now.timeIntervalSince1970))
        state = plan.state
        saveState(state)
        saveInbox(loadInbox().filter { $0.id > state.baseline })
        // A file that is still being written needs another look.
        if items.contains(where: \.pending) { poke() }
        guard !plan.send.isEmpty else { return }
        let targets = core.connectedPaired().map(\.id)
        guard !targets.isEmpty, let share = core.plugin(SharePlugin.self) else { return }
        var any = false
        for (item, kind) in plan.send {
            guard let source = sources[item.id] else { continue }
            if await send(item, kind: kind, from: source, to: targets, with: share) {
                any = true
                state = state.markSent(item.id)
                saveState(state)
            }
        }
        // The sent images can move the baseline now.
        if any { poke() }
    }

    #if os(macOS)
    /// Lists the files in the screenshot folder that arrived after the baseline.
    private func readScreenshots(in folder: URL, after baseline: Int64, now: Date, into items: inout [CaptureItem], sources: inout [Int64: Source]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        } catch {
            FluxLog.plugin.error("scan \(folder.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return
        }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let added = values.addedToDirectoryDate ?? values.creationDate else { continue }
            let id = Self.micros(added)
            guard id > baseline else { continue }
            let name = url.lastPathComponent
            let shot = CaptureRules.isScreenshot(name: name, marked: Self.isScreenCapture(url))
            let changed = values.contentModificationDate ?? added
            items.append(CaptureItem(id: id, kind: shot ? .screenshot : nil, name: name,
                                     pending: now.timeIntervalSince(changed) < Self.quietTime,
                                     dateAdded: Int64(added.timeIntervalSince1970)))
            sources[id] = .file(url)
        }
    }

    /// Reports whether macOS marked the file as a screen capture.
    static func isScreenCapture(_ url: URL) -> Bool {
        let size = getxattr(url.path, screenCaptureAttribute, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, screenCaptureAttribute, $0.baseAddress, size, 0, 0) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }
    #endif

    /// Adds the assets that the library got since the last scan to the inbox,
    /// and lists the inbox entries after the baseline. `libraryKind` decides
    /// which of them go out.
    private func readPhotos(state: CaptureState, now: Date, into items: inout [CaptureItem], sources: inout [Int64: Source]) {
        let library = PHPhotoLibrary.shared()
        var inbox = loadInbox()
        if let token = loadToken() {
            do {
                var next = Self.micros(now)
                var last: PHPersistentChangeToken?
                for change in try library.fetchPersistentChanges(since: token) {
                    for asset in try change.changeDetails(for: .asset).insertedLocalIdentifiers {
                        inbox.append(PhotoEntry(id: next, asset: asset))
                        next += 1
                    }
                    last = change.changeToken
                }
                if let last { saveToken(last) }
            } catch {
                // The history is gone: start again from the library as it is now.
                FluxLog.plugin.error("photo changes failed: \(String(describing: error), privacy: .public)")
                saveToken(library.currentChangeToken)
            }
        } else {
            saveToken(library.currentChangeToken)
        }
        saveInbox(inbox)
        let waiting = inbox.filter { $0.id > state.baseline }
        guard !waiting.isEmpty else { return }
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: waiting.map(\.asset), options: nil).enumerateObjects { a, _, _ in
            assets[a.localIdentifier] = a
        }
        for entry in waiting {
            let added = entry.id / 1_000_000
            let asset = assets[entry.asset]
            let seen = asset.map { LibraryAsset(image: $0.mediaType == .image, screenshot: $0.mediaSubtypes.contains(.photoScreenshot), created: $0.creationDate) }
            guard let asset, let kind = libraryKind(seen, from: state.from) else {
                items.append(CaptureItem(id: entry.id, kind: nil, name: entry.asset, dateAdded: added))
                continue
            }
            let resource = Self.photoResource(asset)
            items.append(CaptureItem(id: entry.id, kind: kind, name: resource?.originalFilename ?? "IMG_\(entry.id).jpg", dateAdded: added))
            sources[entry.id] = .asset(entry.asset)
        }
    }

    static func photoResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo } ?? resources.first
    }

    /// Sends 1 image to each target. Returns true when at least 1 target took it.
    private func send(_ item: CaptureItem, kind: CaptureKind, from source: Source, to targets: [String], with share: SharePlugin) async -> Bool {
        let extra: [String: Any?] = switch kind {
        // The photo marker too, so that an older fluxd saves it as a photo.
        case .screenshot: ["photo": true, "screenshot": true]
        case .photo: ["photo": true]
        }
        let file: URL
        var temp: URL?
        switch source {
        case .file(let url):
            file = url
        case .asset(let id):
            do {
                file = try await Self.export(id, name: item.name)
                temp = file.deletingLastPathComponent()
            } catch {
                FluxLog.plugin.error("export \(item.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        var any = false
        for id in targets {
            do {
                try await share.sendCapture(file: file, name: item.name, extra: extra, to: id)
                any = true
                FluxLog.plugin.info("sent \(item.name, privacy: .public) to \(id, privacy: .public)")
            } catch {
                FluxLog.plugin.error("send \(item.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return any
    }

    /// Writes the original of a photo to a new temporary folder.
    static func export(_ localIdentifier: String, name: String) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let resource = photoResource(asset) else { throw FluxError("the photo is gone") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ShareWire.safeName(name))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return file
    }

    // MARK: Storage

    /// 1 asset that the library got after the switch turned on. The ID is
    /// the time that Flux first saw it, in microseconds.
    private struct PhotoEntry: Codable {
        var id: Int64
        var asset: String
    }

    private func loadState() -> CaptureState {
        guard let data = core?.defaults.data(forKey: Self.stateKey) else { return CaptureState() }
        return (try? JSONDecoder().decode(CaptureState.self, from: data)) ?? CaptureState()
    }

    private func saveState(_ state: CaptureState) {
        core?.defaults.set(try? JSONEncoder().encode(state), forKey: Self.stateKey)
    }

    private func loadInbox() -> [PhotoEntry] {
        guard let data = core?.defaults.data(forKey: Self.inboxKey) else { return [] }
        return (try? JSONDecoder().decode([PhotoEntry].self, from: data)) ?? []
    }

    private func saveInbox(_ inbox: [PhotoEntry]) {
        core?.defaults.set(try? JSONEncoder().encode(inbox), forKey: Self.inboxKey)
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = core?.defaults.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func saveToken(_ token: PHPersistentChangeToken?) {
        let data = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        core?.defaults.set(data, forKey: Self.tokenKey)
    }

    static func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

    private func onMain(_ body: @escaping @MainActor (CaptureWatchPlugin) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { body(self) }
        }
    }
}

/// Pokes the capture watch when the photo library changes.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
