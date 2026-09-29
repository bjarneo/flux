import XCTest
@testable import FluxCore
@testable import FluxProto

/// `FeatureRouter` behavior: pairing + capability gates, every M2 packet,
/// clipboard loop-prevention, and the ring toggle. Mirrors Android
/// `core/Plugins.kt` and Go `internal/core/handlers.go` routing rules.
final class PluginRouterTests: XCTestCase {
    private func ctx(
        paired: Bool = true,
        incoming: [String] = incomingCapabilities,
        clipboardSync: Bool = true,
        lastLocalClipMs: Int64 = 0,
        nowMs: Int64 = 1_790_000_000_000
    ) -> FeatureContext {
        FeatureContext(
            peerId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", peerName: "omarchy-xps",
            paired: paired, incoming: incoming, clipboardSync: clipboardSync,
            lastLocalClipMs: lastLocalClipMs, nowMs: nowMs
        )
    }

    private func route(_ p: Packet, ctx: FeatureContext? = nil) -> (FeatureRouter, [FeatureAction]) {
        var router = FeatureRouter()
        let actions = router.route(p, ctx: ctx ?? self.ctx())
        return (router, actions)
    }

    private func events(_ actions: [FeatureAction]) -> [FeatureEvent] {
        actions.compactMap {
            if case .event(let e) = $0 { return e }
            return nil
        }
    }

    // MARK: - Gates

    func testUnpairedPacketsDrop() {
        let (_, actions) = route(PingMessage.packet(message: "hi"), ctx: ctx(paired: false))
        XCTAssertEqual([.event(.ignored(type: PacketType.ping, reason: .unpaired))], actions)
    }

    func testUnadvertisedPacketsDrop() {
        let (_, actions) = route(PingMessage.packet(message: "hi"), ctx: ctx(incoming: [PacketType.battery]))
        XCTAssertEqual([.event(.ignored(type: PacketType.ping, reason: .unadvertised))], actions)
    }

    func testUnknownTypeLogs() {
        let (_, actions) = route(Packet(type: "kdeconnect.sms.messages"))
        // sms.messages is outside the iOS incoming set → unadvertised.
        XCTAssertEqual([.event(.ignored(type: "kdeconnect.sms.messages", reason: .unadvertised))], actions)
        let (_, actions2) = route(Packet(type: PacketType.mpris))
        XCTAssertEqual([.event(.ignored(type: PacketType.mpris, reason: .unhandled))], actions2)
    }

    // MARK: - Ping / battery

    func testPing() {
        let (_, actions) = route(PingMessage.packet(message: "hello"))
        XCTAssertEqual([.event(.ping(message: "hello"))], actions)
        let (_, def) = route(Packet(type: PacketType.ping))
        XCTAssertEqual([.event(.ping(message: "Ping"))], def)
    }

    func testBattery() {
        let (_, actions) = route(BatteryState(level: 64, charging: false).packet())
        XCTAssertEqual([.event(.battery(BatteryState(level: 64, charging: false, thresholdEvent: 0)))], actions)
    }

    func testBatteryRequest() {
        let (_, actions) = route(Packet(type: PacketType.batteryRequest))
        XCTAssertEqual([.event(.batteryRequested)], actions)
    }

    // MARK: - Clipboard

    func testClipboardApplied() {
        let (router, actions) = route(ClipboardMessage(content: "hi").packet())
        XCTAssertEqual([.event(.clipboard("hi"))], actions)
        XCTAssertEqual("hi", router.lastRemoteClip)
    }

    func testClipboardConnectStaleStored() {
        let (router, actions) = route(
            ClipboardMessage(content: "old", timestampMs: 50, isConnect: true).packet(),
            ctx: ctx(lastLocalClipMs: 100)
        )
        XCTAssertEqual([.event(.clipboardStale("old"))], actions)
        XCTAssertNil(router.lastRemoteClip)
        // Newer connect applies.
        let (router2, actions2) = route(
            ClipboardMessage(content: "new", timestampMs: 150, isConnect: true).packet(),
            ctx: ctx(lastLocalClipMs: 100)
        )
        XCTAssertEqual([.event(.clipboard("new"))], actions2)
        XCTAssertEqual("new", router2.lastRemoteClip)
    }

    func testClipboardSyncOff() {
        let (_, actions) = route(ClipboardMessage(content: "hi").packet(), ctx: ctx(clipboardSync: false))
        XCTAssertEqual([.event(.ignored(type: PacketType.clipboard, reason: .syncDisabled))], actions)
    }

    func testClipboardEmptyIgnored() {
        let (_, actions) = route(Packet(type: PacketType.clipboard))
        XCTAssertEqual([.event(.ignored(type: PacketType.clipboard, reason: .unhandled))], actions)
    }

    // MARK: - Share

    func testShareTextURL() {
        let (_, text) = route(ShareMessage.textPacket("hi"))
        XCTAssertEqual([.event(.shareText("hi", scan: false))], text)
        let (_, url) = route(ShareMessage.urlPacket("https://example.com"))
        XCTAssertEqual([.event(.shareURL("https://example.com"))], url)
    }

