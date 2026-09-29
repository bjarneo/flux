#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import NIOConcurrencyHelpers
import Observation

/// The clipboard state that the UI shows.
@MainActor
@Observable
public final class ClipboardModel {
    /// True when clipboard changes go both ways by themselves.
    public internal(set) var sync = true
}

/// Clipboard sync: flux.clipboard and flux.clipboard.connect in
/// both directions. macOS has no clipboard change notification, so while
/// sync is on and a paired computer is connected, the plugin polls the
/// change count of the general pasteboard. iOS asks the user before each
/// read of text from another app, so the iOS app turns the plugin inactive
/// off the screen: then it neither polls nor reads the clipboard. A new
/// link reads it on iOS only when it changed since Flux last saw it.
///
/// On iOS, images go both ways too, with flux.clipboard.image, like in Flux
/// for Android: an image that is copied goes to the computers while sync is
/// on, Send Clipboard sends it, and an image from a computer goes on the
/// clipboard. The iPhone accepts images only while sync is on, so it sends
/// its identity again when the switch changes.
public final class ClipboardPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: ClipboardModel
    /// The last text that a computer put on the clipboard. Flux does not send it back.
    private let lastRemote = NIOLockedValueBox<String?>(nil)
    @MainActor private var timer: Timer?
    @MainActor private var changeCount = 0
    /// The change count when Flux last read or wrote the clipboard, or nil
    /// before the first time. A new link reads the clipboard on iOS only
    /// when the count changed since then.
    @MainActor private var seenCount: Int?
    /// False while the app is off the screen. The Mac app is always active.
    @MainActor public private(set) var isActive = true
    /// True when images sync too. Only the iOS app turns it on.
    let images: Bool
    #if os(iOS)
    /// The last image that a computer put on the clipboard. Flux does not send it back.
    @MainActor private var lastRemoteImage: Data?
    #endif

    static let syncKey = "clipboard.sync"
    static let timestampKey = "clipboard.timestamp"
    /// How often the plugin reads the pasteboard change count, in seconds.
    static let pollInterval: TimeInterval = 0.5

    @MainActor
    public init() {
        model = ClipboardModel()
        images = false
    }

    #if os(iOS)
    /// `images` syncs clipboard images too.
    @MainActor
    public init(images: Bool) {
        model = ClipboardModel()
        self.images = images
    }
    #endif

    public var incoming: [String] { Self.capabilities(images: images, sync: sync).incoming }
    public var outgoing: [String] { Self.capabilities(images: images, sync: sync).outgoing }
    public var handledTypes: [String] { Self.capabilities(images: images, sync: true).incoming }

    /// The packet types of the plugin. Images come in only while sync is on,
    /// and go out also by the Send Clipboard action, like on Android.
    static func capabilities(images: Bool, sync: Bool) -> (incoming: [String], outgoing: [String]) {
        let text = [PacketType.clipboard, PacketType.clipboardConnect]
        guard images else { return (text, text) }
        return (sync ? text + [PacketType.fluxClipboardImage] : text, text + [PacketType.fluxClipboardImage])
    }

    public func attach(core: FluxCore) {
        self.core = core
        let sync = self.sync
        onMain { $0.model.sync = sync }
    }

    // MARK: Settings

    /// True when clipboard changes go both ways by themselves. The default is on.
    public var sync: Bool { core?.defaults.object(forKey: Self.syncKey) as? Bool ?? true }

    /// The time of the last local clipboard change, in milliseconds.
    private var timestamp: Int64 {
        get { (core?.defaults.object(forKey: Self.timestampKey) as? NSNumber)?.int64Value ?? 0 }
        set { core?.defaults.set(NSNumber(value: newValue), forKey: Self.timestampKey) }
    }

    @MainActor
    public func setSync(_ on: Bool) {
        core?.defaults.set(on, forKey: Self.syncKey)
        model.sync = on
        updatePolling()
        // The computers learn whether this device takes images.
        if images { core?.sendIdentity() }
    }

    /// Sets whether the app is on the screen. The poll stops while it is off
    /// the screen, and a change from that time does not go out.
    @MainActor
    public func setActive(_ active: Bool) {
        isActive = active
        updatePolling()
    }

    /// True while the plugin polls the clipboard.
    @MainActor public var isPolling: Bool { timer != nil }

    /// Polls while sync is on, a paired computer is connected, and the app is active.
    static func shouldPoll(sync: Bool, connected: Bool, active: Bool) -> Bool {
        sync && connected && active
    }

    /// True when a new link reads the clipboard for clipboard.connect. The
    /// Mac reads at each link. iOS asks the user before each read of text
    /// from another app, so the iPhone reads only when the clipboard changed
    /// since Flux last read or wrote it. Before that, it only notes the count.
    static func readsOnConnect(platform: FluxPlatform, count: Int, lastSeen: Int?) -> Bool {
        switch platform {
        case .mac: return true
        case .phone: return lastSeen.map { $0 != count } ?? false
        }
    }

    // MARK: Links

    public func onConnected(_ device: Device) {
        let id = device.id
        onMain { plugin in
            plugin.updatePolling()
            guard let core = plugin.core, plugin.sync, plugin.isActive else { return }
            let count = ClipboardText.changeCount
            let reads = Self.readsOnConnect(platform: .current, count: count, lastSeen: plugin.seenCount)
            plugin.seenCount = count
            guard reads, let text = ClipboardText.text(includingPrivate: false) else { return }
            core.send(Packet(PacketType.clipboardConnect, ["content": text, "timestamp": plugin.timestamp]), to: id)
        }
    }

    public func onDisconnected(_ device: Device) {
        onMain { $0.updatePolling() }
    }

    // MARK: Receive

    public func handle(_ packet: Packet, from device: Device) {
        switch packet.type {
        case PacketType.clipboard: receive(packet.string("content"), timestamp: nil)
        case PacketType.clipboardConnect: receive(packet.string("content"), timestamp: packet.long("timestamp") ?? 0)
        #if os(iOS)
        case PacketType.fluxClipboardImage: receiveImage(packet, from: device)
        #endif
        default: break
        }
    }

    /// A clipboard.connect packet carries the time of the last change on the
    /// computer. It loses to a newer local change.
    private func receive(_ text: String?, timestamp: Int64?) {
        guard let text, !text.isEmpty, sync else { return }
        if let timestamp, timestamp >= 1, timestamp <= self.timestamp { return }
        putFromComputer(text)
    }

    /// Puts text from a computer on the clipboard, so that it does not go back.
    public func putFromComputer(_ text: String) {
        lastRemote.withLockedValue { $0 = text }
        onMain { plugin in
            ClipboardText.write(text)
            plugin.changeCount = ClipboardText.changeCount
            plugin.seenCount = plugin.changeCount
        }
    }

    // MARK: Send

    /// Sends the local clipboard to a computer.
    @MainActor
    @discardableResult
    public func sendClipboard(to deviceId: String) -> Bool {
        guard let core, let device = core.device(deviceId) else { return false }
        seenCount = ClipboardText.changeCount
        #if os(iOS)
        if images, ClipboardImage.available, let image = ClipboardImage.read() {
            return sendImage(image, to: device)
        }
        #endif
        guard let text = ClipboardText.text(includingPrivate: true), !text.isEmpty else {
            core.toast("The clipboard is empty")
            return false
        }
        timestamp = Packet.now()
        guard core.send(Packet(PacketType.clipboard, ["content": text]), to: deviceId) else {
            core.toast("Not connected. Try again in a moment")
            return false
        }
        core.toast("Clipboard sent to \(device.name)")
        return true
    }

    @MainActor
    private func updatePolling() {
        let on = Self.shouldPoll(sync: sync, connected: !(core?.connectedPaired().isEmpty ?? true), active: isActive)
        if on, timer == nil {
            changeCount = ClipboardText.changeCount
            let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            // The tolerance lets macOS group the poll with other wake-ups.
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    @MainActor
    private func poll() {
        let count = ClipboardText.changeCount
        guard count != changeCount else { return }
        changeCount = count
        seenCount = count
        onLocalClipboard()
    }

    /// Sends a local clipboard change to every connected computer.
    @MainActor
    private func onLocalClipboard() {
        guard let core, sync else { return }
        #if os(iOS)
        if ClipboardText.holdsPrivate { return }
        if images, ClipboardImage.available {
            if let image = ClipboardImage.read() { onLocalImage(image) }
            return
        }
        #endif
        guard let text = ClipboardText.text(includingPrivate: false) else { return }
        if text == lastRemote.withLockedValue({ $0 }) { return }
        timestamp = Packet.now()
        let p = Packet(PacketType.clipboard, ["content": text])
        for d in core.connectedPaired() { core.send(p, to: d.id) }
    }

    #if os(iOS)
    // MARK: Images

    /// Takes an image from a computer while sync is on. The transfer runs in
    /// a Task, because the core lock is held.
    private func receiveImage(_ p: Packet, from device: Device) {
        guard let core else { return }
        guard images, sync, ClipImage.accepts(p), let tunnel = p.payloadTunnel, let cert = device.certificate else {
            if let token = p.payloadTunnel { device.send(Tunnel.failed(token: token, error: ClipImage.rejected)) }
            return
        }
        let (id, name, mime) = (device.id, device.name, ClipImage.mime(of: p))
        Task.detached { [self] in
            do {
                let data = try await ClipImageTransfer.receive(p, token: tunnel, tls: core.tls, cert: cert) { [weak core] packet in
                    core?.send(packet, to: id)
                }
                onMain { plugin in
                    plugin.lastRemoteImage = ClipboardImage.digest(data)
                    ClipboardImage.write(data, mime: mime)
                    plugin.changeCount = ClipboardText.changeCount
                    plugin.seenCount = plugin.changeCount
                    core.toast("Image from \(name) is on the clipboard")
                }
            } catch {
                FluxLog.plugin.error("receive clipboard image from \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Sends a copied image to each connected computer that takes images,
    /// unless a computer put it there.
    @MainActor
    private func onLocalImage(_ image: ClipboardImage.Image) {
        guard let core, ClipboardImage.digest(image.data) != lastRemoteImage else { return }
        let targets = core.connectedPaired().filter { $0.accepts(PacketType.fluxClipboardImage) }
        guard !targets.isEmpty else { return }
        guard Int64(image.data.count) <= ClipImage.maxBytes else {
            FluxLog.plugin.info("clipboard image of \(image.data.count) bytes not sent, larger than the limit")
            return
        }
        timestamp = Packet.now()
        let ids = targets.map(\.id)
        Task.detached { [self] in _ = await send(image, to: ids) }
    }

    /// The Send Clipboard action for an image.
    @MainActor
    private func sendImage(_ image: ClipboardImage.Image, to device: Device) -> Bool {
        guard let core else { return false }
        let (id, name) = (device.id, device.name)
        guard device.online else {
            core.toast("Not connected. Try again in a moment")
            return false
        }
        guard device.accepts(PacketType.fluxClipboardImage) else {
            core.toast("Update Flux on \(name) to send images")
            return false
        }
        guard Int64(image.data.count) <= ClipImage.maxBytes else {
            core.toast("The image is larger than \(ClipImage.maxBytes >> 20) MB")
            return false
        }
        timestamp = Packet.now()
        Task.detached { [self] in
            let sent = await send(image, to: [id])
            core.toast(sent > 0 ? "Image sent to \(name)" : "Sending the image failed")
        }
        return true
    }

    /// Sends the image to the computers one after the other and returns the
    /// number of computers that got it.
    private func send(_ image: ClipboardImage.Image, to ids: [String]) async -> Int {
        guard let core else { return 0 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-clip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try image.data.write(to: file)
        } catch {
            FluxLog.plugin.error("cannot write the clipboard image: \(String(describing: error), privacy: .public)")
            return 0
        }
        var sent = 0
        for id in ids {
            guard let cert = core.device(id)?.certificate else { continue }
            do {
                try await ClipImageTransfer.send(file, size: Int64(image.data.count), mime: image.mime, to: id, cert: cert, core: core)
                sent += 1
            } catch {
                FluxLog.plugin.error("send clipboard image to \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return sent
    }
    #endif

    private func onMain(_ body: @escaping @MainActor (ClipboardPlugin) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { body(self) }
        }
    }
}

/// The text of the general pasteboard.
enum ClipboardText {
    #if os(macOS)
    /// Password managers mark secrets with these types (nspasteboard.org), so
    /// that clipboard tools leave them alone.
    static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    @MainActor
    static func text(includingPrivate: Bool) -> String? {
        let pb = NSPasteboard.general
        if !includingPrivate, let types = pb.types, !privateTypes.isDisjoint(with: types) { return nil }
        return pb.string(forType: .string)
    }

    @MainActor
    static func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Changes each time an app writes the pasteboard.
    @MainActor
    static var changeCount: Int { NSPasteboard.general.changeCount }
    #else
    /// Password managers mark secrets with these types (nspasteboard.org), so
    /// that clipboard tools leave them alone.
    static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// Reports whether pasteboard types mark a secret, which sync does not send.
    static func isPrivate(_ types: [String]) -> Bool {
        !privateTypes.isDisjoint(with: types)
    }

    /// True when the pasteboard holds a secret. Reading the types does not
    /// ask the user.
    @MainActor
    static var holdsPrivate: Bool { isPrivate(UIPasteboard.general.types) }

    /// The text, or nil for a secret unless `includingPrivate`.
    @MainActor
    static func text(includingPrivate: Bool) -> String? {
        if !includingPrivate, holdsPrivate { return nil }
        return UIPasteboard.general.string
    }

    @MainActor
    static func write(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Changes each time an app writes the pasteboard.
    @MainActor
    static var changeCount: Int { UIPasteboard.general.changeCount }
    #endif
}
