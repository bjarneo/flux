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
