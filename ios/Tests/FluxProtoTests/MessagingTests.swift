import XCTest
@testable import FluxProto

/// M2 messaging packet vectors. Field shapes mirror
/// `internal/core/{handlers,clipboard,share,telephony}.go` and Android
/// `core/{Plugins,Share,ComputerNotification}.kt` — byte-compatible bodies,
/// asserted through serialize/parse round-trips.
final class MessagingTests: XCTestCase {
    // MARK: - Ping

    func testPingRoundTrip() throws {
        let q = try XCTUnwrap(Packet.parse(try PingMessage.packet(message: "hello").serialize()))
        XCTAssertEqual("hello", PingMessage.message(q))
        let def = try XCTUnwrap(Packet.parse(try PingMessage.packet(message: "").serialize()))
        XCTAssertEqual("Ping", PingMessage.message(def))
        XCTAssertNil(PingMessage.message(Packet(type: PacketType.battery)))
    }

    // MARK: - Battery

    func testBatteryThreshold() {
        XCTAssertEqual(1, BatteryState(level: 15, charging: false).thresholdEvent)
        XCTAssertEqual(0, BatteryState(level: 15, charging: true).thresholdEvent)
        XCTAssertEqual(0, BatteryState(level: 16, charging: false).thresholdEvent)
        XCTAssertEqual(0, BatteryState(level: nil, charging: false).thresholdEvent)
    }

    func testBatteryRoundTrip() throws {
        let p = BatteryState(level: 64, charging: false).packet()
        XCTAssertEqual(PacketType.battery, p.type)
        let back = try XCTUnwrap(BatteryState.parse(try XCTUnwrap(Packet.parse(try p.serialize()))))
        XCTAssertEqual(BatteryState(level: 64, charging: false, thresholdEvent: 0), back)
        // Negative charge = no battery (Go nil, Android dropped).
        let none = try XCTUnwrap(BatteryState.parse(Packet.of(PacketType.battery, ("currentCharge", -1), ("isCharging", false))))
        XCTAssertNil(none.level)
        XCTAssertNil(BatteryState.parse(Packet(type: PacketType.ping)))
        XCTAssertNil(BatteryState.parse(Packet(type: PacketType.batteryRequest)))
    }

    func testBatteryChangeGate() {
        XCTAssertTrue(BatteryState(level: 50, charging: false).shouldReport(previous: nil))
        XCTAssertFalse(BatteryState(level: 50, charging: false).shouldReport(previous: BatteryState(level: 50, charging: false)))
        XCTAssertTrue(BatteryState(level: 51, charging: false).shouldReport(previous: BatteryState(level: 50, charging: false)))
        XCTAssertTrue(BatteryState(level: 50, charging: true).shouldReport(previous: BatteryState(level: 50, charging: false)))
    }

    // MARK: - Clipboard

    func testClipboardRoundTrip() throws {
        let c = ClipboardMessage(content: "hi")
        XCTAssertEqual(PacketType.clipboard, c.packet().type)
        let back = try XCTUnwrap(ClipboardMessage.parse(try XCTUnwrap(Packet.parse(try c.packet().serialize()))))
        XCTAssertEqual(c, back)

        let conn = ClipboardMessage(content: "hi", timestampMs: 123, isConnect: true)
        let rc = try XCTUnwrap(Packet.parse(try conn.packet().serialize()))
        XCTAssertEqual(PacketType.clipboardConnect, rc.type)
        XCTAssertEqual(conn, ClipboardMessage.parse(rc))
    }

    func testClipboardDropsEmpty() {
        XCTAssertNil(ClipboardMessage.parse(Packet(type: PacketType.clipboard)))
        XCTAssertNil(ClipboardMessage.parse(Packet.of(PacketType.clipboard, ("content", ""))))
        XCTAssertNil(ClipboardMessage.parse(Packet(type: PacketType.ping)))
    }

    func testClipboardStaleRule() {
        // Plain clipboard is never stale.
        XCTAssertFalse(ClipboardMessage(content: "x").isStale(againstLocalMs: 999))
        // Connect: stale when older-or-equal to the last local change.
        XCTAssertTrue(ClipboardMessage(content: "x", timestampMs: 100, isConnect: true).isStale(againstLocalMs: 100))
        XCTAssertTrue(ClipboardMessage(content: "x", timestampMs: 99, isConnect: true).isStale(againstLocalMs: 100))
        XCTAssertFalse(ClipboardMessage(content: "x", timestampMs: 101, isConnect: true).isStale(againstLocalMs: 100))
        // Missing/zero timestamp is not stale.
        XCTAssertFalse(ClipboardMessage(content: "x", isConnect: true).isStale(againstLocalMs: 100))
    }

