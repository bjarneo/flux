import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import FluxKit

@MainActor
final class DesktopTests: XCTestCase {
    private func roundTrip(_ p: Packet) throws -> Packet { try XCTUnwrap(Packet.parse(p.serialize())) }

    private func frames(_ list: [(UInt8, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for (flags, data) in list {
            let n = UInt32(data.count)
            out += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), flags]
            out += data
        }
        return out
    }

    private let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x32]
    private let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0xEE, 0x3C]

    func testCapabilityIsInBothLists() {
        let plugin = DesktopPlugin()
        XCTAssertEqual(plugin.incoming, ["flux.desktop", "flux.shortcuts"])
        XCTAssertEqual(plugin.outgoing, ["flux.desktop", "flux.shortcuts"])
    }

    func testStartBody() throws {
        let p = try roundTrip(DesktopPackets.start(port: 1742))
        XCTAssertEqual(p.type, PacketType.fluxDesktop)
        XCTAssertEqual(p.string("state"), "start")
        XCTAssertEqual(p.int("port"), 1742)
        XCTAssertEqual(p.int("maxSize"), 1920)
        XCTAssertFalse(p.has("monitor"))
        XCTAssertEqual(DesktopPackets.start(port: 1742, monitor: "DP-1", maxSize: 3024).string("monitor"), "DP-1")
        XCTAssertEqual(DesktopPackets.start(port: 1742, monitor: "DP-1", maxSize: 3024).int("maxSize"), 3024)
        XCTAssertFalse(DesktopPackets.start(port: 1742, monitor: "").has("monitor"))
        XCTAssertEqual(DesktopPackets.stop().string("state"), "stop")
    }

    func testMaxSizeStaysInTheLimitsOfFluxd() {
        XCTAssertEqual(DesktopPackets.size(forScreen: 3456), 3456)
        XCTAssertEqual(DesktopPackets.size(forScreen: 6016), 3840)
        XCTAssertEqual(DesktopPackets.size(forScreen: 320), 640)
        XCTAssertEqual(DesktopPackets.size(forScreen: 0), 1920)
    }

    func testParsesReplies() {
        let live = Packet(PacketType.fluxDesktop, ["state": "live", "monitor": "eDP-1", "monitors": ["eDP-1", "DP-1"], "width": 1920, "height": 1200])
        XCTAssertEqual(DesktopReply.parse(live), .live(monitor: "eDP-1", monitors: ["eDP-1", "DP-1"], width: 1920, height: 1200))
        XCTAssertEqual(DesktopReply.parse(Packet(PacketType.fluxDesktop, ["state": "error", "message": "off"])), .failed("off"))
        XCTAssertEqual(DesktopReply.parse(Packet(PacketType.fluxDesktop, ["state": "error"])), .failed("The computer could not stream its screen"))
        XCTAssertEqual(DesktopReply.parse(Packet(PacketType.fluxDesktop, ["state": "stop"])), .stop)
        XCTAssertNil(DesktopReply.parse(Packet(PacketType.fluxDesktop, ["state": "start"])))
        XCTAssertNil(DesktopReply.parse(Packet(PacketType.fluxScreen, ["state": "stop"])))
    }

    func testReadsFramesInAnyPieces() throws {
        let stream = frames([
            (DesktopFrame.format, [0x07, 0x80, 0x04, 0xB0]),
            (DesktopFrame.config, sps + pps),
            (DesktopFrame.key, [0, 0, 0, 1, 0x65, 1, 2]),
            (0, [0, 0, 0, 1, 0x41, 3]),
        ])
        var whole = DesktopFrameReader()
        let all = try whole.push(stream)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0].size?.width, 1920)
        XCTAssertEqual(all[0].size?.height, 1200)
        XCTAssertTrue(all[1].isConfig)
        XCTAssertNil(all[1].size)
        XCTAssertTrue(all[2].isKey && !all[2].isConfig)
        XCTAssertFalse(all[3].isKey)
        XCTAssertEqual(all[3].data, [0, 0, 0, 1, 0x41, 3])

        // The network can cut the stream anywhere.
        var bytewise = DesktopFrameReader()
        var pieces: [DesktopFrame] = []
        for b in stream { pieces += try bytewise.push([b]) }
        XCTAssertEqual(pieces, all)
        var halves = DesktopFrameReader()
        let cut = stream.count / 2 + 1
        let first = try halves.push(stream[..<cut])
        let rest = try halves.push(stream[cut...])
        XCTAssertEqual(first + rest, all)
    }

    func testRefusesAHugeFrame() {
        var r = DesktopFrameReader(maxFrame: 32)
        XCTAssertThrowsError(try r.push(frames([(0, [UInt8](repeating: 7, count: 64))])))
    }

    func testParameterSetsNeedBothUnits() throws {
        let sets = try XCTUnwrap(DesktopH264.parameterSets(sps + pps))
        XCTAssertEqual(sets.sps, [0x67, 0x64, 0x00, 0x32])
        XCTAssertEqual(sets.pps, [0x68, 0xEE, 0x3C])
        XCTAssertNil(DesktopH264.parameterSets(sps))
        XCTAssertNil(DesktopH264.parameterSets([]))
    }

    func testAVCCHasLengthsAndNoParameterSets() {
        // A 3-byte start code and an access unit delimiter too.
        let frame = sps + pps + [0, 0, 1, 0x09, 0xF0] + [0, 0, 0, 1, 0x65, 1, 2] + [0, 0, 0, 1, 0x06, 5]
        XCTAssertEqual(DesktopH264.avcc(frame), [0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 2, 0x06, 5])
        XCTAssertEqual(DesktopH264.avcc([0, 0, 0, 1, 0x41, 3]), [0, 0, 0, 2, 0x41, 3])
        XCTAssertEqual(DesktopH264.avcc([]), [])
    }

    func testTheVideoFitsTheView() throws {
        // A 16:10 video in a wide view: bars at the left and the right.
        let g = DesktopGeometry(view: CGSize(width: 2000, height: 1000), video: CGSize(width: 1920, height: 1200))
        XCTAssertEqual(g.fit, CGRect(x: 200, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(g.scale, 1000.0 / 1200, accuracy: 0.0001)
        XCTAssertEqual(g.position(CGPoint(x: 200, y: 0)), DesktopPoint(x: 0, y: 0))
        XCTAssertEqual(g.position(CGPoint(x: 1000, y: 500)), DesktopPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(g.position(CGPoint(x: 1800, y: 1000)), DesktopPoint(x: 1, y: 1))
        XCTAssertNil(g.position(CGPoint(x: 100, y: 500)))
        XCTAssertEqual(g.position(CGPoint(x: 100, y: 500), clamp: true), DesktopPoint(x: 0, y: 0.5))

        // A tall view: bars at the top and the bottom.
        let tall = DesktopGeometry(view: CGSize(width: 960, height: 1000), video: CGSize(width: 1920, height: 1200))
        XCTAssertEqual(tall.fit, CGRect(x: 0, y: 200, width: 960, height: 600))
        XCTAssertNil(tall.position(CGPoint(x: 480, y: 100)))
        let p = try XCTUnwrap(tall.position(CGPoint(x: 240, y: 350)))
        XCTAssertEqual(p.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.25, accuracy: 0.0001)

        // Without a video size, nothing is on the video.
        XCTAssertNil(DesktopGeometry(view: CGSize(width: 100, height: 100), video: .zero).position(CGPoint(x: 50, y: 50)))
    }

    func testPositionPackets() throws {
        let at = try roundTrip(RemoteInput.at(x: 0.123456, y: 2))
        XCTAssertEqual(at.double("x"), 0.1235)
        XCTAssertEqual(at.double("y"), 1)
        XCTAssertFalse(at.has("dx"))

        let click = try roundTrip(RemoteInput.clickAt(.right, x: 0.5, y: 0.25))
        XCTAssertEqual(click.bool("rightclick"), true)
        XCTAssertEqual(click.double("x"), 0.5)
        XCTAssertEqual(click.double("y"), 0.25)

        XCTAssertEqual(RemoteInput.holdAt(true, x: 0, y: 0).bool("singlehold"), true)
        XCTAssertEqual(RemoteInput.holdAt(false, x: 0, y: 0).bool("singlerelease"), true)
        XCTAssertEqual(RemoteInput.at(x: -1, y: .nan).double("x"), 0)
        XCTAssertEqual(RemoteInput.at(x: -1, y: .nan).double("y"), 0)

        let scroll = try roundTrip(RemoteInput.scrollAt(dx: 0, dy: -3, x: 0.5, y: 0.5))
        XCTAssertEqual(scroll.bool("scroll"), true)
        XCTAssertEqual(scroll.double("dy"), -3)
        XCTAssertEqual(scroll.double("x"), 0.5)
    }

    func testMotionThrottle() {
        var t = MotionThrottle(interval: 0.016)
        let a = DesktopPoint(x: 0.1, y: 0.1), b = DesktopPoint(x: 0.2, y: 0.2), c = DesktopPoint(x: 0.3, y: 0.3)
        XCTAssertEqual(t.move(to: a, now: 1), a)
        // A fast motion waits, and only its last position goes out.
        XCTAssertNil(t.move(to: b, now: 1.005))
        XCTAssertNil(t.move(to: c, now: 1.008))
        XCTAssertNil(t.flush(now: 1.01))
        XCTAssertEqual(t.flush(now: 1.017), c)
        XCTAssertNil(t.flush(now: 1.05))
        // The same position does not go again.
        XCTAssertNil(t.move(to: c, now: 2))
        XCTAssertEqual(t.move(to: a, now: 2), a)
        t.reset(sent: b, now: 3)
        XCTAssertNil(t.move(to: b, now: 4))
    }

    func testClickDragAndDoubleClick() throws {
        var p = DesktopPointer()
        let start = DesktopPoint(x: 0.5, y: 0.5)
        // A press that does not move clicks at the press.
        p.leftDown(CGPoint(x: 100, y: 100), at: start)
        XCTAssertTrue(p.leftDragged(CGPoint(x: 101, y: 101), at: DesktopPoint(x: 0.51, y: 0.51)).isEmpty)
        let click = p.leftUp(CGPoint(x: 101, y: 101), at: DesktopPoint(x: 0.51, y: 0.51), clickCount: 1)
        XCTAssertEqual(click.count, 1)
        XCTAssertEqual(click[0].bool("singleclick"), true)
        XCTAssertEqual(click[0].double("x"), 0.5)

        // The second click of a double click goes to the first position.
        p.leftDown(CGPoint(x: 102, y: 100), at: DesktopPoint(x: 0.52, y: 0.5))
        let second = p.leftUp(CGPoint(x: 102, y: 100), at: DesktopPoint(x: 0.52, y: 0.5), clickCount: 2)
        XCTAssertEqual(second[0].double("x"), 0.5)

        // A press that moves drags: the press at the start, the motion, and the release at the end.
        p.leftDown(CGPoint(x: 10, y: 10), at: DesktopPoint(x: 0.1, y: 0.1))
        let begin = p.leftDragged(CGPoint(x: 20, y: 10), at: DesktopPoint(x: 0.2, y: 0.1))
        XCTAssertTrue(p.dragging)
        XCTAssertEqual(begin.count, 2)
        XCTAssertEqual(begin[0].bool("singlehold"), true)
        XCTAssertEqual(begin[0].double("x"), 0.1)
        XCTAssertEqual(begin[1].double("x"), 0.2)
        XCTAssertFalse(begin[1].has("singlehold"))
        XCTAssertEqual(p.leftDragged(CGPoint(x: 30, y: 10), at: DesktopPoint(x: 0.3, y: 0.1)).count, 1)
        let end = p.leftUp(CGPoint(x: 30, y: 10), at: DesktopPoint(x: 0.3, y: 0.1), clickCount: 1)
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].bool("singlerelease"), true)
        XCTAssertEqual(end[0].double("x"), 0.3)
        XCTAssertFalse(p.pressed)
        XCTAssertTrue(p.leftUp(CGPoint(x: 30, y: 10), at: start, clickCount: 1).isEmpty)
    }

    func testCancelReleasesADrag() {
        var p = DesktopPointer()
        p.leftDown(.zero, at: DesktopPoint(x: 0, y: 0))
        XCTAssertTrue(p.cancel(at: nil).isEmpty)
        p.leftDown(.zero, at: DesktopPoint(x: 0, y: 0))
        _ = p.leftDragged(CGPoint(x: 50, y: 0), at: DesktopPoint(x: 0.4, y: 0))
        let end = p.cancel(at: nil)
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].bool("singlerelease"), true)
    }

    func testInputStateHasTheDesktop() {
        let model = RemoteInputModel()
        XCTAssertFalse(model.isDesktopOn("a"))
        model.set("a", true, desktop: true)
        XCTAssertTrue(model.isOn("a"))
        XCTAssertTrue(model.isDesktopOn("a"))
        // An older fluxd does not send the field.
        model.set("a", true)
        XCTAssertFalse(model.isDesktopOn("a"))
    }

    /// Encodes 1 frame with VideoToolbox and turns it into the sample that
    /// the display layer takes, as the computer sends it.
    func testEncodedFrameBecomesASample() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var out: [UInt8]?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        guard let encoder = try? H264Encoder(width: 320, height: 240, bitrate: 500_000, output: { bytes in
            let first = box.lock.withLock { () -> Bool in
                guard box.out == nil else { return false }
                box.out = bytes
                return true
            }
            if first { done.signal() }
        }, onError: { _ in done.signal() }) else { return }
        defer { encoder.release() }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        encoder.encode(pixels)
        guard done.wait(timeout: .now() + 5) == .success, let frame = box.lock.withLock({ box.out }) else {
            return XCTFail("The encoder gave no frame")
        }

        let sets = try XCTUnwrap(DesktopH264.parameterSets(frame))
        let format = try XCTUnwrap(DesktopVideo.format(sps: sets.sps, pps: sets.pps))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 240)
        let avcc = DesktopH264.avcc(frame)
        let sample = try XCTUnwrap(DesktopVideo.sample(avcc, format: format, key: true))
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), avcc.count)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool, false)
        XCTAssertNil(DesktopVideo.sample([], format: format, key: false))
    }

    /// A rotation makes a new view before the old one goes away. The old
    /// view must not take the video from the new one.
    func testAnOldLayerDoesNotDetachTheNewOne() {
        let video = DesktopVideo()
        let old = AVSampleBufferDisplayLayer()
        let new = AVSampleBufferDisplayLayer()
        video.attach(old)
        video.attach(new)
        video.detach(old)
        XCTAssertTrue(video.shows(on: new))
        video.detach(new)
        XCTAssertFalse(video.shows(on: new))
    }
}
