import XCTest
@testable import FluxStream
@testable import FluxProto
@testable import FluxCamera

/// `Pcm` + `MirrorSize` vectors. Ports Android `MicTest` (PCM part) and
/// `ScreenTest` (`fit`/`bitrate`) verbatim.
final class StreamFramingTests: XCTestCase {
    // MARK: - PCM

    func testWritesLittleEndianSamples() {
        let samples: [Int16] = [0x0102, -1, Int16.min, Int16.max]
        XCTAssertEqual(
            Data([0x02, 0x01, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0x7F]),
            Pcm.toLittleEndian(samples, count: 4))
    }

    func testPeakGoesFromSilenceToFullScale() {
        XCTAssertEqual(0, Pcm.peak([Int16](repeating: 0, count: 10), count: 10), accuracy: 0)
        XCTAssertEqual(0.5, Pcm.peak([100, -16384, 20], count: 3), accuracy: 0.001)
        XCTAssertEqual(1, Pcm.peak([Int16.min], count: 1), accuracy: 0)
        XCTAssertEqual(0, Pcm.peak([0, Int16.max], count: 1), accuracy: 0)
    }

    func testSineFixtureIsDeterministic48kMono() {
        let a = Pcm.sine(seconds: 1, rate: 48_000, freq: 440)
        let b = Pcm.sine(seconds: 1, rate: 48_000, freq: 440)
        XCTAssertEqual(96_000, a.count)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(Data(repeating: 0, count: 96_000), a)
    }

    // MARK: - Mirror size

    func testFitKeepsTheShapeUnder1080() {
        let (w, h) = MirrorSize.fit(width: 1080, height: 2340)
        XCTAssertLessThanOrEqual(h, 1080)
        XCTAssertEqual(0, w % 16)
        XCTAssertEqual(0, h % 16)
        XCTAssertEqual(496, w)
        XCTAssertEqual(1072, h)
        let land = MirrorSize.fit(width: 2340, height: 1080)
        XCTAssertEqual(1072, land.0)
        XCTAssertEqual(496, land.1)
        let mid = MirrorSize.fit(width: 720, height: 1280)
        XCTAssertEqual(592, mid.0)
        XCTAssertEqual(1072, mid.1)
        let small = MirrorSize.fit(width: 480, height: 800)
        XCTAssertEqual(480, small.0)
        XCTAssertEqual(800, small.1)
    }

    func testBitrateHasAFloor() {
        XCTAssertEqual(2_000_000, MirrorSize.bitrate(width: 160, height: 160))
        XCTAssertEqual(496 * 1072 * 8, MirrorSize.bitrate(width: 496, height: 1072))
    }

    // MARK: - Fixtures

    func testGoldenNalsMatchAndroidVectors() {
        XCTAssertEqual(Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F]), StreamFixtures.sps)
        XCTAssertEqual(Data([0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80]), StreamFixtures.pps)
    }

    func testVideoStreamIsFramedIdrsWithConfig() {
        let stream = StreamFixtures.videoStream(idrCount: 2, pPerIdr: 1)
        let types = AnnexB.nalTypes(stream)
        // SPS + PPS + IDR, then P (type 1), then SPS + PPS + IDR, then P.
        XCTAssertEqual([7, 8, 5, 1, 7, 8, 5, 1], types)
    }

    func testSha256MatchesKnownVector() {
        XCTAssertEqual(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            StreamFixtures.sha256Hex(Data()))
        // Cross-checks the CryptoKit computation the peer logs.
        XCTAssertEqual(StreamFixtures.sha256Hex(StreamFixtures.sps), StreamFixtures.sha256Hex(StreamFixtures.sps))
    }
}
