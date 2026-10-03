import CoreGraphics
import Foundation

/// The zoom and the pan of the remote desktop on a phone, as in Flux for
/// Android. At scale 1, the video fits the view and keeps its shape. A
/// point of the video at (x, y) at scale 1 shows at (x × scale + offset.x,
/// y × scale + offset.y) in the view. The view uses a top left origin.
public struct DesktopViewport: Equatable, Sendable {
    /// The largest zoom.
    public static let maxScale = 6.0

    public let view: CGSize
    public let video: CGSize
    public private(set) var scale = 1.0
    public private(set) var offset = CGPoint.zero

    public init(view: CGSize, video: CGSize) {
        self.view = view
        self.video = video
    }

    /// The rectangle of the video in the view at scale 1.
    public var fitRect: CGRect { DesktopGeometry(view: view, video: video).fit }

    /// The view points for 1 video pixel.
    public var pixel: Double { DesktopGeometry(view: view, video: video).scale * scale }

    /// The rectangle of the video in the view at the zoom and the pan.
    public var videoFrame: CGRect {
        let f = fitRect
        return CGRect(x: f.minX * scale + offset.x, y: f.minY * scale + offset.y, width: f.width * scale, height: f.height * scale)
    }

    /// The position on the video for a point of the view. It returns nil for
    /// a point outside the video, unless `clamp` moves the point to the
    /// nearest edge.
    public func toVideo(_ p: CGPoint, clamp: Bool = false) -> DesktopPoint? {
        let f = fitRect
        guard f.width > 0, f.height > 0 else { return nil }
        let x = ((p.x - offset.x) / scale - f.minX) / f.width
        let y = ((p.y - offset.y) / scale - f.minY) / f.height
        if clamp { return DesktopPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return DesktopPoint(x: x, y: y)
    }

    /// Zooms by `factor` around the point `focus` of the view and moves by
    /// `pan`. The scale stays from 1 to `maxScale`, and the video stays on the view.
    public func zoom(_ factor: Double, focus: CGPoint, pan: CGVector = CGVector()) -> DesktopViewport {
        let next = min(max(scale * factor, 1), Self.maxScale)
        var v = self
        v.scale = next
        // The point under the focus stays under the focus.
        v.offset = CGPoint(x: focus.x - (focus.x - offset.x) / scale * next + pan.dx,
                           y: focus.y - (focus.y - offset.y) / scale * next + pan.dy)
        return v.clamped()
    }

    /// Moves the view by `dx`, `dy` points.
    public func pan(dx: Double, dy: Double) -> DesktopViewport {
        var v = self
        v.offset = CGPoint(x: offset.x + dx, y: offset.y + dy)
        return v.clamped()
    }

    /// The viewport for a new view or video size. The same sizes keep the
    /// zoom. When 1 side of the view changes, for example when the keyboard
    /// or a panel shows, the video keeps its size on the screen, so that the
    /// text stays readable. The video point `focus` then keeps its place as
    /// a part of the view, so that a tapped field stays in view. Without
    /// `focus`, the point at the center of the view keeps its place. A new
    /// video, a first view, or a view with 2 new sides, as after a
    /// rotation, starts at scale 1.
    public func resized(view: CGSize, video: CGSize, focus: DesktopPoint? = nil) -> DesktopViewport {
        if view == self.view && video == self.video { return self }
        var next = DesktopViewport(view: view, video: video)
        let fitScale = DesktopGeometry(view: view, video: video).scale
        let oneSide = (view.width == self.view.width) != (view.height == self.view.height)
        guard video == self.video, oneSide, self.view.width > 0, self.view.height > 0, pixel > 0, fitScale > 0 else { return next }
        next.scale = min(max(pixel / fitScale, 1), Self.maxScale)
        let center = CGPoint(x: self.view.width / 2, y: self.view.height / 2)
        guard let at = focus ?? toVideo(center, clamp: true) else { return next }
        // The part of the old view where the focus shows.
        let old = videoFrame
        let partX = min(max((old.minX + at.x * old.width) / self.view.width, 0), 1)
        let partY = min(max((old.minY + at.y * old.height) / self.view.height, 0), 1)
        let f = next.fitRect
        next.offset = CGPoint(x: partX * view.width - (f.minX + at.x * f.width) * next.scale,
                              y: partY * view.height - (f.minY + at.y * f.height) * next.scale)
        return next.clamped()
    }

    /// Keeps the video on the view. A video that is smaller than the view
    /// stays in the center. A larger video covers the view.
    private func clamped() -> DesktopViewport {
        func axis(_ offset: Double, _ start: Double, _ length: Double, _ view: Double) -> Double {
            let shown = length * scale
            if shown <= view { return (view - shown) / 2 - start * scale }
            return min(max(offset, view - (start + length) * scale), -start * scale)
        }
        let f = fitRect
        var v = self
        v.offset = CGPoint(x: axis(offset.x, f.minX, f.width, view.width), y: axis(offset.y, f.minY, f.height, view.height))
        return v
    }
}

/// The touches on the remote desktop of a phone, as in Flux for Android. A
/// tap clicks, and a second tap near the first soon after clicks at the
/// same position, so that the computer sees a double click. A finger that
/// holds still clicks the right button, or drags when it then moves. 2
/// fingers scroll, and a tap with 2 fingers clicks the right button. A
/// pinch zooms, and 1 finger moves the zoomed view. Positions and distances
/// are in view points.
public struct DesktopTouches: Sendable {
    public enum Action: Equatable, Sendable {
        /// Puts the pointer on the position.
        case move(DesktopPoint)
        case click(RemoteInput.Click, DesktopPoint)
        /// Presses the left button at the position for a drag, or releases it.
        case hold(Bool, DesktopPoint)
        /// Scrolls the window under the pointer. A positive `dy` scrolls down.
        case scroll(dx: Double, dy: Double)
        /// The zoom or the pan of the view changes.
        case viewport(DesktopViewport)
        /// A finger held still, for a haptic.
        case held
    }

