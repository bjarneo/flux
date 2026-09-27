import AppKit

/// Which icon the Dock and the app switcher show.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case automatic, dark, light

    /// The UserDefaults key of the setting.
    static let key = "appIcon"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// Sets the Dock icon from the setting. In Automatic it follows the system
/// appearance. The bundle icon, which Finder and Launchpad show, stays dark:
/// changing it would modify the signed bundle.
@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private var observation: NSKeyValueObservation?
    private var showsLight: Bool?

    private init() {}

    /// Applies the setting and starts following the system appearance.
    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppIconController.shared.apply() }
        }
    }

    /// Shows the icon for the current setting and appearance.
    func apply() {
        let style = AppIconStyle(rawValue: UserDefaults.standard.string(forKey: AppIconStyle.key) ?? "") ?? .automatic
        let light: Bool
        switch style {
        case .dark: light = false
        case .light: light = true
        case .automatic: light = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
        guard light != showsLight else { return }
        showsLight = light
        // nil restores the bundle icon, which is the dark one.
        NSApp.applicationIconImage = light ? NSImage(named: "AppIconLight") : nil
    }
}
