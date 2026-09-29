import SwiftUI
import FluxProto

/// M4 remote screens: desktop media control (MPRIS) + runcommand list/run.
/// Ports Android `ui/RemoteScreens.kt` (`MediaScreen`, `CommandsScreen`):
/// the phone lists the desktop players/commands and sends
/// `kdeconnect.mpris.request` / `kdeconnect.runcommand.request` — never the
/// reverse. Screens take state + action closures (no backend); the link
/// feeds them from `LinkRunner` media/command events, and the actions build
/// `MprisMessage` / `RunCommandMessage` packets.
///
/// Demo fixtures (`View.fluxDemo`) mirror the `FLUX_DEMO=1` pages; release
/// builds ignore the extras.

// MARK: - Media

/// Desktop media screen: player chips, artwork placeholder, title/artist,
/// seek slider, and Previous/Play-Pause/Next controls.
public struct MediaScreen: View {
    public var computer: String
    public var online: Bool
    public var players: [String]
    public var current: String?
    public var state: MprisState?
    public var onSelectPlayer: (String) -> Void
    public var onAction: (String) -> Void
    public var onSeek: (Int64) -> Void

    public init(
        computer: String, online: Bool = true,
        players: [String] = [], current: String? = nil,
        state: MprisState? = nil,
        onSelectPlayer: @escaping (String) -> Void = { _ in },
        onAction: @escaping (String) -> Void = { _ in },
        onSeek: @escaping (Int64) -> Void = { _ in }
    ) {
        self.computer = computer
        self.online = online
        self.players = players
        self.current = current
        self.state = state
        self.onSelectPlayer = onSelectPlayer
        self.onAction = onAction
        self.onSeek = onSeek
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("On \(computer)").foregroundStyle(.secondary)
                if !online {
                    Text("The player controls need a connection.").foregroundStyle(.secondary)
                } else if let s = state {
                    if players.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(players, id: \.self) { name in
                                    Button(name) { onSelectPlayer(name) }
                                        .buttonStyle(.bordered)
                                        .tint(name == (current ?? s.player) ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                    Image(systemName: "music.note")
                        .font(.system(size: 72))
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityLabel("Album art placeholder")
                    Text(s.title.isEmpty ? "Unknown title" : s.title)
                        .font(.headline).lineLimit(2)
                    Text([s.artist, s.player].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if s.length > 0 {
                        Slider(
                            value: .constant(Double(s.position)),
                            in: 0...Double(max(s.length, 1)),
                            onEditingChanged: { editing in
                                if !editing { onSeek(s.position) }
                            }
                        )
                        .disabled(!s.canSeek)
                        HStack {
                            Text(clock(s.position)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(clock(s.length)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 24) {
                        Spacer()
                        Button { onAction("Previous") } label: {
                            Image(systemName: "backward.fill").font(.system(size: 32))
                        }.accessibilityLabel("Previous")
                        Button { onAction(s.playing ? "Pause" : "Play") } label: {
                            Image(systemName: s.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 44))
                        }.accessibilityLabel(s.playing ? "Pause" : "Play")
                        Button { onAction("Next") } label: {
                            Image(systemName: "forward.fill").font(.system(size: 32))
                        }.accessibilityLabel("Next")
                        Spacer()
                    }
                    .padding(.top, 8)
                } else {
                    Text("Nothing is playing")
                        .font(.headline).padding(.top, 48)
                    Text("Play music or a video on \(computer). The controls show here.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Media")
    }
}

// MARK: - Commands

/// Run-commands screen: the desktop list in config order, tap to run.
/// `canAddCommand` is always false (commands are edited in `config.toml`);
/// loading shows a spinner, an empty list the "No commands yet" state.
public struct CommandsScreen: View {
    public var computer: String
    public var online: Bool
    public var loaded: Bool
    public var commands: [RemoteCommand]
    public var onRun: (RemoteCommand) -> Void
    public var onRefresh: () -> Void

    public init(
        computer: String, online: Bool = true, loaded: Bool = true,
        commands: [RemoteCommand] = [],
        onRun: @escaping (RemoteCommand) -> Void = { _ in },
        onRefresh: @escaping () -> Void = {}
    ) {
        self.computer = computer
        self.online = online
        self.loaded = loaded
        self.commands = commands
        self.onRun = onRun
        self.onRefresh = onRefresh
    }

    public var body: some View {
        Group {
            if !online {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    Text("The commands need a connection.").foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !loaded {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading the commands of \(computer)").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if commands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    Text("No commands yet").font(.headline).padding(.top, 48)
                    Text("On \(computer), add commands with flux commands add. They show here.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // Root List: collapses the large title and insets the last
                // row above the home indicator (VStack-wrapped List clips it).
                List(commands, id: \.key) { cmd in
                    Button { onRun(cmd) } label: {
                        VStack(alignment: .leading) {
                            Text(cmd.name)
                            Text(cmd.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On \(computer)").foregroundStyle(.secondary)
                        Text("Tap a command to run it on \(computer).")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Run commands")
        .onAppear(perform: onRefresh)
    }
}

// MARK: - Helpers

private func clock(_ ms: Int64) -> String {
    let total = max(0, ms) / 1000
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct MediaCommandsViews_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MediaScreen(
                computer: "omarchy-xps", players: ["spotify", "vlc"],
                current: "spotify",
                state: MprisState(
                    player: "spotify", title: "Song", artist: "Band",
                    album: "Record", playing: true, position: 61_000,
                    length: 200_000, canSeek: true))
                .previewDisplayName("media")
            MediaScreen(computer: "omarchy-xps")
                .previewDisplayName("media-empty")
            CommandsScreen(
                computer: "omarchy-xps",
                commands: [
                    RemoteCommand(key: "lock", name: "Lock screen", command: "loginctl lock-session"),
                    RemoteCommand(key: "mute", name: "Mute", command: "mute.sh"),
                ])
                .previewDisplayName("commands")
            CommandsScreen(computer: "omarchy-xps", loaded: false)
                .previewDisplayName("commands-loading")
        }
    }
}
