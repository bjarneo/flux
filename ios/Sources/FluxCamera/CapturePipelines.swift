import Foundation
import FluxProto
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(Photos)
import Photos
#endif

/// Camera-mode pipelines. Ports of Android `camera/` (`TextMode`,
/// `QrMode`, `PhotoMode`, `DocumentMode`) + `scan/TextReader.kt` to
/// `AVFoundation` + `Vision` + `VisionKit`.
///
/// What runs where:
/// - Text: `VNRecognizeTextRequest` (on-device, `.accurate`) →
///   `TextAssembly` grouping → `share.request` `text`+`scan` (desktop
///   `saveScan` lands it in `scan_dir`).
/// - QR/barcode: `VNDetectBarcodesRequest` (stills) + live
///   `AVCaptureMetadataOutput` → `Codes` sheet → `ShareBody` fields.
/// - Photo: `AVCapturePhotoOutput` (HEIC/JPEG) → `share.request`
///   `photo:true` + payload (desktop `photo_dir`).
/// - Document: `VisionKit VNDocumentCameraViewController` (iOS only) →
///   PDF/JPEG → `share.request` `scan:true` + payload (`scan_dir`).
/// - Auto-upload: `PhotoLibraryWatch` (`PHPhotoLibraryChangeObserver` +
///   sent-`localIdentifier` ledger, Android `CaptureWatch` parity).
///
/// The mapping helpers below (no camera needed) are unit-tested;
/// capture sessions need hardware (see the M5 section of `ios/README.md`).

// MARK: - Text (VNRecognizeTextRequest → ScanBlock)

#if canImport(Vision)
/// Text recognition: Vision observations grouped into plain text.
public enum TextRecognition {
    /// Maps one Vision line observation to a single-line block in
    /// top-left-origin pixels. Vision exposes lines (not paragraphs), so
    /// each observation becomes one block and `TextAssembly` recovers the
    /// reading order across them.
    public static func block(from observation: VNRecognizedTextObservation, imageWidth: Int, imageHeight: Int) -> ScanBlock? {
        guard let line = try? observation.topCandidates(1).first?.string,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let b = observation.boundingBox
        let left = Int(b.minX * Double(imageWidth))
        let top = Int((1 - b.maxY) * Double(imageHeight))
        let right = Int(b.maxX * Double(imageWidth))
        let bottom = Int((1 - b.minY) * Double(imageHeight))
        let box = ScanBox(left: left, top: top, right: right, bottom: bottom)
        return ScanBlock(lines: [ScanLine(line, box: box)], box: box)
    }

    /// Builds an on-device accurate text request. The handler converts the
    /// observations with `block(from:imageWidth:imageHeight:)` and assembles
    /// them with `TextAssembly.assemble`.
    public static func request(
        imageWidth: Int, imageHeight: Int,
        completion: @escaping (String) -> Void
    ) -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest { req, _ in
            let blocks = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap {
                block(from: $0, imageWidth: imageWidth, imageHeight: imageHeight)
            }
            completion(TextAssembly.assemble(blocks))
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        return req
    }
}
#endif

// MARK: - Codes (symbology mapping)

#if canImport(Vision)
/// Barcode symbology mapping: Vision + live metadata outputs to the
/// recognizer-independent `CodeFormat`.
public enum CodeDetection {
    /// Maps a Vision symbology to a `CodeFormat` (unknown → `.unknown`).
    public static func format(of symbology: VNBarcodeSymbology) -> CodeFormat {
        switch symbology {
        case .qr: return .qrCode
        case .aztec: return .aztec
        case .pdf417: return .pdf417
        case .dataMatrix: return .dataMatrix
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .upce: return .upcE
        case .code128: return .code128
        case .code39: return .code39
        case .code93: return .code93
        case .codabar: return .codabar
        case .itf14: return .itf
        default: return .unknown
        }
    }

