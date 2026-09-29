import Foundation
import Observation

/// The state of the share extension: the items, the computers, the chosen
/// computer, and the queueing.
@MainActor
@Observable
final class ShareComposer {
    enum Phase: Equatable {
        case choosing
        case queueing
        /// The items wait in the queue for the computer with this name.
        case queued(String)
        case failed(String)
    }

    private(set) var items: [SharedItem] = []
    private(set) var computers: [SharedComputer] = []
    /// The text of a single link or text, as a preview.
    private(set) var preview: String?
    var chosen: String?
    private(set) var phase = Phase.choosing
    /// False when the build has no App Group.
    private(set) var hasQueue = true
    /// Ends the extension. True after the items were queued.
    var finish: ((Bool) -> Void)?

    private let providers: [NSItemProvider]

    init(providers: [NSItemProvider]) {
        self.providers = providers
    }

    var summary: ShareSummary { SharedItem.summary(items) }

    var canSend: Bool { phase == .choosing && hasQueue && !items.isEmpty && chosen != nil }

    func load() {
        items = SharedItem.sendable(providers.compactMap(SharedItem.init))
        guard let root = ShareGroup.root else {
            hasQueue = false
            return
        }
        computers = SharedComputers.read(root: root)
        chosen = SharedComputers.defaultChoice(computers, lastUsed: ShareGroup.lastComputer)
        if items.count == 1, let item = items.first, !item.isFile {
            Task {
                preview = try? await item.loadText()
            }
        }
    }

    /// Copies the items into the queue for the chosen computer. The items
    /// show to the app only when the share is complete, so the app never
    /// sends a part of it, and a failure removes only items it never saw.
    func send() {
        guard canSend, let root = ShareGroup.root, let id = chosen,
              let computer = computers.first(where: { $0.id == id }) else { return }
        phase = .queueing
        let items = self.items
        Task {
            let queue = ShareQueue(root: root)
            let created = Date()
            let share = UUID().uuidString
            var added: [String] = []
            do {
                try queue.checkRoom(adding: items.count)
                for (order, item) in items.enumerated() {
                    if item.isFile {
                        added.append(try await item.queueFile(in: queue, computerId: id, created: created, order: order, share: share).id)
                    } else {
                        let text = try await item.loadText()
                        added.append(try queue.add(text: text, kind: item.kind == .link ? .link : .text,
                                                   computerId: id, created: created, order: order, share: share).id)
                    }
                }
                // The copies can take the queue over its size.
                try queue.checkRoom(adding: 0)
                try queue.complete(share)
                ShareGroup.lastComputer = id
                ShareGroup.postQueued()
                phase = .queued(computer.name)
            } catch {
                // A share goes out whole or not at all.
                for added in added { queue.remove(added) }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
