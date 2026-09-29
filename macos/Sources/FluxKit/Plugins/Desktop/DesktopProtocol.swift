import CoreGraphics
import Foundation

/// The flux.desktop packets. This Mac opens a TLS listener and sends
/// "start" with its port, the longest side of the stream, and optionally a
/// monitor. The computer connects and writes frames, see
/// `DesktopFrameReader`. The computer answers "live" with the monitor and
/// the size, "error", or "stop". The mouse goes as
/// flux.mousepad.request with a position. docs/remote-desktop.md
/// describes the fields.
public enum DesktopPackets {
    /// The limits of the longest side of the stream, as fluxd has them.
    public static let minSize = 640
    public static let maxSize = 3840
    /// The size that fluxd uses when this Mac does not know its screen.
    public static let defaultSize = 1920

    /// The longest side of the stream for a screen with this longest side
    /// in pixels, from `minSize` to `maxSize`.
    public static func size(forScreen pixels: Int) -> Int {
        pixels <= 0 ? defaultSize : min(maxSize, max(minSize, pixels))
    }

    public static func start(port: Int, monitor: String? = nil, maxSize: Int = defaultSize) -> Packet {
        var body: [String: Any?] = ["state": "start", "port": port, "maxSize": maxSize]
        if let monitor, !monitor.isEmpty { body["monitor"] = monitor }
        return Packet(PacketType.fluxDesktop, body)
    }

    public static func stop() -> Packet { Packet(PacketType.fluxDesktop, ["state": "stop"]) }
}

/// An answer from the computer.
public enum DesktopReply: Equatable, Sendable {
    /// The computer streams `monitor` at `width` × `height`. `monitors` are
    /// all the monitors that it can stream.
    case live(monitor: String, monitors: [String], width: Int, height: Int)
    case failed(String)
    /// The user stopped the stream on the computer.
    case stop

    /// Parses a flux.desktop packet. It returns nil for other packets and unknown states.
    public static func parse(_ p: Packet) -> DesktopReply? {
        guard p.type == PacketType.fluxDesktop else { return nil }
        switch p.string("state") {
        case "live":
            return .live(monitor: p.string("monitor") ?? "", monitors: p.strings("monitors"), width: p.int("width") ?? 0, height: p.int("height") ?? 0)
        case "error":
            let message = p.string("message") ?? ""
            return .failed(message.isEmpty ? "The computer could not stream its screen" : message)
        case "stop":
            return .stop
        default:
            return nil
        }
    }
}

/// 1 frame of the stream. `data` is H.264 in Annex-B form, or the video
/// size for a format frame.
public struct DesktopFrame: Equatable, Sendable {
    /// The SPS and the PPS.
    public static let config: UInt8 = 1
    /// A frame that a decoder can start at.
    public static let key: UInt8 = 2
    /// The video size: the width and the height as 2 big-endian 16-bit numbers.
    public static let format: UInt8 = 4

    public let flags: UInt8
    public let data: [UInt8]

    public init(flags: UInt8, data: [UInt8]) {
        self.flags = flags
        self.data = data
    }

    public var isConfig: Bool { flags & Self.config != 0 }
    public var isKey: Bool { flags & Self.key != 0 }
    public var isFormat: Bool { flags & Self.format != 0 }

    /// The width and the height of a format frame.
    public var size: (width: Int, height: Int)? {
        guard isFormat, data.count >= 4 else { return nil }
        return (Int(data[0]) << 8 | Int(data[1]), Int(data[2]) << 8 | Int(data[3]))
    }
}

/// Reads the frames that the computer writes: the size of the data as a
/// big-endian 32-bit number, 1 byte of flags, and the data. The size comes
/// first, so a frame is complete as soon as its last byte arrives. The
/// network gives the bytes in pieces of any size.
public struct DesktopFrameReader: Sendable {
    public static let maxFrame = 16 << 20

    private let maxFrame: Int
    private var buffer: [UInt8] = []
    /// The first byte of `buffer` that no frame has used yet.
    private var start = 0

    public init(maxFrame: Int = DesktopFrameReader.maxFrame) { self.maxFrame = maxFrame }

    /// Adds the bytes and returns the frames that are complete. It throws
    /// for a frame that is larger than the limit.
    public mutating func push(_ bytes: some Collection<UInt8>) throws -> [DesktopFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [DesktopFrame] = []
        while buffer.count - start >= 5 {
            let size = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard size <= maxFrame else { throw FluxError("A frame of \(size) bytes is too large") }
            guard buffer.count - start >= 5 + size else { break }
            frames.append(DesktopFrame(flags: buffer[start + 4], data: Array(buffer[start + 5 ..< start + 5 + size])))
            start += 5 + size
        }
        // Drop the used bytes when they are most of the buffer.
        if start > 0 && start * 2 >= buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return frames
    }
}

/// H.264 helpers for the frames of the computer. VideoToolbox takes NAL
/// units with a 4-byte length in front (AVCC), and the parameter sets
/// without a start code.
public enum DesktopH264 {
    static let nalAUD: UInt8 = 9

    /// The NAL units of Annex-B data, without the start codes.
    static func units(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        let starts = AnnexB.nalStarts(b)
        var out: [ArraySlice<UInt8>] = []
        for (i, start) in starts.enumerated() where start < b.count {
            // The unit ends at the start code of the next unit, without the zero bytes before it.
            var end = i + 1 < starts.count ? starts[i + 1] - 3 : b.count
            while end > start && b[end - 1] == 0 { end -= 1 }
            if end > start { out.append(b[start..<end]) }
        }
        return out
    }

