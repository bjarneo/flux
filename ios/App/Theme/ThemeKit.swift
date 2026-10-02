import FluxKit
import SwiftUI
import UIKit

extension Color {
    /// A color from 0xRRGGBB in sRGB.
    init(themeRGB rgb: Int) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

/// The palette as SwiftUI colors. Each view of the shell takes its colors
/// from it, through `@Environment(\.tn)`. `ThemePalette` in FluxKit gives
/// the contrast contract of the roles.
struct ThemeColors: Equatable, Sendable {
    let palette: ThemePalette

    init(_ palette: ThemePalette) { self.palette = palette }

    var dark: Bool { palette.dark }
    /// The page.
    var bg: Color { Color(themeRGB: palette.bg) }
    /// A tile that is off, and the command block.
    var offTile: Color { Color(themeRGB: palette.offTile) }
    var tile: Color { Color(themeRGB: palette.tile) }
    /// A tile that stands out, such as the master tool.
    var tileHi: Color { Color(themeRGB: palette.tileHi) }
    /// The border of a tile.
    var line: Color { Color(themeRGB: palette.line) }
    var lineHi: Color { Color(themeRGB: palette.lineHi) }
    /// The body ink.
    var text: Color { Color(themeRGB: palette.text) }
    /// The second ink, for hints and data that is not the main value.
    var sub: Color { Color(themeRGB: palette.sub) }
    /// For borders and disabled states only. Never for text that carries meaning.
    var dim: Color { Color(themeRGB: palette.dim) }
    /// The ink on a fill of the accent or of a semantic color.
    var onAccent: Color { Color(themeRGB: palette.onAccent) }
    /// Actions and selection.
    var accent: Color { Color(themeRGB: palette.accent) }
    /// A selected item.
    var accentTile: Color { Color(themeRGB: palette.accentTile) }
    var cyan: Color { Color(themeRGB: palette.cyan) }
    var green: Color { Color(themeRGB: palette.green) }
    var magenta: Color { Color(themeRGB: palette.magenta) }
    var orange: Color { Color(themeRGB: palette.orange) }
    /// "Needs you", errors, and destructive actions only.
    var red: Color { Color(themeRGB: palette.red) }
    var yellow: Color { Color(themeRGB: palette.yellow) }
    /// ANSI blue in the agent output.
    var termBlue: Color { Color(themeRGB: palette.termBlue) }
    /// The colors of the active border gradient.
    var border: [Color] { palette.border.map { Color(themeRGB: $0) } }
    /// The angle of the border gradient in degrees, or nil for corner to corner.
    var borderAngle: Double? { palette.borderAngle }

    /// The color of the state of an Inbox item.
    func tone(_ t: InboxTone) -> Color {
        switch t {
        case .red: return red
        case .green: return green
        case .accent: return accent
        case .cyan: return cyan
        case .sub: return sub
        }
    }
}

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors(.tokyoNight)
}

extension EnvironmentValues {
    /// The palette of the app, see `ThemeRoot`.
    var tn: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

/// Puts the palette of the app into the environment and sets the tint. The
/// window style of `AppearanceController` sets the color scheme, so the
/// color scheme here is the iPhone's mode when the theme follows the iPhone.
struct ThemeRoot: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let colors = ThemeColors(model.palette(systemDark: scheme == .dark))
        content
            .environment(\.tn, colors)
            .tint(colors.accent)
    }
}

extension ThemeMode {
    /// The window style of a night mode. Only `.system`, `.light`, and
    /// `.dark` come here, see `ThemeMode.nightMode(computer:)`.
    var style: UIUserInterfaceStyle {
        switch self {
        case .computer, .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The 1 motion of the shell: 200 ms with the standard easing, or none with Reduce Motion.
enum Motion {
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    }
}
