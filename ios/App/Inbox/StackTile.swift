import FluxKit
import SwiftUI

/// A tile of the stack: the window title, the title, and 1 line about the
/// computer, each on 1 line. A tap moves the tile to the master position.
/// A player tile also plays and pauses. The border is `red` for an item
/// that needs the user.
struct StackTile: View {
    let item: InboxItem
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var playSize: CGFloat = 22

    var body: some View {
        let player = media
        ZStack(alignment: .bottomTrailing) {
            Button { model.showFirst(item.key) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    WindowTitle(item: item, size: .stack)
                    Text(item.stackTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                        .padding(.trailing, player == nil ? 0 : 40)
                    Text(item.stackLine)
                        .font(.caption)
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .padding(.trailing, player == nil ? 0 : 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 48)
            }
            .buttonStyle(TiledPressStyle(fill: tn.tile, border: item.kind.needsYou ? tn.red : tn.line))
            .accessibilityLabel(spoken)
            .accessibilityValue(item.stateWord)
            .accessibilityHint("Shows it first")
            if let player {
                Button {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else {
                        model.core.plugin(MprisPlugin.self)?.action(player.deviceId, "PlayPause")
                    }
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: playSize))
                        .foregroundStyle(tn.green)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
                .accessibilityLabel(player.playing ? "Pause" : "Play")
            }
        }
    }

    /// The title, the source, and the computer, for VoiceOver.
    private var spoken: String {
        ([item.stackTitle] + item.sourceParts + [item.stackLine]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The player of a media item, or nil.
    private var media: (deviceId: String, playing: Bool)? {
        if case .media(let deviceId, let player) = item.content { return (deviceId, player.playing) }
        return nil
    }
}
