import FluxKit
import SwiftUI

/// 1 item in the stack of the Inbox. A click moves it to the master
/// position. The border is `red` for an item that needs the user.
struct StackTile: View {
    let item: InboxItem
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        let media = item.inboxMedia
        ZStack(alignment: .bottomTrailing) {
            Button { model.showFirst(item.key) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    WindowTitle(item: item, size: .stack)
                    Text(item.stackTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    Text(item.stackLine)
                        .font(.system(size: 11))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                }
                .padding(.trailing, media == nil ? 0 : 36)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: TiledMetrics.rowHeight, alignment: .leading)
                .background(shape.fill(tn.tile))
                .overlay(shape.strokeBorder(item.kind.needsYou ? tn.red : tn.line, lineWidth: 1))
                .contentShape(shape)
            }
            .buttonStyle(TilePressStyle())
            .accessibilityLabel(item.spokenTitle)
            .accessibilityValue(item.stateWord)
            .accessibilityHint("Shows it first")
            .contextMenu {
                Button("Show it first") { model.showFirst(item.key) }
            }
            if let media {
                Button {
                    model.core.plugin(MprisPlugin.self)?.action(media.deviceId, "PlayPause")
                } label: {
                    Image(systemName: media.player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.green)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(TilePressStyle())
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .help(media.player.playing ? "Pause" : "Play")
                .accessibilityLabel(media.player.playing ? "Pause \(item.stackTitle)" : "Play \(item.stackTitle)")
            }
        }
    }
}

extension InboxItem {
    /// The computer and the player of a media item, or nil for another item.
    var inboxMedia: (deviceId: String, player: RemotePlayer)? {
        if case .media(let deviceId, let player) = content { return (deviceId, player) }
        return nil
    }

    /// What VoiceOver reads for the item: the title, the source, and the computer.
    var spokenTitle: String {
        ([stackTitle] + sourceParts + [computer]).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
