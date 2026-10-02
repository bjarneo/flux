import Foundation

/// A color in OKLCH: the lightness `l` from 0 to 1, the chroma `c`, and the hue `h` in radians.
public struct Oklch: Sendable, Equatable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

/// A minimum contrast `ratio` of a color against the color `against`.
public struct ContrastNeed: Sendable, Equatable {
    public let against: Int
    public let ratio: Double
    /// The luminance of `against`, so that the guard computes it once.
    let lum: Double

    public init(_ against: Int, _ ratio: Double) {
        self.against = against
        self.ratio = ratio
        lum = ColorMath.luminance(against)
    }
}

/// The color math of the theme engine. A color is an Int 0xRRGGBB. Each
/// function ignores the alpha byte. It is a port of ColorMath.kt of the
/// Android app, and the tests check the same values.
public enum ColorMath {
    /// The color without its alpha byte.
    public static func opaque(_ color: Int) -> Int { color & 0xFFFFFF }

    static func channel(_ color: Int, _ shift: Int) -> Int { (color >> shift) & 0xFF }

    /// Decodes 1 sRGB channel, from 0 to 255, to linear light.
    static func linear(_ c: Int) -> Double {
        let v = Double(c) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Encodes linear light to 1 sRGB channel, from 0 to 255.
    static func encode(_ v: Double) -> Int {
        let c = min(max(v, 0), 1)
        let s: Double = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        let scaled = (s * 255).rounded()
        guard scaled.isFinite else { return 0 }
        return min(max(Int(scaled), 0), 255)
    }

    /// The relative luminance of WCAG 2.2, from 0 for black to 1 for white.
    public static func luminance(_ color: Int) -> Double {
        let r: Double = 0.2126 * linear(channel(color, 16))
        let g: Double = 0.7152 * linear(channel(color, 8))
        let b: Double = 0.0722 * linear(channel(color, 0))
        return r + g + b
    }

    /// The contrast ratio of WCAG 2.2, from 1 to 21. The order of the colors does not matter.
    public static func contrast(_ a: Int, _ b: Int) -> Double { ratio(luminance(a), luminance(b)) }

    static func ratio(_ la: Double, _ lb: Double) -> Double {
        la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05)
    }

    /// The color at `t` on the sRGB line from `a` to `b`. `t` = 0 gives `a`, and `t` = 1 gives `b`.
    public static func mix(_ a: Int, _ b: Int, _ t: Double) -> Int {
        func m(_ shift: Int) -> Int {
            let x = Double(channel(a, shift))
            let y = Double(channel(b, shift))
            let v = (x + (y - x) * t).rounded()
            guard v.isFinite else { return 0 }
            return min(max(Int(v), 0), 255) << shift
        }
        return m(16) | m(8) | m(0)
    }

    /// Converts a color to OKLCH.
    public static func oklch(_ color: Int) -> Oklch {
        let r = linear(channel(color, 16))
        let g = linear(channel(color, 8))
        let b = linear(channel(color, 0))
        let l: Double = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m: Double = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s: Double = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lab: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return Oklch(l: lab, c: hypot(a, bb), h: atan2(bb, a))
    }

    /// The distance of 2 colors in OKLAB, from 0 for the same color. 0.02
    /// is about the smallest difference that people see. 0.1 is a clear
    /// difference.
    public static func distance(_ a: Int, _ b: Int) -> Double {
        let x = oklch(a)
        let y = oklch(b)
        let da: Double = x.c * cos(x.h) - y.c * cos(y.h)
        let db: Double = x.c * sin(x.h) - y.c * sin(y.h)
        let dl: Double = x.l - y.l
        return sqrt(dl * dl + da * da + db * db)
    }

    /// Converts OKLAB to linear sRGB. The values can be outside 0 to 1.
    static func linearRgb(_ l: Double, _ a: Double, _ b: Double) -> [Double] {
        let l3: Double = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3: Double = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3: Double = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r: Double = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g: Double = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl: Double = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return [r, g, bl]
    }

    static let gamutEpsilon = 1e-4

    static func inGamut(_ v: [Double]) -> Bool {
        v.allSatisfy { $0 >= -gamutEpsilon && $0 <= 1 + gamutEpsilon }
    }

