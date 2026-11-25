import FluxKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The number of recent photos in the tray.
private let recentCount = 4

/// A tool of the tray: an icon over a label. `name` is the hint for VoiceOver.
private struct TrayTool: Identifiable {
    let icon: String
    let label: String
    let name: String
    var enabled = true
    let action: () -> Void

    var id: String { label }
}

/// The tray of the chat of a computer, under the composer: the 4 newest
/// photos of this iPhone, and the tools in rows of 4. A tap on a photo
/// selects it or takes it out, and the send key sends the `picked` photos
/// in the order of the taps. All photos opens the photo picker, which
/// sends the photos at once. A tool opens its screen for the computer.
/// Flux reads the photo library only when it has the access already.
/// Without the access, a line asks for it. `onClose` closes the tray, and
/// `onNewAgent` opens the new pane sheet.
struct ChatTray: View {
    let device: DeviceSnapshot
    @Binding var picked: [String]
    let onClose: () -> Void
    let onNewAgent: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var recent: [PHAsset] = []
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingFiles = false

    var body: some View {
        let on = device.online
        let readable = RecentPhotos.readable(access)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Recent photos")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tn.sub)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("All photos") { allPhotos() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tn.accent)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .disabled(!on)
                    .opacity(on ? 1 : TiledMetrics.disabledAlpha)
                    .accessibilityHint("Opens the photo picker")
            }
            .padding(.horizontal, 4)
            if model.demo {
                // The demo for App Review and screenshots does not read the photo library of the device.
                HStack(spacing: 6) {
                    ForEach(0..<recentCount, id: \.self) { _ in
                        Stripes()
                            .frame(maxWidth: .infinity)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
                    }
                }
            } else if !readable {
                accessRow
            } else if recent.isEmpty {
                Text("No photos on this iPhone yet.")
                    .font(.caption)
                    .foregroundStyle(tn.sub)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: 6) {
                    ForEach(recent, id: \.localIdentifier) { asset in
                        let id = asset.localIdentifier
                        PhotoCell(asset: asset, number: (picked.firstIndex(of: id) ?? -1) + 1, enabled: on) {
                            if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
                        }
                    }
                    ForEach(0..<(recentCount - min(recent.count, recentCount)), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(tools) { t in TrayCell(tool: t, enabled: on && t.enabled) }
            }
        }
        .padding(.top, 2)
        // The tray reads the newest photos each time it opens and after a new access.
        .task(id: readable) {
            recent = readable && !model.demo ? RecentPhotos.newest(recentCount) : []
            // A picked photo that the tray no longer shows cannot be taken out, so it leaves the selection.
            picked.removeAll { id in !recent.contains { $0.localIdentifier == id } }
        }
        // The user can change the access in the Settings app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { access = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            ShareFeature.send(photos: items, to: device, model: model)
            photoItems = []
            onClose()
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                ShareFeature.send(picked: urls, to: device, model: model)
                onClose()
            case .failure(let error):
                model.show("Cannot open the files: \(error.localizedDescription)")
            }
        }
    }

    /// The line that asks for the access to the photos. iOS asks only once,
    /// so after a refusal the action opens the Settings app.
    private var accessRow: some View {
        let asks = access == .notDetermined
        return HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18))
                .foregroundStyle(tn.accent)
                .accessibilityHidden(true)
            Text(asks ? "Allow access to show your newest photos here."
                      : "Flux has no access to your photos. Allow it in Settings to show your newest photos here.")
                .font(.caption)
                .foregroundStyle(tn.sub)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(asks ? "Allow" : "Settings") { askAccess() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tn.accent)
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tn.bg))
    }

    /// The tools for the computer. A camera mode, a file, and Get files open
    /// their screens. Agent shows while the computer lets this iPhone start
    /// an agent.
    private var tools: [TrayTool] {
        let d = device
        let share = SendTools.canShare(model)(d)
        var list = [
            TrayTool(icon: CameraMode.photo.systemImage, label: "Camera", name: "Take a photo for \(d.name)", enabled: share) {
                open(.cameraMode(d.id, .photo))
            },
            TrayTool(icon: "doc.badge.arrow.up", label: "File", name: "Send files to \(d.name)", enabled: share) { files() },
            TrayTool(icon: CameraMode.document.systemImage, label: "Scan", name: CameraMode.document.hint, enabled: share) {
                open(.cameraMode(d.id, .document))
            },
            TrayTool(icon: CameraMode.text.systemImage, label: "Text", name: CameraMode.text.hint, enabled: share) {
                open(.cameraMode(d.id, .text))
            },
            TrayTool(icon: CameraMode.qr.systemImage, label: "QR", name: CameraMode.qr.hint, enabled: share) {
                open(.cameraMode(d.id, .qr))
            },
            TrayTool(icon: CameraMode.signature.systemImage, label: "Signature", name: CameraMode.signature.hint, enabled: share) {
                open(.cameraMode(d.id, .signature))
            },
            TrayTool(icon: "folder", label: "Get files", name: "Get files from \(d.name)", enabled: SendTools.canBrowse(model)(d)) {
                open(.browse(d.id))
            },
        ]
        if SendTools.canCreate(model)(d) {
            list.append(TrayTool(icon: "brain", label: "Agent", name: "Start an agent on \(d.name)") {
                onClose()
                onNewAgent()
            })
        }
        return list
    }

    /// Closes the tray and opens the screen of `route` above the chat.
    private func open(_ route: FeatureRoute) {
        onClose()
        model.path.append(.feature(route))
    }

    /// Opens the file picker. The tray closes when the files go out.
    private func files() {
        if model.demo {
            model.show(DemoMode.sendsNothing)
        } else {
            pickingFiles = true
        }
    }

    /// Opens the photo picker. The tray closes when the photos go out.
    private func allPhotos() {
        if model.demo {
            model.show(DemoMode.sendsNothing)
        } else {
            pickingPhotos = true
        }
    }

    /// Asks for the access to the photos, or opens the Settings app after a refusal.
    private func askAccess() {
        guard access == .notDetermined else {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        Task {
            access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            // Send new screenshots and Send new photos in Settings use the same access.
            model.core.plugin(CaptureWatchPlugin.self)?.refreshPhotoAccess()
        }
    }
}