    /// Maps a Vision observation to a `ScannedCode`. Vision reports the raw
    /// string only (no typed Wi-Fi/contact values like ML Kit), so `url` is
    /// set when the raw value is a link and structured fields stay nil —
    /// `Codes.kind` still classifies `WIFI:`/`VCARD` prefixes from `raw`.
    public static func code(from observation: VNBarcodeObservation) -> ScannedCode? {
        guard let raw = observation.payloadStringValue, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLink = trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$", options: .regularExpression) != nil
        return ScannedCode(format: format(of: observation.symbology), raw: raw, url: isLink ? trimmed : nil)
    }
}
#endif

#if canImport(AVFoundation)
/// Live metadata-output mapping (`AVCaptureMetadataOutput` object types to
/// `CodeFormat`). The union mirrors `VNDetectBarcodesRequest` coverage
/// (QR, Aztec, Code128, EAN, PDF417, …).
public enum LiveCodeDetection {
    public static func format(of type: AVMetadataObject.ObjectType) -> CodeFormat {
        switch type {
        case .qr: return .qrCode
        case .aztec: return .aztec
        case .pdf417: return .pdf417
        case .dataMatrix: return .dataMatrix
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .upce: return .upcE
        case .code128: return .code128
        case .code39: return .code39
        case .code93: return .code93
        case .codabar: return .codabar
        case .itf14: return .itf
        default: return .unknown
        }
    }
}
#endif

// MARK: - Photo (AVCapturePhotoOutput)

#if canImport(AVFoundation)
/// Still-photo capture. `photo_dir` routing rides the `photo:true` share
/// flag (Go `handleShare` → `destPhoto`); the format only affects bytes.
public enum PhotoCapture {
    /// Photo settings: HEIC when the device encodes it and the user keeps
    /// it, JPEG otherwise (compat note: the desktop routes by flag, and
    /// every desktop reads JPEG; HEIC needs a HEIF-capable viewer).
    public static func settings(preferHEIC: Bool, hevcSupported: Bool) -> AVCapturePhotoSettings {
        if preferHEIC, hevcSupported {
            return AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        return AVCapturePhotoSettings()
    }
}
#endif

// MARK: - Document (VisionKit, iOS only)

#if os(iOS)
#if canImport(VisionKit)
import VisionKit
import UIKit

/// Document capture: `VNDocumentCameraViewController` scan → PDF data.
/// iOS only (no macOS equivalent); needs hardware, like every mode here.
///
/// Main-thread-confined by convention (UIKit delegate object; VisionKit
/// calls back on main), deliberately not `@MainActor`: the delegate
/// protocol requirements are nonisolated (first caught by the Xcode
/// simulator build, D7 — SPM macOS builds skip this section).
public final class DocumentScanner: NSObject, VNDocumentCameraViewControllerDelegate {
    public var onScan: ((Data, String) -> Void)?
    public var onCancel: (() -> Void)?

    /// Creates the scanner VC. Main-actor (UIKit); the delegate callbacks
    /// below stay nonisolated to satisfy the protocol.
    @MainActor
    public func viewController() -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = self
        return vc
    }

    public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        // `dismiss` is MainActor in the current SDK; the delegate protocol
        // requirements are nonisolated (D7 Xcode-only isolation rule), so
        // hop — the dismissal is a UI nicety, never load-bearing.
        DispatchQueue.main.async { controller.dismiss(animated: true) }
        onCancel?()
    }

    public func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFinishWith scan: VNDocumentCameraScan
    ) {
        DispatchQueue.main.async { controller.dismiss(animated: true) }
        guard scan.pageCount > 0, let pdf = pdfData(scan: scan) else { return }
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        onScan?(pdf, CaptureNames.document(now))
    }

    private func pdfData(scan: VNDocumentCameraScan) -> Data? {
        let fmt = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: scan.imageOfPage(at: 0).size), format: fmt)
        return renderer.pdfData { ctx in
            for i in 0 ..< scan.pageCount {
                ctx.beginPage()
                scan.imageOfPage(at: i).draw(in: ctx.pdfContextBounds)
            }
        }
    }
}
#endif
#endif

// MARK: - Auto-upload watch (PHPhotoLibraryChangeObserver)

