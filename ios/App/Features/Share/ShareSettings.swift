import AppIntents
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
                Toggle("Send the clipboard when Flux opens", isOn: Binding(get: { clipboard.model.sendOnOpen }, set: { clipboard.setSendOnOpen($0) }))
                    .disabled(!clipboard.model.sync)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("While Flux is on the screen, text and images that you copy go to your connected computers, and what they copy comes here. When Flux opens, a new copy from another app goes out once. iOS asks before Flux reads what another app copied.")
            }
            ClipboardShortcutSettings()
        }
        if let capture = model.core.plugin(CaptureWatchPlugin.self) {
            CaptureSettings(capture: capture)
        }
    }
}

/// How to send the clipboard with a shortcut, while Flux stays closed.
private struct ClipboardShortcutSettings: View {
    var body: some View {
        Section {
            ShortcutsLink()
            SetupRow(title: "Back Tap", path: "Settings > Accessibility > Touch > Back Tap")
            SetupRow(title: "Action button", path: "Settings > Action Button > Shortcut")
            SetupRow(title: "Control Center", path: "Control Center > Add a Control > Shortcut")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                LabeledContent("Paste from Other Apps", value: "Settings")
            }
            .tint(.primary)
        } header: {
            Text("Send without opening Flux")
        } footer: {
            Text("""
            In Shortcuts, make a shortcut with Get Clipboard and then Send Text to Computer. \
            Run it with Back Tap, the Action button, or Control Center. The text goes to the paired computers \
            that connect first. Flux waits at most 20 seconds for them. Flux cannot see if the text is a password, \
            so do not run the shortcut after you copy a password. To let Flux read the clipboard without a question \
            when it opens, choose Allow in Paste from Other Apps.
            """)
        }
    }
}

/// One way to run the shortcut, with its place in iOS.
private struct SetupRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(path)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
            Text("When Flux opens, the new screenshots and photos that are on this iPhone go to your connected computers once. Photos that only iCloud has, for example from your other devices or a Shared Library, stay home. iOS does not run Flux in the background.")
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
