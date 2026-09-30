import AppKit
import FluxKit
import SwiftUI

/// The share settings: download folder, clipboard sync, and the images that
/// go out by themselves.
struct ShareSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let share = model.core.plugin(SharePlugin.self) {
            Section("Received files") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(share.model.downloadFolder.path(percentEncoded: false).abbreviatingHome)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder(share) }
                    }
                }
            }
        }
        if let clipboard = model.core.plugin(ClipboardPlugin.self) {
            Section {
                Toggle("Sync clipboard", isOn: Binding(get: { clipboard.model.sync }, set: { clipboard.setSync($0) }))
                if clipboard.model.sync, let hint = PasteAccess.hint {
                    LabeledContent {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(PasteAccess.settings) }
                    } label: {
                        Label(hint, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Text that you copy goes to your connected computers, and text that they copy comes here. A copy while no computer is connected goes out when one connects.")
            }
        }
        if let capture = model.core.plugin(CaptureWatchPlugin.self) {
            CaptureSettings(capture: capture)
        }
    }

    private func chooseFolder(_ share: SharePlugin) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = share.model.downloadFolder
        panel.prompt = "Choose"
        panel.message = "Choose the folder for files from your computers."
        if panel.runModal() == .OK, let url = panel.url { share.setDownloadFolder(url) }
    }
}

/// The pasteboard access of Flux. From macOS 15.4, the user can make macOS
/// ask before, or deny, each read of the clipboard that is not a paste.
enum PasteAccess {
    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// A line for the settings when macOS does not let Flux read the
    /// clipboard by itself, else nil.
    static var hint: String? {
        guard #available(macOS 15.4, *) else { return nil }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysDeny:
            return "macOS does not let Flux read what you copy, so copies do not go out. Choose Allow for Flux in Privacy & Security > Paste from Other Apps."
        case .ask:
            return "macOS asks before Flux reads each copy. Choose Allow for Flux in Privacy & Security > Paste from Other Apps."
        default:
            return nil
        }
    }
}

/// Send new screenshots and Send new photos, with the photo library access.
private struct CaptureSettings: View {
    let capture: CaptureWatchPlugin

    var body: some View {
        let m = capture.model
        Section {
            Toggle("Send new screenshots", isOn: Binding(get: { m.screenshots }, set: { capture.setSendScreenshots($0) }))
            Toggle("Send new photos", isOn: Binding(
                get: { m.photos && m.photoAccess == .authorized },
                set: { on in Task { await capture.setSendPhotos(on) } }
            ))
            LabeledContent("Photos access") {
                HStack {
                    Text(accessText(m.photoAccess))
                    if m.photoAccess != .authorized && m.photoAccess != .notDetermined {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                        }
                    }
                }
            }
        } header: {
            Text("Send by themselves")
        } footer: {
            Text("Each new screenshot in \(m.screenshotFolder.path(percentEncoded: false).abbreviatingHome) and each new photo in the Photos library goes to your connected computers once. Images wait until a computer connects.")
        }
        .onAppear { capture.refreshPhotoAccess() }
    }

    private func accessText(_ access: PhotoAccess) -> String {
        switch access {
        case .authorized: "Full access"
        case .limited: "Selected photos only. Flux needs full access to see new photos."
        case .denied: "Not allowed"
        case .restricted: "Restricted on this Mac"
        case .notDetermined: "Flux asks when you turn on Send new photos"
        }
    }
}

/// Menu bar items for 1 connected computer.
struct ShareMenuItems: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        Button("Send File…") { ShareActions.pickFiles(to: device, model: model) }
        Button("Send Clipboard") { model.core.plugin(ClipboardPlugin.self)?.sendClipboard(to: device.id) }
    }
}

private extension String {
    /// The path with ~ for the home folder.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