    /// The first SPS and the first PPS of a config frame, without start
    /// codes. It returns nil when one of them is missing.
    public static func parameterSets(_ data: [UInt8]) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for unit in units(data) {
            switch unit.first! & 0x1F {
            case AnnexB.nalSPS where sps == nil: sps = Array(unit)
            case AnnexB.nalPPS where pps == nil: pps = Array(unit)
            default: break
            }
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }

    /// Turns Annex-B data into AVCC. It drops the parameter sets and the
    /// access unit delimiters, because the format description holds the
    /// parameter sets.
    public static func avcc(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for unit in units(data) {
            let type = unit.first! & 0x1F
            if type == AnnexB.nalSPS || type == AnnexB.nalPPS || type == nalAUD { continue }
            let n = UInt32(unit.count)
            out += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += unit
        }
        return out
    }
}

/// A position on the remote desktop, from 0 at the top left corner to 1 at
/// the bottom right corner of the monitor.
public struct DesktopPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where the video shows in its view. The video keeps its shape, fills the
/// view in 1 direction, and has bars in the other direction. The view uses
/// a top left origin.
public struct DesktopGeometry: Equatable, Sendable {
    public let view: CGSize
    public let video: CGSize

    public init(view: CGSize, video: CGSize) {
        self.view = view
        self.video = video
    }

    /// The view points for 1 video pixel.
    public var scale: Double {
        guard video.width > 0, video.height > 0 else { return 0 }
        return min(view.width / video.width, view.height / video.height)
    }

    /// The rectangle of the video in the view.
    public var fit: CGRect {
        let w = video.width * scale, h = video.height * scale
        return CGRect(x: (view.width - w) / 2, y: (view.height - h) / 2, width: w, height: h)
    }

    /// The position on the video for a point of the view. It returns nil for
    /// a point on the bars, unless `clamp` moves the point to the nearest edge.
    public func position(_ p: CGPoint, clamp: Bool = false) -> DesktopPoint? {
        let f = fit
        guard f.width > 0, f.height > 0 else { return nil }
        let x = (p.x - f.minX) / f.width, y = (p.y - f.minY) / f.height
        if clamp { return DesktopPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return DesktopPoint(x: x, y: y)
    }
}

/// Limits the pointer motion over the video to 1 packet each `interval`.
/// The last position of a fast motion waits and goes out with `flush`.
public struct MotionThrottle: Sendable {
    public let interval: TimeInterval
    private var sentAt: TimeInterval = -.infinity
    private var sent: DesktopPoint?
    public private(set) var pending: DesktopPoint?

    public init(interval: TimeInterval = 1.0 / 60) { self.interval = interval }

    /// Returns the position to send now, or nil when it waits or did not change.
    public mutating func move(to p: DesktopPoint, now: TimeInterval) -> DesktopPoint? {
        guard p != sent else {
            pending = nil
            return nil
        }
        guard now - sentAt >= interval else {
            pending = p
            return nil
        }
        pending = nil
        sent = p
        sentAt = now
        return p
    }

    /// Returns the waiting position when its time came.
    public mutating func flush(now: TimeInterval) -> DesktopPoint? {
        guard let p = pending, now - sentAt >= interval else { return nil }
        return move(to: p, now: now)
    }

    /// Forgets the waiting position and the last position, for example after a click.
    public mutating func reset(sent p: DesktopPoint? = nil, now: TimeInterval = -.infinity) {
        pending = nil
        sent = p
        sentAt = now
    }
}

/// Turns the left button over the video into packets with positions. A
/// press that moves is a drag: singlehold at the press, the motion, then
/// singlerelease. A press that does not move clicks. The second click of a
/// double click goes to the position of the first click, so that the
/// computer sees a double click.
public struct DesktopPointer: Sendable {
    /// The motion in view points after which a press becomes a drag.
    public static let dragSlop = 3.0
    /// The largest distance in view points between the 2 clicks of a double click.
    public static let doubleClickDistance = 6.0

    private var press: (point: CGPoint, at: DesktopPoint)?
    private var lastClick: (point: CGPoint, at: DesktopPoint)?
    public private(set) var dragging = false

    public init() {}

    public var pressed: Bool { press != nil }

    public mutating func leftDown(_ point: CGPoint, at: DesktopPoint) {
        press = (point, at)
        dragging = false
    }

    /// The packets for a motion of the pressed button.
    public mutating func leftDragged(_ point: CGPoint, at: DesktopPoint) -> [Packet] {
        guard let press else { return [] }
        if !dragging {
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragSlop else { return [] }
            dragging = true
            return [RemoteInput.holdAt(true, x: press.at.x, y: press.at.y), RemoteInput.at(x: at.x, y: at.y)]
        }
        return [RemoteInput.at(x: at.x, y: at.y)]
    }

    /// The packets for the release. `clickCount` is 2 or more for the
    /// second click of a double click.
    public mutating func leftUp(_ point: CGPoint, at: DesktopPoint, clickCount: Int) -> [Packet] {
        defer {
            press = nil
            dragging = false
        }
        guard let press else { return [] }
        if dragging {
            lastClick = nil
            return [RemoteInput.holdAt(false, x: at.x, y: at.y)]
        }
        var target = press.at
        if clickCount >= 2, let last = lastClick,
           hypot(press.point.x - last.point.x, press.point.y - last.point.y) < Self.doubleClickDistance {
            target = last.at
        }
        lastClick = (press.point, target)
        return [RemoteInput.clickAt(.left, x: target.x, y: target.y)]
    }

    /// Ends a press without a click. A drag releases the button at `at`.
    public mutating func cancel(at: DesktopPoint?) -> [Packet] {
        defer {
            press = nil
            dragging = false
        }
        guard dragging, let p = at ?? press?.at else { return [] }
        return [RemoteInput.holdAt(false, x: p.x, y: p.y)]
    }
}
