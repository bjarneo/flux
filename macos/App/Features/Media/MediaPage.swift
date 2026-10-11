import AppKit
import FluxKit
import SwiftUI

/// The media page of 1 computer: the players as pills, the album art, the
/// title, the artist, and the album, and the dock with the position,
/// Previous, Play or Pause, Next, and the volume. A player that sends no
/// volume shows no volume row. The dashboard keeps its own media card.
struct MediaPage: View {
    let deviceId: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        Group {
            if let device = model.pairedDevice(deviceId), let plugin = model.core.plugin(MprisPlugin.self) {
                content(device, plugin: plugin)
            } else {
                ContentUnavailableView("The computer is gone", systemImage: "desktopcomputer",
                                       description: Text("The computer is no longer paired."))
            }
        }
        .navigationTitle("Media")
    }

    @ViewBuilder
    private func content(_ device: DeviceSnapshot, plugin: MprisPlugin) -> some View {
        let media = plugin.model.media(device.id)
        let player = media.player
        VStack(spacing: 0) {
            if let player, device.online, media.players.count > 1 {
                PillStrip {
                    ForEach(media.players, id: \.self) { name in
                        let on = name == player.name
                        let state = media.states[name]
                        StripPill(label: name, selected: on, meta: state.map { $0.playing ? "playing" : "paused" } ?? "",
                                  help: "Show \(name)") {
                            if !on { plugin.select(device.id, player: name) }
                        } mark: {
                            if state?.playing == true { LinkDot(online: true) } else { RingMark() }
                        }
                    }
                }
            }
            if !device.online {
                ContentUnavailableView("\(device.name) is offline", systemImage: "wifi.slash",
                                       description: Text("The player controls show when \(device.name) is online."))
            } else if let player {
                PlayerBody(device: device, plugin: plugin, player: player)
            } else {
                ContentUnavailableView("Nothing is playing", systemImage: "music.note",
                                       description: Text("Play music or a video on \(device.name). The controls show here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationSubtitle(contextLine([player?.name ?? "", device.name]))
        // The computer pushes changes, and this also catches players that
        // start or stop while the page shows.
        .task(id: device.online) {
            guard device.online else { return }
            while !Task.isCancelled {
                plugin.requestPlayers(device.id)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

/// The line of the position, the now playing part, and the dock.
private struct PlayerBody: View {
    let device: DeviceSnapshot
    let plugin: MprisPlugin
    let player: RemotePlayer
    @Environment(\.tn) private var tn
    /// The part of the length that the user drags to, until the drag ends.
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = player.position(at: ProcessInfo.processInfo.systemUptime)
            let shown = dragging.map { Int64($0 * Double(player.length)) } ?? position
            let fraction = player.length > 0 ? Double(shown) / Double(player.length) : 0
            VStack(spacing: 0) {
                ProgressLine { if player.length > 0 { LineFill(fraction: fraction, color: tn.green) } }
                NowPlaying(player: player)
                VStack(alignment: .leading, spacing: 10) {
                    if player.length > 0 {
                        VStack(spacing: 4) {
                            LineSlider(value: fraction, color: tn.green, label: "Position", state: mediaClock(shown), thumb: player.canSeek,
                                       enabled: player.canSeek, height: 22) { dragging = $0 } done: { f in
                                dragging = nil
                                plugin.seek(device.id, to: Int64(f * Double(player.length)))
                            }
                            HStack {
                                Text(mediaClock(shown))
                                Spacer()
                                Text(mediaClock(player.length))
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tn.sub)
                        }
                        .padding(.horizontal, 4)
                    }
                    // Play takes 1.4 parts of the width, and Previous and Next 1 part each.
                    GeometryReader { geo in
                        let unit = max(0, geo.size.width - 16) / 3.4
                        HStack(spacing: 8) {
                            PlayerKey(symbol: "backward.end.fill", help: "Previous", fill: tn.line, ink: tn.text, size: 22) { plugin.action(device.id, "Previous") }
                                .frame(width: unit)
                            PlayerKey(symbol: player.playing ? "pause.fill" : "play.fill", help: player.playing ? "Pause" : "Play",
                                      fill: tn.green, ink: tn.onAccent, size: 26) { plugin.action(device.id, "PlayPause") }
                                .frame(width: unit * 1.4)
                            PlayerKey(symbol: "forward.end.fill", help: "Next", fill: tn.line, ink: tn.text, size: 22) { plugin.action(device.id, "Next") }
                                .frame(width: unit)
                        }
                    }
                    .frame(height: 56)
                    if let volume = player.volume {
                        VolumeRow(volume: volume) { plugin.setVolume(device.id, $0) }
                    }
                }
                .pageDock(top: 16)
            }
        }
    }
}

/// The album art, the title, the artist, and the album, at the bottom of the space above the dock.
private struct NowPlaying: View {
    let player: RemotePlayer
    @Environment(\.tn) private var tn

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    ArtThumb(url: player.artURL, size: min(260, max(120, geo.size.height - 150)), corner: 16)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title.isEmpty ? "Unknown title" : player.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tn.text)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if !player.artist.isEmpty {
                            Text(player.artist)
                                .font(.system(size: 14))
                                .foregroundStyle(tn.sub)
                        }
                        if !player.album.isEmpty {
                            Text(player.album)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(tn.sub)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
            }
        }
    }
}

/// A key of the player dock: a rounded tile with a symbol.
private struct PlayerKey: View {
    let symbol: String
    let help: String
    let fill: Color
    let ink: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(fill))
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The volume of the player: the symbol, a line to click or drag, and the
/// value. At most 1 request goes out each 150 ms during a drag.
private struct VolumeRow: View {
    let volume: Int
    let set: (Int) -> Void
    @Environment(\.tn) private var tn
    @State private var dragging: Double?
    @State private var sentAt = Date.distantPast

    var body: some View {
        let shown = dragging.map { Int(($0 * 100).rounded()) } ?? volume
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.1.fill")
                .font(.system(size: 13))
                .foregroundStyle(tn.sub)
            LineSlider(value: Double(shown) / 100, color: tn.text, label: "Volume", state: "\(shown)%", thumb: false, height: 28) { f in
                dragging = f
                if Date().timeIntervalSince(sentAt) >= 0.15 {
                    sentAt = Date()
                    set(Int((f * 100).rounded()))
                }
            } done: { f in
                set(Int((f * 100).rounded()))
                dragging = nil
            }
            Text("\(shown)%")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tn.sub)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
    }
}

/// A line of 4 pt that the user clicks or drags, with the part `value` in
/// `color`, and a thumb of 4 by 16 pt at the end of the part when `thumb`
/// is set. `change` follows a drag, and `done` gets the value at the end
/// of a click or a drag. VoiceOver reads `label` with `state`, and its
/// adjust action moves the value by 5%.
private struct LineSlider: View {
    let value: Double
    let color: Color
    let label: String
    let state: String
    let thumb: Bool
    var enabled = true
    var height: CGFloat = 24
    let change: (Double) -> Void
    let done: (Double) -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let v = min(max(value, 0), 1)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tn.line).frame(height: 4)
                Capsule().fill(color).frame(width: w * v, height: 4)
                if thumb {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 4, height: 16)
                        .offset(x: min(max(w * v - 2, 0), max(w - 4, 0)))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in if enabled { change(min(max(g.location.x / max(w, 1), 0), 1)) } }
                    .onEnded { g in if enabled { done(min(max(g.location.x / max(w, 1), 0), 1)) } }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(state)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: done(min(v + 0.05, 1))
            case .decrement: done(max(v - 0.05, 0))
            @unknown default: break
            }
        }
    }
}
