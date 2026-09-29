import Foundation
#if canImport(Photos)
import Photos
#endif
#if canImport(CoreImage)
import CoreImage
#endif

/// Production photo-library asset loading + the offline capture outbox
/// (D18). Ports the last mile of Android `core/CaptureWatch.kt`: asset ID
/// → upload bytes.
///
/// - `CaptureAssetLoader.fetchSync` is the production `dataForAsset` for
///   `PhotoLibraryWatch` (`PHImageManager` full-size data; HEIC/HEIF →
///   JPEG, the desktop routes by flag but not every desktop reads HEIC).
/// - `CaptureOutbox` holds staged captures while no computer is linked
///   (M3 `PendingShareStore` semantics: the queue waits for the link —
///   payload bytes are raw TCP, so no background task can finish them
///   suspended). The app flushes it on every link-ready + after each
///   capture; failures surface on the status line, never silently.
/// - `stageTempFile` bridges `Data` captures (photo/document/library) to
///   the `URL` shape `TransferEngine.sendCaptures` serves.

/// Auto-upload switch kinds (ungated, for the UI layer — the app maps
/// these onto `PhotoLibraryWatch.UploadKind`, which is Photos-gated).
public enum CaptureAutoKind: String, Sendable, CaseIterable {
    case screenshot
    case photo
}

/// Persisted auto-upload switches (`WebcamPreferences` parity — caps
/// excluded there, authorization excluded here: a stored ON still needs a
/// full-access grant at enable time, Limited access keeps manual only).
public enum CapturePrefs {
    private static let shotsKey = "org.omarchy.flux.capture.auto.screenshots"
    private static let photosKey = "org.omarchy.flux.capture.auto.photos"

    public static var screenshotsOn: Bool {
        UserDefaults.standard.bool(forKey: shotsKey)
    }

    public static var photosOn: Bool {
        UserDefaults.standard.bool(forKey: photosKey)
    }

    public static func set(_ kind: CaptureAutoKind, on: Bool) {
        UserDefaults.standard.set(on, forKey: kind == .screenshot ? shotsKey : photosKey)
    }
}

/// Photo-library asset → JPEG/file data (production `dataForAsset`).
public enum CaptureAssetLoader {
    /// HEIC/HEIF Uniform Type Identifiers (upload as JPEG instead).
    public static func needsJPEGTranscode(uti: String?) -> Bool {
        guard let uti else { return false }
        let lower = uti.lowercased()
        return lower.contains("heic") || lower.contains("heif")
    }

    /// Transcodes image data to JPEG (nil when undecodable).
    public static func transcodeToJPEG(_ data: Data) -> Data? {
        #if canImport(CoreImage)
        guard let image = CIImage(data: data) else { return nil }
        return CIContext().jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
        #else
        return nil
        #endif
    }

    /// Resolves an asset ID to upload bytes + filename (nil when missing,
    /// undecodable, or past the timeout). Blocking with a timeout — call
    /// off main (the watch calls from its debounce queue, like
    /// `LinkRunner.sync` never runs on the cooperative pool).
    public static func fetchSync(
        localIdentifier: String, timeout: TimeInterval = 15
    ) -> (data: Data, name: String)? {
        #if canImport(Photos)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "image.jpg"
        var result: (Data, String)?
        let sem = DispatchSemaphore(value: 0)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(
            for: asset, options: options
        ) { data, uti, _, _ in
            defer { sem.signal() }
            guard let data, !data.isEmpty else { return }
            if needsJPEGTranscode(uti: uti) {
                guard let jpeg = transcodeToJPEG(data) else { return }
                result = (jpeg, jpegName(name))
            } else {
                result = (data, name)
            }
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return result
        #else
        return nil
        #endif
    }

    /// Swaps a HEIC/HEIF extension for `.jpg` (transcoded bytes must not
    /// keep the old suffix — desktops route by flag but users read names).
    public static func jpegName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        guard ext == "heic" || ext == "heif" else { return name }
        return url.deletingPathExtension().appendingPathExtension("jpg").lastPathComponent
    }

    /// Stages capture bytes as a file for `sendCaptures` (unique name,
    /// `flux-captures` tmp dir).
    public static func stageTempFile(data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flux-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.isEmpty ? "capture" : name
        var candidate = dir.appendingPathComponent(safe)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = URL(fileURLWithPath: safe).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: safe).pathExtension
            let next = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            i += 1
        }
        try data.write(to: candidate)
        return candidate
    }

    /// Deletes a staged file after delivery (tmp hygiene: without this
    /// every sent capture lingers until the OS purges tmp). Only touches
    /// the `flux-captures` staging dir — never Downloads or the library.
    public static func deleteStaged(path: String) {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent == "flux-captures" else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Offline capture queue: staged file URLs + routing flags waiting for a
/// link. Pure value type (unit-tested); the app owns one and flushes it on
/// every `.paired` + after each capture.
///
/// Kill-proof: the queue persists to `UserDefaults` on every mutation
/// (a SIGKILL between staging and sending — seen on-device 2026-09-28 —
/// must not lose the capture; the staged tmp files outlive the process,
/// and entries whose files vanished are dropped on restore).
public struct CaptureOutbox: Sendable {
    public struct Item: Sendable, Equatable, Codable {
        public var url: URL
        public var scan: Bool
        public var photo: Bool
        public var screenshot: Bool

        public init(url: URL, scan: Bool = false, photo: Bool = false, screenshot: Bool = false) {
            self.url = url
            self.scan = scan
            self.photo = photo
            self.screenshot = screenshot
        }
    }

    private struct Stored: Codable {
        var items: [Item]
    }

    private static let outboxKey = "org.omarchy.flux.capture.outbox"

    private var items: [Item] = []

    public init() {}

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Queues a staged capture (replaces nothing — every tap sends).
    public mutating func enqueue(_ item: Item) {
        items.append(item)
    }

    /// Re-queues a flushed batch the link refused (offline race: the link
    /// died between the presence check and the send).
    public mutating func requeue(_ batch: [Item]) {
        items = batch + items
    }

    /// Takes the whole queue for one send attempt, dropping staged files
    /// the OS already purged (tmp dir).
    public mutating func takeAll() -> [Item] {
        let batch = items.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        items.removeAll()
        return batch
    }

    /// Reads the queue without taking: flushes peek and send, and items
    /// leave only on delivery (see `drop`). A batch taken before its
    /// transfer dies mid-flight is lost forever — peeking is what makes a
    /// link-death retry possible (seen on-device 2026-09-28: two queued
    /// screenshots flushed into a churning link and never arrived, the
    /// ledger already calling them sent).
    public func peek() -> [Item] {
        items.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
    }

    /// Drops delivered items by staged path (matches
    /// `TransferEngine` completion `path`, the local staged file — never
    /// an inbound Downloads path, so receives can't clear uploads).
    public mutating func drop(paths: [String]) {
        let doomed = Set(paths)
        items.removeAll { doomed.contains($0.url.path) }
    }

    /// Persists the queue (call after every mutation).
    public func persist(store: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Stored(items: items)) else { return }
        store.set(data, forKey: Self.outboxKey)
    }

    /// Restores the queue, dropping staged files that vanished (tmp purge
    /// across a reboot) — uploads resume on the next `.paired`.
    public static func restored(store: UserDefaults = .standard) -> CaptureOutbox {
        var box = CaptureOutbox()
        guard let data = store.data(forKey: outboxKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return box }
        box.items = stored.items.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        return box
    }

    /// Clears the persisted ledger (tests).
    public static func forget(store: UserDefaults = .standard) {
        store.removeObject(forKey: outboxKey)
    }
}
