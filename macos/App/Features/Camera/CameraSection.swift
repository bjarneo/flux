import FluxKit
import SwiftUI

/// Opens the camera modes for a computer: text, codes, photos, documents, and signatures.
struct CameraSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(CameraMode.allCases) { mode in
                    Button {
                        CameraWindows.shared.show(device, mode: mode, app: model)
                    } label: {
                        Label(mode.label, systemImage: mode.systemImage)
                    }
                    .help(mode.hint)
                }
            }
            .disabled(!device.online)
        } header: {
            Text("Camera")
        } footer: {
            Text("Scan text, codes, and documents, take photos, or capture a signature for \(device.name). Text, codes, documents, and signatures also work from an image.")
        }
    }
}

/// Opens the camera window from the menu bar.
struct CameraMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        Menu("Camera") {
            ForEach(CameraMode.allCases) { mode in
                Button(mode.label) { CameraWindows.shared.show(device, mode: mode, app: model) }
            }
        }
    }
}