    // MARK: - Share

    func testShareTextURLPrecedence() throws {
        let text = try XCTUnwrap(ShareMessage.parse(try XCTUnwrap(Packet.parse(try ShareMessage.textPacket("hi").serialize()))))
        XCTAssertEqual(.text("hi", scan: false), text)
        let scan = try XCTUnwrap(ShareMessage.parse(ShareMessage.textPacket("hi", scan: true)))
        XCTAssertEqual(.text("hi", scan: true), scan)
        let url = try XCTUnwrap(ShareMessage.parse(ShareMessage.urlPacket("https://example.com")))
        XCTAssertEqual(.url("https://example.com"), url)
        // URL wins over text (Go checks URL first).
        let both = try XCTUnwrap(ShareMessage.parse(Packet.of(PacketType.share, ("text", "t"), ("url", "u"))))
        XCTAssertEqual(.url("u"), both)
    }

    func testShareFileParse() throws {
        let p = Packet(type: PacketType.share, body: ["filename": .string("../evil.jpg")], payloadSize: 10, payloadPort: 1740)
        guard case .file(let f) = ShareMessage.parse(p) else { return XCTFail("expected file") }
        XCTAssertEqual("evil.jpg", f.filename)
        XCTAssertEqual(10, f.payloadSize)
        XCTAssertEqual(1740, f.payloadPort)
        XCTAssertNil(f.payloadTunnel)
        // Tunnel variant (Flux reverse direction).
        let t = Packet(type: PacketType.share, body: ["filename": .string("a.bin")], payloadSize: 5, payloadTunnel: "tok-1")
        guard case .file(let tf) = ShareMessage.parse(t) else { return XCTFail("expected file") }
        XCTAssertEqual("tok-1", tf.payloadTunnel)
        XCTAssertEqual(0, tf.payloadPort)
        // No text/URL/payload = nothing to do.
        XCTAssertEqual(.none, ShareMessage.parse(Packet(type: PacketType.share)))
        XCTAssertNil(ShareMessage.parse(Packet(type: PacketType.ping)))
    }

    func testShareUpdateRoundTrip() throws {
        let u = try XCTUnwrap(ShareMessage.parseUpdate(try XCTUnwrap(Packet.parse(try ShareMessage.updatePacket(numberOfFiles: 3, totalPayloadSize: 99).serialize()))))
        XCTAssertEqual(3, u.numberOfFiles)
        XCTAssertEqual(99, u.totalPayloadSize)
        XCTAssertNil(ShareMessage.parseUpdate(Packet(type: PacketType.share)))
    }

    func testSanitize() {
        XCTAssertEqual("evil.jpg", ShareMessage.sanitize("../evil.jpg"))
        XCTAssertEqual("a.jpg", ShareMessage.sanitize("C:\\pics\\a.jpg"))
        XCTAssertEqual("a.jpg", ShareMessage.sanitize("/x/y/a.jpg"))
        XCTAssertEqual("ab", ShareMessage.sanitize("a\u{0B}b"))
        XCTAssertEqual("file", ShareMessage.sanitize(""))
        XCTAssertEqual("file", ShareMessage.sanitize(".."))
        XCTAssertEqual("file", ShareMessage.sanitize("."))
        XCTAssertEqual("file", ShareMessage.sanitize("a/"))
    }

    // MARK: - Connectivity

    func testConnectivityShape() throws {
        let line = try ConnectivityReport.packet(signals: [(key: "wifi", networkType: "wifi", signalStrength: 4)]).serialize()
        let q = try XCTUnwrap(Packet.parse(line))
        XCTAssertEqual(PacketType.connectivity, q.type)
        let signals = try XCTUnwrap(q.obj("signalStrengths"))
        guard case .object(let wifi) = signals["wifi"] else { return XCTFail("wifi missing") }
        XCTAssertEqual("wifi", wifi["networkType"]?.string)
        XCTAssertEqual(4, wifi["signalStrength"]?.int)
    }

    // MARK: - Find my phone

    func testFindMyPhone() throws {
        let line = try FindMyPhone.packet().serialize()
        let q = try XCTUnwrap(Packet.parse(line))
        XCTAssertTrue(FindMyPhone.isRingRequest(q))
        XCTAssertFalse(FindMyPhone.isRingRequest(Packet(type: PacketType.ping)))
    }

    // MARK: - Notifications

