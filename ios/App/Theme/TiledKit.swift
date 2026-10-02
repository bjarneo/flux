import FluxKit
import SwiftUI
import UIKit

/// The numbers of the tiled layout, in points.
enum TiledMetrics {
    /// The gap between tiles, as the Hyprland gaps.
    static let gap: CGFloat = 8
    /// The side margin of the screen.
    static let gutter: CGFloat = 10
    static let tileCorner: CGFloat = 12
    /// The corner of the smaller parts in a tile: choice rows, badges, and the command block.
    static let smallCorner: CGFloat = 8
    static let chipCorner: CGFloat = 10
    /// The widest column of the screens other than the Inbox.
    static let maxContentWidth: CGFloat = 840
    /// The widest choice row and action row of the master tile.
    static let maxActionWidth: CGFloat = 600
    /// The alpha of a tile, a tool, or a choice that takes no taps.
    static let disabledAlpha: Double = 0.55
}

/// The shape of a tile.
func tileShape(_ corner: CGFloat = TiledMetrics.tileCorner) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: corner, style: .continuous)
}

/// A tile: a fill and a 1 pt border on the tile shape. It has no shadow.
/// To raise a tile, use `tileHi` and `lineHi`.
struct TiledTile: ViewModifier {
    var fill: Color
    var border: Color
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(tileShape().fill(fill))
            .overlay(tileShape().strokeBorder(border, lineWidth: 1))
    }
}

extension View {
    func tiledTile(fill: Color, border: Color, padding: CGFloat = 14) -> some View {
        modifier(TiledTile(fill: fill, border: border, padding: padding))
    }

    /// The active border of the master position: the hyprland_active_border
    /// gradient of the theme, 2 pt wide.
    func activeBorder(_ tn: ThemeColors) -> some View {
        modifier(ActiveBorder(colors: tn))
    }

    /// The surfaces of the theme for a feature page: the theme background,
    /// the accent tint, and the light or dark mode of the theme. A `List`
    /// or a `Form` in the page shows the theme background behind its rows.
    /// The inside of the page keeps its own colors.
    func fluxScreen() -> some View {
        modifier(FluxScreen())
    }
}

/// See `View.fluxScreen()`.
struct FluxScreen: ViewModifier {
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(tn.bg.ignoresSafeArea())
            .tint(tn.accent)
            .environment(\.colorScheme, tn.dark ? .dark : .light)
    }
}

/// The active border on the tile shape. 1 color is a solid stroke. Without
/// an angle, the gradient goes from the top leading corner to the bottom
/// trailing corner. 0 degrees goes from left to right and 90 degrees from
/// top to bottom, as in Hyprland.
struct ActiveBorder: ViewModifier {
    let colors: ThemeColors

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                tileShape().strokeBorder(Self.style(colors.border, angle: colors.borderAngle, size: geo.size), lineWidth: 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The gradient that spans the whole box at `angle`, with evenly spaced stops.
    static func style(_ colors: [Color], angle: Double?, size: CGSize) -> AnyShapeStyle {
        guard let first = colors.first else { return AnyShapeStyle(Color.clear) }
        if colors.count == 1 { return AnyShapeStyle(first) }
        let w = Double(size.width)
        let h = Double(size.height)
        guard let angle, w > 0, h > 0 else {
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        let rad = angle * Double.pi / 180
        let dx = cos(rad)
        let dy = sin(rad)
        let half = (abs(w * dx) + abs(h * dy)) / 2
        let start = UnitPoint(x: CGFloat(0.5 - dx * half / w), y: CGFloat(0.5 - dy * half / h))
        let end = UnitPoint(x: CGFloat(0.5 + dx * half / w), y: CGFloat(0.5 + dy * half / h))
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: start, endPoint: end))
    }
}

// MARK: Buttons

/// The kinds of the 1 button of the app.
enum FluxButtonKind {
    /// The main action of a screen or a tile: the accent fill.
    case filled
    /// A second action that still needs weight.
    case tonal
    /// A second action: an outline and the accent text.
    case outlined
    /// An action that ends or deletes for good: a red outline and red text.
    case destructive
    /// A small action in a line of text, such as Retry or Later.
    case text
}

/// The button of the app, on the tile shape. It is 44 pt high or more, and
/// its label wraps at a large text size. A disabled button takes the `tile`
/// fill or no fill, and a `dim` label.
struct FluxButtonStyle: ButtonStyle {
    var kind: FluxButtonKind = .filled
    /// True to fill the width that the button gets.
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FluxButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }
}

