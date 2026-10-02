import AppKit
import FluxKit
import SwiftUI

/// The numbers of the tiled layout on the Mac, in points.
enum TiledMetrics {
    /// The gap between 2 tiles.
    static let gap: CGFloat = 8
    /// The side margin of a page.
    static let gutter: CGFloat = 12
    static let tileCorner: CGFloat = 12
    /// The corner of the smaller parts in a tile: choice rows, buttons, badges, the command block.
    static let smallCorner: CGFloat = 8
    static let chipCorner: CGFloat = 10
    /// The widest column of the pages other than the Inbox.
    static let maxContentWidth: CGFloat = 840
    /// The widest choice row and action row in the master tile.
    static let maxActionWidth: CGFloat = 600
    /// The alpha of a tile, a tool, or a choice that takes no clicks.
    static let disabledAlpha: Double = 0.55
    /// The least height of a stack tile and a choice row.
    static let rowHeight: CGFloat = 36
    /// The least height of a button.
    static let buttonHeight: CGFloat = 28
}

/// The theme surfaces of a page or a window: the theme background, the
/// tint, the light or dark mode of the palette, and no system background
/// behind a `List` or a `Form`. The inside of a feature keeps its colors.
struct FluxScreen: ViewModifier {
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(tn.bg)
            .tint(tn.accent)
            .environment(\.colorScheme, tn.dark ? .dark : .light)
    }
}

extension View {
    /// Puts the theme surfaces on a root. See `FluxScreen`.
    func fluxScreen() -> some View {
        modifier(FluxScreen())
    }

    /// A tile with a fill, a 1 pt border, and the tile corner. No shadow.
    func tiledTile(fill: Color, border: Color, padding: CGFloat = 14) -> some View {
        modifier(TiledTile(fill: fill, border: border, padding: padding))
    }

    /// The active border of Hyprland around the master tile.
    func activeBorder(_ colors: ThemeColors) -> some View {
        modifier(ActiveBorder(colors: colors))
    }
}

/// A tile: a fill, a 1 pt border, and the tile corner. To raise a tile,
/// use `tileHi` and `lineHi`.
struct TiledTile: ViewModifier {
    let fill: Color
    let border: Color
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

/// A 2 pt border with the gradient of `hyprland_active_border` at its
/// angle. 1 color gives a solid border. Without an angle, the gradient goes
/// from the top left corner to the bottom right corner. Only the master
/// position uses it.
struct ActiveBorder: ViewModifier {
    let colors: ThemeColors

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
                let stops = colors.border
                if stops.count < 2 {
                    shape.strokeBorder(stops.first ?? colors.accent, lineWidth: 2)
                } else {
                    let ends = Self.ends(angle: colors.borderAngle, size: geo.size)
                    shape.strokeBorder(LinearGradient(colors: stops, startPoint: ends.start, endPoint: ends.end), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The ends of the gradient as unit points. 0 degrees goes from left to
    /// right, and 90 degrees goes from top to bottom, as in Hyprland.
    static func ends(angle: Double?, size: CGSize) -> (start: UnitPoint, end: UnitPoint) {
        guard let angle, size.width > 0, size.height > 0 else { return (.topLeading, .bottomTrailing) }
        let rad = angle * Double.pi / 180
        let dx = cos(rad)
        let dy = sin(rad)
        let w = Double(size.width)
        let h = Double(size.height)
        let half = (abs(w * dx) + abs(h * dy)) / 2
        let start = UnitPoint(x: 0.5 - dx * half / w, y: 0.5 - dy * half / h)
        let end = UnitPoint(x: 0.5 + dx * half / w, y: 0.5 + dy * half / h)
        return (start, end)
    }
}

/// A button style that only dims the label while it is pressed. The label
/// draws its own tile.
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The kinds of the 1 button of the app.
enum FluxButtonKind {
    /// The main action of a page or a tile.
    case filled
    /// A second action with weight.
    case tonal
    /// A second action.
    case outlined
    /// An action that ends or deletes for good.
    case destructive
    /// A small action in a line of text, such as Retry or Later.
    case text
}

/// The button of the app. It is 28 pt high or more. A disabled button
/// takes the `dim` label.
struct FluxButtonStyle: ButtonStyle {
    var kind: FluxButtonKind = .filled

    func makeBody(configuration: Configuration) -> some View {
        FluxButtonBody(configuration: configuration, kind: kind)
    }
}

private struct FluxButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FluxButtonKind
    @Environment(\.tn) private var tn
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(labelColor)
            .multilineTextAlignment(.center)
            .padding(.horizontal, kind == .text ? 8 : 14)
            .padding(.vertical, 5)
            .frame(minHeight: TiledMetrics.buttonHeight)
            .background(shape.fill(fill))
            .overlay(shape.fill(tn.text.opacity(hovering && enabled ? 0.06 : 0)))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
    }

