import AppKit

/// The appearance of the app: its windows and its Dock icon.
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

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
    }
}

/// Applies the appearance setting to the windows and picks the Dock icon
/// that matches: the light icon in light mode, the dark bundle icon in dark
/// mode. Automatic follows macOS. Finder and Launchpad keep the dark bundle
/// icon, because changing it would modify the signed bundle.
@MainActor
final class AppearanceController {
    static let shared = AppearanceController()

    private var observation: NSKeyValueObservation?
    private var showsLightIcon: Bool?

    private init() {}

    /// Applies the setting and starts following the system appearance.
    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppearanceController.shared.updateIcon() }
        }
    }

    /// Applies the current setting.
    func apply() {
        switch AppAppearance.current {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
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