    /// A finger that stays still this long clicks the right button, or drags when it moves.
    public static let holdDelay: TimeInterval = 0.45
    /// A second tap within this time and distance clicks at the first tap.
    public static let doubleTapTime: TimeInterval = 0.4
    public static let doubleTapDistance = 24.0
    /// The motion after which a touch is no tap.
    public static let slop = 8.0

    private enum Mode { case pending, pan, held, drag, multi, pinch, scroll }

    private var active = false
    private var mode = Mode.pending
    private var first = 0
    private var start = CGPoint.zero
    private var holdAt: TimeInterval = 0
    private var last = CGPoint.zero
    private var ids: Set<Int> = []
    private var startCentroid = CGPoint.zero
    private var startSpan = 0.0
    private var lastCentroid = CGPoint.zero
    private var lastSpan = 0.0
    /// The last tap: its time, its point in the view, and its position on the video.
    private var lastTap: (time: TimeInterval, point: CGPoint, at: DesktopPoint)?

    public init() {}

    /// The time at which a still finger holds, or nil when no hold can start.
    public var holdDeadline: TimeInterval? { active && mode == .pending ? holdAt : nil }

    /// Handles the fingers on the view after a touch event, by id. No
    /// fingers ends the gesture. `viewport` is the zoom and the pan now.
    public mutating func touches(_ now: [Int: CGPoint], at time: TimeInterval, viewport v: DesktopViewport) -> [Action] {
        if !active {
            guard let id = now.keys.min(), let p = now[id] else { return [] }
            active = true
            mode = .pending
            first = id
            start = p
            last = p
            holdAt = time + Self.holdDelay
            ids = [id]
            startCentroid = p
            startSpan = 0
            lastCentroid = p
            lastSpan = 0
        }
        var out = holdIfDue(at: time, viewport: v)
        guard !now.isEmpty else { return out + end(at: time, viewport: v) }
        let nowIds = Set(now.keys)
        if now.count >= 2 && (mode == .pending || mode == .pan) {
            mode = .multi
            startCentroid = Self.centroid(now)
            startSpan = Self.span(now, startCentroid)
        }
        switch mode {
        case .pending, .pan:
            guard let p = primary(now) else { break }
            if mode == .pending && distance(p, start) >= Self.slop { mode = .pan }
            if mode == .pan {
                out.append(.viewport(v.pan(dx: p.x - last.x, dy: p.y - last.y)))
                last = p
            }
        case .held, .drag:
            guard let p = primary(now) else { break }
            if mode == .held && distance(p, start) >= Self.slop {
                mode = .drag
                if let at = v.toVideo(start, clamp: true) { out.append(.hold(true, at)) }
            }
            if mode == .drag && p != last, let at = v.toVideo(p, clamp: true) { out.append(.move(at)) }
            last = p
        case .multi, .pinch, .scroll:
            guard now.count >= 2 else { break }
            let c = Self.centroid(now)
            let s = Self.span(now, c)
            // A finger that lands or lifts moves the center. The next motion starts from there.
            if nowIds == ids {
                if mode == .multi {
                    if abs(s - startSpan) > Self.slop {
                        mode = .pinch
                    } else if distance(c, startCentroid) > Self.slop {
                        mode = .scroll
                        // The scroll goes to the window under the fingers.
                        if let at = v.toVideo(startCentroid) { out.append(.move(at)) }
                    }
                }
                switch mode {
                case .pinch:
                    out.append(.viewport(v.zoom(lastSpan > 0 ? s / lastSpan : 1, focus: lastCentroid,
                                                pan: CGVector(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y))))
                case .scroll where v.pixel > 0:
                    // Natural scrolling: the content follows the fingers.
                    out.append(.scroll(dx: -(c.x - lastCentroid.x) / v.pixel, dy: -(c.y - lastCentroid.y) / v.pixel))
                default:
                    break
                }
            }
            lastCentroid = c
            lastSpan = s
        }
        ids = nowIds
        return out
    }

