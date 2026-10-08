import FluxKit
import SwiftUI

/// The title of an Inbox tile, in the form of a Hyprland window title: a
/// status dot, the state word in its color, then the source in mono, for
/// example "Needs input · codex · billing". 1 line, and the end of the
/// source goes first. With `many` computers in scope, the source ends with
/// the computer. Without `showSource`, only the state shows. A working
/// agent shows a ring that turns in the place of the dot, and the master
/// marks what needs the user with a dot that pulses. VoiceOver does not
/// read it, because the tile gives the source and the state.
struct WindowTitle: View {
    enum Size {
        case master, stack
    }

    let item: InboxItem
    let size: Size
    var many = false
    var showSource = true
    @Environment(\.tn) private var tn

    var body: some View {
        let font: CGFloat = size == .master ? 12 : 11
        let dot: CGFloat = size == .master ? 8 : 7
        let color = tn.tone(item.tone)
        let parts = showSource ? item.sourceParts + (many && !item.computer.isEmpty ? [item.computer] : []) : []
        let source = parts.joined(separator: " · ")
        HStack(spacing: 7) {
            if item.kind == .agentWorking {
                RingSpinner(size: 10, color: color)
            } else {
                PulseDot(color: color, size: dot, pulse: size == .master && item.kind.needsYou)
            }
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
