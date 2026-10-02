import FluxKit
import SwiftUI

/// The title of an Inbox tile, in the form of a Hyprland window title: a
/// status dot, the state word in its color, then the source in mono, for
/// example "Needs input · codex · billing". 1 line, and the end of the
/// source goes first. VoiceOver does not read it, because the tile gives
/// the source and the state.
struct WindowTitle: View {
    enum Size {
        case master, stack
    }

    let item: InboxItem
    let size: Size
    @Environment(\.tn) private var tn

    var body: some View {
        let font: CGFloat = size == .master ? 12 : 11
        let dot: CGFloat = size == .master ? 8 : 7
        let color = tn.tone(item.tone)
        let source = item.sourceParts.joined(separator: " · ")
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: dot, height: dot)
            HStack(spacing: 0) {
                Text(item.stateWord)
                    .font(.system(size: font, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                if !source.isEmpty {
                    Text(" · " + source)
                        .font(.system(size: font, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
