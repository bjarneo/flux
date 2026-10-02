import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Share actions that start outside a computer's page: the file picker, drops,
/// files opened with Flux, and the Services menu.
@MainActor
enum ShareActions {
    /// Asks for files and sends them to the computer.
    static func pickFiles(to device: DeviceSnapshot, model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(device.name)."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.core.plugin(SharePlugin.self)?.send(files: panel.urls, to: device.id)
    }

    /// Sends dropped files as 1 batch, and dropped links and text one by one.
    static func drop(_ providers: [NSItemProvider], to deviceId: String, share: SharePlugin) {
        Task { @MainActor in
            var files: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = await load(URL.self, from: provider), url.isFileURL { files.append(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await load(URL.self, from: provider) { share.send(text: url.absoluteString, to: deviceId) }
                } else if let text = await load(String.self, from: provider), !text.isEmpty {
                    share.send(text: text, to: deviceId)
                }
            }
            if !files.isEmpty { share.send(files: files, to: deviceId) }
        }
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// The computer for files and text from outside the window: the
    /// computer in scope when it is connected, or else the only connected computer.
    static func target(_ model: AppModel) -> String? {
        let connected = model.connectedPaired
        if let id = model.scope, connected.contains(where: { $0.id == id }) { return id }
        if connected.count == 1 { return connected[0].id }
        model.show(connected.isEmpty ? "No computer is connected" : "Pick a computer in the scope menu of Flux first")
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    /// Files dropped on the Dock icon or opened with Flux.
    static func open(urls: [URL], model: AppModel) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let id = target(model) else { return }
        model.core.plugin(SharePlugin.self)?.send(files: files, to: id)
    }
}

/// The "Send to Flux" entries of the Services menu, for files and for text.
/// The NSServices entries in Info.plist name these methods.
@MainActor
final class ShareServices: NSObject {
    private static var installed: ShareServices?
    private let model: AppModel

    private init(model: AppModel) {
        self.model = model
    }

    static func install(model: AppModel) {
        let provider = ShareServices(model: model)
        installed = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    @objc func sendFilesToFlux(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to send" as NSString
            return
        }
        ShareActions.open(urls: urls, model: model)
    }

    @objc func sendTextToFlux(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text to send" as NSString
            return
        }
        guard let id = ShareActions.target(model) else { return }
        model.core.plugin(SharePlugin.self)?.send(text: text, to: id)
    }
}
