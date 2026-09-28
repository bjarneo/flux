import Foundation

/// The kind of device that Flux runs on, for the texts that name it.
public enum FluxPlatform: Sendable {
    case mac, phone

    /// The platform of this build.
    public static var current: FluxPlatform {
        #if os(macOS)
        .mac
        #else
        .phone
        #endif
    }

    /// "this Mac" or "this iPhone", inside a sentence.
    public var deviceNoun: String { self == .mac ? "this Mac" : "this iPhone" }

    /// "This Mac" or "This iPhone", at the start of a sentence.
    public var deviceNounStart: String { self == .mac ? "This Mac" : "This iPhone" }

    /// The app with the privacy settings.
    public var settingsApp: String { self == .mac ? "System Settings" : "Settings" }
}
