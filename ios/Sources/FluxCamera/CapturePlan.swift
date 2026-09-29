import Foundation

/// Auto-upload ledger. Port of Android `core/CapturePlan.kt`
/// (`CaptureKind`, `MediaImage`, `CaptureRules`, `CaptureState`,
/// `planCapture`, `MAX_SENT`).
///
/// Android watches MediaStore (`Pictures/Screenshots`, `DCIM/Screenshots`,
/// `DCIM/Camera`); iOS watches the photo library
/// (`PHAssetCollectionSubtype.smartAlbumScreenshots` + the camera roll,
/// see `CapturePipelines.PhotoLibraryWatch`). The ledger below is
/// platform-independent: what the watch has done, so no image goes out
/// twice.

/// The kinds of new images Flux sends by itself.
public enum CaptureKind: String, Sendable, CaseIterable {
    case screenshot
    case photo
}

/// One image from the library, as the watch reads it.
public struct MediaImage: Sendable, Equatable {
    public var id: Int64
    public var relativePath: String
    public var name: String
    public var pending: Bool
    /// The time the library added the image, in seconds.
    public var dateAdded: Int64

    public init(id: Int64, relativePath: String, name: String, pending: Bool, dateAdded: Int64) {
        self.id = id
        self.relativePath = relativePath
        self.name = name
        self.pending = pending
        self.dateAdded = dateAdded
    }
}

/// The folders of new screenshots and camera photos (Android-relative-path
/// form; `PhotoLibraryWatch` maps photo-library albums onto these so the
/// rules stay byte-identical).
public enum CaptureRules {
    /// A pending image older than this is lost; the watch does not wait.
    public static let pendingLimitSec: Int64 = 24 * 60 * 60

    /// Returns the kind of an image in `relativePath`, or nil for an image
    /// in another folder.
    public static func kind(of relativePath: String) -> CaptureKind? {
        let p = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .lowercased() + "/"
        if p.hasPrefix("pictures/screenshots/") || p.hasPrefix("dcim/screenshots/") { return .screenshot }
        if p.hasPrefix("dcim/camera/") { return .photo }
        return nil
    }
}

/// What the watch has done, so no image goes out twice. Every image up to
/// `baseline` is done. `sent` holds the images after the baseline that went
/// out. `from` holds, for each switch that is on, the newest image at the
/// time the switch turned on — only a newer image of that kind goes out.
public struct CaptureState: Sendable, Equatable {
    public var baseline: Int64
    public var sent: Set<Int64>
    public var from: [CaptureKind: Int64]

    public init(baseline: Int64 = 0, sent: Set<Int64> = [], from: [CaptureKind: Int64] = [:]) {
        self.baseline = baseline
        self.sent = sent
        self.from = from
    }

    /// Turns a kind on. `newest` is the newest image ID now.
    public func enable(_ kind: CaptureKind, newest: Int64) -> CaptureState {
        if from[kind] != nil { return self }
        if from.isEmpty {
            return CaptureState(baseline: newest, sent: [], from: [kind: newest])
        }
        var next = from
        next[kind] = newest
        return CaptureState(baseline: baseline, sent: sent, from: next)
    }

    public func disable(_ kind: CaptureKind) -> CaptureState {
        var next = from
        next.removeValue(forKey: kind)
        return CaptureState(baseline: baseline, sent: sent, from: next)
    }

    public func markSent(_ id: Int64) -> CaptureState {
        CaptureState(baseline: baseline, sent: sent.union([id]), from: from)
    }
}

/// The result of one scan: the images to send now, and the new state.
public struct CapturePlan: Sendable, Equatable {
    public var send: [(MediaImage, CaptureKind)]
    public var state: CaptureState

    public init(send: [(MediaImage, CaptureKind)], state: CaptureState) {
        self.send = send
        self.state = state
    }

    public static func == (lhs: CapturePlan, rhs: CapturePlan) -> Bool {
        lhs.state == rhs.state
            && lhs.send.map(\.0) == rhs.send.map(\.0)
            && lhs.send.map(\.1) == rhs.send.map(\.1)
    }
}

/// The most IDs `CaptureState.sent` keeps.
public let maxSentIDs = 500

/// Plans a scan of the images after the baseline. An image goes out when it
/// is complete, in a watched folder, its switch is on, newer than the time
/// the switch turned on, and not sent before. The baseline moves up through
/// images needing no more work; a pending image or an unsent one stops it,
/// so the next scan looks again. `now` is seconds.
public func planCapture(state: CaptureState, images: [MediaImage], now: Int64) -> CapturePlan {
    var send: [(MediaImage, CaptureKind)] = []
    var baseline = state.baseline
    var blocked = false
    for img in images.filter({ $0.id > state.baseline }).sorted(by: { $0.id < $1.id }) {
        let done: Bool
        if state.sent.contains(img.id) {
            done = true
        } else if img.pending {
            done = now - img.dateAdded > CaptureRules.pendingLimitSec
        } else if let kind = CaptureRules.kind(of: img.relativePath),
                  let start = state.from[kind], img.id > start
        {
            send.append((img, kind))
            done = false
        } else {
            done = true
        }
        if !done { blocked = true }
        if done, !blocked { baseline = img.id }
    }
    let sent = Set(state.sent.filter { $0 > baseline }.sorted().suffix(maxSentIDs))
    return CapturePlan(send: send, state: CaptureState(baseline: baseline, sent: sent, from: state.from))
}
