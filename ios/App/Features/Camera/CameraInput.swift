import FluxKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Sends what the camera modes make to 1 computer, and shows short messages
/// on the camera screen.
@MainActor
final class CameraOutput {
    let deviceId: String
    private let app: AppModel
    var onMessage: ((String) -> Void)?

    init(deviceId: String, app: AppModel) {
        self.deviceId = deviceId
        self.app = app
    }

    var device: DeviceSnapshot? { app.device(deviceId) }
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

/// Images from outside the camera: photos from the library and pasted images.
enum ImageInput {
    /// Loads the data of picked photos, in the order of the picker. A photo
    /// that does not load is left out.
    static func load(_ items: [PhotosPickerItem]) async -> [Data] {
        var images: [Data] = []
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) { images.append(data) }
            } catch {
                FluxLog.plugin.info("a picked photo did not load: \(String(describing: error), privacy: .public)")
            }
        }
        return images
    }

    static let pasteTypes: [UTType] = [.image]

    /// Loads the data of pasted images.
    static func load(_ providers: [NSItemProvider]) async -> [Data] {
        var images: [Data] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in c.resume(returning: data) }
            }
            if let data { images.append(data) }
        }
        return images
    }
}
