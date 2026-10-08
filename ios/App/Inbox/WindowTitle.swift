import FluxKit
import SwiftUI

/// The window title of an Inbox item, as Hyprland shows a window: a dot in
/// the color of the state, the state word in that color, and the source of
/// the item in mono, for example "Needs input · codex · billing". The state
/// comes first, so that a line that is too long cuts only the source, and
/// the state does not depend on the color. With `many` computers in scope,
/// the source ends with the computer. Without `showSource`, only the state
/// shows. A working agent shows a ring that turns in the place of the dot,
/// and the master marks what needs the user with a dot that pulses.
/// VoiceOver does not read the title, because the tile gives the source and
/// the state.
struct WindowTitle: View {
    enum Size {
        /// The master tile: the footnote size.
        case master
        /// A stack tile: the caption size.
        case stack
    }

    let item: InboxItem
    let size: Size
    var many = false
    var showSource = true
    @Environment(\.tn) private var tn
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let color = tn.tone(item.tone)
        let font: Font = size == .master ? .footnote : .caption
        let dot: CGFloat = size == .master ? 8 : 7
        let parts = showSource ? item.sourceParts + (many && !item.computer.isEmpty ? [item.computer] : []) : []
        let source = parts.joined(separator: " · ")
        Group {
            // From the xxxLarge size, the state takes line 1 and the source
            // line 2. A stack tile keeps line 2 also without a source, so
            // that the tiles of 1 row keep the same height.
            if typeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        mark(color, dot)
                        Text(item.stateWord)
                            .font(font.weight(.medium))
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    if size == .stack || !source.isEmpty {
                        Text(source.isEmpty ? " " : source)
                            .font(font.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                            .padding(.leading, dot + 8)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    mark(color, dot)
                    HStack(spacing: 0) {
                        Text(item.stateWord)
                            .font(font.weight(.medium))
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                        if !source.isEmpty {
                            Text(" · " + source)
                                .font(font.monospaced())
                                .foregroundStyle(tn.sub)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mark(_ color: Color, _ dot: CGFloat) -> some View {
        if item.kind == .agentWorking {
            RingSpinner(size: 11, color: color)
        } else {
            PulseDot(color: color, size: dot, pulse: size == .master && item.kind.needsYou)
        }
    }
}