    /// Holds when the finger stayed still until its time: the pointer goes under it.
    public mutating func holdIfDue(at time: TimeInterval, viewport v: DesktopViewport) -> [Action] {
        guard active, mode == .pending, time >= holdAt else { return [] }
        mode = .held
        var out: [Action] = [.held]
        if let at = v.toVideo(start) { out.append(.move(at)) }
        return out
    }

    /// Ends the gesture without a click, for example when iOS takes the
    /// touches. A drag releases the button.
    public mutating func cancel(viewport v: DesktopViewport) -> [Action] {
        defer { active = false }
        guard active, mode == .drag, let at = v.toVideo(last, clamp: true) else { return [] }
        return [.hold(false, at)]
    }

    private mutating func end(at time: TimeInterval, viewport v: DesktopViewport) -> [Action] {
        active = false
        switch mode {
        case .pending:
            guard let position = v.toVideo(start) else { return [] }
            var at = position
            if let prev = lastTap, time - prev.time < Self.doubleTapTime, distance(start, prev.point) < Self.doubleTapDistance {
                at = prev.at
            }
            lastTap = (time, start, at)
            return [.click(.left, at)]
        case .held:
            return v.toVideo(start).map { [.click(.right, $0)] } ?? []
        case .drag:
            return v.toVideo(last, clamp: true).map { [.hold(false, $0)] } ?? []
        case .multi:
            return v.toVideo(startCentroid).map { [.click(.right, $0)] } ?? []
        case .pan, .pinch, .scroll:
            return []
        }
    }

    /// The first finger, or the earliest finger that is still down.
    private func primary(_ now: [Int: CGPoint]) -> CGPoint? { now[first] ?? now.min { $0.key < $1.key }?.value }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func centroid(_ points: [Int: CGPoint]) -> CGPoint {
        let n = Double(points.count)
        return CGPoint(x: points.values.reduce(0) { $0 + $1.x } / n, y: points.values.reduce(0) { $0 + $1.y } / n)
    }

    /// The mean distance of the fingers from their center.
    private static func span(_ points: [Int: CGPoint], _ center: CGPoint) -> Double {
        points.values.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) } / Double(points.count)
    }
}
