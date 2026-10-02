import Foundation

/// The theme setting. The order is the order of the choices.
public enum ThemeMode: String, CaseIterable, Sendable, Identifiable {
    /// The palette of the computer theme in effect. Without one, it follows the device like System.
    case computer
    /// Tokyo Night when the device is dark, else Tokyo Night Day.
    case system
    /// Tokyo Night Day.
    case light
    /// Tokyo Night.
    case dark

    /// The key of the setting in `UserDefaults.standard` of both apps. The
    /// old Appearance values `automatic`, `light`, and `dark` read as
    /// `computer`, `light`, and `dark`.
    public static let defaultsKey = "appearance"

    /// A missing or unknown value reads as `computer`.
    public init(key: String?) {
        self = key.flatMap { ThemeMode(rawValue: $0) } ?? .computer
    }

    public var id: String { rawValue }

    /// "Computer", "System", "Light", or "Dark".
    public var label: String {
        switch self {
        case .computer: return "Computer"
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The palette to draw. Computer takes `computer`, and without it
    /// follows the device like System.
    public func palette(computer: ThemePalette?, systemDark: Bool) -> ThemePalette {
        let device = systemDark ? ThemePalette.tokyoNight : ThemePalette.tokyoNightDay
        switch self {
        case .computer: return computer ?? device
        case .system: return device
        case .light: return ThemePalette.tokyoNightDay
        case .dark: return ThemePalette.tokyoNight
        }
    }

    /// The light or dark mode that the app sets on its windows: `.dark`,
    /// `.light`, or `.system` to follow the device.
    public func nightMode(computer: ThemePalette?) -> ThemeMode {
        guard self == .computer else { return self }
        guard let computer else { return .system }
        return computer.dark ? .dark : .light
    }

    /// The second line of the Computer choice. It names the theme that the
    /// choice draws now and the computer that sent it, for example
    /// "cotton-candy from omarchy-desk". Without a computer theme, it names
    /// the Tokyo Night palette that the app draws until a computer sends
    /// its theme. `themeComputer` is the name of the computer that sent
    /// `theme`. `scopeComputer` is the name of the computer in scope. Give
    /// nil for a missing name. An empty name counts as no name.
    public static func computerLine(theme: ComputerTheme?, themeComputer: String?, scopeComputer: String?,
                                    systemDark: Bool) -> String {
        func named(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        guard let theme else {
            let fallback = systemDark ? "Tokyo Night" : "Tokyo Night Day"
            if let scope = named(scopeComputer) { return "\(fallback) until \(scope) sends its theme" }
            return "\(fallback) until a computer sends its theme"
        }
        let name = named(theme.name)
        let computer = named(themeComputer)
        if let name, let computer { return "\(name) from \(computer)" }
        if let name { return name }
        if let computer { return "The theme of \(computer)" }
        return "The theme of a computer"
    }
}
