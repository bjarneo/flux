import AppKit
import SwiftUI

/// Places cards in a grid of equal columns. The cards of one row get the
/// height of the tallest card in that row. Views with no height take no
/// place in the grid.
struct CardGridLayout: Layout {
    var minColumnWidth: CGFloat = 300
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minColumnWidth * 2 + spacing
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (view, frame) in zip(subviews, frames) {
            guard let frame else {
                view.place(at: bounds.origin, proposal: .zero)
                continue
            }
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect?], height: CGFloat) {
        let columns = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        let visible = heights.indices.filter { heights[$0] > 0 }
        var frames = [CGRect?](repeating: nil, count: subviews.count)
        var y: CGFloat = 0
        for rowStart in stride(from: 0, to: visible.count, by: columns) {
            let row = visible[rowStart..<min(rowStart + columns, visible.count)]
            let rowHeight = row.map { heights[$0] }.max() ?? 0
            for (column, index) in row.enumerated() {
                frames[index] = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: rowHeight)
            }
            y += rowHeight + spacing
        }
        return (frames, max(0, y - spacing))
    }
}

/// The background of a dashboard card or the device header.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

/// One feature on the device dashboard: a titled card with its main
/// controls, and optional details that the user expands. The expanded state
/// is saved per card.
struct DashboardCard<Accessory: View, Content: View, Details: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let detailsTitle: String
    let accessory: Accessory
    let content: Content
    let details: Details
    @AppStorage private var expanded: Bool

    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        detailsTitle: String = "Settings",
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content,
        @ViewBuilder details: () -> Details
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detailsTitle = detailsTitle
        self.accessory = accessory()
        self.content = content()
        self.details = details()
        _expanded = AppStorage(wrappedValue: false, "dashboard.\(title).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.15)))
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory
            }
            content
            if Details.self != EmptyView.self {
                Divider()
                Button {
                    withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
                } label: {
                    HStack {
                        Text(detailsTitle)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Hide" : "Show") \(detailsTitle) of \(title)")
                if expanded {
                    VStack(alignment: .leading, spacing: 12) { details }
                        .transition(.opacity)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

extension DashboardCard where Details == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, systemImage: systemImage, tint: tint, accessory: accessory, content: content, details: { EmptyView() })
    }
}

extension DashboardCard where Accessory == EmptyView, Details == EmptyView {
    init(_ title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, tint: tint, accessory: { EmptyView() }, content: content, details: { EmptyView() })
    }
}

extension DashboardCard where Accessory == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        tint: Color,
        detailsTitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder details: () -> Details
    ) {
        self.init(title, systemImage: systemImage, tint: tint, detailsTitle: detailsTitle, accessory: { EmptyView() }, content: content, details: details)
    }
}

/// A label on the left and a control on the right.
struct CardRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            control
        }
    }
}

/// A switch with a title and an optional explanation.
struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A slider with its title and its value.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// A short colored state, such as Live or Enrolled.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// A large button with an icon over a short title, for quick actions and modes.
struct Tile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .buttonStyle(TileButtonStyle())
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.09 : 0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// A strip at the top of the dashboard for something that needs attention now.
struct Banner<Actions: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    let actions: Actions

    init(_ text: String, systemImage: String, tint: Color, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            Text(text)
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}
