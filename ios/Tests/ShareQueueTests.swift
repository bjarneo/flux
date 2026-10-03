import UniformTypeIdentifiers
import XCTest
@testable import Flux

final class ShareQueueTests: XCTestCase {
    private func makeQueue() throws -> ShareQueue {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ShareQueue(root: root)
    }

    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testItemsRoundTripInOrder() throws {
        let queue = try makeQueue()
        let photo = try makeFile("IMG_0001.jpeg", "jpeg")
        try queue.add(file: photo, computerId: "a", created: t0, order: 0)
        try queue.add(text: "hello", kind: .text, computerId: "a", created: t0, order: 1)
        try queue.add(text: "https://example.com", kind: .link, computerId: "b", created: t0.addingTimeInterval(-10), order: 0)
        let items = queue.items()
        XCTAssertEqual(items.map(\.kind), [.link, .file, .text], "older shares go first, then the order in the share")
        XCTAssertEqual(items[0].text, "https://example.com")
        XCTAssertEqual(items[0].computerId, "b")
        XCTAssertEqual(items[1].name, "IMG_0001.jpeg")
        XCTAssertNil(items[1].text)
        XCTAssertEqual(items[2].text, "hello")
        let copy = try XCTUnwrap(queue.file(of: items[1]))
        XCTAssertEqual(copy.lastPathComponent, "IMG_0001.jpeg", "the computer gets the original name")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "jpeg")
        XCTAssertNotEqual(copy.standardizedFileURL, photo.standardizedFileURL, "the queue keeps its own copy")
        XCTAssertNil(queue.file(of: items[0]), "a link has no file")
    }

    func testItemsSurviveANewQueueOnTheSameFolder() throws {
        let queue = try makeQueue()
        try queue.add(text: "hello", kind: .text, computerId: "a", created: t0, order: 0)
        XCTAssertEqual(ShareQueue(root: queue.root).items(), queue.items(), "the app reads what the extension wrote")
    }

    func testFileNamesStayInTheirFolder() throws {
        let queue = try makeQueue()
        let file = try makeFile("x", "data")
        let item = try queue.add(file: file, computerId: "a", created: t0, order: 0, name: "../../evil")
        XCTAssertEqual(item.name, "evil")
        XCTAssertEqual(queue.file(of: item)?.deletingLastPathComponent().lastPathComponent, item.id)
        let blank = try queue.add(file: file, computerId: "a", created: t0, order: 1, name: " ")
        XCTAssertEqual(blank.name, "file")
    }

    func testRemove() throws {
        let queue = try makeQueue()
        let a = try queue.add(file: try makeFile("a.txt", "a"), computerId: "a", created: t0, order: 0)
        let b = try queue.add(text: "b", kind: .text, computerId: "a", created: t0, order: 1)
        let fileFolder = try XCTUnwrap(queue.file(of: a)).deletingLastPathComponent()
        queue.remove(a.id)
        XCTAssertEqual(queue.items().map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileFolder.path), "the copy goes with the item")
        queue.remove("../..")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.root.path), "an id never names a folder outside the queue")
        XCTAssertEqual(queue.items().map(\.id), [b.id])
    }

    func testAFailureStaysForTheNextTry() throws {
        let queue = try makeQueue()
        let a = try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        try queue.markFailed(a.id, message: "Not connected")
        let items = queue.items()
        XCTAssertEqual(items.map(\.id), [a.id], "a failed item stays")
        XCTAssertEqual(items[0].failure, "Not connected")
        XCTAssertEqual(items[0].created, t0, "it keeps its place in the order")
    }

    func testAnUnfinishedItemIsHiddenAndRemovedLater() throws {
        let queue = try makeQueue()
        // The extension copies the file first and writes the entry last.
        let folder = queue.folder.appendingPathComponent("unfinished", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: folder.appendingPathComponent("big.mov"))
        let done = try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        XCTAssertEqual(queue.items().map(\.id), [done.id], "an item without its entry does not show")
        queue.removeAbandoned(now: Date(), olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "an extension may still copy it")
        queue.removeAbandoned(now: Date().addingTimeInterval(7200), olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(queue.items().map(\.id), [done.id], "finished items stay")
    }

    func testAShareShowsWhenItIsComplete() throws {
        let queue = try makeQueue()
        let alone = try queue.add(text: "alone", kind: .text, computerId: "a", created: t0, order: 0)
        let a = try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 1, share: "s1")
        let b = try queue.add(file: try makeFile("b.txt", "b"), computerId: "a", created: t0, order: 2, share: "s1")
        XCTAssertEqual(queue.items().map(\.id), [alone.id], "the app never sees a part of a share")
        try queue.complete("s1")
        XCTAssertEqual(queue.items().map(\.id), [alone.id, a.id, b.id])
        XCTAssertThrowsError(try queue.complete("../x"))
    }

    func testAnUnfinishedShareIsRemovedLater() throws {
        let queue = try makeQueue()
        let left = try queue.add(text: "left", kind: .text, computerId: "a", created: t0, order: 0, share: "s1")
        let done = try queue.add(text: "done", kind: .text, computerId: "a", created: t0, order: 0, share: "s2")
        try queue.complete("s2")
        queue.removeAbandoned(now: t0.addingTimeInterval(60), olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.folder.appendingPathComponent(left.id).path), "the extension may still copy")
        queue.removeAbandoned(now: t0.addingTimeInterval(7200), olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.folder.appendingPathComponent(left.id).path))
        XCTAssertEqual(queue.items().map(\.id), [done.id], "a complete share stays")
        queue.remove(done.id)
        queue.removeAbandoned(now: Date().addingTimeInterval(120), olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.shares.appendingPathComponent("s2").path), "the mark of a sent share goes")
    }

    func testAFolderDoesNotGoInTheQueue() throws {
        let queue = try makeQueue()
        let dir = try makeFile("x", "x").deletingLastPathComponent()
        XCTAssertThrowsError(try queue.add(file: dir, computerId: "a", created: t0, order: 0)) { error in
            XCTAssertEqual(error as? ShareQueueError, .folder(dir.lastPathComponent))
        }
        XCTAssertTrue(queue.items().isEmpty)
    }

    func testTheSizeCheckComesBeforeTheCopy() throws {
        var queue = try makeQueue()
        queue.byteLimit = 100
        let big = try makeFile("movie.mov", String(repeating: "x", count: 200))
        XCTAssertThrowsError(try queue.add(file: big, computerId: "a", created: t0, order: 0)) {
            XCTAssertEqual($0 as? ShareQueueError, .tooLarge("movie.mov"), "a file over the limit fails at once, also in an empty queue")
        }
        XCTAssertEqual(queue.bytes(), 0, "the file was not copied")
        try queue.add(file: try makeFile("a.txt", String(repeating: "x", count: 60)), computerId: "a", created: t0, order: 0)
        XCTAssertThrowsError(try queue.add(file: try makeFile("b.txt", String(repeating: "x", count: 60)), computerId: "a", created: t0, order: 1)) {
            XCTAssertEqual($0 as? ShareQueueError, .full)
        }
        XCTAssertEqual(queue.items().count, 1)
        XCTAssertTrue(ShareQueueError.tooLarge("movie.mov").localizedDescription.contains("1 GB"))
    }

    func testTextHasASizeLimit() throws {
        let queue = try makeQueue()
        let big = String(repeating: "x", count: ShareQueue.maxTextBytes + 1)
        XCTAssertThrowsError(try queue.add(text: big, kind: .text, computerId: "a", created: t0, order: 0)) {
            XCTAssertEqual($0 as? ShareQueueError, .textTooLarge)
        }
        XCTAssertNoThrow(try queue.add(text: String(repeating: "x", count: ShareQueue.maxTextBytes), kind: .text, computerId: "a", created: t0, order: 0))
    }

    func testTheQueueIsFullAtItsItemLimit() throws {
        let queue = try makeQueue()
        XCTAssertNoThrow(try queue.checkRoom(adding: ShareQueue.maxItems))
        try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        XCTAssertThrowsError(try queue.checkRoom(adding: ShareQueue.maxItems)) { XCTAssertEqual($0 as? ShareQueueError, .full) }
        let file = try makeFile("big.bin", String(repeating: "x", count: 10_000))
        try queue.add(file: file, computerId: "a", created: t0, order: 1)
        XCTAssertGreaterThanOrEqual(queue.bytes(), 10_000, "the size counts the copies")
    }

    func testItemsThatFailTooOftenOrWaitTooLongExpire() throws {
        let queue = try makeQueue()
        let a = try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        let b = try queue.add(text: "b", kind: .text, computerId: "a", created: t0, order: 1)
        for _ in 1..<ShareQueue.maxTries { try queue.markFailed(a.id, message: "Not connected") }
        XCTAssertEqual(queue.items().first?.failures, ShareQueue.maxTries - 1)
        XCTAssertTrue(ShareQueue.expired(queue.items(), now: t0).isEmpty)
        try queue.markFailed(a.id, message: "Not connected")
        XCTAssertEqual(ShareQueue.expired(queue.items(), now: t0).map(\.id), [a.id])
        XCTAssertEqual(Set(ShareQueue.expired(queue.items(), now: t0.addingTimeInterval(ShareQueue.maxAge + 1)).map(\.id)), [a.id, b.id])
    }

    func testATryThatALinkCutDoesNotCount() throws {
        let queue = try makeQueue()
        let a = try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        for _ in 0..<ShareQueue.maxTries { try queue.markFailed(a.id, message: "Not connected", counts: false) }
        let item = try XCTUnwrap(queue.items().first)
        XCTAssertEqual(item.failure, "Not connected", "the reason shows")
        XCTAssertNil(item.failures, "a cut try does not count")
        XCTAssertTrue(ShareQueue.expired(queue.items(), now: t0).isEmpty, "the item waits for the next link")
    }

    func testDroppedText() {
        let file = QueuedShare(id: "1", computerId: "a", kind: .file, name: "a.txt", created: t0, order: 0)
        XCTAssertEqual(QueuedShares.droppedText([file]), "1 file that you shared did not go out in 5 tries or 7 days, so Flux removed it.")
        XCTAssertEqual(QueuedShares.droppedText([file, file]), "2 files that you shared did not go out in 5 tries or 7 days, so Flux removed them.")
    }

    @MainActor
    func testTheOutboxKeepsFilesWithTheSameName() async throws {
        let a = try makeFile("notes.txt", "a")
        let b = try makeFile("notes.txt", "b")
        let copies = try await Outbox.copy([a, b])
        defer { Outbox.remove(copies) }
        XCTAssertEqual(copies.map(\.lastPathComponent), ["notes.txt", "notes.txt"], "each file keeps its name")
        XCTAssertEqual(try copies.map { try String(contentsOf: $0, encoding: .utf8) }, ["a", "b"])
    }

    @MainActor
    func testAFailedOutboxCopyRemovesItsCopies() async throws {
        let a = try makeFile("a.txt", "a")
        let missing = a.deletingLastPathComponent().appendingPathComponent("missing.txt")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: Outbox.folder.path)) ?? []
        do {
            _ = try await Outbox.copy([a, missing])
            XCTFail("a missing file fails the copy")
        } catch {}
        let after = (try? FileManager.default.contentsOfDirectory(atPath: Outbox.folder.path)) ?? []
        XCTAssertEqual(Set(after), Set(before), "the copies so far go")
    }

    @MainActor
    func testTheOutboxRemovesOnlyItsCopies() throws {
        let outside = try makeFile("keep.txt", "keep")
        let dir = try Outbox.newFolder()
        let copy = dir.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: copy)
        Outbox.remove([copy, outside])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a file outside the outbox stays")
        let (files, folders) = Outbox.splitFolders([outside, outside.deletingLastPathComponent()])
        XCTAssertEqual(files, [outside])
        XCTAssertEqual(folders, [outside.deletingLastPathComponent()])
    }

    func testItemsOfForgottenComputersGo() throws {
        let queue = try makeQueue()
        try queue.add(text: "a", kind: .text, computerId: "a", created: t0, order: 0)
        try queue.add(text: "b", kind: .text, computerId: "b", created: t0, order: 1)
        queue.removeItems(notFor: ["a"])
        XCTAssertEqual(queue.items().map(\.computerId), ["a"], "an unpaired computer never takes its items")
    }

    func testPlanSendsConnectedComputersInOrder() {
        func item(_ id: String, _ computer: String, _ kind: QueuedShare.Kind) -> QueuedShare {
            QueuedShare(id: id, computerId: computer, kind: kind, name: kind == .file ? id : nil, text: kind == .file ? nil : id,
                        created: t0, order: 0, failure: nil)
        }
        let items = [
            item("1", "a", .file), item("2", "a", .file), item("3", "b", .file), item("4", "a", .file),
            item("5", "a", .text), item("6", "a", .file), item("7", "a", .link),
        ]
        let steps = ShareQueue.plan(items, connected: ["a"])
        XCTAssertEqual(steps, [
            .files("a", ["1", "2", "4"]),
            .text("a", "5"),
            .files("a", ["6"]),
            .text("a", "7"),
        ], "files of 1 computer next to each other go in 1 batch, and a computer that is not connected waits")
        XCTAssertEqual(ShareQueue.plan(items, connected: []), [])
        XCTAssertEqual(ShareQueue.plan(items, connected: ["b"]), [.files("b", ["3"])])
    }

    func testSummary() {
        XCTAssertEqual(ShareSummary.text(ShareSummary(photos: 1)), "1 photo")
        XCTAssertEqual(ShareSummary.text(ShareSummary(photos: 2, videos: 1)), "2 photos and 1 video")
        XCTAssertEqual(ShareSummary.text(ShareSummary(photos: 1, videos: 2, files: 3)), "1 photo, 2 videos, and 3 files")
        XCTAssertEqual(ShareSummary.text(ShareSummary(links: 1)), "1 link")
        XCTAssertEqual(ShareSummary.text(ShareSummary(texts: 2)), "2 texts")
        XCTAssertEqual(ShareSummary.text(ShareSummary(files: 1, texts: 1)), "1 file and 1 text")
        XCTAssertEqual(ShareSummary.text(ShareSummary()), "Nothing to send")
        XCTAssertEqual(ShareSummary().count, 0)
        XCTAssertEqual(ShareSummary(photos: 1, links: 2).count, 3)
    }
}

