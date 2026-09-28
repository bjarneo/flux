import AppKit
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

/// Clipboard sync: kdeconnect.clipboard and kdeconnect.clipboard.connect in
/// both directions. macOS has no clipboard change notification, so while
/// sync is on and a paired computer is connected, the plugin polls the
/// change count of the general pasteboard.
public final class ClipboardPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: ClipboardModel
    /// The last text that a computer put on the clipboard. Flux does not send it back.
    private let lastRemote = NIOLockedValueBox<String?>(nil)
    @MainActor private var timer: Timer?
    @MainActor private var changeCount = 0

    static let syncKey = "clipboard.sync"
    static let timestampKey = "clipboard.timestamp"
    /// How often the plugin reads the pasteboard change count, in seconds.
    static let pollInterval: TimeInterval = 0.5

    @MainActor
    public init() {
        model = ClipboardModel()
    }

    public let incoming = [PacketType.clipboard, PacketType.clipboardConnect]
    public let outgoing = [PacketType.clipboard, PacketType.clipboardConnect]

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
    }

    // MARK: Links

    public func onConnected(_ device: Device) {
        let id = device.id
        onMain { plugin in
            plugin.updatePolling()
            guard let core = plugin.core, plugin.sync, let text = ClipboardText.text(includingPrivate: false) else { return }
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
            plugin.changeCount = NSPasteboard.general.changeCount
        }
    }

    // MARK: Send

    /// Sends the local clipboard to a computer.
    @MainActor
    @discardableResult
    public func sendClipboard(to deviceId: String) -> Bool {
        guard let core, let device = core.device(deviceId) else { return false }
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

    /// Polls while sync is on and a paired computer is connected.
    @MainActor
    private func updatePolling() {
        let on = sync && !(core?.connectedPaired().isEmpty ?? true)
        if on, timer == nil {
            changeCount = NSPasteboard.general.changeCount
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
        let count = NSPasteboard.general.changeCount
        guard count != changeCount else { return }
        changeCount = count
        onLocalClipboard()
    }

    /// Sends a local clipboard change to every connected computer.
    @MainActor
    private func onLocalClipboard() {
        guard let core, sync, let text = ClipboardText.text(includingPrivate: false) else { return }
        if text == lastRemote.withLockedValue({ $0 }) { return }
        timestamp = Packet.now()
        let p = Packet(PacketType.clipboard, ["content": text])
        for d in core.connectedPaired() { core.send(p, to: d.id) }
    }

    private func onMain(_ body: @escaping @MainActor (ClipboardPlugin) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { body(self) }
        }
    }
}

/// The text of the general pasteboard.
enum ClipboardText {
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
}
