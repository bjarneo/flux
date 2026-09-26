import Foundation

/// The kinds of new images that Flux sends by itself.
public enum CaptureKind: String, Codable, Sendable, CaseIterable {
    case screenshot, photo
}

/// 1 new image that the capture watch found. The ID orders the images by
/// the time that they arrived on this Mac, in microseconds: the date that a
/// file was added to the screenshot folder, or the time that Flux first saw
/// a photo in the library.
public struct CaptureItem: Sendable, Equatable {
    public var id: Int64
    /// The kind of the image, or nil for an item that Flux does not send.
    public var kind: CaptureKind?
    public var name: String
    /// True while the item is still being written.
    public var pending: Bool
    /// The time that the item arrived, in seconds.
    public var dateAdded: Int64

    public init(id: Int64, kind: CaptureKind?, name: String, pending: Bool = false, dateAdded: Int64) {
        self.id = id
        self.kind = kind
        self.name = name
        self.pending = pending
        self.dateAdded = dateAdded
    }
}

/// The rules of the capture watch.
public enum CaptureRules {
    /// A pending item that is older than this is lost. The watch does not wait for it.
    public static let pendingLimit: Int64 = 24 * 60 * 60

    /// The extensions of the image formats that `screencapture` writes.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "pdf"]

    /// Reports whether a file in the screenshot folder is a screenshot. macOS
    /// marks each screenshot and screen recording with the screen capture
    /// attribute, so that other files in the folder, often the Desktop, stay
    /// home. Screen recordings are not images, so they stay home too.
    public static func isScreenshot(name: String, marked: Bool) -> Bool {
        marked && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// What the capture watch has done, so that no image goes out twice.
/// Every item up to `baseline` is done. `sent` holds the items after the
/// baseline that went out. `from` holds, for each switch that is on, the
/// newest item ID at the time that the switch turned on. Only a newer item
/// of that kind goes out.
public struct CaptureState: Codable, Sendable, Equatable {
    public var baseline: Int64 = 0
    public var sent: Set<Int64> = []
    public var from: [CaptureKind: Int64] = [:]

    public init(baseline: Int64 = 0, sent: Set<Int64> = [], from: [CaptureKind: Int64] = [:]) {
        self.baseline = baseline
        self.sent = sent
        self.from = from
    }

    /// Turns a kind on. `newest` is the newest item ID now.
    public func enable(_ kind: CaptureKind, newest: Int64) -> CaptureState {
        if from[kind] != nil { return self }
        // With no switch on, nothing older than now needs a look.
        if from.isEmpty { return CaptureState(baseline: newest, sent: [], from: [kind: newest]) }
        var s = self
        s.from[kind] = newest
        return s
    }

    public func disable(_ kind: CaptureKind) -> CaptureState {
        var s = self
        s.from[kind] = nil
        return s
    }

    public func markSent(_ id: Int64) -> CaptureState {
        var s = self
        s.sent.insert(id)
        return s
    }
}

/// The result of 1 scan: the items to send now, and the new state.
public struct CapturePlan: Sendable {
    public var send: [(item: CaptureItem, kind: CaptureKind)]
    public var state: CaptureState
}

/// The most IDs that `CaptureState.sent` keeps.
public let maxCaptureSent = 500

/// Plans a scan of the items after the baseline. An item goes out when it
/// is complete, its kind is known, its switch is on, it is newer than the
/// time that the switch turned on, and it did not go out before. The
/// baseline moves up through the items that need no more work. A pending
/// item or an item that did not go out yet stops it, so that the next scan
/// looks at that item again. `now` is the time in seconds.
public func planCapture(_ state: CaptureState, items: [CaptureItem], now: Int64) -> CapturePlan {
    var send: [(item: CaptureItem, kind: CaptureKind)] = []
    var baseline = state.baseline
    var blocked = false
    for item in items.filter({ $0.id > state.baseline }).sorted(by: { $0.id < $1.id }) {
        let done: Bool
        if state.sent.contains(item.id) {
            done = true
        } else if item.pending {
            done = now - item.dateAdded > CaptureRules.pendingLimit
        } else if let kind = item.kind, let start = state.from[kind], item.id > start {
            send.append((item, kind))
            done = false
        } else {
            done = true
        }
        if !done { blocked = true }
        if done && !blocked { baseline = item.id }
    }
    var next = state
    next.baseline = baseline
    next.sent = Set(state.sent.filter { $0 > baseline }.sorted().suffix(maxCaptureSent))
    return CapturePlan(send: send, state: next)
}
