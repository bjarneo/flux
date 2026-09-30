#if os(macOS)
import AppKit
#else
import Security
import UIKit
#endif
import Crypto
import Foundation
import NIOConcurrencyHelpers
import Observation

/// The clipboard state that the UI shows.
@MainActor
@Observable
public final class ClipboardModel {
    /// True when clipboard changes go both ways by themselves.
    public internal(set) var sync = true

    /// True when a copy from another app goes out when the iOS app opens.
    public internal(set) var sendOnOpen = true
}

/// Clipboard sync: flux.clipboard and flux.clipboard.connect in
/// both directions. macOS has no clipboard change notification, so while
/// sync is on and a paired computer is connected, the plugin polls the
/// change count of the general pasteboard. While no computer is connected,
/// the Mac reads only the change count and keeps the time of a new copy, so
/// that the copy wins over older copies of the computers on the next link.
///
/// iOS asks the user before each read of text from another app, so the iOS
/// app turns the plugin inactive off the screen: then it neither polls nor
/// reads the clipboard. When the app becomes active or a computer connects,
/// the iPhone reads the clipboard only when it changed since Flux last saw
/// it, see `unseenCopy`. Flux keeps that change count across launches.
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
    /// What the timer does now.
    @MainActor private var watching = Watch.off
    /// The change count that the timer handled last.
    @MainActor private var changeCount = 0
    /// The change count of the last copy that went out, see `sentLatestCopy`.
    @MainActor private var sentCount: Int?
    /// The computer of the last text from a computer, and the change count
    /// after its write, see `sendsOnConnect`.
    @MainActor private var remoteCopy: RemoteCopy?
    /// False while the app is off the screen. The Mac app is always active.
    /// The iOS app starts inactive, because iOS can start it in the
    /// background, for example for an App Intent. Its scene makes it active.
    @MainActor public private(set) var isActive = FluxPlatform.current == .mac
    /// `isActive` for the network threads.
    private let active = NIOLockedValueBox(FluxPlatform.current == .mac)
    /// True when images sync too. Only the iOS app turns it on.
    let images: Bool
    #if os(iOS)
    /// The last image that a computer put on the clipboard. Flux does not send it back.
    @MainActor private var lastRemoteImage: Data?
    /// The image transfers from computers that run, so that an unpair ends them.
    private let imageStreams = NIOLockedValueBox<[UUID: (deviceId: String, stream: TLSStream)]>([:])
    /// The key of the text digests, see `ClipboardDigestKey`. Flux reads it once.
    private let digestKey = NIOLockedValueBox<Data?>(nil)
    #endif

    static let syncKey = "clipboard.sync"
    static let timestampKey = "clipboard.timestamp"
    static let sendOnOpenKey = "clipboard.sendOnOpen"
    static let seenCountKey = "clipboard.seenCount"
    static let sentDigestKey = "clipboard.sentDigest"
    static let remoteDigestKey = "clipboard.remoteDigest"
    static let shortcutDigestKey = "clipboard.shortcutDigest"
    /// How often the plugin reads the pasteboard change count, in seconds.
    static let pollInterval: TimeInterval = 0.5
    /// How often the Mac reads the change count while no computer is
    /// connected, in seconds. The time of a copy can be this much late.
    static let noteInterval: TimeInterval = 2

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
        let (sync, sendOnOpen) = (self.sync, self.sendOnOpen)
        onMain { plugin in
            plugin.model.sync = sync
            plugin.model.sendOnOpen = sendOnOpen
            // The Mac keeps the time of a copy also before the first link.
            plugin.updatePolling()
        }
    }

    // MARK: Settings

    /// True when clipboard changes go both ways by themselves. The default is on.
    public var sync: Bool { core?.defaults.object(forKey: Self.syncKey) as? Bool ?? true }

    /// True when a copy that the user made in another app goes out when
    /// the iOS app opens, see `catchUp`. The default is on.
    public var sendOnOpen: Bool { core?.defaults.object(forKey: Self.sendOnOpenKey) as? Bool ?? true }

    /// The time of the last clipboard change, in milliseconds: a local
    /// copy, or the text that a computer put on the clipboard.
    private var timestamp: Int64 {
        get { (core?.defaults.object(forKey: Self.timestampKey) as? NSNumber)?.int64Value ?? 0 }
        set { core?.defaults.set(NSNumber(value: newValue), forKey: Self.timestampKey) }
    }

    /// The change count when Flux last read or wrote the clipboard, or nil
    /// before the first time. It stays across launches, so that a copy
    /// from before a cold start of the iOS app goes out too.
    @MainActor var seenCount: Int? {
        get { (core?.defaults.object(forKey: Self.seenCountKey) as? NSNumber)?.intValue }
        set { core?.defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Self.seenCountKey) }
    }

    @MainActor
    public func setSync(_ on: Bool) {
        core?.defaults.set(on, forKey: Self.syncKey)
        model.sync = on
        updatePolling()
        // The computers learn whether this device takes images.
        if images { core?.sendIdentity() }
    }

    @MainActor
    public func setSendOnOpen(_ on: Bool) {
        core?.defaults.set(on, forKey: Self.sendOnOpenKey)
        model.sendOnOpen = on
    }

    /// Sets whether the app is on the screen. The poll stops while it is off
    /// the screen, and a change from that time does not go out.
    @MainActor
    public func setActive(_ active: Bool) {
        isActive = active
        self.active.withLockedValue { $0 = active }
        updatePolling()
    }

    /// True while the plugin polls the clipboard and sends new copies.
    @MainActor public var isPolling: Bool { watching == .send }

    /// What the timer does with the pasteboard.
    enum Watch: Equatable {
        /// No timer runs.
        case off
        /// It sends each new copy to the connected computers.
        case send
        /// It reads only the change count and keeps the time of a new copy.
        case note
    }

    /// The plugin sends new copies while sync is on, a paired computer is
    /// connected, and the app is active. While sync is on, a computer is
    /// paired, and none is connected, the Mac keeps the time of each new
    /// copy without a read. The iPhone does not, because iOS suspends Flux
    /// soon after it leaves the screen.
    static func watch(platform: FluxPlatform, sync: Bool, paired: Bool, connected: Bool, active: Bool) -> Watch {
        guard sync, active else { return .off }
        if connected { return .send }
        return platform == .mac && paired ? .note : .off
    }

    /// Reports whether a change of the watch keeps the time of a copy that
    /// the old watch did not handle yet. The note watch keeps the time of a
    /// copy from its last seconds. A copy from the last poll before the last
    /// link dropped did not go out, so it keeps its time for the next link.
    static func notesOnChange(from old: Watch, to next: Watch) -> Bool {
        old == .note || (old == .send && next == .note)
    }

    /// A text that a computer put on the clipboard, and the change count
    /// after the write.
    struct RemoteCopy: Equatable {
        let device: String
        let count: Int
    }

    /// Reports whether a new link to `device` gets the clipboard of the Mac.
    /// Text that the same computer put there does not go back while the
    /// clipboard did not change. Its time is the time that it arrived,
    /// which is later than the copy on the computer, so the computer would
    /// take its own text again.
    static func sendsOnConnect(to device: String, count: Int, remote: RemoteCopy?) -> Bool {
        guard let remote else { return true }
        return remote.device != device || remote.count != count
    }

    /// What the iPhone does with the clipboard when Flux becomes active or
    /// a computer connects.
    enum Unseen: Equatable {
        /// Flux saw this copy already.
        case seen
        /// Flux notes the change count and does not read the clipboard.
        case note
        /// Flux reads the copy and sends it.
        case send
    }

    /// Decides what the iPhone does with a copy that Flux did not see yet.
    /// iOS asks the user before each read of text from another app, so
    /// Flux reads nothing before it knows the change count, and it does not
    /// read a secret or a copy without text or image. `sends` is false when
    /// the user turned off Send the clipboard when Flux opens.
    static func unseenCopy(count: Int, lastSeen: Int?, sends: Bool, holdsPrivate: Bool, holdsContent: Bool) -> Unseen {
        guard let lastSeen else { return .note }
        guard count != lastSeen else { return .seen }
        return sends && !holdsPrivate && holdsContent ? .send : .note
    }

    // MARK: Links

    public func onConnected(_ device: Device) {
        #if os(iOS)
        onMain { plugin in
            plugin.updatePolling()
            guard plugin.sync, plugin.isActive else { return }
            // A copy that Flux did not see yet is newer than the clipboard
            // of the computer, so it goes out as a new copy.
            plugin.sendUnseenCopy(onOpen: false)
        }
        #else
        let id = device.id
        onMain { plugin in
            plugin.updatePolling()
            guard let core = plugin.core, plugin.sync, plugin.isActive else { return }
            // The Mac reads at each link. `timestamp` holds the time of its
            // last copy, also of a copy while no computer was connected, so
            // the newer copy wins on both sides.
            let count = ClipboardText.changeCount
            plugin.markSeen(count)
            guard Self.sendsOnConnect(to: id, count: count, remote: plugin.remoteCopy),
                  let text = ClipboardText.text(includingPrivate: false) else { return }
            core.send(Packet(PacketType.clipboardConnect, ["content": text, "timestamp": plugin.timestamp]), to: id)
        }
        #endif
    }

    public func onDisconnected(_ device: Device) {
        onMain { $0.updatePolling() }
        #if os(iOS)
        // An unpair ends the image transfers of the computer. A link that
        // only drops leaves them, because they have their own connections.
        guard !device.paired else { return }
        let id = device.id
        let ended = imageStreams.withLockedValue { all -> [TLSStream] in
            let mine = all.filter { $0.value.deviceId == id }
            for key in mine.keys { all[key] = nil }
            return mine.values.map { $0.stream }
        }
        ended.forEach { $0.channel.channel.close(promise: nil) }
        #endif
    }

    // MARK: Receive

    public func handle(_ packet: Packet, from device: Device) {
        switch packet.type {
        case PacketType.clipboard: receive(packet.string("content"), timestamp: nil, from: device.id)
        case PacketType.clipboardConnect: receive(packet.string("content"), timestamp: packet.long("timestamp") ?? 0, from: device.id)
        #if os(iOS)
        case PacketType.fluxClipboardImage: receiveImage(packet, from: device)
        #endif
        default: break
        }
    }

    /// A clipboard.connect packet carries the time of the last change on the
    /// computer. It loses to a newer local change. The iPhone takes changes
    /// only while Flux is on the screen, as the docs say, also when the
    /// microphone stream keeps Flux running in the background.
    private func receive(_ text: String?, timestamp: Int64?, from deviceId: String) {
        guard let text, !text.isEmpty, sync, active.withLockedValue({ $0 }) else { return }
        onMain { plugin in
            #if os(iOS)
            // A copy that Flux did not see yet is newer, and the text of the
            // computer does not replace it. The computer can send its packet
            // before `onConnected` runs.
            if timestamp != nil, plugin.sendUnseenCopy(onOpen: false) { return }
            #endif
            // A Mac copy from the last seconds before the link keeps its time first.
            if plugin.watching == .note { plugin.noteChange() }
            guard Self.takes(timestamp, last: plugin.timestamp) else { return }
            // The same text after a reconnect then changes nothing, like on Android.
            plugin.timestamp = Self.time(of: timestamp, now: Packet.now())
            plugin.put(text, from: deviceId)
        }
    }

    /// Reports whether text from a computer replaces the clipboard. A
    /// clipboard.connect packet with a time that is not later than `last`
    /// is old. flux.clipboard has no time and always counts.
    static func takes(_ timestamp: Int64?, last: Int64) -> Bool {
        guard let timestamp, timestamp >= 1 else { return true }
        return timestamp > last
    }

    /// The time that the clipboard keeps for text from a computer: the time
    /// of the packet, or `now` for a packet without a time.
    static func time(of timestamp: Int64?, now: Int64) -> Int64 {
        guard let timestamp, timestamp >= 1 else { return now }
        return timestamp
    }

    /// Puts text from a computer on the clipboard, so that it does not go back.
    public func putFromComputer(_ text: String, from deviceId: String) {
        onMain { $0.put(text, from: deviceId) }
    }

    @MainActor
    private func put(_ text: String, from deviceId: String) {
        lastRemote.withLockedValue { $0 = text }
        if let digest = digest(text) { core?.defaults.set(digest, forKey: Self.remoteDigestKey) }
        ClipboardText.write(text)
        markSeen(ClipboardText.changeCount)
        remoteCopy = RemoteCopy(device: deviceId, count: changeCount)
    }

    /// Notes that Flux saw the clipboard at `count`, so that neither the
    /// poll nor the next link sends it again. The copy that Send Text to
    /// Computer sent is then old, see `sendText`.
    @MainActor
    private func markSeen(_ count: Int) {
        changeCount = count
        seenCount = count
        core?.defaults.removeObject(forKey: Self.shortcutDigestKey)
    }

    // MARK: Digests

    /// Identifies a text, so that Flux can compare texts without keeping
    /// them. The digest is an HMAC-SHA256 with the random key of this
    /// install. The digests go into a backup of the settings and the key
    /// does not, so a digest does not give away a short text, such as a
    /// password.
    static func digest(_ text: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }

    /// The digest of a text on the iPhone, see `ClipboardDigestKey`. Only the
    /// iOS app compares texts, so the Mac keeps no digests.
    private func digest(_ text: String) -> Data? {
        #if os(iOS)
        let key = digestKey.withLockedValue { cached -> Data in
            if let known = cached { return known }
            let loaded = ClipboardDigestKey.load()
            cached = loaded
            return loaded
        }
        return Self.digest(text, key: key)
        #else
        return nil
        #endif
    }

    /// Reports whether a text is the last text that Flux sent or the last
    /// text that a computer put on the clipboard.
    static func isUnchanged(_ digest: Data, sent: Data?, remote: Data?) -> Bool {
        digest == sent || digest == remote
    }

    /// True when the text is the last text that Flux sent or the last text
    /// that a computer put on the clipboard. Send Text to Computer can skip
    /// such text, for example in an automation that runs often.
    public func isUnchanged(_ text: String) -> Bool {
        guard let digest = digest(text) else { return false }
        return Self.isUnchanged(digest, sent: core?.defaults.data(forKey: Self.sentDigestKey),
                                remote: core?.defaults.data(forKey: Self.remoteDigestKey))
    }

    /// Keeps the digest of text that went out. A copy that went out by
    /// Send Text to Computer is kept apart until Flux sees the clipboard.
    private func noteSent(_ text: String, byShortcut: Bool = false) {
        guard let digest = digest(text) else { return }
        core?.defaults.set(digest, forKey: Self.sentDigestKey)
        if byShortcut {
            core?.defaults.set(digest, forKey: Self.shortcutDigestKey)
        } else {
            core?.defaults.removeObject(forKey: Self.shortcutDigestKey)
        }
    }

    // MARK: Send

    /// Sends the local clipboard to a computer.
    @MainActor
    @discardableResult
    public func sendClipboard(to deviceId: String) -> Bool {
        sendClipboard(to: [deviceId])
    }

    /// Sends the local clipboard to computers: an image, or else its text.
    /// It reads the clipboard once, so that iOS asks at most once.
    @MainActor
    @discardableResult
    public func sendClipboard(to deviceIds: [String]) -> Bool {
        guard let core else { return false }
        let known = deviceIds.filter { core.withDevice($0, { _ in true }) == true }
        guard !known.isEmpty else { return false }
        let count = ClipboardText.changeCount
        markSeen(count)
        #if os(iOS)
        if images, ClipboardImage.available, let image = ClipboardImage.read() {
            let started = known.map { sendImage(image, to: $0) }.contains(true)
            if started { sentCount = count }
            return started
        }
        #endif
        guard let text = ClipboardText.text(includingPrivate: true), !text.isEmpty else {
            core.toast("The clipboard is empty")
            return false
        }
        timestamp = Packet.now()
        let p = Packet(PacketType.clipboard, ["content": text])
        let names = known.filter { core.send(p, to: $0) }.compactMap { id in core.withDevice(id, { $0.name }) }
        guard !names.isEmpty else {
            core.toast("Not connected. Try again in a moment")
            return false
        }
        noteSent(text)
        sentCount = count
        core.toast("Clipboard sent to \(names.joined(separator: ", "))")
        return true
    }

    /// True when the copy on the clipboard went out already, for example
    /// when Flux opened. Reading it does not read the clipboard.
    @MainActor public var sentLatestCopy: Bool { sentCount == ClipboardText.changeCount }

    /// Sends text from Send Text to Computer, an App Intent, to the
    /// computers `ids` that take clipboard text. It waits until each link
    /// wrote the packet, so that the app can close the links after it. It
    /// returns the IDs of the computers that got the text.
    ///
    /// The text usually comes from the clipboard through the Shortcuts app.
    /// Flux keeps its digest, so that the same copy does not go out again
    /// when Flux opens, see `sendUnseenCopy`.
    public func sendText(_ text: String, to ids: [String]) async -> [String] {
        guard let core else { return [] }
        let p = Packet(PacketType.clipboard, ["content": text])
        var sent: [String] = []
        for id in ids where core.withDevice(id, { $0.accepts(PacketType.clipboard) }) == true {
            if await core.sendFlushed(p, to: id) { sent.append(id) }
        }
        guard !sent.isEmpty else { return [] }
        // A new copy wins over older copies of the computers on the next link.
        timestamp = Packet.now()
        noteSent(text, byShortcut: true)
        return sent
    }

    @MainActor
    private func updatePolling() {
        let paired = !(core?.trust.all().isEmpty ?? true)
        let connected = !(core?.connectedPairedIds().isEmpty ?? true)
        let next = Self.watch(platform: .current, sync: sync, paired: paired, connected: connected, active: isActive)
        guard next != watching else { return }
        if Self.notesOnChange(from: watching, to: next) { noteChange() }
        timer?.invalidate()
        timer = nil
        watching = next
        let interval: TimeInterval
        switch next {
        case .off:
            return
        case .send:
            // On iOS, a copy that Flux did not see yet goes out with the
            // first poll. The Mac reads the clipboard at each link instead.
            let count = ClipboardText.changeCount
            changeCount = FluxPlatform.current == .phone ? seenCount ?? count : count
            interval = Self.pollInterval
        case .note:
            changeCount = ClipboardText.changeCount
            interval = Self.noteInterval
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // The tolerance lets macOS group the poll with other wake-ups.
        t.tolerance = interval * 0.4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor
    private func poll() {
        switch watching {
        case .send:
            let count = ClipboardText.changeCount
            guard count != changeCount else { return }
            changeCount = count
            markSeen(count)
            if onLocalClipboard() { sentCount = count }
        case .note:
            noteChange()
        case .off:
            break
        }
    }

    /// Keeps the time of a new copy without a read of its content.
    @MainActor
    private func noteChange() {
        let count = ClipboardText.changeCount
        guard count != changeCount else { return }
        changeCount = count
        timestamp = Packet.now()
    }

    /// Sends a local clipboard change to every connected computer. It
    /// returns true when the copy went out. Text with the digest `skipping`
    /// does not go out.
    @MainActor
    @discardableResult
    private func onLocalClipboard(skipping: Data? = nil) -> Bool {
        guard let core, sync else { return false }
        #if os(iOS)
        if ClipboardText.holdsPrivate { return false }
        if images, ClipboardImage.available {
            guard let image = ClipboardImage.read() else { return false }
            return onLocalImage(image)
        }
        #endif
        guard let text = ClipboardText.text(includingPrivate: false) else { return false }
        if text == lastRemote.withLockedValue({ $0 }) { return false }
        if let skipping, digest(text) == skipping { return false }
        timestamp = Packet.now()
        noteSent(text)
        let p = Packet(PacketType.clipboard, ["content": text])
        for id in core.connectedPairedIds() { core.send(p, to: id) }
        return true
    }

    #if os(iOS)
    // MARK: Copies from other apps

    /// Sends a copy that the user made in another app while Flux was off
    /// the screen or closed. The app calls it when it becomes active. With
    /// no computer connected, the first computer that connects gets it.
    @MainActor
    public func catchUp() {
        guard sync, isActive else { return }
        sendUnseenCopy(onOpen: true)
    }

    /// Sends a copy that Flux did not see yet to the connected computers,
    /// see `unseenCopy`. `onOpen` follows the Send the clipboard when Flux
    /// opens setting. It returns true when the copy went out.
    ///
    /// A copy that Send Text to Computer sent already does not go again, so
    /// that it does not replace a newer copy of a computer.
    @MainActor
    @discardableResult
    private func sendUnseenCopy(onOpen: Bool) -> Bool {
        let count = ClipboardText.changeCount
        let step = Self.unseenCopy(count: count, lastSeen: seenCount, sends: !onOpen || sendOnOpen,
                                   holdsPrivate: ClipboardText.holdsPrivate, holdsContent: ClipboardText.holdsContent)
        switch step {
        case .seen:
            return false
        case .note:
            markSeen(count)
            return false
        case .send:
            // The first computer that connects gets the copy, see `onConnected`.
            guard let core, !core.connectedPairedIds().isEmpty else { return false }
            let shortcut = core.defaults.data(forKey: Self.shortcutDigestKey)
            markSeen(count)
            guard onLocalClipboard(skipping: shortcut) else { return false }
            sentCount = count
            return true
        }
    }
    #endif

    #if os(iOS)
    // MARK: Images

    /// Takes an image from a computer while sync is on. The transfer runs in
    /// a Task, because the core lock is held.
    private func receiveImage(_ p: Packet, from device: Device) {
        guard let core else { return }
        guard images, sync, active.withLockedValue({ $0 }), ClipImage.accepts(p), let tunnel = p.payloadTunnel, let cert = device.certificate else {
            if let token = p.payloadTunnel { device.send(Tunnel.failed(token: token, error: ClipImage.rejected)) }
            return
        }
        let (id, name, mime) = (device.id, device.name, ClipImage.mime(of: p))
        Task.detached { [self] in
            let key = UUID()
            defer { imageStreams.withLockedValue { $0[key] = nil } }
            do {
                let data = try await ClipImageTransfer.receive(p, token: tunnel, tls: core.tls, cert: cert,
                                                               register: { self.registerImage($0, key: key, deviceId: id) }) { [weak core] packet in
                    core?.send(packet, to: id)
                }
                onMain { plugin in
                    // The transfer can take seconds. The image goes on the
                    // clipboard only when Flux is still on the screen, sync
                    // is still on, and the computer is still paired.
                    guard plugin.isActive, plugin.sync, core.withDevice(id, { $0.paired }) == true else {
                        FluxLog.plugin.info("dropped the clipboard image from \(name, privacy: .public): Flux left the screen, sync is off, or the computer is not paired")
                        return
                    }
                    plugin.lastRemoteImage = ClipboardImage.digest(data)
                    ClipboardImage.write(data, mime: mime)
                    plugin.markSeen(ClipboardText.changeCount)
                    core.toast("Image from \(name) is on the clipboard")
                }
            } catch {
                FluxLog.plugin.error("receive clipboard image from \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Keeps an image stream until its transfer ends. It returns false when
    /// the computer is no longer paired. The core lock comes first, as in
    /// an unpair.
    private func registerImage(_ stream: TLSStream, key: UUID, deviceId: String) -> Bool {
        core?.withDevice(deviceId) { d -> Bool in
            guard d.paired else { return false }
            imageStreams.withLockedValue { $0[key] = (deviceId, stream) }
            return true
        } ?? false
    }

    /// Sends a copied image to each connected computer that takes images,
    /// unless a computer put it there. It returns true when the transfer starts.
    @MainActor
    private func onLocalImage(_ image: ClipboardImage.Image) -> Bool {
        guard let core, ClipboardImage.digest(image.data) != lastRemoteImage else { return false }
        let ids = core.connectedPairedIds(accepting: PacketType.fluxClipboardImage)
        guard !ids.isEmpty else { return false }
        guard Int64(image.data.count) <= ClipImage.maxBytes else {
            FluxLog.plugin.info("clipboard image of \(image.data.count) bytes not sent, larger than the limit")
            return false
        }
        timestamp = Packet.now()
        Task.detached { [self] in _ = await send(image, to: ids) }
        return true
    }

    /// The Send Clipboard action for an image.
    @MainActor
    private func sendImage(_ image: ClipboardImage.Image, to id: String) -> Bool {
        guard let core, let peer = core.withDevice(id, { (name: $0.name, online: $0.online, accepts: $0.accepts(PacketType.fluxClipboardImage)) }) else {
            return false
        }
        let name = peer.name
        guard peer.online else {
            core.toast("Not connected. Try again in a moment")
            return false
        }
        guard peer.accepts else {
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
            guard let cert = core.withDevice(id, { $0.certificate }) ?? nil else { continue }
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

#if os(iOS)
/// The random key of the clipboard digests, see `ClipboardPlugin.digest`.
/// It stays in the Keychain of this iPhone. It is available after the first
/// unlock and does not go into a backup or to another iPhone.
enum ClipboardDigestKey {
    static let service = "org.omarchy.flux.clipboard"
    static let account = "digest"

    /// The key from the Keychain, or a new key that Flux adds there. When
    /// the Keychain fails, the new key lasts until Flux quits. The digests
    /// of an earlier launch then do not match, so a text counts as new.
    static func load() -> Data {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard status == errSecItemNotFound else {
            FluxLog.plugin.error("cannot use the clipboard key in the Keychain: status \(status)")
            return key
        }
        var add = item
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = key
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess {
            FluxLog.plugin.error("cannot keep the clipboard key in the Keychain: status \(added)")
        }
        return key
    }
}
#endif

/// The text of the general pasteboard.
enum ClipboardText {
    #if os(macOS)
    /// Password managers mark secrets with these types (nspasteboard.org), so
    /// that clipboard tools leave them alone.
    static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
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

    /// True when the pasteboard holds text or an image. Reading this does
    /// not ask the user.
    @MainActor
    static var holdsContent: Bool { UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages }

    /// The text, or nil for a secret unless `includingPrivate`.
    @MainActor
    static func text(includingPrivate: Bool) -> String? {
        if !includingPrivate, holdsPrivate { return nil }
        return UIPasteboard.general.string
    }

    /// Writes text from a computer. It stays on this iPhone: Universal
    /// Clipboard does not pass it to the other Apple devices of the user.
    @MainActor
    static func write(_ text: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true])
    }

    /// Changes each time an app writes the pasteboard.
    @MainActor
    static var changeCount: Int { UIPasteboard.general.changeCount }
    #endif
}
