import FluxKit
import SwiftUI

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

/// Now Playing: the player picker, the track, the position, the transport,
/// and the volume.
struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String

    var body: some View {
        if let device = model.device(deviceId), let plugin = model.core.plugin(MprisPlugin.self) {
            let media = plugin.model.media(device.id)
            Group {
                if !device.online {
                    ContentUnavailableView("Not connected", systemImage: "wifi.slash",
                                           description: Text("The player controls show when \(device.name) is online."))
                } else if let player = media.player {
                    ScrollView {
                        NowPlayingControls(device: device, plugin: plugin, player: player)
                            .padding(20)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("Nothing is playing", systemImage: "music.note",
                                           description: Text("Play music or a video on \(device.name). The controls show here."))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if device.online, let player = media.player, media.players.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Player", selection: Binding(get: { player.name }, set: { plugin.select(device.id, player: $0) })) {
                                ForEach(media.players, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            Label("Player", systemImage: "hifispeaker.2")
                        }
                    }
                }
            }
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

private struct NowPlayingControls: View {
    let device: DeviceSnapshot
    let plugin: MprisPlugin
    let player: RemotePlayer

    var body: some View {
        VStack(spacing: 24) {
            AlbumArt(url: player.artURL)
            VStack(spacing: 4) {
                Text(player.title.isEmpty ? "Unknown title" : player.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text([player.artist, player.name].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !player.album.isEmpty {
                    Text(player.album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if player.length > 0 {
                SeekBar(player: player) { plugin.seek(device.id, to: $0) }
            }
            Transport(playing: player.playing) { plugin.action(device.id, $0) }
            if let volume = player.volume {
                VolumeBar(volume: volume) { plugin.setVolume(device.id, $0) }
            }
        }
    }
}

private struct AlbumArt: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 260, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.pink.gradient.opacity(0.25))
            Image(systemName: "music.note")
                .font(.system(size: 72))
                .foregroundStyle(.pink)
        }
    }
}

/// The position of the track. It moves while the player plays, and a drag
/// seeks when it ends.
private struct SeekBar: View {
    let player: RemotePlayer
    let seek: (Int64) -> Void
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !player.playing || dragging != nil)) { _ in
            let position = Double(player.position(at: ProcessInfo.processInfo.systemUptime))
            VStack(spacing: 2) {
                Slider(value: Binding(get: { dragging ?? position }, set: { dragging = $0 }), in: 0...Double(player.length)) {
                    Text("Position")
                } onEditingChanged: { editing in
                    if !editing, let target = dragging {
                        seek(Int64(target))
                        dragging = nil
                    }
                }
                .disabled(!player.canSeek)
                .accessibilityValue(Self.clock(dragging ?? position))
                HStack {
                    Text(Self.clock(dragging ?? position))
                    Spacer()
                    Text(Self.clock(Double(player.length)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    static func clock(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

private struct Transport: View {
    let playing: Bool
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 44) {
            Button { action("Previous") } label: { Label("Previous", systemImage: "backward.fill") }
                .font(.title)
            Button { action("PlayPause") } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.circle.fill" : "play.circle.fill")
            }
            .font(.system(size: 64))
            Button { action("Next") } label: { Label("Next", systemImage: "forward.fill") }
                .font(.title)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .tint(.primary)
    }
}

/// The player volume. A drag sets the volume when it ends.
private struct VolumeBar: View {
    let volume: Int
    let set: (Int) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .accessibilityHidden(true)
            Slider(value: Binding(get: { dragging ?? Double(volume) }, set: { dragging = $0 }), in: 0...100) {
                Text("Volume")
            } onEditingChanged: { editing in
                if !editing, let target = dragging {
                    set(Int(target.rounded()))
                    dragging = nil
                }
            }
            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}
