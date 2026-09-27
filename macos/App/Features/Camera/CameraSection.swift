import FluxKit
import SwiftUI

/// Opens the camera modes for a computer: text, codes, photos, documents, and signatures.
struct CameraSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        DashboardCard("Camera", systemImage: "camera", tint: .purple) {
            // All modes in one row when they fit, else 3 per row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tiles.frame(minWidth: 64) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { tiles }
            }
            .disabled(!device.online)
            Text("Text, codes, documents, and signatures also work from an image.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tiles: some View {
        ForEach(CameraMode.allCases) { mode in
            Tile(title: mode.label, systemImage: mode.systemImage, tint: .purple) {
                CameraWindows.shared.show(device, mode: mode, app: model)
            }
            .help(mode.hint)
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
