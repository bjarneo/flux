import FluxKit
import SwiftUI
import UIKit

/// Clipboard sync and the images that go out by themselves.
struct ShareSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let clipboard = model.core.plugin(ClipboardPlugin.self) {
            Section {
                Toggle("Sync clipboard", isOn: Binding(get: { clipboard.model.sync }, set: { clipboard.setSync($0) }))
            } header: {
                Text("Clipboard")
            } footer: {
                Text("While Flux is on the screen, text and images that you copy go to your connected computers, and what they copy comes here. iOS asks before Flux reads what another app copied.")
            }
        }
        if let capture = model.core.plugin(CaptureWatchPlugin.self) {
            CaptureSettings(capture: capture)
        }
    }
}

/// Send new screenshots and Send new photos, with the photo library access.
private struct CaptureSettings: View {
    let capture: CaptureWatchPlugin

    var body: some View {
        let m = capture.model
        Section {
            Toggle("Send new screenshots", isOn: Binding(
                get: { m.screenshots && m.photoAccess == .authorized },
                set: { on in Task { await capture.setSendScreenshots(on) } }
            ))
            Toggle("Send new photos", isOn: Binding(
                get: { m.photos && m.photoAccess == .authorized },
                set: { on in Task { await capture.setSendPhotos(on) } }
            ))
            if m.photoAccess != .authorized && m.photoAccess != .notDetermined {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    LabeledContent("Photos access", value: Self.accessText(m.photoAccess))
                }
                .tint(.primary)
            }
        } header: {
            Text("Send by themselves")
        } footer: {
            Text("When Flux opens, the screenshots and photos that are new in the Photos library go to your connected computers once. iOS does not run Flux in the background.")
        }
        .onAppear { capture.refreshPhotoAccess() }
    }

    static func accessText(_ access: PhotoAccess) -> String {
        switch access {
        case .authorized: "Full access"
        case .limited: "Selected photos only"
        case .denied: "Not allowed"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        }
    }
}