#if canImport(Photos)
/// Sends each new screenshot and camera photo to the connected computers,
/// when its switch is on. Port of Android `core/CaptureWatch.kt`.
///
/// Differences from Android (platform-driven):
/// - Identity is the `localIdentifier` string (no MediaStore integer IDs),
///   persisted in `UserDefaults` (App Group suite when the app sets one).
/// - Folders are photo-library albums: the screenshots smart album maps to
///   `Pictures/Screenshots/` and the camera roll recent-camera assets to
///   `DCIM/Camera/`, so `CaptureRules.kind(of:)` stays the single
///   classifier both platforms share.
/// - Uploads are foreground/queued: while no computer is linked the watch
///   queues (M3 `PendingShareStore` semantics); a link flush calls
///   `flushQueue(_:)`. Payload bytes are raw TCP, so no `BGProcessingTask`
///   can finish them suspended — like M3, the queue waits for the link.
/// - HEIC compat: assets upload as JPEG (`PHImageRequestOptions` +
///   `CIFilter` chain in the app layer) unless the asset already is JPEG;
///   the desktop routes by flag, not by UTI.
public final class PhotoLibraryWatch: NSObject, PHPhotoLibraryChangeObserver {
    public enum UploadKind: String, Sendable {
        case screenshot, photo
    }

    /// One queued capture: asset ID + kind + display name.
    public struct QueuedCapture: Sendable, Equatable {
        public var localIdentifier: String
        public var kind: UploadKind
        public var name: String
    }

    private static let sentKey = "org.omarchy.flux.capture.sent"
    private static let sinceKey = "org.omarchy.flux.capture.since"

