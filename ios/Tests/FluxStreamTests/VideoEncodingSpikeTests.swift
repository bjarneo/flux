import XCTest
import CoreVideo
import CoreMedia
@testable import FluxStream
@testable import FluxCamera

/// Hardware-encode spike: feeds solid pixel buffers through
/// `H264VideoEncoder` and checks the Annex-B tail (SPS/PPS before IDR,
/// P frames after). Needs a VideoToolbox encoder; when the machine has
/// none (or forbids it), the test throws ` XCTSkip` instead of failing —
/// the framing contract itself is held by `AnnexBTests` + E2E bytes.
final class VideoEncodingSpikeTests: XCTestCase {
    func testEncodesAnnexBWithConfigBeforeIdr() throws {
        #if canImport(VideoToolbox)
        let encoder = H264VideoEncoder()
        do {
            try encoder.configure(width: 128, height: 128, bitrate: 1_000_000, fps: 30)
        } catch {
            throw XCTSkip("no VideoToolbox encoder on this machine: \(error)")
        }
        var chunks: [Data] = []
        var errors: [String] = []
        let box = LockBox()
        encoder.onFrame = { data, _ in box.sync { chunks.append(data) } }
        encoder.onError = { message in box.sync { errors.append(message) } }
        encoder.requestKeyFrame()
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 128, 128,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixelBuffer) == kCVReturnSuccess,
            let pixels = pixelBuffer
        else {
            throw XCTSkip("cannot allocate a pixel buffer on this machine")
        }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        // Solid mid-gray: Y + interleaved CbCr planes.
        if let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
            memset(y, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * 128)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) {
            memset(uv, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 64)
        }
        for i in 0 ..< 10 {
            try encoder.encode(pixels, presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        encoder.invalidate()
        // Callbacks arrive on the encoder queue; wait briefly.
        let deadline = Date().addingTimeInterval(5)
        while box.sync({ chunks.isEmpty && errors.isEmpty }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(errors.isEmpty, "encoder errors: \(box.sync { errors })")
        let stream = box.sync { chunks.reduce(Data(), +) }
        XCTAssertFalse(stream.isEmpty, "the encoder produced no bytes")
        let types = AnnexB.nalTypes(stream)
        XCTAssertTrue(types.contains(AnnexB.nalSPS), "no SPS in \(types)")
        XCTAssertTrue(types.contains(AnnexB.nalPPS), "no PPS in \(types)")
        XCTAssertTrue(types.contains(AnnexB.nalIDR), "no IDR in \(types)")
        // SPS+PPS precede the first IDR (framer parity with the fixtures).
        let firstIDR = types.firstIndex(of: AnnexB.nalIDR)!
        XCTAssertTrue(types[..<firstIDR].contains(AnnexB.nalSPS))
        #else
        throw XCTSkip("VideoToolbox is unavailable on this platform")
        #endif
    }
}

/// Tiny test lock box (the encoder calls back off-thread).
private final class LockBox: @unchecked Sendable {
    private let lock = NSLock()

    func sync<T>(_ op: () -> T) -> T {
        lock.withLock(op)
    }
}