private struct FluxButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FluxButtonKind
    let fullWidth: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(ink)
            .padding(.horizontal, kind == .text ? 12 : 18)
            .padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var fill: Color {
        switch kind {
        case .filled: return enabled ? tn.accent : tn.tile
        case .tonal: return enabled ? tn.line : tn.tile
        case .outlined, .destructive, .text: return .clear
        }
    }

    private var ink: Color {
        guard enabled else { return tn.dim }
        switch kind {
        case .filled: return tn.onAccent
        case .tonal: return tn.text
        case .outlined, .text: return tn.accent
        case .destructive: return tn.red
        }
    }

    private var stroke: Color {
        switch kind {
        case .outlined: return enabled ? tn.dim : tn.line
        case .destructive: return enabled ? tn.red : tn.line
        case .filled, .tonal, .text: return .clear
        }
    }
}

/// A button on a tile. The border takes the accent while pressed.
struct TiledPressStyle: ButtonStyle {
    var fill: Color
    var border: Color
    var borderWidth: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, fill: fill, border: border, borderWidth: borderWidth)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let border: Color
        let borderWidth: CGFloat
        @Environment(\.tn) private var tn

        var body: some View {
            configuration.label
                .background(tileShape().fill(fill))
                .overlay(tileShape().strokeBorder(configuration.isPressed ? tn.accent : border, lineWidth: borderWidth))
                .contentShape(tileShape())
        }
    }
}

// MARK: Tools

/// The most used tool of a destination: full width, 128 pt high or more,
/// on `tileHi`. The icon sits at the top and the label at the bottom.
struct MasterTool: View {
    let icon: String
    let title: String
    let line: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundStyle(enabled ? tn.accent : tn.sub)
                    .accessibilityHidden(true)
                Spacer(minLength: 16)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tn.text)
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(18)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tileHi, border: tn.lineHi))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// A tool in a group: full width, 56 pt high or more, on `tile`. A badge
/// above 0 counts the items that need the user.
struct ToolRow: View {
    let icon: String
    let title: String
    let line: String
    var badge = 0
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundStyle(enabled ? tn.accent : tn.sub)
                    .frame(minWidth: iconSize + 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(tn.sub)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if badge > 0 {
                    NeedsBadge(count: badge)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// The heading of a group of tools.
struct SectionLabel: View {
    let text: String
    @Environment(\.tn) private var tn

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tn.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The count of items that need the user: 1 to 9, then 9+, on `red`.
struct NeedsBadge: View {
    let count: Int
    @Environment(\.tn) private var tn

    var body: some View {
        Text(verbatim: count > 9 ? "9+" : String(count))
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(tn.onAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tileShape(TiledMetrics.smallCorner).fill(tn.red))
            .accessibilityLabel(count == 1 ? "1 needs you" : "\(count) need you")
    }
}

// MARK: States

/// The link of a computer: an 8 pt `green` dot while it is connected, or a
/// ring while it is not reachable.
struct LinkDot: View {
    let online: Bool
    var size: CGFloat = 8
    @Environment(\.tn) private var tn

    var body: some View {
        Group {
            if online {
                Circle().fill(tn.green)
            } else {
                Circle().strokeBorder(tn.sub, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The battery of a computer as a dot. It is never red, because red means
/// that something needs the user.
struct BatteryDot: View {
    let state: BatteryState
    var size: CGFloat = 8
    @Environment(\.tn) private var tn

    init(_ state: BatteryState, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var color: Color {
        if state.charging { return tn.green }
        if state.charge <= 20 { return tn.orange }
        if state.charge <= 50 { return tn.yellow }
        return tn.cyan
    }
}

/// A spinner in the accent. With Reduce Motion, it is a fixed ring of 3 quarters.
struct FluxSpinner: View {
    var size: CGFloat = 18
    var color: Color?
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(color ?? tn.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .tint(color ?? tn.accent)
                .frame(width: size, height: size)
        }
    }
}

/// Lines in the place of text that loads. The bars pulse, except with
/// Reduce Motion. VoiceOver reads `label`.
struct LineSkeleton: View {
    var widths: [CGFloat] = [0.9, 0.7, 0.5]
    let label: String
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        let height = CGFloat(widths.count) * 12 + CGFloat(max(0, widths.count - 1)) * 10
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tn.line)
                        .frame(width: geo.size.width * w, height: 12)
                }
            }
        }
        .frame(height: height)
        .opacity(dimmed ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A command to copy, such as `flux-cli setup`, in mono on `offTile`.
struct CommandBlock: View {
    let command: String
    @Environment(\.tn) private var tn
    @State private var copied = false

    init(_ command: String) { self.command = command }

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.footnote.monospaced())
                .foregroundStyle(tn.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = command
                copied = true
            }
            .buttonStyle(FluxButtonStyle(kind: .text))
            .accessibilityHint("Copies the command")
        }
        .padding(.leading, 12)
        .padding([.trailing, .vertical], 2)
        .background(tileShape(TiledMetrics.smallCorner).fill(tn.offTile))
        .overlay(tileShape(TiledMetrics.smallCorner).strokeBorder(tn.line, lineWidth: 1))
    }
}
