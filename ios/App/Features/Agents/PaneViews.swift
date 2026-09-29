import FluxKit
import SwiftUI

/// The output of an agent or a terminal as a small terminal: mono, and in
/// the colors of the pane. The view follows new lines at the end. When the
/// user scrolls up to read older lines, the view stays there, and a button
/// goes back to the newest lines.
struct PaneOutput: View {
    let output: HerdrOutput?

    var body: some View {
        Group {
            if let out = output, !(out.loading && out.lines.isEmpty) {
                if let error = out.error, out.lines.isEmpty {
                    ContentUnavailableView("No output", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    TerminalText(output: out)
                }
            } else {
                ProgressView("Reading the output…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How close to the end the output must be, in points, to follow new lines.
private let followSlack: CGFloat = 48

private struct TerminalText: View {
    let output: HerdrOutput
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if output.truncated {
                        Text("Older lines are cut.").font(.caption2.monospaced()).foregroundStyle(TermColors.dim)
                            .padding(.horizontal, termPad)
                    }
                    if let error = output.error {
                        Text(error).font(.caption).foregroundStyle(TermColors.red)
                            .padding(.horizontal, termPad)
                    }
                    if output.lines.isEmpty {
                        Text("No output yet.").font(TermColors.font).foregroundStyle(TermColors.dim)
                            .padding(.horizontal, termPad)
                    } else if width > 0 {
                        // The rows draw their own side padding, so the fill of a panel reaches both edges.
                        TermLinesView(lines: output.lines, width: width)
                            .textSelection(.enabled)
                    }
                    // The end of the output. Its place in the viewport tells
                    // whether the newest lines show.
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: EndOffset.self, value: g.frame(in: .named("output")).minY)
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
            .coordinateSpace(name: "output")
            .defaultScrollAnchor(.bottom)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear {
                        viewport = g.size.height
                        width = g.size.width
                    }
                    .onChange(of: g.size) { _, size in
                        viewport = size.height
                        width = size.width
                    }
            })
            .onPreferenceChange(EndOffset.self) { end in
                guard viewport > 0 else { return }
                follow = end <= viewport + followSlack
            }
            // New output scrolls to the newest lines, unless the user reads older ones.
            .onChange(of: output.text) {
                if follow { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow && !output.lines.isEmpty {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TermColors.blue)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TermColors.background))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TermColors.blue))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Show the newest lines")
                }
            }
        }
        .background(shape.fill(TermColors.background))
        .overlay(shape.strokeBorder(TermColors.border))
        .clipShape(shape)
    }
}

private struct EndOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A key of a key bar, with a mono label. `accent` marks the key that a
/// dialog needs.
struct PaneKey: View {
    let label: String
    let name: String
    var accent = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent ? Color.accentColor : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(shape.fill(accent ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground)))
                .overlay(shape.strokeBorder(accent ? Color.accentColor : Color(.separator).opacity(0.5)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// The screen of a computer that is not reachable.
struct PaneNotReachable: View {
    @Environment(AppModel.self) private var model
    let name: String
    let what: String

    var body: some View {
        ContentUnavailableView {
            Label("\(name) is not reachable", systemImage: "wifi.slash")
        } description: {
            Text("\(what) show here when \(name) connects again.")
        } actions: {
            Button("Retry") { model.core.search() }
        }
    }
}

/// The close action of an agent or a terminal: a confirmation, Face ID or
/// the passcode, and the close. The screen goes back when the computer
/// closed the pane.
struct PaneCloser: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceId: String
    let pane: String
    let title: String
    let message: String
    @Binding var asking: Bool
    @Binding var error: String?
    /// Only a close from this screen counts. Its number is higher than the
    /// last action at the tap.
    @State private var after = Int.max

    func body(content: Content) -> some View {
        let plugin = model.core.plugin(HerdrPlugin.self)
        let action = plugin?.model.actions[deviceId].flatMap { $0.action == "close" && $0.seq > after && $0.pane == pane ? $0 : nil }
        content
            .confirmationDialog(title, isPresented: $asking, titleVisibility: .visible) {
                Button("Close", role: .destructive) {
                    guard let plugin else { return }
                    let last = plugin.model.actions[deviceId]?.seq ?? 0
                    error = nil
                    ReplyLock.run(reason: "Close a pane on \(model.device(deviceId)?.name ?? "the computer").") {
                        after = last
                        plugin.close(deviceId, pane: pane)
                    } onError: { error = $0 }
                }
            } message: {
                Text(message)
            }
            .onChange(of: action) { _, a in
                guard let a, !a.sending else { return }
                if let e = a.error {
                    error = e
                } else {
                    plugin?.clearAction(deviceId, seq: a.seq)
                    dismiss()
                }
            }
    }
}

/// The Close key of the header of an agent or a terminal.
struct PaneCloseButton: View {
    let closing: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            if closing {
                ProgressView().controlSize(.small)
            } else {
                Text("Close").font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.borderless)
        .tint(.red)
        .disabled(closing)
        .accessibilityLabel("Close the pane")
    }
}
