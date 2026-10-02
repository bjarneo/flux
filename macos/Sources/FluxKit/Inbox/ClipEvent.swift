import Foundation

/// A clip that this device sent or received, for the Inbox. `preview` is
/// a short form of the text, and it is empty for an image. Flux keeps it
/// only in memory.
public struct ClipEvent: Sendable, Equatable {
    /// The computers of the clip.
    public var deviceIds: [String]
    /// The name of the computer, or "<n> computers".
    public var computer: String
    /// True for a clip that this device sent, false for a clip from a computer.
    public var sent: Bool
    public var preview: String
    public var image: Bool
    /// True for a secret, such as a password from a password manager. Its
    /// `preview` is `hiddenText`, so that the Inbox does not show the secret.
    public var secret: Bool
    public var at: Date

    /// The preview of a secret.
    public static let hiddenText = "Hidden text"

    public init(deviceIds: [String], computer: String, sent: Bool, preview: String, image: Bool = false,
                secret: Bool = false, at: Date = Date()) {
        self.deviceIds = deviceIds
        self.computer = computer
        self.sent = sent
        self.preview = secret ? Self.hiddenText : preview
        self.image = image
        self.secret = secret
        self.at = at
    }

    /// A clip that went to `computers`. `text` is nil for an image. With
    /// `secret`, the event keeps no part of the text. It returns nil when
    /// `computers` is empty.
    public static func sent(to computers: [(id: String, name: String)], text: String?, secret: Bool = false,
                            at: Date = Date()) -> ClipEvent? {
        guard let first = computers.first else { return nil }
        let name = computers.count == 1 ? first.name : "\(computers.count) computers"
        let hidden = secret && text != nil
        let preview = hidden ? "" : text.map { Inbox.clipPreview($0) } ?? ""
        return ClipEvent(deviceIds: computers.map { $0.id }, computer: name, sent: true,
                         preview: preview, image: text == nil, secret: hidden, at: at)
    }

    /// A clip from a computer. `text` is nil for an image.
    public static func received(from deviceId: String, computer: String, text: String?, at: Date = Date()) -> ClipEvent {
        ClipEvent(deviceIds: [deviceId], computer: computer, sent: false,
                  preview: text.map { Inbox.clipPreview($0) } ?? "", image: text == nil, at: at)
    }
}
