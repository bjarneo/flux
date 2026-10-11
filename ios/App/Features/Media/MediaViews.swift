import FluxKit
import SwiftUI
import UIKit

/// The media players of a computer. The iPhone controls them, and the
/// computer does not control the iPhone.
struct MediaTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.mprisRequest), let plugin = model.core.plugin(MprisPlugin.self) {
            let player = plugin.model.media(device.id).player
            FeatureTile("Media", systemImage: player?.playing == true ? "play.circle.fill" : "music.note", tint: .pink,
                        subtitle: player.map(Self.subtitle) ?? "Nothing is playing") {
                NowPlayingScreen(deviceId: device.id)
            }
        }
    }

    static func subtitle(_ player: RemotePlayer) -> String {
        let what = player.title.isEmpty ? player.name : player.title
        return player.playing ? what : "Paused · \(what)"
    }
}

/// Media: the players as pills, the album art, the title, the artist, and
/// the album, and the dock with the position, Previous, Play or Pause,
/// Next, and the volume. A player that sends no volume shows no volume row.
struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    let deviceId: String

    var body: some View {
        if let device = model.device(deviceId), let plugin = model.core.plugin(MprisPlugin.self) {
            let media = plugin.model.media(device.id)
            let player = media.player
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let position = player?.position(at: ProcessInfo.processInfo.systemUptime) ?? 0
                VStack(spacing: 0) {
                    if let player, media.players.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(media.players, id: \.self) { name in
                                    let on = name == player.name
                                    StripPill(label: name, selected: on, meta: on ? (player.playing ? "playing" : "paused") : "") {
                                        if !on { plugin.select(device.id, player: name) }
                                    } mark: {
                                        if on && player.playing { Circle().fill(tn.green).frame(width: 8, height: 8) } else { RingMark() }
                                    }
                                    .accessibilityLabel(name)
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                        .padding(.bottom, 2)
                    }
                    ProgressLine {
                        if let player, player.length > 0 { LineFill(fraction: Double(position) / Double(player.length), color: tn.green) }
                    }
                    if !device.online {
                        ContentUnavailableView("Not connected", systemImage: "wifi.slash",
                                               description: Text("The player controls show when \(device.name) is online."))
                    } else if let player {
                        NowPlayingInfo(player: player)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                PlayerDock(device: device, plugin: plugin, player: player, position: position)
                            }
                    } else {
                        ContentUnavailableView("Nothing is playing", systemImage: "music.note",
                                               description: Text("Play music or a video on \(device.name). The controls show here."))
                    }
                }
            }
            .featureTitle("Media", context: ScreenWords.join(player?.name ?? "", device.name))
            // The computer pushes changes, and this also catches players that
            // start or stop while the screen is open.
            .task(id: device.online) {
                guard device.online else { return }
                while !Task.isCancelled {
                    plugin.requestPlayers(device.id)
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}

/// The album art, the title, the artist, and the album, at the bottom of
/// the space above the dock.
private struct NowPlayingInfo: View {
    let player: RemotePlayer
    @Environment(\.tn) private var tn

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer(minLength: 0)
                    ArtThumb(url: player.artURL, size: min(230, max(0, geo.size.width - 40)), corner: 16, iconSize: 44)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title.isEmpty ? "Unknown title" : player.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tn.text)
                            .lineLimit(3)
                        if !player.artist.isEmpty {
                            Text(player.artist).font(.subheadline).foregroundStyle(tn.sub)
                        }
                        if !player.album.isEmpty {
                            Text(player.album).font(.caption.monospaced()).foregroundStyle(tn.sub)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 30)
                .frame(minHeight: geo.size.height, alignment: .bottom)
            }
        }
    }
}

/// The dock of the player: the position with a thumb, the time and the
/// length, Previous, Play or Pause, and Next, and the volume.
private struct PlayerDock: View {
    let device: DeviceSnapshot
    let plugin: MprisPlugin
    let player: RemotePlayer
    let position: Int64
    @Environment(\.tn) private var tn
    /// The position and the volume that the user drags to, until the drag ends.
    @State private var seeking: Double?
    @State private var volume: Double?
    /// The time of the last volume that a drag sent. A drag sends at most 1 volume each 150 ms.
    @State private var volumeSentAt = Date.distantPast

