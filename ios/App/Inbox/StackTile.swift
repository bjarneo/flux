import FluxKit
import SwiftUI

/// A tile of the stack: the window title, the title, and 1 line about the
/// computer, each on 1 line. The window title of an agent also names the
/// agent and its project. The other tiles show only the state, and
/// VoiceOver reads their source. A tap moves the tile to the master
/// position. The context menu of a player plays and pauses. The border is `red` for an item that needs the user.
struct StackTile: View {
    let item: InboxItem
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let many = model.scope == nil && model.state.devices.filter(\.paired).count > 1
        Button { model.showFirst(item.key) } label: {
            VStack(alignment: .leading, spacing: 3) {
                WindowTitle(item: item, size: .stack, showSource: isAgent)
                Text(item.stackTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                Text(item.stackLine(many: many))
                    .font(.caption)
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: item.kind.needsYou ? tn.red : tn.line))
        .accessibilityLabel(spoken)
        .accessibilityValue(item.stateWord)
        .accessibilityHint("Shows it first")
        .contextMenu {
            if case .media(let deviceId, let player) = item.content {
                Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else {
                        model.core.plugin(MprisPlugin.self)?.action(deviceId, "PlayPause")
                    }
                }
            }
        }
    }

    private var isAgent: Bool {
        if case .agent = item.content { return true }
        return false
    }

    /// The title, the source, and the computer, for VoiceOver.
    private var spoken: String {
        ([item.stackTitle] + item.sourceParts + [item.stackLine]).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
