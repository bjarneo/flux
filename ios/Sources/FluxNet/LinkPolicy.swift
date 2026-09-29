import Foundation
import FluxProto

/// Describes one authenticated TLS link for race-window decisions.
/// Mirrors `Preferred` in `internal/lan/link.go`:
///
/// - After the race window, the new link always wins (old socket may be
///   dead without an error).
/// - Inside the window, both sides keep the link the device with the larger
///   ID opened, so simultaneous dials converge instead of killing both links.
public struct LinkDescriptor: Sendable, Equatable {
    public var peerId: String
    public var outgoing: Bool
    public var started: Date

    public init(peerId: String, outgoing: Bool, started: Date = Date()) {
        self.peerId = peerId
        self.outgoing = outgoing
        self.started = started
    }
}

/// Chooses which of two links to the same device survives.
public func preferredLink(old: LinkDescriptor, next: LinkDescriptor, selfId: String) -> LinkDescriptor {
    if Date().timeIntervalSince(old.started) > Lan.raceWindow {
        return next
    }
    func opener(_ l: LinkDescriptor) -> String {
        l.outgoing ? selfId : l.peerId
    }
    let larger = max(selfId, next.peerId)
    if opener(old) == larger, opener(next) != larger {
        return old
    }
    return next
}
