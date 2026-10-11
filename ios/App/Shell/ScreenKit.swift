import FluxKit
import SwiftUI

// The parts of Send, Control, Computers, Media, and the Omarchy panel in
// the app design, like the Android screens: the title with the context
// line, the computer pills, the progress line, the list headings, the
// tools of the grids, and the dock. The agent thread parts are in
// AgentThreadViews.swift.

// MARK: Header

/// The Flux mark: a square outline with a bar in the accent through its
/// middle, like the launcher icon.
struct FluxMark: View {
    var size: CGFloat = 22
    @Environment(\.tn) private var tn

    var body: some View {
        Canvas { context, box in
            let u = min(box.width, box.height) / 16
            context.stroke(Path(CGRect(x: 4 * u, y: 4 * u, width: 8 * u, height: 8 * u)), with: .color(tn.text), lineWidth: 2 * u)
            context.fill(Path(CGRect(x: 7 * u, y: u, width: 2 * u, height: 14 * u)), with: .color(tn.accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The title of a screen and its context line in mono, such as
/// "to omarchy · 2 of 3 online".
struct ScreenTitle: View {
    let title: String
    let context: String
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tn.text)
                .lineLimit(1)
            if !context.isEmpty {
                Text(context)
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The root of Send, Control, and Computers: the Flux mark, the title, and
/// the context line at the leading side of the navigation bar, on the
/// theme background.
struct DestinationRoot: ViewModifier {
    let title: String
    let context: String
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .background(tn.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        FluxMark()
                        ScreenTitle(title: title, context: context)
                    }
                }
            }
            .toolbarBackground(tn.bg, for: .navigationBar)
            .toolbarColorScheme(tn.dark ? .dark : .light, for: .navigationBar)
    }
}

/// The title of a screen above a destination, such as Media: the title and
/// the context line in the middle of the navigation bar, after Back.
struct FeatureTitle: ViewModifier {
    let title: String
    let context: String
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .background(tn.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ScreenTitle(title: title, context: context) }
            }
    }
}

extension View {
    /// See `DestinationRoot`.
    func destinationRoot(_ title: String, context: String) -> some View {
        modifier(DestinationRoot(title: title, context: context))
    }

    /// See `FeatureTitle`.
    func featureTitle(_ title: String, context: String) -> some View {
        modifier(FeatureTitle(title: title, context: context))
    }

    /// The frame of a dock at the bottom of a screen: the tile color with
    /// round top corners, and a line along the top edge.
    func dockFrame() -> some View {
        modifier(DockFrame())
    }
}

/// See `View.dockFrame()`.
struct DockFrame: ViewModifier {
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .background(DockShape().fill(tn.tile).ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                DockShape().stroke(tn.line, lineWidth: 1).frame(height: 40).mask(alignment: .top) { Rectangle().frame(height: 20) }
            }
    }
}

/// The context words of the destinations.
@MainActor
enum ScreenWords {
    /// "2 of 3 online" for the paired computers, or empty when none is paired.
    static func online(_ model: AppModel) -> String {
        let paired = model.paired
        guard !paired.isEmpty else { return "" }
        return "\(paired.filter(\.online).count) of \(paired.count) online"
    }

    /// The name of the computer in scope, or "all computers".
    static func scopeName(_ model: AppModel) -> String {
        model.paired.first { $0.id == model.scope }?.name ?? "all computers"
    }

    /// The parts that are not empty, with " · " between them.
    static func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
}

// MARK: Pills

/// A pill of a strip: a mark, the label, and the meta text in mono. The
/// selected pill has the accent. A dim pill shows at 55%, for a computer
/// that is offline. It draws 36 pt high and takes taps on 44 pt.
struct StripPill<Mark: View>: View {
    let label: String
    let selected: Bool
    var meta = ""
    var dim = false
    let action: () -> Void
    @ViewBuilder let mark: Mark
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                mark
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(selected ? tn.accentTile : tn.tile))
            .overlay(Capsule().strokeBorder(selected ? tn.accent : tn.line))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dim ? TiledMetrics.disabledAlpha : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mark of something that is off or paused: a ring of 10 pt.
