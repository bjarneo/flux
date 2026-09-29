import Foundation

/// A notification that a computer sends to this Mac, from a
/// flux.notification packet (`flux-cli notify`, `flux-cli notify --run`).
public struct ComputerNotification: Equatable, Sendable {
    /// The ID of the macOS notification. The same computer and ID replace the old notification.
    public var key: String
    /// The app name next to the computer name.
    public var subtitle: String
    public var title: String
    public var text: String

    /// Reads the packet from the computer named `computer`. The app name of
    /// the packet shows next to the computer name, when it is another name.
    /// Returns nil for a packet with no ID or no title.
    public init?(_ p: Packet, deviceId: String, computer: String) {
        guard let id = p.string("id"), !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let title = (p.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let app = (p.string("appName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        key = "\(deviceId):\(id)"
        subtitle = app.isEmpty || app.caseInsensitiveCompare(computer) == .orderedSame ? computer : "\(app) · \(computer)"
        self.title = title
        text = (p.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
