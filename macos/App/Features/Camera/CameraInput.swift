import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Sends what the camera modes make to 1 computer, and shows short messages
/// in the camera window.
@MainActor
final class CameraOutput {
    let deviceId: String
    private let app: AppModel
    var onMessage: ((String) -> Void)?

    init(deviceId: String, app: AppModel) {
        self.deviceId = deviceId
        self.app = app
    }

    var device: DeviceSnapshot? { app.state.devices.first { $0.id == deviceId } }
    var name: String { device?.name ?? "the computer" }

    func say(_ message: String) { onMessage?(message) }

    /// Sends text that the camera read. The computer saves it in its scan folder.
    func sendScan(_ text: String) -> Bool {
        app.core.plugin(SharePlugin.self)?.sendScan(text: text, to: deviceId) ?? false
    }

    /// Sends the packet of a code action, as Flux for Android does.
    func send(_ body: ShareBody) -> Bool {
        app.core.send(body.packet, to: deviceId)
    }

    /// Sends 1 captured file with the extra share fields, such as "photo".
    func sendCapture(_ data: Data, name: String, extra: [String: Any?]) async throws {
        guard let share = app.core.plugin(SharePlugin.self) else { throw FluxError("Sharing is not available") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flux Camera/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try data.write(to: file)
        try await share.sendCapture(file: file, name: name, extra: extra, to: deviceId)
    }
}

/// Images from outside the camera: files, a region of the screen, the
/// clipboard, and drops.
@MainActor
enum ImageInput {
    /// Asks for image files and decodes them upright.
    static func open(multiple: Bool, prompt: String) -> [CGImage] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { try? CameraImages.load($0) }
    }

    /// Lets the user drag over a region of the screen with the system
    /// screenshot tool and returns it. It returns nil when the user presses
    /// Escape. macOS asks for Screen Recording the first time.
    static func screenRegion() async -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flux-region-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path]
            p.terminationHandler = { c.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { c.resume(returning: false) }
        }
        NSApp.activate(ignoringOtherApps: true)
        guard ok, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? CameraImages.load(file)
    }

    /// Returns the image on the clipboard: image data or an image file.
    static func paste() -> CGImage? {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let image = try? CameraImages.load(url) {
            return image
        }
        guard let image = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CameraImages.crop(cg, to: nil, maxSide: CameraImages.maxStillSide)
    }

    static let dropTypes: [UTType] = [.fileURL, .image]

    /// Decodes dropped image files and image data.
    static func load(_ providers: [NSItemProvider]) async -> [CGImage] {
        var images: [CGImage] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url = await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadObject(ofClass: URL.self) { value, _ in c.resume(returning: value) }
                }
                if let url, let image = try? CameraImages.load(url) { images.append(image) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let data = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in c.resume(returning: data) }
                }
                if let data, let image = try? CameraImages.decode(data) { images.append(image) }
            }
        }
        return images
    }
}
