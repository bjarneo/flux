import FluxKit
import SwiftUI

/// Controls for the media players of a computer.
struct MediaSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.mprisRequest), let plugin = model.core.plugin(MprisPlugin.self) {
            MediaControls(device: device, plugin: plugin, media: plugin.model.media(device.id))
        }
    }
}

private struct MediaControls: View {
    let device: DeviceSnapshot
    let plugin: MprisPlugin
    let media: RemoteMedia

    var body: some View {
        DashboardCard("Now Playing", systemImage: "music.note", tint: .pink) {
            if device.online, let player = media.player, media.players.count > 1 {
                Picker("Player", selection: Binding(get: { player.name }, set: { plugin.select(device.id, player: $0) })) {
                    ForEach(media.players, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        } content: {
            if !device.online {
                Text("The player controls show when \(device.name) is online.")
                    .foregroundStyle(.secondary)
            } else if let player = media.player {
                NowPlaying(player: player)
                if player.length > 0 {
                    SeekBar(player: player) { plugin.seek(device.id, to: $0) }
                }
                Transport(playing: player.playing) { plugin.action(device.id, $0) }
                if let volume = player.volume {
                    VolumeBar(volume: volume) { plugin.setVolume(device.id, $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing is playing")
                    Text("Play music or a video on \(device.name). The controls show here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The computer pushes changes, and this also catches players that
        // start or stop while the section is on screen.
        .task(id: device.online) {
            guard device.online else { return }
            while !Task.isCancelled {
                plugin.requestPlayers(device.id)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct NowPlaying: View {
    let player: RemotePlayer

    var body: some View {
        HStack(spacing: 12) {
            AlbumArt(url: player.artURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title.isEmpty ? "Unknown title" : player.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([player.artist, player.name].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !player.album.isEmpty {
                    Text(player.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
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
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
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
                .labelsHidden()
                .disabled(!player.canSeek)
                HStack {
                    Text(clock(dragging ?? position))
                    Spacer()
                    Text(clock(Double(player.length)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func clock(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

private struct Transport: View {
    let playing: Bool
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 28) {
            Spacer()
            Button { action("Previous") } label: { Label("Previous", systemImage: "backward.fill") }
                .help("Previous")
            Button { action("PlayPause") } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
            }
            .help(playing ? "Pause" : "Play")
            Button { action("Next") } label: { Label("Next", systemImage: "forward.fill") }
                .help("Next")
            Spacer()
        }
        .font(.title3)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// The player volume. A drag sets the volume when it ends.
private struct VolumeBar: View {
    let volume: Int
    let set: (Int) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack {
            Image(systemName: "speaker.fill")
            Slider(value: Binding(get: { dragging ?? Double(volume) }, set: { dragging = $0 }), in: 0...100) {
                Text("Volume")
            } onEditingChanged: { editing in
                if !editing, let target = dragging {
                    set(Int(target.rounded()))
                    dragging = nil
                }
            }
            .labelsHidden()
            Image(systemName: "speaker.wave.3.fill")
        }
        .foregroundStyle(.secondary)
    }
}