final class SharedComputersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testLastOnline() {
        let first = SharedComputers.next(previous: [], current: [
            .init(id: "a", name: "omarchy", type: "laptop", online: true),
            .init(id: "b", name: "desk", type: "desktop", online: false),
        ], now: t0)
        XCTAssertEqual(first.map(\.lastOnline), [t0, nil], "a computer that was never seen online has no time")

        let later = t0.addingTimeInterval(60)
        let second = SharedComputers.next(previous: first, current: [
            .init(id: "a", name: "omarchy", type: "laptop", online: false),
            .init(id: "b", name: "desk", type: "desktop", online: false),
        ], now: later)
        XCTAssertEqual(second.map(\.lastOnline), [later, nil], "a computer that goes offline was online until now")

        let third = SharedComputers.next(previous: second, current: [
            .init(id: "a", name: "omarchy 2", type: "laptop", online: false),
        ], now: later.addingTimeInterval(60))
        XCTAssertEqual(third.map(\.lastOnline), [later], "an offline computer keeps its time")
        XCTAssertEqual(third.map(\.name), ["omarchy 2"], "names follow the app, and unpaired computers go")
    }

    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let computers = [SharedComputer(id: "a", name: "omarchy", type: "laptop", online: true, lastOnline: t0)]
        XCTAssertEqual(SharedComputers.read(root: dir), [], "no snapshot before the app wrote one")
        XCTAssertTrue(try SharedComputers.write(computers, root: dir), "a new list is written")
        XCTAssertEqual(SharedComputers.read(root: dir), computers)
        XCTAssertFalse(try SharedComputers.write(computers, root: dir), "the same list is not written again")
    }

    func testDefaultComputer() {
        let a = SharedComputer(id: "a", name: "omarchy", type: "laptop", online: false, lastOnline: nil)
        let b = SharedComputer(id: "b", name: "desk", type: "desktop", online: false, lastOnline: nil)
        XCTAssertEqual(SharedComputers.defaultChoice([a], lastUsed: nil), "a", "the only computer")
        XCTAssertEqual(SharedComputers.defaultChoice([a, b], lastUsed: "b"), "b", "the last used computer")
        XCTAssertNil(SharedComputers.defaultChoice([a, b], lastUsed: nil), "the user picks 1 of several")
        XCTAssertNil(SharedComputers.defaultChoice([a, b], lastUsed: "gone"), "a computer that is no longer paired")
        XCTAssertNil(SharedComputers.defaultChoice([], lastUsed: "a"))
    }
}

