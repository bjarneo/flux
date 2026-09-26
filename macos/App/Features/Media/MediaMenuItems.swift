import AppKit
import FluxKit
import SwiftUI

/// Play or pause the current player of a computer from the menu bar.
struct MediaMenuItems: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = model.core.plugin(MprisPlugin.self), let player = plugin.model.media(device.id).player {
            let what = player.title.isEmpty ? player.name : "“\(player.title)”"
            Button(player.playing ? "Pause \(what)" : "Play \(what)") { plugin.action(device.id, "PlayPause") }
        }
    }
}

/// The commands of a computer as a submenu.
struct CommandsMenu: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let plugin = model.core.plugin(RunCommandPlugin.self), let commands = plugin.model.commands(device.id), !commands.isEmpty {
            Menu("Commands") {
                ForEach(commands) { c in
                    Button(c.name) { plugin.run(device.id, c) }
                }
            }
        }
    }
}

/// Explains how computers control Music and Spotify on this Mac.
struct MediaSettings: View {
    var body: some View {
        Section("Media") {
            LabeledContent("Music and Spotify") {
                Button("Automation Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            Text("Paired computers can play, pause, skip, seek, and change the volume of Music and Spotify on this Mac. macOS asks once for each app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