struct RingMark: View {
    @Environment(\.tn) private var tn

    var body: some View {
        Circle().strokeBorder(tn.lineHi, lineWidth: 2).frame(width: 10, height: 10).accessibilityHidden(true)
    }
}

/// The paired computers as pills. The pill of the computer in scope has the
/// accent, and a tap on it shows all computers again. A tap on another
/// pill makes that computer the scope. A computer that is offline shows
/// dimmed and does not take the scope.
struct ComputerStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let paired = model.paired
        let batteries = model.core.plugin(BatteryPlugin.self)?.model.computers ?? [:]
        if !paired.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(paired) { d in
                        let on = model.scope == d.id
                        StripPill(label: d.name, selected: on,
                                  meta: !d.online ? "offline" : batteries[d.id].map { "\($0.charge)%" } ?? "",
                                  dim: !d.online) {
                            if on {
                                model.setScope(nil)
                            } else if d.online {
                                model.setScope(d.id)
                            } else {
                                model.show("\(d.name) is not reachable")
                            }
                        } mark: {
                            if d.online { Circle().fill(tn.green).frame(width: 8, height: 8) } else { RingMark() }
                        }
                        .accessibilityLabel(d.name)
                        .accessibilityValue(d.linkText(battery: batteries[d.id]))
                        .accessibilityHint(on ? "Shows all computers" : "Shows only \(d.name)")
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 2)
        }
    }
}

/// The line of 2 pt under the pills. `content` draws the progress on it.
struct ProgressLine<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.tn) private var tn

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tn.line)
            content
        }
        .frame(height: 2)
        .clipped()
        .accessibilityHidden(true)
    }
}

extension ProgressLine where Content == EmptyView {
    init() { content = EmptyView() }
}

/// The part `fraction` of a line or a bar in `color`.
struct LineFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            Rectangle().fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: Lists

/// The heading of a group of rows: the title, and `trailing` in mono at the
/// end, such as a count. VoiceOver reads the title as a heading.
struct ListHeader<Action: View>: View {
    let title: String
    var trailing = ""
    @ViewBuilder var action: Action
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            action
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

extension ListHeader where Action == EmptyView {
    init(_ title: String, trailing: String = "") {
        self.title = title
        self.trailing = trailing
        action = EmptyView()
    }
}

// MARK: Tools

/// A tool of a 2-column grid: the icon at the top, then the title and the
/// line under it. A tool that is not enabled shows dimmed and takes no taps.
struct GridTool: View {
    let icon: String
    let title: String
    let line: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                    if !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(tn.sub)
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// A tool of a 3-column grid: the icon over the title, in the center.
struct SmallTool: View {
    let icon: String
    let title: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// A key of a dock on the page color, such as a tool of Send or an arrow of
/// the Omarchy panel. A long press runs `onHold` when it is set.
struct DockKeyButton<Label: View>: View {
    let name: String
    var height: CGFloat = 56
    var corner: CGFloat = 12
    var border: Color?
    var enabled = true
    var onHold: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        label
            .frame(maxWidth: .infinity, minHeight: height)
            .background(shape.fill(tn.bg))
            .overlay(shape.strokeBorder(border ?? .clear, lineWidth: 1))
            .contentShape(shape)
            .onTapGesture { if enabled { action() } }
            .onLongPressGesture(minimumDuration: 0.45) { if enabled { onHold?() } }
            .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { action() } }
    }
}

/// The time words of the screens: the time of a day, and the day header.
enum ThreadTime {
    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "Today", "Yesterday", or the date.
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// The position of a player, such as 3:19, from milliseconds.
    static func position(_ ms: Int64) -> String {
        let s = Int(max(0, ms) / 1000)
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
