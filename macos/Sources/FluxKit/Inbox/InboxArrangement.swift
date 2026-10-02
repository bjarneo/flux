import Foundation

/// The order that the user gave the Inbox. `pinned` is the item that the
/// user moved to the master tile. `deferred` are the items that the user
/// swiped away, in the order of the swipes. `known` are the item keys of the
/// last `sync`, so that a new item that needs the user can take the master
/// tile back. The apps keep `pinned` and `deferred` across a restore, but
/// not `known` and `started`.
public struct InboxArrangement: Sendable, Equatable {
    public var pinned: String?
    public var deferred: [String]
    public var known: Set<String>
    public var started: Bool

    public init(pinned: String? = nil, deferred: [String] = [], known: Set<String> = [], started: Bool = false) {
        self.pinned = pinned
        self.deferred = deferred
        self.known = known
        self.started = started
    }

    /// Moves the master item `key` to the end of the stack. The next item
    /// becomes the master. A swipe on the pinned item removes the pin.
    public func swipe(_ key: String) -> InboxArrangement {
        var next = self
        if next.pinned == key { next.pinned = nil }
        next.deferred = deferred.filter { $0 != key } + [key]
        return next
    }

    /// Moves the stack item `key` to the master tile.
    public func promote(_ key: String) -> InboxArrangement {
        var next = self
        next.pinned = key
        next.deferred = deferred.filter { $0 != key }
        return next
    }

    /// Forgets the keys that are gone. A new item that needs the user
    /// removes the pin, so that the rank puts the new item first. The first
    /// sync keeps a restored pin.
    public func sync(_ items: [InboxItem]) -> InboxArrangement {
        let keys = Set(items.map { $0.key })
        let fresh = started && items.contains { $0.kind.needsYou && !known.contains($0.key) }
        var keptPin: String?
        if let pinned, keys.contains(pinned), !fresh { keptPin = pinned }
        return InboxArrangement(pinned: keptPin, deferred: deferred.filter { keys.contains($0) }, known: keys, started: true)
    }

    /// Puts `items` in the order of the user: the pinned item first, and the deferred items last.
    public func arrange(_ items: [InboxItem]) -> [InboxItem] {
        // The last item of a key wins, as with associateBy on Android.
        let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let late = deferred.compactMap { byKey[$0] }
        let lateKeys = Set(late.map { $0.key })
        let ordered = items.filter { !lateKeys.contains($0.key) } + late
        guard let pinned, let pin = byKey[pinned] else { return ordered }
        return [pin] + ordered.filter { $0.key != pin.key }
    }
}
