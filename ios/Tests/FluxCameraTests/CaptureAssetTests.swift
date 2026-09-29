import XCTest
import Foundation
#if canImport(CoreImage)
import CoreImage
#endif
@testable import FluxCamera

/// D15/D18 capture seams: result gates, asset UTI mapping, staging, the
/// offline outbox, and persisted switches. Live drains need hardware; the
/// mapping helpers they call are covered in `CapturePipelines` tests.
final class CaptureAssetTests: XCTestCase {
    // MARK: - Result gates (CaptureSessions)

    func testUsableText() {
        XCTAssertFalse(usableText(""))
        XCTAssertFalse(usableText("   \n  "))
        XCTAssertFalse(usableText("ab"))
        XCTAssertTrue(usableText("abc"))
        XCTAssertTrue(usableText("  hello world  "))
    }

    func testCodeIsLink() {
        XCTAssertTrue(codeIsLink("https://omarchy.org/flux"))
        XCTAssertTrue(codeIsLink("  ftp://host/x  "))
        XCTAssertTrue(codeIsLink("WIFI:S:x;T:WPA;P:y;;") == false)
        XCTAssertFalse(codeIsLink("hello"))
        XCTAssertFalse(codeIsLink(""))
    }

    // MARK: - Asset UTI mapping (CaptureAssetLoader)

    func testNeedsJPEGTranscode() {
        XCTAssertTrue(CaptureAssetLoader.needsJPEGTranscode(uti: "public.heic"))
        XCTAssertTrue(CaptureAssetLoader.needsJPEGTranscode(uti: "public.heif"))
        XCTAssertTrue(CaptureAssetLoader.needsJPEGTranscode(uti: "PUBLIC.HEIC"))
        XCTAssertFalse(CaptureAssetLoader.needsJPEGTranscode(uti: "public.jpeg"))
        XCTAssertFalse(CaptureAssetLoader.needsJPEGTranscode(uti: "public.png"))
        XCTAssertFalse(CaptureAssetLoader.needsJPEGTranscode(uti: nil))
    }

    func testJpegName() {
        XCTAssertEqual("a.jpg", CaptureAssetLoader.jpegName("a.heic"))
        XCTAssertEqual("a.jpg", CaptureAssetLoader.jpegName("a.HEIF"))
        XCTAssertEqual("a.jpg", CaptureAssetLoader.jpegName("a.jpg"))
        XCTAssertEqual("a.png", CaptureAssetLoader.jpegName("a.png"))
    }

