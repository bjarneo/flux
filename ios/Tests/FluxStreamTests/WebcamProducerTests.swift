import XCTest
#if canImport(AVFoundation)
@testable import FluxStream
import FluxProto
import FluxCamera
import CoreVideo

/// `WebcamProducer` glue: drain chunks reach the live stream, stop finishes
/// it, a failed start holds nothing, live applies forward, and caps flow
/// through. The drain itself is hardware (`WebcamCapture`); a stub stands
/// in here. The crop math runs on real pixel buffers (no camera needed).
final class WebcamProducerTests: XCTestCase {
    final class StubSource: WebcamChunkSource, @unchecked Sendable {
        private let lock = NSLock()
        var onChunk: ((Data) -> Void)?
        var onError: ((String) -> Void)?
        var started = 0
        var stopped = 0
        var applied: [WebcamConfig] = []
        var error: Error?
        var caps = WebcamCaps.loose

        func start(config: WebcamConfig) throws {
            lock.withLock { started += 1 }
            if let error { throw error }
        }

        func stop() {
            lock.withLock { stopped += 1 }
        }

        func applyLive(_ config: WebcamConfig) {
            lock.withLock { applied.append(config) }
        }

        func currentCaps() -> WebcamCaps {
            lock.withLock { caps }
        }
    }

    struct Boom: Error, Equatable {}

    func testChunksFlow() async throws {
        let stub = StubSource()
        let producer = WebcamProducer(makeSource: { stub })
        let stream = try producer.start(config: WebcamConfig())
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6])]
        for chunk in chunks { stub.onChunk?(chunk) }
        producer.stop()
        var got: [Data] = []
        for await part in stream { got.append(part) }
        XCTAssertEqual(chunks, got)
    }

    func testFailedStartHoldsNothing() {
        let stub = StubSource()
        stub.error = Boom()
        let producer = WebcamProducer(makeSource: { stub })
        XCTAssertThrowsError(try producer.start(config: WebcamConfig())) {
            XCTAssertTrue($0 is Boom)
        }
        // Nothing started, so nothing to stop — and a retry works.
        producer.stop()
        let retry = StubSource()
        let retrying = WebcamProducer(makeSource: { retry })
        XCTAssertNotNil(try? retrying.start(config: WebcamConfig()))
        retrying.stop()
        XCTAssertEqual(1, retry.stopped)
    }

    func testRestartStopsFirst() async {
        let stub = StubSource()
        let producer = WebcamProducer(makeSource: { stub })
        let first = try? producer.start(config: WebcamConfig())
        stub.onChunk?(Data([1]))
        let second = try? producer.start(config: WebcamConfig())
        XCTAssertNotNil(second)
        var firstParts: [Data] = []
        if let first {
            for await part in first { firstParts.append(part) }
        }
        XCTAssertEqual([Data([1])], firstParts)
        producer.stop()
        XCTAssertEqual(2, stub.stopped)
    }

    func testApplyLiveForwardsToRunningSource() throws {
        let stub = StubSource()
        let producer = WebcamProducer(makeSource: { stub })
        // Idle: forwarded nowhere (no source), and never crashes.
        producer.applyLive(WebcamConfig(zoom: 2))
        _ = try producer.start(config: WebcamConfig())
        let next = WebcamConfig(zoom: 2)
        producer.applyLive(next)
        XCTAssertEqual([next], stub.applied)
        producer.stop()
    }

    func testCapsAreLooseWhenIdle() {
        let stub = StubSource()
        stub.caps = WebcamCaps(zoomMax: 8)
        let producer = WebcamProducer(makeSource: { stub })
        XCTAssertEqual(.loose, producer.currentCaps())
        _ = try? producer.start(config: WebcamConfig())
        XCTAssertEqual(WebcamCaps(zoomMax: 8), producer.currentCaps())
        producer.stop()
    }

    // MARK: - Crop math (real pixel buffers, no camera)

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
        let buffer = buffer(width: 1280, height: 720) { x, _ in UInt8(x & 0xFF) }
        XCTAssertNotNil(buffer)
        let out = WebcamCapture.frameForEncode(buffer!, config: WebcamConfig())
        XCTAssertTrue(out === buffer)
    }

    func testWideFrameCropsToCenter() {
        // 1280x720 camera frame announcing 4:3/720 (960x720): the crop keeps
        // the centered columns.
        let buffer = buffer(width: 1280, height: 720) { x, _ in UInt8(x & 0xFF) }
        XCTAssertNotNil(buffer)
        let out = WebcamCapture.frameForEncode(
            buffer!, config: WebcamConfig(aspect: "4:3", resolution: 720))
        XCTAssertNotNil(out)
        XCTAssertEqual(960, CVPixelBufferGetWidth(out!))
        XCTAssertEqual(720, CVPixelBufferGetHeight(out!))
        // Offset is ((1280-960)/2) = 160: column 0 of the crop is column 160.
        XCTAssertEqual(UInt8(160), byte(out!, x: 0, y: 0))
        XCTAssertEqual(UInt8((160 + 959) & 0xFF), byte(out!, x: 959, y: 719))
    }

    func testSmallerFrameIsDropped() {
        // A frame smaller than the announced size cannot feed the desktop's
        // fixed virtual camera (no upscale): dropped, not encoded.
        let buffer = buffer(width: 640, height: 480) { _, _ in 7 }
        XCTAssertNotNil(buffer)
        XCTAssertNil(WebcamCapture.frameForEncode(buffer!, config: WebcamConfig()))
    }
}
#endif