    private let store: UserDefaults
    private let lock = NSLock()
    private var observing = false
    private var debounce: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "org.omarchy.flux.capture")

    /// Kinds currently watched (both switches from Settings).
    public var screenshotsOn = false
    public var photosOn = false

    /// Called for each capture to upload: JPEG/file data, filename, and
    /// the share flags (`photo:true` always; `screenshot:true` for shots,
    /// so older `fluxd` still saves them as photos — Android parity).
    public var onCapture: ((Data, String, [(String, Any?)]) -> Void)?

    /// Resolves an asset ID to JPEG/file data for upload (the app injects
    /// the `PHImageManager` request; the harness injects test bytes).
    public var dataForAsset: ((String) -> (data: Data, name: String)?)?

    /// Diagnostic sink (the app sets `print`-with-`flux:`-prefix): scan
    /// summaries + skip reasons. The watch is silent by default, which
    /// made one device round undiagnosable (switches on, nothing
    /// uploaded, no line anywhere) — every skip path below logs.
    public var log: ((String) -> Void)?

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    /// Starts or stops the observer to match the switches (Android
    /// `CaptureWatch.refresh` parity). Enabling a kind seeds `since` at
    /// now, so older images never go out (Android `setKind` parity).
    public func refresh() {
        let on = screenshotsOn || photosOn
        lock.withLock {
            if on, !observing {
                PHPhotoLibrary.shared().register(self)
                observing = true
                seedSinceLocked()
                log?("watch: observing (screenshots=\(screenshotsOn) photos=\(photosOn))")
            } else if !on, observing {
                PHPhotoLibrary.shared().unregisterChangeObserver(self)
                observing = false
                log?("watch: stopped")
            }
        }
        if on { poke() }
    }

    public func photoLibraryDidChange(_ change: PHChange) {
        poke()
    }

    /// Scans soon (1.5 s debounce, Android `SCAN_DELAY_MS` parity).
    public func poke() {
        debounceQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.debounce?.cancel() }
            let item = DispatchWorkItem { [weak self] in self?.scanNow() }
            self.lock.withLock { self.debounce = item }
            self.debounceQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }

    /// Turns a kind on or off. Enabling seeds the baseline at the newest
    /// asset now, so the gap before the switch never uploads.
    public func setKind(_ kind: UploadKind, on: Bool) {
        lock.withLock {
            switch kind {
            case .screenshot: screenshotsOn = on
            case .photo: photosOn = on
            }
            if on { seedSinceLocked() }
        }
        refresh()
    }

    // MARK: - Ledger (sent localIdentifiers + per-kind baseline)

    private func seedSinceLocked() {
        var since = (store.dictionary(forKey: Self.sinceKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        if screenshotsOn, since["screenshot"] == nil { since["screenshot"] = now }
        if photosOn, since["photo"] == nil { since["photo"] = now }
        store.set(since, forKey: Self.sinceKey)
    }

    /// Records an asset as sent (idempotent).
    public func markSent(_ id: String) {
        lock.withLock {
            var sent = Set(store.stringArray(forKey: Self.sentKey) ?? [])
            sent.insert(id)
            // Cap the ledger like Android MAX_SENT.
            store.set(Array(sent.suffix(maxSentIDs)), forKey: Self.sentKey)
        }
    }

    public func isSent(_ id: String) -> Bool {
        lock.withLock { Set(store.stringArray(forKey: Self.sentKey) ?? []).contains(id) }
    }

    // MARK: - Scan

    private func scanNow() {
        guard screenshotsOn || photosOn else { return }
        let since = store.dictionary(forKey: Self.sinceKey) as? [String: Double] ?? [:]
        // Album membership once per scan, not once per asset: the old
        // shape re-fetched whole albums inside the per-asset loop
        // (quadratic — on a real-size library the first scan never
        // finished, and the end-of-scan summary never printed).
        let screenshotIDs = screenshotsOn ? ids(in: .smartAlbumScreenshots) : []
        var sent: [QueuedCapture] = []
        var skippedSent = 0
        // Screenshots: the screenshots album, newer than the baseline.
        if screenshotsOn, let after = sinceDate(since["screenshot"]) {
            for asset in assets(in: .smartAlbumScreenshots, after: after) {
                guard !isSent(asset.localIdentifier) else { skippedSent += 1; continue }
                sent.append(QueuedCapture(
                    localIdentifier: asset.localIdentifier, kind: .screenshot,
                    name: asset.value(forKey: "filename") as? String ?? "image.jpg"))
            }
        }
        // Camera photos: the user library minus screenshots (exclusive —
        // screenshots live in the user library too, but they upload once
        // with the `screenshot` flag, Android folder parity), newer than
        // the baseline.
        if photosOn, let after = sinceDate(since["photo"]) {
            for asset in assets(in: .smartAlbumUserLibrary, after: after) {
                guard !screenshotIDs.contains(asset.localIdentifier) else { continue }
                guard !isSent(asset.localIdentifier) else { skippedSent += 1; continue }
                sent.append(QueuedCapture(
                    localIdentifier: asset.localIdentifier, kind: .photo,
                    name: asset.value(forKey: "filename") as? String ?? "image.jpg"))
            }
        }
        var unresolved = 0
        for item in sent {
            guard let data = dataForAsset?(item.localIdentifier) else {
                unresolved += 1
                continue
            }
            var flags: [(String, Any?)] = [("photo", true)]
            if item.kind == .screenshot { flags.append(("screenshot", true)) }
            onCapture?(data.data, data.name.isEmpty ? item.name : data.name, flags)
            markSent(item.localIdentifier)
        }
        log?("watch: scan found=\(sent.count) uploaded=\(sent.count - unresolved) " +
            "unresolved=\(unresolved) sent=\(skippedSent)")
    }

    /// Baseline as a `PHFetchOptions` predicate date (nil = kind never
    /// enabled — nothing is newer than "never", so skip the fetch).
    private func sinceDate(_ stamp: Double?) -> Date? {
        guard let stamp else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    /// Assets in one smart album newer than `after` (Photos does the
    /// filtering — the scan stays proportional to new arrivals, not to
    /// library size).
    private func assets(
        in subtype: PHAssetCollectionSubtype, after: Date
    ) -> [PHAsset] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
        var out: [PHAsset] = []
        collections.enumerateObjects { collection, _, _ in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "creationDate > %@", after as NSDate)
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            assets.enumerateObjects { asset, _, _ in out.append(asset) }
        }
        return out
    }

    /// The full membership of one smart album (for the screenshot
    /// exclusion — one enumeration per scan, not per asset).
    private func ids(in subtype: PHAssetCollectionSubtype) -> Set<String> {
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
        var out = Set<String>()
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in out.insert(asset.localIdentifier) }
        }
        return out
    }
}
#endif
