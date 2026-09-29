import XCTest
@testable import FluxStream
import CoreVideo

/// `ScreenProducer` glue + frame sizing: drain chunks reach the live
/// stream, stop finishes it, a failed start holds nothing, the announced
/// size fits the screen (H.264-safe), and mismatched frames scale to it.
/// The recorder itself is iOS hardware (`ScreenCapture`); a stub stands in
/// here. The size/scale math runs on real pixel buffers (no phone needed).
final class ScreenProducerTests: XCTestCase {
    final class StubSource: ScreenChunkSource, @unchecked Sendable {
        private let lock = NSLock()
        var onChunk: ((Data) -> Void)?
        var onError: ((String) -> Void)?
        var started = 0
        var stopped = 0
        var sizes: [(Int, Int, Int)] = []
        var error: Error?

        func start(width: Int, height: Int, bitrate: Int) throws {
            lock.withLock {
                started += 1
                sizes.append((width, height, bitrate))
            }
            if let error { throw error }
        }

        func stop() {
            lock.withLock { stopped += 1 }
        }
    }

    struct Boom: Error, Equatable {}

    private func start(width: Int = 592, height: Int = 1072) throws -> (ScreenProducer, StubSource, AsyncStream<Data>) {
        let stub = StubSource()
        let producer = ScreenProducer(makeSource: { stub })
        let stream = try producer.start(width: width, height: height, bitrate: MirrorScreenSize.bitrate(width: width, height: height))
        return (producer, stub, stream)
    }

    func testChunksFlow() async throws {
        let (producer, stub, stream) = try start()
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6])]
        for chunk in chunks { stub.onChunk?(chunk) }
        producer.stop()
        var got: [Data] = []
        for await part in stream { got.append(part) }
        XCTAssertEqual(chunks, got)
        XCTAssertEqual(1, stub.sizes.count)
        XCTAssertEqual(592, stub.sizes[0].0)
        XCTAssertEqual(1072, stub.sizes[0].1)
        XCTAssertEqual(MirrorScreenSize.bitrate(width: 592, height: 1072), stub.sizes[0].2)
    }

    func testFailedStartHoldsNothing() {
        let stub = StubSource()
        stub.error = Boom()
        let producer = ScreenProducer(makeSource: { stub })
        XCTAssertThrowsError(try producer.start(width: 592, height: 1072, bitrate: 100)) {
            XCTAssertTrue($0 is Boom)
        }
        // Nothing started, so nothing to stop — and a retry works.
        producer.stop()
        let retry = StubSource()
        let retrying = ScreenProducer(makeSource: { retry })
        XCTAssertNotNil(try? retrying.start(width: 592, height: 1072, bitrate: 100))
        retrying.stop()
        XCTAssertEqual(1, retry.stopped)
    }

    func testRestartStopsFirst() async {
        let stub = StubSource()
        let producer = ScreenProducer(makeSource: { stub })
        let first = try? producer.start(width: 592, height: 1072, bitrate: 100)
        stub.onChunk?(Data([1]))
        let second = try? producer.start(width: 592, height: 1072, bitrate: 100)
        XCTAssertNotNil(second)
        var firstParts: [Data] = []
        if let first {
            for await part in first { firstParts.append(part) }
        }
        XCTAssertEqual([Data([1])], firstParts)
        producer.stop()
        XCTAssertEqual(2, stub.stopped)
    }

    func testDefaultSourceMatchesPlatform() {
        #if os(iOS) && canImport(ReplayKit)
        XCTAssertTrue(ScreenProducer.defaultSource() is ScreenCapture)
        #else
        XCTAssertTrue(ScreenProducer.defaultSource() is UnsupportedScreenCapture)
        XCTAssertThrowsError(try ScreenProducer.defaultSource().start(width: 1, height: 1, bitrate: 1)) {
            XCTAssertEqual($0 as? ScreenCaptureError, .unsupported("Screen mirror needs an iPhone."))
        }
        #endif
    }

    // MARK: - Announced size (pure math, every platform)

    func testPhonePortraitFitsLongSide() {
        // iPhone SE2 native pixels 750x1334 → same shape, long side ≤1080,
        // 16-aligned (H.264-safe).
        let (w, h) = MirrorScreenSize.announce(nativeWidth: 750, nativeHeight: 1334)
        XCTAssertEqual(592, w)
        XCTAssertEqual(1072, h)
        XCTAssertLessThanOrEqual(max(w, h), MirrorSize.maxLong)
        XCTAssertEqual(0, w % 2)
        XCTAssertEqual(0, h % 2)
    }

    func testLandscapeStaysLandscape() {
        let (w, h) = MirrorScreenSize.announce(nativeWidth: 1280, nativeHeight: 720)
        XCTAssertEqual(1072, w)
        XCTAssertEqual(592, h)
    }

    func testSmallScreenIsNotUpscaled() {
        // At or under the cap the size passes through (aligned down).
        let (w, h) = MirrorScreenSize.announce(nativeWidth: 640, nativeHeight: 480)
        XCTAssertEqual(640, w)
        XCTAssertEqual(480, h)
    }

    // MARK: - Scale math (real pixel buffers, no recorder)

    private func buffer(width: Int, height: Int, fill: (Int, Int) -> UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
            let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base.advanced(by: y * rowBytes + x * 4)
                pixel.storeBytes(of: fill(x, y), as: UInt8.self)
                pixel.advanced(by: 3).storeBytes(of: 0xFF, as: UInt8.self)
            }
        }
        return buffer
    }

    private func byte(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return base.advanced(by: y * rowBytes + x * 4).load(as: UInt8.self)
    }

    func testMatchingFramePassesThrough() {
        let buffer = buffer(width: 592, height: 1072) { x, _ in UInt8(x & 0xFF) }
        XCTAssertNotNil(buffer)
        let out = ScreenScaler.frameForEncode(buffer!, width: 592, height: 1072)
        XCTAssertTrue(out === buffer)
    }

    func testLargerFrameScalesToAnnounced() {
        // 750x1334 native frame announcing the (592, 1072) fit: exact size
        // out, content mapped across (top-left stays top-left).
        let buffer = buffer(width: 750, height: 1334) { x, y in UInt8((x + y) & 0xFF) }
        XCTAssertNotNil(buffer)
        let out = ScreenScaler.frameForEncode(buffer!, width: 592, height: 1072)
        XCTAssertNotNil(out)
        XCTAssertEqual(592, CVPixelBufferGetWidth(out!))
        XCTAssertEqual(1072, CVPixelBufferGetHeight(out!))
        XCTAssertEqual(byte(buffer!, x: 0, y: 0), byte(out!, x: 0, y: 0))
    }

    func testRotatedFrameStillFitsAnnounced() {
        // A rotation mid-stream swaps the frame shape; the scale absorbs
        // it — the desktop window stays fixed at the announced size.
        let buffer = buffer(width: 1072, height: 592) { _, _ in 9 }
        XCTAssertNotNil(buffer)
        let out = ScreenScaler.frameForEncode(buffer!, width: 592, height: 1072)
        XCTAssertNotNil(out)
        XCTAssertEqual(592, CVPixelBufferGetWidth(out!))
        XCTAssertEqual(1072, CVPixelBufferGetHeight(out!))
    }

    func testDegenerateSizeIsDropped() {
        let buffer = buffer(width: 64, height: 64) { _, _ in 7 }
        XCTAssertNotNil(buffer)
        XCTAssertNil(ScreenScaler.scaled(buffer!, toWidth: 0, toHeight: 64))
        XCTAssertNil(ScreenScaler.scaled(buffer!, toWidth: 64, toHeight: 0))
    }
}
