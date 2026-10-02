import FluxKit
import SwiftUI

extension Color {
    /// A color from 0xRRGGBB in sRGB.
    init(themeRGB rgb: Int) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

/// The palette of the app as SwiftUI colors. Each new view takes its colors
/// from it, through `@Environment(\.tn)`. The roles are those of
/// `ThemePalette` and DESIGN.md.
struct ThemeColors: Equatable, Sendable {
    let palette: ThemePalette

    init(_ palette: ThemePalette) {
        self.palette = palette
    }

    var dark: Bool { palette.dark }
    var bg: Color { Color(themeRGB: palette.bg) }
    var offTile: Color { Color(themeRGB: palette.offTile) }
    var tile: Color { Color(themeRGB: palette.tile) }
    var tileHi: Color { Color(themeRGB: palette.tileHi) }
    var line: Color { Color(themeRGB: palette.line) }
    var lineHi: Color { Color(themeRGB: palette.lineHi) }
    var text: Color { Color(themeRGB: palette.text) }
    var sub: Color { Color(themeRGB: palette.sub) }
    var dim: Color { Color(themeRGB: palette.dim) }
    var onAccent: Color { Color(themeRGB: palette.onAccent) }
    var accent: Color { Color(themeRGB: palette.accent) }
    var accentTile: Color { Color(themeRGB: palette.accentTile) }
    var cyan: Color { Color(themeRGB: palette.cyan) }
    var green: Color { Color(themeRGB: palette.green) }
    var magenta: Color { Color(themeRGB: palette.magenta) }
    var orange: Color { Color(themeRGB: palette.orange) }
    var red: Color { Color(themeRGB: palette.red) }
    var yellow: Color { Color(themeRGB: palette.yellow) }
    var termBlue: Color { Color(themeRGB: palette.termBlue) }
    var border: [Color] { palette.border.map { Color(themeRGB: $0) } }
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
    static let defaultValue = ThemeColors(ThemePalette.tokyoNight)
}

extension EnvironmentValues {
    /// The colors of the theme in effect.
    var tn: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

/// Puts the palette of the app into the environment and sets the tint. The
/// palette follows the theme setting, the computer in scope, and the light
/// or dark mode of macOS. `AppModel.watchTheme` sets the light or dark mode
/// of the windows to match.
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

extension View {
    /// Puts the theme on the root of a feature window. A feature window is
    /// an AppKit window with its own SwiftUI root, so it gets the app model
    /// here. With `surfaces` false, the window gets only the tint and the
    /// light or dark mode, and keeps its own background.
    @ViewBuilder
    func themeWindow(_ app: AppModel?, surfaces: Bool = true) -> some View {
        if let app {
            if surfaces {
                fluxScreen().modifier(ThemeRoot()).environment(app)
            } else {
                modifier(ThemeTint()).modifier(ThemeRoot()).environment(app)
            }
        } else {
            self
        }
    }
}

/// The tint and the light or dark mode of the theme, without its surfaces.
private struct ThemeTint: ViewModifier {
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .tint(tn.accent)
            .environment(\.colorScheme, tn.dark ? .dark : .light)
    }
}

/// The 1 motion of the shell: 200 ms with the standard easing, or none
/// with Reduce Motion.
enum Motion {
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    }
}
