import AppKit
import FluxKit
import ImageIO
import SwiftUI

/// The tray of the chat of a computer, under the composer: the 4 newest
/// screenshots of this Mac, and the tools in rows of 4. The screenshots
/// show while Send new screenshots is on, because only then does Flux read
/// the screenshot folder. A click on a screenshot selects it or takes it
/// out, and the send key sends `shots` in the order of the clicks. All
/// screenshots opens the file picker in the screenshot folder. A tool
/// closes the tray and opens its window for the computer. The Mac has no
/// photo library tray, so the tray has no Recent photos.
struct ChatTray: View {
    let device: DeviceSnapshot
    @Binding var shots: [URL]
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var recent: [URL] = []

    /// The number of recent screenshots in the tray.
    private static let recentCount = 4

    var body: some View {
        let on = device.online
        let capture = model.core.plugin(CaptureWatchPlugin.self)
        let folder = capture?.model.screenshots == true ? capture?.model.screenshotFolder : nil
        VStack(alignment: .leading, spacing: 8) {
            if let folder {
                HStack(spacing: 8) {
                    Text("Recent screenshots")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tn.sub)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("All screenshots") { pick(in: folder) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                        .disabled(!on)
                        .help("Choose screenshots to send to \(device.name)")
                }
                .padding(.leading, 4)
                if recent.isEmpty {
                    Text("No screenshots in \(folder.lastPathComponent) yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                        .padding(.horizontal, 4)
                } else {
                    HStack(spacing: 6) {
                        ForEach(recent, id: \.self) { url in
                            ShotCell(url: url, number: (shots.firstIndex(of: url) ?? -1) + 1, enabled: on) {
                                if let i = shots.firstIndex(of: url) { shots.remove(at: i) } else { shots.append(url) }
                            }
                        }
                        ForEach(0..<max(0, Self.recentCount - recent.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
            GridRows(items: tools(on: on), columns: 4) { $0 }
        }
        .padding(.top, 2)
        // The tray reads the newest screenshots each time it opens.
        .task(id: folder) {
            guard let folder else { return }
            recent = await RecentShots.newest(in: folder, limit: Self.recentCount)
        }
    }

    /// The tools: Camera, File, Scan, Text, QR, Signature, Get files, and
    /// Agent while the computer lets this Mac start agents.
    private func tools(on: Bool) -> [TrayTool] {
        let d = device
        let model = model
        let herdr = model.core.plugin(HerdrPlugin.self)?.model.states[d.id]
        let camera: [(CameraMode, String, String)] = [
            (.photo, "camera", "Camera"), (.document, "doc.viewfinder", "Scan"), (.text, "text.viewfinder", "Text"),
            (.qr, "qrcode.viewfinder", "QR"), (.signature, "signature", "Signature"),
        ]
        var list: [TrayTool] = []
        for (mode, icon, label) in camera {
            list.append(TrayTool(id: mode.rawValue, icon: icon, label: label, help: mode.hint, enabled: on) {
                close()
                CameraWindows.shared.show(d, mode: mode, app: model)
            })
        }
        // The file picker sits after the camera, as on Android.
        list.insert(TrayTool(id: "file", icon: "doc.badge.arrow.up", label: "File", help: "Send files to \(d.name)", enabled: on) {
            close()
            ShareActions.pickFiles(to: d, model: model)
        }, at: 1)
        if d.accepts(PacketType.sftpRequest) {
            list.append(TrayTool(id: "get", icon: "folder", label: "Get files", help: "Open the home folder of \(d.name), read-only", enabled: on) {
                close()
                BrowseWindows.shared.show(d.id, app: model)
            })
        }
        if herdr?.running == true && herdr?.control == true {
            list.append(TrayTool(id: "agent", icon: "brain", label: "Agent", help: "Start an agent on \(d.name)", enabled: on) {
                close()
                model.startAgent = d.id
            })
        }
        return list
    }

    /// Asks for screenshots in `folder` and sends them to the computer.
    private func pick(in folder: URL) {
        close()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = folder
        panel.prompt = "Send"
        panel.message = "Choose screenshots to send to \(device.name)."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.core.plugin(SharePlugin.self)?.send(files: panel.urls, to: device.id)
    }
}

/// A tool of the tray: an icon in the accent over a label, on `bg` with a
/// `line` border. A tool that is off shows at 55%.
private struct TrayTool: View, Identifiable {
    let id: String
    let icon: String
    let label: String
    let help: String
    var enabled = true
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(enabled ? tn.accent : tn.sub)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(shape.fill(tn.bg))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}

/// A recent screenshot of the tray, 64 pt high. A selected screenshot has
/// a 2 pt accent border and its number in an accent circle at the top right.
private struct ShotCell: View {
    let url: URL
    let number: Int
    let enabled: Bool
    let toggle: () -> Void
    @Environment(\.tn) private var tn
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let selected = number > 0
        Button(action: toggle) {
            tn.offTile
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tn.onAccent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(tn.accent))
                            .padding(5)
                    }
                }
                .overlay(shape.strokeBorder(selected ? tn.accent : tn.line, lineWidth: selected ? 2 : 1))
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help(url.lastPathComponent)
        .accessibilityLabel("Screenshot \(url.lastPathComponent)")
        .accessibilityValue(selected ? "Selected, number \(number)" : "Not selected")
        .task(id: url) { image = await RecentShots.thumbnail(url) }
    }
}

/// The newest screenshots in the screenshot folder of this Mac, and their
/// pictures. macOS marks each screenshot with the screen capture
/// attribute, so the other files in the folder, often the Desktop, stay
/// out.
enum RecentShots {
    /// The extended attribute that macOS sets on a screenshot.
    private static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
    /// The extensions of the image formats that `screencapture` writes.
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]

    /// The `limit` newest screenshots in `folder`, the newest first. It reads the folder off the main thread.
    static func newest(in folder: URL, limit: Int) async -> [URL] {
        (try? await offMain({ list(folder, limit: limit) })) ?? []
    }

    /// The picture of a screenshot, at most `size` pixels on its long side, or nil when it does not read.
    static func thumbnail(_ url: URL, size: Int = 240) async -> NSImage? {
        guard let cg = try? await offMain({ picture(url, size: size) }) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private static func list(_ folder: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var shots: [(url: URL, added: Date)] = []
        for url in urls where extensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let added = values.addedToDirectoryDate ?? values.creationDate, marked(url) else { continue }
            shots.append((url: url, added: added))
        }
        return shots.sorted { $0.added > $1.added }.prefix(limit).map { $0.url }
    }

    /// True when macOS marked the file as a screen capture.
    private static func marked(_ url: URL) -> Bool {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func picture(_ url: URL, size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