    func testShareFileQueuedForM3() {
        let p = Packet(type: PacketType.share, body: ["filename": .string("a.jpg")], payloadSize: 7, payloadPort: 1740)
        let (_, actions) = route(p)
        guard case .event(.shareFile(let f)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one shareFile event, got \(actions)")
        }
        XCTAssertEqual("a.jpg", f.filename)
        XCTAssertEqual(7, f.payloadSize)
        XCTAssertEqual(1740, f.payloadPort)
    }

    func testShareUpdate() {
        let (_, actions) = route(ShareMessage.updatePacket(numberOfFiles: 2, totalPayloadSize: 20))
        XCTAssertEqual([.event(.shareUpdate(numberOfFiles: 2, totalPayloadSize: 20))], actions)
        let (_, none) = route(Packet(type: PacketType.share))
        XCTAssertEqual([.event(.ignored(type: PacketType.share, reason: .unhandled))], none)
    }

    // MARK: - Ring

    func testRingToggle() {
        var router = FeatureRouter()
        let c = ctx()
        let on = router.route(FindMyPhone.packet(), ctx: c)
        XCTAssertEqual([.event(.ringToggled(ringing: true, from: "omarchy-xps"))], on)
        XCTAssertTrue(router.ring.ringing)
        // A second request while ringing stops it.
        let off = router.route(FindMyPhone.packet(), ctx: c)
        XCTAssertEqual([.event(.ringToggled(ringing: false, from: "omarchy-xps"))], off)
        XCTAssertFalse(router.ring.ringing)
    }

    func testRingExpiry() {
        var router = FeatureRouter()
        var c = ctx(nowMs: 1_000_000)
        _ = router.route(FindMyPhone.packet(), ctx: c)
        c.nowMs = 1_000_000 + RingState.maxRingMs - 1
        XCTAssertNil(router.expireRing(nowMs: c.nowMs))
        c.nowMs = 1_000_000 + RingState.maxRingMs
        XCTAssertEqual(.ringToggled(ringing: false, from: "omarchy-xps"), router.expireRing(nowMs: c.nowMs))
        XCTAssertFalse(router.ring.ringing)
    }

    func testRingStateUnit() {
        var ring = RingState()
        XCTAssertTrue(ring.toggle(from: "pc", nowMs: 0))
        XCTAssertEqual(120_000, ring.stopAtMs)
        XCTAssertFalse(ring.toggle(from: "pc", nowMs: 1))
        XCTAssertNil(ring.ringingFrom)
        XCTAssertTrue(ring.toggle(from: "pc", nowMs: 0))
        XCTAssertNil(ring.expire(nowMs: 119_999))
        XCTAssertEqual("pc", ring.expire(nowMs: 120_000))
    }

    // MARK: - Notifications

    func testDesktopNotificationRenders() {
        let p = NotificationPackets.incoming(
            id: "flux-1", appName: "omarchy", title: "Build done", text: "OK", timeMs: 5)
        let (_, actions) = route(p)
        guard case .event(.notification(let n)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one notification event, got \(actions)")
        }
        XCTAssertEqual("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:flux-1", n.key)
        XCTAssertEqual("Build done", n.title)
        XCTAssertFalse(n.cancel)
    }

    func testDesktopNotificationCancel() {
        let p = NotificationPackets.incoming(
            id: "flux-1", appName: "omarchy", title: "", text: "", timeMs: 5)
        // Empty render packet is invalid (Go + Android drop it too).
        let (_, invalid) = route(p)
        XCTAssertEqual([.event(.ignored(type: PacketType.notification, reason: .unhandled))], invalid)

        let cancel = Packet.of(PacketType.notification, ("id", "flux-1"), ("isCancel", true))
        let (_, cancelled) = route(cancel)
        XCTAssertEqual(
            [.event(.notificationCancelled(key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:flux-1"))],
            cancelled)
    }

    func testNotificationRequestPaths() {
        let (_, all) = route(NotificationPackets.requestAll())
        XCTAssertEqual([.event(.notificationSyncRequested)], all)
        let (_, cancel) = route(NotificationPackets.cancelRequest(id: "k9"))
        XCTAssertEqual([.event(.notificationCancel(id: "k9"))], cancel)
        let (_, unknown) = route(Packet(type: PacketType.notificationRequest))
        XCTAssertEqual([.event(.ignored(type: PacketType.notificationRequest, reason: .unhandled))], unknown)
    }

    func testNotificationReplyActionDropped() {
        let (_, reply) = route(NotificationPackets.replyPacket(replyId: "r", message: "ok"))
        XCTAssertEqual([.event(.notificationReplyDropped(replyId: "r", message: "ok"))], reply)
        let (_, action) = route(NotificationPackets.actionPacket(key: "k", action: "Open"))
        XCTAssertEqual([.event(.notificationActionDropped(key: "k", action: "Open"))], action)
        // Malformed reply/action packets are refused, not crashed on.
        let (_, badReply) = route(Packet(type: PacketType.notificationReply))
        XCTAssertEqual([.event(.ignored(type: PacketType.notificationReply, reason: .unhandled))], badReply)
    }
}