    private var labelColor: Color {
        guard enabled else { return tn.dim }
        switch kind {
        case .filled: return tn.onAccent
        case .tonal: return tn.text
        case .outlined, .text: return tn.accent
        case .destructive: return tn.red
        }
    }

    private var fill: Color {
        switch kind {
        case .filled: return enabled ? tn.accent : tn.tile
        case .tonal: return enabled ? tn.line : tn.tile
        case .outlined, .destructive, .text: return Color.clear
        }
    }

    private var border: Color {
        switch kind {
        case .outlined: return enabled ? tn.dim : tn.line
        case .destructive: return enabled ? tn.red : tn.line
        case .filled, .tonal, .text: return Color.clear
        }
    }
}

/// The large tool at the top of Send and Control: an icon at the top, the
/// label and its line at the bottom, on `tileHi`.
struct MasterTool: View {
    let icon: String
    let title: String
    let line: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        Button(action: action) {
            // The icon sits at the top, and the label and its line at the bottom.
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tn.text)
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 38)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .bottomLeading)
            .overlay(alignment: .topLeading) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(enabled ? tn.accent : tn.sub)
            }
            .padding(16)
            .background(shape.fill(tn.tileHi))
            .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// The content of a tool row. `ToolRow` and the Settings link use it.
struct ToolRowLabel: View {
    let icon: String
    let title: String
    let line: String
    var badge = 0
    var enabled = true
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(enabled ? tn.accent : tn.sub)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(tn.sub)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if badge > 0 {
                NeedsBadge(count: badge)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(shape.fill(tn.tile))
        .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
        .contentShape(shape)
    }
}

/// A tool of Send or Control: an icon, a label, a line, and a badge of the
/// items that need the user.
struct ToolRow: View {
    let icon: String
    let title: String
    let line: String
    var badge = 0
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolRowLabel(icon: icon, title: title, line: line, badge: badge, enabled: enabled)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// The heading of a group of tools or rows.
struct SectionLabel: View {
    let text: String
    @Environment(\.tn) private var tn

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tn.text)
            .padding(.leading, 4)
            .padding(.top, 16)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The link state of a computer: a `green` dot when it is online, else a ring.
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

/// The battery of a computer as a dot: `green` while it charges, `orange`
/// at 20% or less, `yellow` at 50% or less, else `cyan`. Never red.
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

/// The link text of a computer: "Not reachable", "Connected, battery 80%",
/// or "Connected".
func linkText(_ device: DeviceSnapshot, battery: BatteryState?) -> String {
    guard device.online else { return "Not reachable" }
    guard let battery else { return "Connected" }
    return "Connected, battery \(battery.charge)%" + (battery.charging ? ", charging" : "")
}

/// The spinner of the app. With Reduce Motion, it is a fixed ring of 3 quarters.
struct FluxSpinner: View {
    var size: CGFloat = 14
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(tn.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Bars in `line` that stand in for text that loads. They pulse, except
/// with Reduce Motion. VoiceOver reads `label`.
struct LineSkeleton: View {
    let widths: [CGFloat]
    let label: String
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded = false

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(widths.enumerated()), id: \.offset) { entry in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tn.line)
                        .frame(width: max(0, geo.size.width * entry.element), height: 10)
                }
            }
        }
        .frame(height: CGFloat(widths.count) * 18)
        .opacity(faded ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { faded = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// The count of the items that need the user, in `onAccent` on `red`.
struct NeedsBadge: View {
    let count: Int
    @Environment(\.tn) private var tn

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tn.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous).fill(tn.red))
            .accessibilityLabel(count == 1 ? "1 needs you" : "\(count) need you")
    }
}

/// A command to run on the computer, with a copy button.
struct CommandBlock: View {
    let command: String
    @Environment(\.tn) private var tn
    @State private var copied = false

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous)
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tn.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(FluxButtonStyle(kind: .text))
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(shape.fill(tn.offTile))
        .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { copied = false }
        }
    }
}