final class QueuedSharesTests: XCTestCase {
    func testSentText() {
        func item(_ kind: QueuedShare.Kind) -> QueuedShare {
            QueuedShare(id: UUID().uuidString, computerId: "a", kind: kind, name: nil, text: nil, created: Date(), order: 0)
        }
        XCTAssertEqual(QueuedShares.sentText([item(.file)]), "1 file that you shared went out.")
        XCTAssertEqual(QueuedShares.sentText([item(.file), item(.file), item(.link)]), "2 files and 1 link that you shared went out.")
    }

    func testTileSubtitle() {
        XCTAssertEqual(ShareTile.subtitle(running: 0, waiting: 0), "Files, photos, text, and links")
        XCTAssertEqual(ShareTile.subtitle(running: 0, waiting: 2), "2 waiting to send")
        XCTAssertEqual(ShareTile.subtitle(running: 1, waiting: 2), "1 transferring", "a running transfer shows first")
    }
}

final class SharedItemTests: XCTestCase {
    private func text(_ s: String) -> NSItemProvider { NSItemProvider(object: s as NSString) }
    private func link(_ s: String) -> NSItemProvider { NSItemProvider(object: URL(string: s)! as NSURL) }
    private func data(_ type: UTType, name: String? = nil) -> NSItemProvider {
        let p = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: type.identifier)
        p.suggestedName = name
        return p
    }

    func testKinds() throws {
        XCTAssertEqual(try XCTUnwrap(SharedItem(data(.jpeg))).kind, .photo)
        XCTAssertEqual(try XCTUnwrap(SharedItem(data(.quickTimeMovie))).kind, .video)
        XCTAssertEqual(try XCTUnwrap(SharedItem(data(.pdf))).kind, .file)
        XCTAssertEqual(try XCTUnwrap(SharedItem(link("https://example.com"))).kind, .link)
        XCTAssertEqual(try XCTUnwrap(SharedItem(text("hello"))).kind, .text)
    }

    func testATextFileIsAFile() throws {
        let file = try XCTUnwrap(SharedItem(data(.plainText, name: "notes.txt")))
        XCTAssertEqual(file.kind, .file, "a text file from Files goes as a file, not as clipboard text")
        XCTAssertEqual(file.fileName(loaded: URL(fileURLWithPath: "/tmp/x/abc.txt")), "notes.txt")
        XCTAssertEqual(try XCTUnwrap(SharedItem(data(.plainText))).kind, .text, "text without a name stays text")
        XCTAssertEqual(try XCTUnwrap(SharedItem(data(.plainText, name: "Swift 5.9 released"))).kind, .text,
                       "a title with a dot is no file name")
        XCTAssertTrue(SharedItem.isFileName("data.json"))
        XCTAssertFalse(SharedItem.isFileName("Example Domain"))
        XCTAssertFalse(SharedItem.isFileName(nil))
    }

    func testFilesWinOverLinksAndLinksOverText() {
        let photo = data(.jpeg), page = link("https://example.com"), title = text("Example")
        XCTAssertEqual(SharedItem.sendable([page, photo, title].compactMap(SharedItem.init)).map(\.kind), [.photo])
        XCTAssertEqual(SharedItem.sendable([title, page].compactMap(SharedItem.init)).map(\.kind), [.link], "Safari adds the title as text")
        XCTAssertEqual(SharedItem.sendable([title].compactMap(SharedItem.init)).map(\.kind), [.text])
        let named = data(.plainText, name: "index.html")
        XCTAssertEqual(SharedItem.sendable([page, named].compactMap(SharedItem.init)).map(\.kind), [.link],
                       "a page title with a file name does not replace the link")
        XCTAssertEqual(SharedItem.sendable([data(.plainText, name: "notes.txt")].compactMap(SharedItem.init)).map(\.kind), [.file])
        XCTAssertEqual(SharedItem.summary(SharedItem.sendable([data(.png), data(.mpeg4Movie), data(.pdf)].compactMap(SharedItem.init))),
                       ShareSummary(photos: 1, videos: 1, files: 1))
    }

    func testFileNames() throws {
        let photo = try XCTUnwrap(SharedItem(data(.jpeg, name: "IMG_0001")))
        XCTAssertEqual(photo.fileName(loaded: URL(fileURLWithPath: "/tmp/x/IMG_0001.jpeg")), "IMG_0001.jpeg")
        XCTAssertEqual(photo.fileName(loaded: URL(fileURLWithPath: "/tmp/x/abc")), "IMG_0001.jpeg", "the type gives the extension")
        let named = try XCTUnwrap(SharedItem(data(.pdf, name: "Report.pdf")))
        XCTAssertEqual(named.fileName(loaded: URL(fileURLWithPath: "/tmp/x/tmp123.pdf")), "Report.pdf")
        let unnamed = try XCTUnwrap(SharedItem(data(.pdf)))
        XCTAssertEqual(unnamed.fileName(loaded: URL(fileURLWithPath: "/tmp/x/tmp123.pdf")), "tmp123.pdf")
    }

    func testQueueAFileAndText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ShareQueue(root: root)
        let photo = try XCTUnwrap(SharedItem(data(.jpeg, name: "IMG_0001")))
        let item = try await photo.queueFile(in: queue, computerId: "a", created: Date(), order: 0)
        XCTAssertEqual(item.name, "IMG_0001.jpeg")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(queue.file(of: item))), Data([1, 2, 3]))
        let linkText = try await XCTUnwrap(SharedItem(link("https://example.com/a"))).loadText()
        XCTAssertEqual(linkText, "https://example.com/a")
        let plainText = try await XCTUnwrap(SharedItem(text("hello"))).loadText()
        XCTAssertEqual(plainText, "hello")
        let notes = try XCTUnwrap(SharedItem(data(.plainText, name: "notes.txt")))
        let queued = try await notes.queueFile(in: queue, computerId: "a", created: Date(), order: 1)
        XCTAssertEqual(queued.kind, .file)
        XCTAssertEqual(queued.name, "notes.txt", "the computer gets the text file with its name")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(queue.file(of: queued))), Data([1, 2, 3]))
    }

    func testALargeTextStopsBeforeItsDecode() async throws {
        let big = try XCTUnwrap(SharedItem(text(String(repeating: "x", count: ShareQueue.maxTextBytes + 1))))
        do {
            _ = try await big.loadText()
            XCTFail("a text larger than 1 MB does not load")
        } catch {
            XCTAssertEqual(error as? ShareQueueError, .textTooLarge)
        }
        let preview = try await big.loadPreview()
        XCTAssertEqual(preview.utf8.count, SharedItem.previewBytes, "the preview decodes only the start")
        let fits = try await XCTUnwrap(SharedItem(text(String(repeating: "x", count: ShareQueue.maxTextBytes)))).loadText()
        XCTAssertEqual(fits.utf8.count, ShareQueue.maxTextBytes)
    }

    func testTheStartOfATextKeepsWholeCharacters() {
        let text = Data("aé".utf8)
        XCTAssertEqual(SharedItem.decodeStart(text, encoding: .utf8, maxBytes: 2), "a", "a cut in a character drops the character")
        XCTAssertEqual(SharedItem.decodeStart(text, encoding: .utf8, maxBytes: 3), "aé")
        let wide = Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00, 0x63, 0x00])
        XCTAssertEqual(SharedItem.decodeStart(wide, encoding: .utf16(bigEndian: true), maxBytes: 7), "ab", "the byte order mark wins")
        XCTAssertEqual(SharedItem.decode(Data([0x00, 0x61]), encoding: .utf16(bigEndian: true)), "a")
        XCTAssertEqual(SharedItem.decode(Data([0x61, 0x00]), encoding: .utf16(bigEndian: false)), "a")
    }
}