    func testNotificationBuilders() throws {
        let out = try XCTUnwrap(Packet.parse(try NotificationPackets.outgoing(
            id: "k1", appName: "Mail", title: "Hi", text: "Body", timeMs: 1_790_000_000_123,
            replyId: "r1", actions: ["Archive"]).serialize()))
        XCTAssertEqual(PacketType.notification, out.type)
        XCTAssertEqual("k1", out.string("id"))
        XCTAssertEqual("Hi: Body", out.string("ticker"))
        XCTAssertEqual("1790000000123", out.string("time"))
        XCTAssertEqual("r1", out.string("requestReplyId"))
        XCTAssertEqual(["Archive"], out.strings("actions"))

        let inc = try XCTUnwrap(Packet.parse(try NotificationPackets.incoming(
            id: "flux-abc", appName: "omarchy", title: "T", text: "B", timeMs: 7).serialize()))
        XCTAssertEqual("T: B", inc.string("ticker"))

        XCTAssertEqual(.requestAll, NotificationPackets.parseRequest(NotificationPackets.requestAll()))
        XCTAssertEqual(.cancel(id: "k1"), NotificationPackets.parseRequest(NotificationPackets.cancelRequest(id: "k1")))
        XCTAssertEqual(.unknown, NotificationPackets.parseRequest(Packet(type: PacketType.notificationRequest)))
        XCTAssertNil(NotificationPackets.parseRequest(Packet(type: PacketType.ping)))

        let reply = NotificationPackets.replyPacket(replyId: "r", message: "ok")
        XCTAssertEqual("r", reply.string("requestReplyId"))
        let action = NotificationPackets.actionPacket(key: "k", action: "Open")
        XCTAssertEqual("Open", action.string("action"))
    }

    func testComputerNotification() throws {
        let now: Int64 = 9_999_000
        func render(_ body: [String: JSONValue]) -> ComputerNotification? {
            ComputerNotification.from(Packet(type: PacketType.notification, body: body), deviceId: "dev", computer: "omarchy-xps", nowMs: now)
        }
        // Same app as computer: sub shows the computer only.
        let same = try XCTUnwrap(render(["id": .string("1"), "appName": .string("omarchy-xps"), "title": .string("T"), "text": .string("B"), "time": .string("1790000000123")]))
        XCTAssertEqual("dev:1", same.key)
        XCTAssertEqual("omarchy-xps", same.subText)
        XCTAssertEqual("T", same.title)
        XCTAssertEqual("B", same.text)
        XCTAssertEqual(1_790_000_000_123, same.timeMs)
        XCTAssertTrue(same.clearable)
        XCTAssertFalse(same.cancel)
        // Other app: "app · computer".
        let other = try XCTUnwrap(render(["id": .string("2"), "appName": .string("Firefox"), "title": .string("T"), "text": .string("B")]))
        XCTAssertEqual("Firefox · omarchy-xps", other.subText)
        XCTAssertEqual(now, other.timeMs) // missing time falls back to now
        // Ticker fallback when title is empty; title falls back to text.
        let tick = try XCTUnwrap(render(["id": .string("3"), "ticker": .string("Tick"), "text": .string("")]))
        XCTAssertEqual("Tick", tick.title)
        XCTAssertEqual("", tick.text)
        // Cancel passes with no text.
        let cancel = try XCTUnwrap(render(["id": .string("4"), "isCancel": .bool(true)]))
        XCTAssertTrue(cancel.cancel)
        XCTAssertEqual("dev:4", cancel.key)
        // Flexible booleans (Go flexString): "1"/"true" cancel, explicit false stays clearable.
        XCTAssertTrue(render(["id": .string("5"), "isCancel": .string("1")])?.cancel ?? false)
        XCTAssertFalse(render(["id": .string("6"), "title": .string("T"), "isClearable": .bool(false)])?.clearable ?? true)
        // Rejects: no ID, no text at all, wrong type.
        XCTAssertNil(render(["title": .string("T")]))
        XCTAssertNil(render(["id": .string("7")]))
        XCTAssertNil(ComputerNotification.from(Packet(type: PacketType.ping), deviceId: "dev", computer: "c", nowMs: now))
    }

    // MARK: - Caps (M2 acceptance: MaxPacketSize + id tolerance on M2 bodies)

    func testLargeClipboardRoundTrip() throws {
        let big = String(repeating: "a", count: 1 << 20)
        let q = try XCTUnwrap(Packet.parse(try ClipboardMessage(content: big).packet().serialize()))
        XCTAssertEqual(big, ClipboardMessage.parse(q)?.content)
        // Over the 16 MiB cap the line is refused, like Go `readLine`.
        XCTAssertNil(Packet.parse(Data(repeating: 0x41, count: FluxProto.maxPacketSize + 16)))
    }
}
