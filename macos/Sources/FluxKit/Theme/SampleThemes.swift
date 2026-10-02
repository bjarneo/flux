import Foundation

/// Sample computer themes. The tests check the contrast guard with them, and
/// the demo of the apps shows them on the sample computer. It is a port of
/// SampleThemes.kt of the Android app.
public enum SampleThemes {
    private static func theme(_ name: String, _ dark: Bool?, _ colors: KeyValuePairs<String, String>,
                              border: [String] = [], angle: Double? = nil) -> OmarchyTheme {
        var map: [String: Int] = [:]
        for (key, value) in colors { map[key] = ColorMath.parseColor(value)! }
        return OmarchyTheme(name: name, dark: dark, colors: map, border: border.map { ColorMath.parseColor($0)! },
                            borderAngle: angle)
    }

    /// A dark theme with a deep purple page, neon colors, and a lime blue.
    public static let neon: OmarchyTheme = theme(
        "neon", true,
        ["background": "#0c031f", "foreground": "#e8e6ef", "accent": "#d563fe", "muted": "#665a8c",
         "red": "#fe288f", "blue": "#bdff6d", "cyan": "#21e4f8"],
        border: ["#21e4f8ee", "#d563feee"], angle: 45
    )

    public static let tokyoNight: OmarchyTheme = theme(
        "tokyo-night", true,
        ["background": "#1a1b26", "dark_background": "#16161e", "darker_background": "#0f0f14",
         "lighter_background": "#24283b", "foreground": "#c0caf5", "dark_foreground": "#a9b1d6",
         "muted": "#565f89", "accent": "#7aa2f7", "selection": "#33467c",
         "red": "#f7768e", "green": "#9ece6a", "yellow": "#e0af68", "orange": "#ff9e64",
         "cyan": "#7dcfff", "blue": "#7aa2f7", "magenta": "#bb9af7"],
        border: ["#33ccffee", "#00ff99ee"], angle: 45
    )

    public static let tokyoNightDay: OmarchyTheme = theme(
        "tokyo-night-day", false,
        ["background": "#e1e2e7", "dark_background": "#d5d6db", "darker_background": "#c8c9ce",
         "lighter_background": "#e9e9ec", "foreground": "#3760bf", "muted": "#848cb5",
         "accent": "#2e7de9", "red": "#f52a65", "green": "#587539", "yellow": "#8c6c3e",
         "orange": "#b15c00", "cyan": "#007197", "blue": "#2e7de9", "magenta": "#9854f1"]
    )

    public static let catppuccinLatte: OmarchyTheme = theme(
        "catppuccin-latte", false,
        ["background": "#eff1f5", "dark_background": "#e6e9ef", "darker_background": "#dce0e8",
         "lighter_background": "#ccd0da", "foreground": "#4c4f69", "muted": "#9ca0b0",
         "accent": "#8839ef", "red": "#d20f39", "green": "#40a02b", "yellow": "#df8e1d",
         "orange": "#fe640b", "cyan": "#04a5e5", "blue": "#1e66f5", "magenta": "#ea76cb"],
        border: ["#8839efee"], angle: 0
    )

    /// A dark Omarchy theme whose accent and red are 2 pinks that look alike.
    public static let cottonCandy: OmarchyTheme = theme(
        "cotton-candy", true,
        ["background": "#191125", "dark_background": "#130d1c", "darker_background": "#0d0913",
         "lighter_background": "#271f35", "foreground": "#e9e6ef", "muted": "#685c81",
         "accent": "#e1a4ed", "selection": "#513a5d", "red": "#f097c5", "yellow": "#f9dd7d",
         "orange": "#feb79e", "green": "#58e3dc", "cyan": "#61e6ff", "blue": "#8eaffe",
         "magenta": "#e1a4ed", "bright_blue": "#bdd1fe"],
        border: ["#61e6ffee", "#e1a4edee"], angle: 45
    )

    /// A dark Omarchy theme whose accent is its red, and whose blue is a near white.
    public static let futurism: OmarchyTheme = theme(
        "futurism", true,
        ["background": "#0a1428", "lighter_background": "#17294a", "foreground": "#f0f8ff",
         "muted": "#53627a", "accent": "#ff40a3", "red": "#ff40a3", "yellow": "#5076b2",
         "orange": "#ff7ab8", "green": "#00bfff", "cyan": "#f0f8ff", "blue": "#f0f8ff",
         "magenta": "#ff40a3", "bright_blue": "#00bfff", "bright_cyan": "#00bfff",
         "bright_magenta": "#ff40a3"]
    )

    /// A broken theme: every color is a gray near the background.
    public static let lowContrast: OmarchyTheme = theme(
        "low-contrast", true,
        ["background": "#5a5a5a", "foreground": "#6e6e6e", "accent": "#606080", "muted": "#5c5c5c",
         "red": "#704848", "green": "#4a5a4a", "yellow": "#66664a", "cyan": "#4a6666"],
        border: ["#5b5b5bee", "#595959ee"]
    )

    public static let all: [OmarchyTheme] = [neon, tokyoNight, tokyoNightDay, catppuccinLatte, cottonCandy, futurism, lowContrast]

    /// The sample with `name`, such as "neon", or nil.
    public static func named(_ name: String?) -> OmarchyTheme? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }
}
