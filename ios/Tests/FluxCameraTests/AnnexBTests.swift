import XCTest
@testable import FluxCamera

/// Annex-B golden-frame tests. Ports the `AnnexB`/`AnnexBFramer` vectors of
/// Android `WebcamTest` byte-for-byte (same SPS/PPS/IDR/P fixtures), so the
/// desktop `ffmpeg -f h264` path joins the iOS stream at any IDR.
final class AnnexBTests: XCTestCase {
    private let sps = Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F])
    private let pps = Data([0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0, 0, 0, 1, 0x65, 0x11, 0x22])
    private let pframe = Data([0, 0, 0, 1, 0x41, 0x33, 0x44])

    func testFindsNalTypes() {
        XCTAssertEqual([7, 8, 5], AnnexB.nalTypes(sps + pps + idr))
        XCTAssertEqual([1], AnnexB.nalTypes(Data([0, 0, 1, 0x41, 0x01])))
    }

    func testAddsMissingStartCode() {
        XCTAssertEqual(idr, AnnexB.withStartCode(Data([0x65, 0x11, 0x22])))
        XCTAssertEqual(idr, AnnexB.withStartCode(idr))
    }

    func testFramerPutsConfigBeforeEachIdr() {
        let f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(sps + pps + idr, f.onFrame(idr, keyFrame: true))
        XCTAssertEqual(pframe, f.onFrame(pframe, keyFrame: false))
        XCTAssertEqual(sps + pps + idr, f.onFrame(idr, keyFrame: true))
    }

    func testFramerDropsFramesBeforeTheFirstIdr() {
        let f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertNil(f.onFrame(pframe, keyFrame: false))
        XCTAssertEqual(sps + pps + idr, f.onFrame(idr, keyFrame: true))
    }

    func testFramerDoesNotRepeatConfigThatTheFrameHas() {
        let f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(sps + pps + idr, f.onFrame(sps + pps + idr, keyFrame: true))
    }

    func testFramerFindsIdrWithoutTheKeyFlag() {
        let f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(sps + pps + idr, f.onFrame(idr, keyFrame: false))
    }
}
