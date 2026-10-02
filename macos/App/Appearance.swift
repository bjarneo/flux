import AppKit
import FluxKit

/// Sets the light or dark mode of the windows from the theme, and picks the
/// Dock icon that matches: the light icon in light mode, the dark bundle
/// icon in dark mode. Finder and Launchpad keep the dark bundle icon,
/// because changing it would modify the signed bundle.
@MainActor
final class AppearanceController {
    static let shared = AppearanceController()

    private var observation: NSKeyValueObservation?
    private var showsLightIcon: Bool?

    private init() {}

    /// Starts to follow the appearance of the app for the Dock icon.
    /// `AppModel.watchTheme` calls `apply(_:)` with the mode of the theme.
    func start() {
        updateIcon()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppearanceController.shared.updateIcon() }
        }
    }

    /// Sets the light or dark mode of the windows. `.system` follows macOS.
    func apply(_ night: ThemeMode) {
        switch night {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system, .computer: NSApp.appearance = nil
        }
        updateIcon()
    }

    private func updateIcon() {
        let light = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        guard light != showsLightIcon else { return }
        showsLightIcon = light
        // nil restores the bundle icon, which is the dark one.
        NSApp.applicationIconImage = light ? NSImage(named: "AppIconLight") : nil
    }
}
