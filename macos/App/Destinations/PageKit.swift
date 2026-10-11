import AppKit
import FluxKit
import SwiftUI

// The parts of the destination pages of the app design, in the sizes of the
// Mac app: the computer pills, the progress line, the list headings, the
// tool tiles of the grids, and the dock at the bottom of a page. The window
// toolbar shows the title of a page, and its subtitle shows the context
// line, such as "to omarchy-xps · 2 of 3 online".

// MARK: Context

/// "2 of 3 online" for the paired computers, or "" when none is paired.
@MainActor
func onlineText(_ model: AppModel) -> String {
    let paired = model.paired
    guard !paired.isEmpty else { return "" }
    return "\(paired.filter(\.online).count) of \(paired.count) online"
}

/// The name of the computer in scope, or "all computers".
@MainActor
func scopeName(_ model: AppModel) -> String {
    model.pairedDevice(model.scope)?.name ?? "all computers"
}

/// The parts of a context line that are not empty, joined with " · ".
func contextLine(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " · ")
}

// MARK: Pills

/// A pill of a strip: a mark, the label, and `meta` in mono. The selected
/// pill has the accent. A `dim` pill shows at 55%, for a computer that is
/// offline.
struct StripPill<Mark: View>: View {
    let label: String
    let selected: Bool
    var meta = ""
    var dim = false
    var help = ""
    let action: () -> Void
    @ViewBuilder let mark: () -> Mark
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = Capsule()
        Button(action: action) {
            HStack(spacing: 7) {
                mark()
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 11)
            .frame(height: 30)
            .background(shape.fill(selected ? tn.accentTile : tn.tile))
            .overlay(shape.strokeBorder(selected ? tn.accent : tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .opacity(dim ? TiledMetrics.disabledAlpha : 1)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mark of something that is off or paused: a ring.
struct RingMark: View {
    var size: CGFloat = 9
    @Environment(\.tn) private var tn

    var body: some View {
        Circle().strokeBorder(tn.lineHi, lineWidth: 2)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A row of pills under the toolbar. It scrolls to the side.
struct PillStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, TiledMetrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// The paired computers as pills. The pill of the computer in scope has the
/// accent, and a click on it shows all computers again. A click on another
/// pill makes that computer the scope. A computer that is offline shows
/// dimmed and does not take the scope. The battery shows as a dot and a
/// number.
struct ComputerPills: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let batteries = model.core.plugin(BatteryPlugin.self)?.model.computers ?? [:]
        if !model.paired.isEmpty {
            PillStrip {
                ForEach(model.paired) { d in
                    let on = model.scope == d.id
                    let battery = d.online ? batteries[d.id] : nil
                    StripPill(label: d.name, selected: on, meta: d.online ? battery.map { "\($0.charge)%" } ?? "" : "offline",
                              dim: !d.online, help: on ? "Show all computers" : "Show only \(d.name)") {
                        if on {
                            model.setScope(nil)
                        } else if d.online {
                            model.setScope(d.id)
                        } else {
                            model.show("\(d.name) is not reachable")
                        }
                    } mark: {
                        if d.online {
                            HStack(spacing: 3) {
                                LinkDot(online: true)
                                if let battery { BatteryDot(battery) }
                            }
                        } else {
                            RingMark()
                        }
                    }
                    .accessibilityLabel("\(d.name), \(linkText(d, battery: battery))")
                }
            }
        }
    }
}

// MARK: Lines

/// The line of 2 pt under the pills. `content` draws the progress on it.
struct ProgressLine<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.tn) private var tn

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tn.line)
            content()
        }
        .frame(height: 2)
        .clipped()
    }
}

extension ProgressLine where Content == EmptyView {
    /// A line with no progress.
    init() {
        self.init { EmptyView() }
    }
}

/// The part `fraction` of a line or a bar, in `color`.
struct LineFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(color)
                .frame(width: geo.size.width * min(max(fraction, 0), 1))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Lists

/// The heading of a group of rows: the title, and `trailing` in mono at the
/// end, such as a count. `action` draws at the end, for example a link.
struct ListHeading<Action: View>: View {
    let title: String
    var trailing = ""
    @ViewBuilder var action: () -> Action
    @Environment(\.tn) private var tn

    init(_ title: String, trailing: String = "", @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            action()
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

extension ListHeading where Action == EmptyView {
    /// A heading with no action.
    init(_ title: String, trailing: String = "") {
        self.init(title, trailing: trailing) { EmptyView() }
    }
}

/// Lays out `items` in rows of `columns`. Each row takes the height of its
/// highest item.
struct GridRows<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        Grid(horizontalSpacing: TiledMetrics.gap, verticalSpacing: TiledMetrics.gap) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)]) { item in
                        cell(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(0..<(columns - min(columns, items.count - start)), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}

// MARK: Tools

/// A tool of a grid: an icon, a label, and a line. The `small` form puts
/// the icon over the label in the center, for the Stream grid.
struct GridTool: View, Identifiable {
    let id: String
    let icon: String
    let title: String
    var line = ""
    var enabled = true
    var small = false
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        Button(action: action) {
            Group {
                if small {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .foregroundStyle(enabled ? tn.accent : tn.sub)
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tn.text)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .foregroundStyle(enabled ? tn.accent : tn.sub)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tn.text)
                            if !line.isEmpty {
                                Text(line)
                                    .font(.system(size: 11))
                                    .foregroundStyle(tn.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help(line.isEmpty ? title : line)
    }
}

/// A key of a dock on the page color: an icon or a label in a rounded box
/// with an optional border.
struct DockKey<Label: View>: View {
    let help: String
    var enabled = true
    var border: Color?
    var corner: CGFloat = TiledMetrics.tileCorner
    var height: CGFloat = 48
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: height)
                .background(shape.fill(tn.bg))
                .overlay { if let border { shape.strokeBorder(border, lineWidth: 1) } }
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Dock

/// The frame of the dock at the bottom of a page: the tile color with the
/// round corners at the top and a line along the top edge. The content
/// stays in the column of the page.
struct PageDock: ViewModifier {
    var top: CGFloat = 14
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, top)
            .padding(.bottom, 10)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(DockShape().fill(tn.tile))
            .overlay(alignment: .top) {
                // The line along the top edge and the round corners.
                DockShape().stroke(tn.line, lineWidth: 1).frame(height: 40).mask(alignment: .top) { Rectangle().frame(height: 20) }
            }
    }
}

extension View {
    /// Puts the view in the dock at the bottom of a page. See `PageDock`.
    func pageDock(top: CGFloat = 14) -> some View {
        modifier(PageDock(top: top))
    }

    /// The column of the content of a page: at most the content width, in the center, with the gutter.
    func pageColumn(top: CGFloat = 6, bottom: CGFloat = 20) -> some View {
        self
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Time

/// The time on this Mac, such as "13:41", in the format of the system.
func clockTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// "Today", "Yesterday", or the date of `date`.
func dayText(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

/// A position or a length in milliseconds as "3:19" or "1:02:03".
func mediaClock(_ ms: Int64) -> String {
    let s = Int(max(ms, 0) / 1000)
    let h = s / 3600, m = s / 60 % 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