    func testTranscodeToJPEG() throws {
        #if canImport(CoreImage)
        // Garbage is not an image.
        XCTAssertNil(CaptureAssetLoader.transcodeToJPEG(Data([0, 1, 2, 3])))
        // A real JPEG round-trips to JPEG (SOI marker).
        let image = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let jpeg = try XCTUnwrap(CIContext().jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]))
        let out = try XCTUnwrap(CaptureAssetLoader.transcodeToJPEG(jpeg))
        XCTAssertEqual(0xFF, out[out.startIndex])
        XCTAssertEqual(0xD8, out[out.index(after: out.startIndex)])
        #else
        XCTAssertNil(CaptureAssetLoader.transcodeToJPEG(Data([0, 1, 2, 3])))
        #endif
    }

    // MARK: - Staging (CaptureAssetLoader.stageTempFile)

    func testStageTempFileUniquifies() throws {
        let data = Data("capture".utf8)
        let first = try CaptureAssetLoader.stageTempFile(data: data, name: "IMG_x.jpg")
        let second = try CaptureAssetLoader.stageTempFile(data: data, name: "IMG_x.jpg")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(data, try Data(contentsOf: first))
        XCTAssertEqual(data, try Data(contentsOf: second))
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    // MARK: - Offline outbox (CaptureOutbox)

    private func stagedFile(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testOutboxEnqueueTakeAll() throws {
        var box = CaptureOutbox()
        XCTAssertTrue(box.isEmpty)
        let a = try stagedFile(named: "a.jpg")
        let b = try stagedFile(named: "b.pdf")
        box.enqueue(CaptureOutbox.Item(url: a, photo: true))
        box.enqueue(CaptureOutbox.Item(url: b, scan: true))
        XCTAssertEqual(2, box.count)
        let batch = box.takeAll()
        XCTAssertEqual(2, batch.count)
        XCTAssertEqual(a, batch[0].url)
        XCTAssertTrue(batch[0].photo)
        XCTAssertTrue(batch[1].scan)
        XCTAssertTrue(box.isEmpty)
        XCTAssertTrue(box.takeAll().isEmpty)
    }

    func testOutboxDropsPurgedFiles() throws {
        var box = CaptureOutbox()
        let live = try stagedFile(named: "live.jpg")
        let gone = live.deletingLastPathComponent().appendingPathComponent("gone.jpg")
        box.enqueue(CaptureOutbox.Item(url: live, photo: true))
        box.enqueue(CaptureOutbox.Item(url: gone, photo: true))
        let batch = box.takeAll()
        XCTAssertEqual([live], batch.map(\.url))
    }

    func testOutboxRequeuePrepends() throws {
        var box = CaptureOutbox()
        let a = try stagedFile(named: "a.jpg")
        let b = try stagedFile(named: "b.jpg")
        let c = try stagedFile(named: "c.jpg")
        box.enqueue(CaptureOutbox.Item(url: c, photo: true))
        box.requeue([CaptureOutbox.Item(url: a, photo: true),
                     CaptureOutbox.Item(url: b, photo: true)])
        XCTAssertEqual([a, b, c], box.takeAll().map(\.url))
    }

    func testOutboxPeekLeavesQueue() throws {
        // Delivery-tracked flushes peek (a taken batch dying mid-flight
        // is lost forever — seen on-device 2026-09-28): peeking twice
        // returns the same items, and the queue survives.
        var box = CaptureOutbox()
        let a = try stagedFile(named: "a.jpg")
        let b = try stagedFile(named: "b.pdf")
        box.enqueue(CaptureOutbox.Item(url: a, photo: true))
        box.enqueue(CaptureOutbox.Item(url: b, scan: true))
        XCTAssertEqual([a, b], box.peek().map(\.url))
        XCTAssertEqual([a, b], box.peek().map(\.url))
        XCTAssertEqual(2, box.count)
    }

    func testOutboxDropRemovesDeliveredPathsOnly() throws {
        var box = CaptureOutbox()
        let a = try stagedFile(named: "a.jpg")
        let b = try stagedFile(named: "b.jpg")
        box.enqueue(CaptureOutbox.Item(url: a, screenshot: true))
        box.enqueue(CaptureOutbox.Item(url: b, screenshot: true))
        // An inbound Downloads path never matches a staged upload.
        let inbound = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/a.jpg").path
        box.drop(paths: [inbound])
        XCTAssertEqual(2, box.count)
        box.drop(paths: [a.path])
        XCTAssertEqual([b], box.peek().map(\.url))
    }

    func testDeleteStagedOnlyTouchesStagingDir() throws {
        let staged = try CaptureAssetLoader.stageTempFile(
            data: Data("x".utf8), name: "todelete-\(UUID().uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        CaptureAssetLoader.deleteStaged(path: staged.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // Anything outside flux-captures is left alone.
        let outside = try stagedFile(named: "keep.jpg")
        CaptureAssetLoader.deleteStaged(path: outside.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testOutboxPersistsAcrossKill() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "flux-capture-outbox-tests"))
        store.removePersistentDomain(forName: "flux-capture-outbox-tests")
        defer { store.removePersistentDomain(forName: "flux-capture-outbox-tests") }
        CaptureOutbox.forget(store: store)
        XCTAssertTrue(CaptureOutbox.restored(store: store).isEmpty)

        var box = CaptureOutbox.restored(store: store)
        let a = try stagedFile(named: "a.jpg")
        let gone = a.deletingLastPathComponent().appendingPathComponent("gone.jpg")
        box.enqueue(CaptureOutbox.Item(url: a, scan: true))
        box.enqueue(CaptureOutbox.Item(url: gone, scan: true))
        box.persist(store: store)

        // A fresh process restores the queue minus the vanished file.
        var revived = CaptureOutbox.restored(store: store)
        XCTAssertEqual(1, revived.count)
        // Flushing clears the ledger.
        XCTAssertEqual([a], revived.takeAll().map(\.url))
        revived.persist(store: store)
        XCTAssertTrue(CaptureOutbox.restored(store: store).isEmpty)
    }

    // MARK: - Persisted switches (CapturePrefs)

    func testCapturePrefsRoundTrip() {
        let priorShots = CapturePrefs.screenshotsOn
        let priorPhotos = CapturePrefs.photosOn
        defer {
            CapturePrefs.set(.screenshot, on: priorShots)
            CapturePrefs.set(.photo, on: priorPhotos)
        }
        CapturePrefs.set(.screenshot, on: true)
        CapturePrefs.set(.photo, on: false)
        XCTAssertTrue(CapturePrefs.screenshotsOn)
        XCTAssertFalse(CapturePrefs.photosOn)
        CapturePrefs.set(.screenshot, on: false)
        CapturePrefs.set(.photo, on: true)
        XCTAssertFalse(CapturePrefs.screenshotsOn)
        XCTAssertTrue(CapturePrefs.photosOn)
    }
}
