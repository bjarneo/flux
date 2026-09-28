import SwiftUI
import UIKit

/// The appearance of the app.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    /// The UserDefaults key of the setting.
    static let key = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The interface style of the windows. Automatic follows iOS.
    var style: UIUserInterfaceStyle {
        switch self {
        case .automatic: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Applies the appearance to the windows of the app. A window style also
/// reaches sheets and alerts, and going back to Automatic follows iOS again,
/// which a preferred color scheme on the root view does not do reliably.
@MainActor
enum AppearanceController {
    static func apply(_ appearance: AppAppearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = appearance.style }
        }
    }
}
