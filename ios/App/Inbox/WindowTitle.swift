import FluxKit
import SwiftUI

/// The window title of an Inbox item, as Hyprland shows a window: a dot in
/// the color of the state, the state word in that color, and the source of
/// the item in mono, for example "Needs input · codex · billing". The state
/// comes first, so that a line that is too long cuts only the source, and
/// the state does not depend on the color. VoiceOver does not read the
/// title, because the tile gives the source and the state.
struct WindowTitle: View {
    enum Size {
        /// The master tile: the footnote size.
        case master
        /// A stack tile: the caption size.
        case stack
    }

    let item: InboxItem
    let size: Size
    @Environment(\.tn) private var tn
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let color = tn.tone(item.tone)
        let font: Font = size == .master ? .footnote : .caption
        let dot: CGFloat = size == .master ? 8 : 7
        let source = item.sourceParts.joined(separator: " · ")
        Group {
            // From the xxxLarge size, the state takes line 1 and the source
            // line 2. A stack tile keeps line 2 also without a source, so
            // that the tiles of 1 row keep the same height.
            if typeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: dot, height: dot)
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
                    Circle().fill(color).frame(width: dot, height: dot)
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
}
