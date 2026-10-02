import FluxKit
import SwiftUI
import UIKit

/// Applies the light or dark mode of the theme to the windows of the app.
/// A window style also reaches sheets, alerts, and the keyboard, and going
/// back to the mode of the iPhone works, which a preferred color scheme on
/// the root view does not do reliably.
@MainActor
enum AppearanceController {
    /// `night` is `.system`, `.light`, or `.dark`, see `AppModel.nightMode`.
    static func apply(_ night: ThemeMode) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = night.style }
        }
    }
}
