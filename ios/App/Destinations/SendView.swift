import FluxKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Send destination: the tools that send to the computer in scope. The
/// most used tool, Send clipboard, takes the master position. The other
/// tools stack under it in groups. With all computers in scope and more
/// than 1 online, each tool asks for the computer first.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var filesTarget: DeviceSnapshot?
    @State private var pickingFiles = false
    @State private var photosTarget: DeviceSnapshot?
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    /// The camera modes on Send. Webcam is under Control.
    private static let cameraModes: [CameraMode] = [.photo, .text, .document, .qr, .signature]

    var body: some View {
        let clipboard = SendTools.canClipboard(model)
        let share = SendTools.canShare(model)
        let browse = canBrowse
        let camera = canCamera
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                TargetLine(verb: "Sends to")
                MasterTool(icon: "doc.on.clipboard", title: "Send clipboard", line: "Paste it on the computer",
                           enabled: TargetRun.enabled(model, can: clipboard)) {
                    SendTools.sendClipboard(model)
                }
                SectionLabel("Files")
                ToolRow(icon: "doc.badge.arrow.up", title: "Send files", line: "Pick files on this iPhone",
                        enabled: TargetRun.enabled(model, can: share)) {
                    TargetRun.run(model, can: share, title: "Send files to") { d in
                        filesTarget = d
                        pickingFiles = true
                    }
                }
                ToolRow(icon: "photo.on.rectangle", title: "Send photos", line: "Pick photos and videos on this iPhone",
                        enabled: TargetRun.enabled(model, can: share)) {
                    TargetRun.run(model, can: share, title: "Send photos to") { d in
                        photosTarget = d
                        pickingPhotos = true
                    }
                }
                ToolRow(icon: "text.bubble", title: "Text and links", line: "Send text, links, and see the transfers",
                        enabled: TargetRun.enabled(model, can: share)) {
                    open(share, "Send text to") { .share($0) }
                }
                ToolRow(icon: "folder", title: "Get files", line: "Open the home folder of the computer, read-only",
                        enabled: TargetRun.enabled(model, can: browse)) {
                    open(browse, "Get files from") { .browse($0) }
                }
                SectionLabel("Camera")
                ForEach(Self.cameraModes) { mode in
                    ToolRow(icon: mode.systemImage, title: mode.label, line: mode.hint,
                            enabled: TargetRun.enabled(model, can: camera)) {
                        open(camera, "Send from the camera to") { .cameraMode($0, mode) }
                    }
                }
                Text("To send text or a link from another app, select it, then choose Flux in the Share menu.")
                    .font(.footnote)
                    .foregroundStyle(tn.sub)
                    .padding(.leading, 4)
                    .padding(.top, 12)
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .tabRoot("Send")
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard let d = filesTarget else { return }
            switch result {
            case .success(let urls): ShareFeature.send(picked: urls, to: d, model: model)
            case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            if let d = photosTarget { ShareFeature.send(photos: picked, to: d, model: model) }
            photos = []
        }
    }

    /// The computers that open their files, see `BrowseTile`.
    private var canBrowse: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(BrowsePlugin.self) != nil
        return { has && $0.accepts(PacketType.sftpRequest) }
    }

    /// The computers that take the camera modes, see `CameraTile`.
    private var canCamera: (DeviceSnapshot) -> Bool {
        return { $0.accepts(PacketType.share) }
    }

    /// Opens the screen of `route` for the computer of the tool.
    private func open(_ can: (DeviceSnapshot) -> Bool, _ title: String, _ route: @escaping (String) -> FeatureRoute) {
        TargetRun.run(model, can: can, title: title) { d in
            model.sendPath.append(.feature(route(d.id)))
        }
    }
}
