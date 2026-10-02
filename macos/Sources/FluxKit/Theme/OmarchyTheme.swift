import Foundation

/// The active Omarchy theme of a computer, from a flux.theme packet. The
/// packet body is {"name", "mode": "dark" or "light", "colors": {key:
/// "#rrggbb"}, "border": {"colors": ["#rrggbbaa", ...], "angle": deg}}. The
/// color keys are the keys of colors.toml, for example background,
/// foreground, accent, muted, and red. Any key can be missing. It is a port
/// of OmarchyTheme.kt of the Android app.
public struct OmarchyTheme: Sendable, Equatable {
    /// The most colors that Flux keeps from 1 theme.
    public static let maxColors = 64
    /// The most border colors that Flux keeps. Hyprland takes 10.
    public static let maxBorder = 10
    /// The longest theme name that Flux keeps.
    public static let maxName = 64

    public var name: String
    /// True for "dark", false for "light", nil when the computer does not tell.
    public var dark: Bool?
    /// The colors by their colors.toml key, as 0xRRGGBB.
    public var colors: [String: Int]
    /// The colors of the active Hyprland border, as 0xRRGGBB, or empty.
    public var border: [Int]
    /// The angle of the border gradient in degrees, or nil for corner to corner.
    public var borderAngle: Double?

    public init(name: String, dark: Bool?, colors: [String: Int], border: [Int] = [], borderAngle: Double? = nil) {
        self.name = name
        self.dark = dark
        self.colors = colors
        self.border = border
        self.borderAngle = borderAngle
    }

    /// The color of a colors.toml key, or nil.
    public subscript(key: String) -> Int? { colors[key] }

    /// Reads a theme from a flux.theme packet body. It ignores a key or a
    /// color that it cannot read. It returns nil when the body has no
    /// readable color.
    public static func parse(_ body: [String: JSONValue]) -> OmarchyTheme? {
        var colors: [String: Int] = [:]
        if let object = body["colors"]?.object {
            // A dictionary has no order, so the sorted keys decide which colors stay at the limit.
            for key in object.keys.sorted() where colors.count < maxColors && validKey(key) {
                if let color = ColorMath.parseColor(object[key]?.string) { colors[key] = color }
            }
        }
        let borderObject = body["border"]?.object
        let borderValues: [JSONValue] = borderObject?["colors"]?.array ?? []
        let border = Array(borderValues.compactMap { ColorMath.parseColor($0.string) }.prefix(maxBorder))
        var angle: Double?
        if let value = borderObject?["angle"], let a = angleValue(value), a.isFinite {
            angle = (a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }
        if colors.isEmpty && border.isEmpty { return nil }
        var name = ""
        if let text = body["name"]?.string {
            name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        }
        let mode = body["mode"]?.string?.lowercased() ?? ""
        let dark: Bool?
        switch mode {
        case "dark": dark = true
        case "light": dark = false
        default: dark = nil
        }
        return OmarchyTheme(name: name, dark: dark, colors: colors, border: border, borderAngle: angle)
    }

    /// A number, or a string such as "-90deg" without the suffix "deg".
    private static func angleValue(_ value: JSONValue) -> Double? {
        if let d = value.double { return d }
        guard var text = value.string else { return nil }
        if text.hasSuffix("deg") { text.removeLast(3) }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 1 to 32 characters: a to z first, then a to z, 0 to 9, or "_".
    static func validKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 32, ("a"..."z").contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { s in
            ("a"..."z").contains(s) || ("0"..."9").contains(s) || s == "_"
        }
    }

    /// The theme in the packet form, for the saved book.
    public func json() -> [String: JSONValue] {
        var out: [String: JSONValue] = ["name": .string(name)]
        if let dark { out["mode"] = .string(dark ? "dark" : "light") }
        out["colors"] = .object(colors.mapValues { JSONValue.string(ColorMath.hex($0)) })
        if !border.isEmpty || borderAngle != nil {
            var b: [String: JSONValue] = ["colors": .array(border.map { JSONValue.string(ColorMath.hex($0)) })]
            if let borderAngle { b["angle"] = .double(borderAngle) }
            out["border"] = .object(b)
        }
        return out
    }
}
