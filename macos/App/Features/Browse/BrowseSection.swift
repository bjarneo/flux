import FluxKit
import SwiftUI

/// The header action that opens the files of a computer that runs fluxd.
struct BrowseQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.sftpRequest) {
            Tile(title: "Browse Files", systemImage: "folder") { BrowseWindows.shared.show(device.id, core: model.core) }
                .help("Browse \(device.name) read-only and download files to this Mac")
        }
    }
}

/// The menu bar item that opens the files of a computer.
struct BrowseMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.sftpRequest) {
            Button("Browse Files…") { BrowseWindows.shared.show(device.id, core: model.core) }
        }
    }
}
