import FluxKit
import Foundation
import Observation
import os

/// The items that the share extension queued. Flux sends them when their
/// computer is connected: when it opens, when a computer connects, and when
/// the extension queues items while Flux still runs. It removes each item
/// once the computer received it and keeps the others for the next try.
@MainActor
@Observable
final class QueuedShares {
    static let shared = QueuedShares()

    private(set) var items: [QueuedShare] = []

    @ObservationIgnored private var queue: ShareQueue?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var computers: [SharedComputer] = []
    @ObservationIgnored private var current: [SharedComputers.Current]?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var drainAgain = false

    static let notificationCategory = "share.queue"
    /// An item folder without its entry after this many seconds is a copy
    /// that the extension did not finish.
    static let abandonedAfter: TimeInterval = 3600

    private init() {}

    func items(for deviceId: String) -> [QueuedShare] { items.filter { $0.computerId == deviceId } }

    func start(model: AppModel) {
        self.model = model
        guard let root = ShareGroup.root else {
            FluxLog.plugin.error("no App Group \(ShareGroup.identifier ?? "", privacy: .public), so shared items cannot queue")
            return
        }
        self.root = root
        queue = ShareQueue(root: root)
        computers = SharedComputers.read(root: root)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QueuedShares.shared.drain() } }
        }, ShareGroup.queuedNotification as CFString, nil, .deliverImmediately)
        stateChanged(model.state)
    }

    /// Reads the queue again. Items that failed too often or waited too
    /// long go, see `ShareQueue.expired`, and a notification says so.
    func refresh() {
        guard let queue else { return }
        queue.removeAbandoned(now: Date(), olderThan: Self.abandonedAfter)
        let expired = ShareQueue.expired(queue.items(), now: Date())
        for item in expired { queue.remove(item.id) }
        for (computer, items) in Dictionary(grouping: expired, by: \.computerId) {
            let name = model?.device(computer)?.name ?? "your computer"
            Notifier.shared.post(id: "share-queue-dropped-\(computer)", category: Self.notificationCategory,
                                 title: "Not sent to \(name)", body: Self.droppedText(items))
        }
        items = queue.items()
    }

    func remove(_ id: String) {
        queue?.remove(id)
        refresh()
    }

    /// Writes the computer list for the extension, drops the items of
    /// computers that are no longer paired, and sends to computers that
    /// connected.
    func stateChanged(_ state: CoreState) {
        guard let root, let queue else { return }
        let paired = state.devices.filter(\.paired)
        let now = paired.map { SharedComputers.Current(id: $0.id, name: $0.name, type: $0.type, online: $0.online) }
        guard now != current else { return }
        let before = Set(current?.filter(\.online).map(\.id) ?? [])
        current = now
        computers = SharedComputers.next(previous: computers, current: now, now: Date())
        do {
            try SharedComputers.write(computers, root: root)
        } catch {
            FluxLog.plugin.error("cannot write the computers for the share extension: \(String(describing: error), privacy: .public)")
        }
        queue.removeItems(notFor: Set(paired.map(\.id)))
        refresh()
        if now.contains(where: { $0.online && !before.contains($0.id) }) { drain() }
    }

    /// Sends the queued items of the connected computers, in order. A call
    /// while a drain runs makes it read the queue again when it ends.
    ///
    /// Nothing goes while Flux runs in the background only for an App
    /// Intent. The links close when the action ends and cut the transfers.
    /// The items go when Flux opens.
    func drain() {
        guard queue != nil, let model, !model.runsOnlyForIntents else { return }
        if draining {
            drainAgain = true
            return
        }
        draining = true
        Task {
            repeat {
                drainAgain = false
                await drainOnce()
            } while drainAgain
            draining = false
        }
    }

    private func drainOnce() async {
        refresh()
        guard let queue, let model, let share = model.core.plugin(SharePlugin.self) else { return }
        let connected = Set(model.state.devices.filter { $0.paired && $0.online && $0.accepts(PacketType.share) }.map(\.id))
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sent: [String: [QueuedShare]] = [:]
        for step in ShareQueue.plan(items, connected: connected) {
            switch step {
            case .files(let computer, let ids):
                let files = ids.compactMap { id in byId[id].flatMap { item in queue.file(of: item).map { ($0, item) } } }
                let byFile = Dictionary(files.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                let done = OSAllocatedUnfairLock(initialState: [QueuedShare]())
                let core = model.core
                let link = Self.openLink(computer, core: core)
                do {
                    try await share.sendAndWait(files: files.map(\.0), to: computer) { url, error in
                        guard let item = byFile[url] else { return }
                        if let error {
                            let counts = QueuedShares.counts(start: link, now: QueuedShares.openLink(computer, core: core))
                            try? queue.markFailed(item.id, message: error.localizedDescription, counts: counts)
                        } else {
                            queue.remove(item.id)
                            done.withLock { $0.append(item) }
                        }
                    }
                } catch {
                    let counts = Self.counts(start: link, now: Self.openLink(computer, core: core))
                    for (_, item) in files { try? queue.markFailed(item.id, message: error.localizedDescription, counts: counts) }
                }
                sent[computer, default: []] += done.withLock { $0 }
            case .text(let computer, let id):
                guard let item = byId[id], let text = item.text else { continue }
                // The computer drops a line over its packet limit, so a large
                // text from an older version never goes out.
                if text.utf8.count > ShareQueue.maxTextBytes {
                    try? queue.markFailed(id, message: ShareQueueError.textTooLarge.localizedDescription)
                } else if share.send(text: text, to: computer) {
                    queue.remove(id)
                    sent[computer, default: []].append(item)
                } else {
                    // The send fails only without an open link, so the try does not count.
                    try? queue.markFailed(id, message: "Not connected", counts: false)
                }
            }
            refresh()
        }
        for (computer, items) in sent where !items.isEmpty {
            let name = model.device(computer)?.name ?? "your computer"
            Notifier.shared.post(id: "share-queue-\(computer)", category: Self.notificationCategory,
                                 title: "Sent to \(name)", body: Self.sentText(items))
        }
    }

    /// The open link to the computer, or nil.
    nonisolated static func openLink(_ computer: String, core: FluxCore) -> Link? {
        core.withDevice(computer) { d in d.online ? d.link : nil } ?? nil
    }

    /// Reports whether a failed try counts toward `ShareQueue.maxTries`. It
    /// counts only while the link from the start of the try is still open.
    /// A link that closed cut the try, for example at the end of the
    /// background time of Flux or after a network change. The item then
    /// waits for the next link.
    nonisolated static func counts(start: Link?, now: Link?) -> Bool {
        guard let start, let now else { return false }
        return start === now
    }

    /// For example "2 files that you shared did not go out in 5 tries or 7 days, so Flux removed them."
    nonisolated static func droppedText(_ items: [QueuedShare]) -> String {
        let s = summary(items)
        let them = s.count == 1 ? "it" : "them"
        return "\(ShareSummary.text(s)) that you shared did not go out in \(ShareQueue.maxTries) tries or \(Int(ShareQueue.maxAge / 86400)) days, so Flux removed \(them)."
    }

    nonisolated private static func summary(_ items: [QueuedShare]) -> ShareSummary {
        var s = ShareSummary()
        for item in items {
            switch item.kind {
            case .file: s.files += 1
            case .link: s.links += 1
            case .text: s.texts += 1
            }
        }
        return s
    }

    /// For example "2 files and 1 link that you shared went out."
    nonisolated static func sentText(_ items: [QueuedShare]) -> String {
        "\(ShareSummary.text(summary(items))) that you shared went out."
    }
}