    var body: some View {
        VStack(spacing: 10) {
            if player.length > 0 {
                let shown = seeking.map { Int64($0 * Double(player.length)) } ?? position
                VStack(spacing: 4) {
                    LineSlider(value: Double(shown) / Double(player.length), color: tn.green, thumb: player.canSeek, enabled: player.canSeek,
                               name: "Position", state: ThreadTime.position(shown)) { seeking = $0 } done: { f in
                        seeking = nil
                        plugin.seek(device.id, to: Int64(f * Double(player.length)))
                    }
                    .frame(height: 24)
                    HStack {
                        Text(ThreadTime.position(shown))
                        Spacer()
                        Text(ThreadTime.position(player.length))
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                }
                .padding(.horizontal, 4)
            }
            // Play or Pause is 1.4 times as wide as Previous and Next.
            GeometryReader { g in
                let unit = max((g.size.width - 16) / 3.4, 0)
                HStack(spacing: 8) {
                    PlayerKey(icon: "backward.end.fill", name: "Previous", fill: tn.line, ink: tn.text, size: 26) { plugin.action(device.id, "Previous") }
                        .frame(width: unit)
                    PlayerKey(icon: player.playing ? "pause.fill" : "play.fill", name: player.playing ? "Pause" : "Play", fill: tn.green,
                              ink: tn.onAccent, size: 30) { plugin.action(device.id, "PlayPause") }
                        .frame(width: unit * 1.4)
                    PlayerKey(icon: "forward.end.fill", name: "Next", fill: tn.line, ink: tn.text, size: 26) { plugin.action(device.id, "Next") }
                        .frame(width: unit)
                }
            }
            .frame(height: 64)
            if let v = player.volume {
                let shown = volume ?? Double(v) / 100
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.1.fill").font(.footnote).foregroundStyle(tn.sub).accessibilityHidden(true)
                    LineSlider(value: shown, color: tn.text, thumb: false, enabled: true, name: "Volume", state: "\(Int(shown * 100))%") { f in
                        volume = f
                        // The player follows the drag.
                        if Date().timeIntervalSince(volumeSentAt) >= 0.15 {
                            volumeSentAt = Date()
                            plugin.setVolume(device.id, Int((f * 100).rounded()))
                        }
                    } done: { f in
                        volume = nil
                        plugin.setVolume(device.id, Int((f * 100).rounded()))
                    }
                    .frame(height: 32)
                    Text("\(Int((shown * 100).rounded()))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .frame(height: 40)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .dockFrame()
    }
}

/// A key of the player dock: a rounded tile with an icon.
private struct PlayerKey: View {
    let icon: String
    let name: String
    let fill: Color
    let ink: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// A line of 4 pt that the user taps or drags, with the part `value` in
/// `color`, and a thumb of 4 by 16 pt with `thumb`. `change` follows a drag,
/// and `done` gets the value at the end of a tap or a drag. VoiceOver reads
/// `name` with `state`, and can raise or lower the value by 5%.
private struct LineSlider: View {
    let value: Double
    let color: Color
    let thumb: Bool
    let enabled: Bool
    let name: String
    let state: String
    let change: (Double) -> Void
    let done: (Double) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let v = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(tn.line).frame(height: 4)
                Capsule().fill(color).frame(width: w * v, height: 4)
                if thumb {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16).offset(x: min(max(w * v - 2, 0), w - 4))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in if enabled { change(min(max(g.location.x / w, 0), 1)) } }
                    .onEnded { g in if enabled { done(min(max(g.location.x / w, 0), 1)) } }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(state)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: done(min(value + 0.05, 1))
            case .decrement: done(max(value - 0.05, 0))
            @unknown default: break
            }
        }
    }
}