/// A tool of the tray: a 20 pt accent icon over the label, on `bg` with a
/// `line` border, 64 pt high.
private struct TrayCell: View {
    let tool: TrayTool
    let enabled: Bool
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: tool.action) {
            VStack(spacing: 4) {
                Image(systemName: tool.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                Text(tool.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(TiledPressStyle(fill: tn.bg, border: tn.line))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .accessibilityLabel(tool.label)
        .accessibilityHint(tool.name)
    }
}

/// A recent photo of the tray, 80 pt high. A selected photo has a 2 pt
/// accent border and its `number` in an accent circle at the top trailing
/// corner. 0 is not selected. Without the picture, stripes show.
private struct PhotoCell: View {
    let asset: PHAsset
    let number: Int
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        let selected = number > 0
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Stripes()
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? tn.accent : tn.line, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Text("\(number)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tn.onAccent)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(tn.accent))
                            .padding(5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .accessibilityLabel("Photo")
        .accessibilityValue(selected ? "Selected, number \(number)" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: asset.localIdentifier) {
            image = await RecentPhotos.thumbnail(asset, side: 120 * scale)
        }
    }
}

/// Diagonal stripes on `bg`, the place of a picture that did not load.
private struct Stripes: View {
    @Environment(\.tn) private var tn

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tn.bg))
            var x = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(tn.offTile), lineWidth: 7)
                x += 14
            }
        }
        .accessibilityHidden(true)
    }
}

/// The newest photos of the photo library, for the tray.
@MainActor
enum RecentPhotos {
    /// True when Flux may read the photo library: all photos, or the photos that the user selected.
    static func readable(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    /// The `limit` newest images of the library, the newest first.
    static func newest(_ limit: Int) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        return result.objects(at: IndexSet(integersIn: 0..<result.count))
    }

    /// The picture of `asset` with `side` pixels on its short side, or nil
    /// when this iPhone cannot read it. A photo that only iCloud has loads
    /// from iCloud.
    static func thumbnail(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        // Photos then calls the handler once, with the final picture.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                                  options: options) { image, _ in
                c.resume(returning: image)
            }
        }
    }
}
