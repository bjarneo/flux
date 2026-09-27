import Foundation

/// A notification that a computer sends to this Mac, from a
/// kdeconnect.notification packet (`flux-cli notify`, `flux-cli notify --run`).
public struct ComputerNotification: Equatable, Sendable {
    /// The ID of the macOS notification. The same computer and ID replace the old notification.
    public var key: String
    /// The app name next to the computer name.
    public var subtitle: String
    public var title: String
    public var text: String
    /// True when the computer removes the notification.
    public var cancel: Bool

    /// Reads the packet from the computer named `computer`. The app name of
    /// the packet shows next to the computer name, when it is another name.
    /// Returns nil for a packet with no ID or no text.
    public init?(_ p: Packet, deviceId: String, computer: String) {
        guard let id = p.string("id"), !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let cancel = p.bool("isCancel") == true
        let text = (p.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = (p.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = (p.string("ticker") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !cancel && title.isEmpty && text.isEmpty { return nil }
        let app = (p.string("appName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        key = "\(deviceId):\(id)"
        subtitle = app.isEmpty || app.caseInsensitiveCompare(computer) == .orderedSame ? computer : "\(app) · \(computer)"
        self.title = title.isEmpty ? text : title
        self.text = title.isEmpty ? "" : text
        self.cancel = cancel
    }
}