    /// Converts OKLCH to a color. A color outside sRGB loses chroma until
    /// it fits. The lightness and the hue stay.
    public static func fromOklch(_ c: Oklch) -> Int {
        func at(_ chroma: Double) -> [Double] { linearRgb(c.l, chroma * cos(c.h), chroma * sin(c.h)) }
        var v = at(c.c)
        if !inGamut(v) {
            var lo = 0.0
            var hi = c.c
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if inGamut(at(mid)) { lo = mid } else { hi = mid }
            }
            v = at(lo)
        }
        return (encode(v[0]) << 16) | (encode(v[1]) << 8) | encode(v[2])
    }

    /// True when `color` meets each of the `needs`.
    public static func meets(_ color: Int, _ needs: [ContrastNeed]) -> Bool {
        needs.allSatisfy { contrast(color, $0.against) >= $0.ratio }
    }

    /// The step of the lightness search, in OKLCH lightness.
    static let lightnessStep = 0.002

    /// The contrast guard. It moves only the OKLCH lightness of `color`
    /// until the color meets each need, and it keeps the hue. It takes the
    /// smallest move, and it tries the lighter side first when `lighter` is
    /// true. A color that meets the needs stays as it is. When no lightness
    /// meets each need, the guard returns the color that comes closest.
    public static func guarded(_ color: Int, _ needs: [ContrastNeed], lighter: Bool) -> Int {
        let start = opaque(color)
        if needs.isEmpty { return start }
        func score(_ x: Int) -> Double {
            let lx = luminance(x)
            var least = Double.greatestFiniteMagnitude
            for n in needs { least = min(least, ratio(lx, n.lum) / n.ratio) }
            return least
        }
        var best = start
        var bestScore = score(start)
        if bestScore >= 1 { return start }
        let o = oklch(start)
        let sides: [Double] = lighter ? [1, -1] : [-1, 1]
        let steps = Int(1 / lightnessStep) + 1
        for k in 1...steps {
            var any = false
            for side in sides {
                let l: Double = o.l + side * Double(k) * lightnessStep
                if l < 0 || l > 1 { continue }
                any = true
                let x = fromOklch(Oklch(l: l, c: o.c, h: o.h))
                let s = score(x)
                if s >= 1 { return x }
                if s > bestScore {
                    best = x
                    bestScore = s
                }
            }
            if !any { break }
        }
        return best
    }

    /// The color with the hue of `mix(base, toward, t)` and the luminance of
    /// `base`. Each color keeps its contrast against it, as against `base`.
    public static func tint(_ base: Int, toward: Int, _ t: Double) -> Int {
        let o = oklch(mix(base, toward, t))
        let target = luminance(base)
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if luminance(fromOklch(Oklch(l: mid, c: o.c, h: o.h))) < target { lo = mid } else { hi = mid }
        }
        let a = fromOklch(Oklch(l: lo, c: o.c, h: o.h))
        let b = fromOklch(Oklch(l: hi, c: o.c, h: o.h))
        return abs(luminance(a) - target) < abs(luminance(b) - target) ? a : b
    }

    /// Reduces the chroma of a color to `limit` at most. The lightness and the hue stay.
    public static func limitChroma(_ color: Int, max limit: Double) -> Int {
        let o = oklch(color)
        return o.c <= limit ? opaque(color) : fromOklch(Oklch(l: o.l, c: limit, h: o.h))
    }

    /// The color on the sRGB line from `from` to `to` whose contrast against
    /// `from` is `target`. When `to` is not far enough from `from`, it returns `to`.
    public static func stepTo(from: Int, to: Int, target: Double) -> Int {
        if contrast(from, to) <= target { return opaque(to) }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if contrast(from, mix(from, to, mid)) < target { lo = mid } else { hi = mid }
        }
        return mix(from, to, hi)
    }

    /// Writes 0xRRGGBB as "#rrggbb".
    public static func hex(_ color: Int) -> String {
        let s = String(opaque(color), radix: 16)
        return "#" + String(repeating: "0", count: Swift.max(0, 6 - s.count)) + s
    }

    /// Reads "#rrggbb" or "#rrggbbaa", with or without "#", as 0xRRGGBB. It drops the alpha.
    public static func parseColor(_ text: String?) -> Int? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        let scalars = Array(s.unicodeScalars)
        guard scalars.count == 6 || scalars.count == 8, scalars.allSatisfy({ isHexDigit($0) }) else { return nil }
        return Int(String(s.prefix(6)), radix: 16)
    }

    /// True for an ASCII hex digit. `Character.isHexDigit` also takes the fullwidth digits.
    static func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(s) || ("a"..."f").contains(s) || ("A"..."F").contains(s)
    }
}
