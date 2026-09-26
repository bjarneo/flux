import FluxKit
import SwiftUI

/// Opens the files of a computer that runs fluxd.
struct BrowseSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.sftpRequest) {
            Section("Files") {
                LabeledContent {
                    Button("Browse Files…") { BrowseWindows.shared.show(device.id, core: model.core) }
                        .disabled(!device.online)
                } label: {
                    Text("Home folder")
                    Text("Browse \(device.name) read-only and download files to this Mac.")
                }
            }
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
