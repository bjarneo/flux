import Foundation
import FluxProto
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if os(iOS)
import CallKit
#endif
#if canImport(Intents)
import Intents
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// iOS system bridges for the M2 primitives. The packet layer
/// (`FluxProto.Messaging`, `FluxCore.FeatureRouter`) is platform-free and
/// unit-tested; these bridges touch `UIDevice` / `UIPasteboard` /
/// `UNUserNotificationCenter`, so they only act on device (the harness
/// logs the same events instead).
///
/// Limits, by design (see `docs/ios-plan.md` §§4.2–4.4):
/// - Clipboard is foreground + manual-push only (`auto_clipboard` off).
/// - Desktop→phone notifications render display-only (the desktop never
///   accepts replies to its own notifications).
/// - Find-my-phone cannot override the silent switch; loudest allowed +
///   vibration + flash.

// MARK: - Battery

/// Reads the phone battery. `UIDevice.batteryMonitoringEnabled` is turned
/// on once; callers throttle with `BatteryState.shouldReport`.
public enum BatteryBridge {
    /// Returns nil where there is no battery API (macOS harness, simulator
    /// without monitoring). Main-actor: `UIDevice` is main-isolated on iOS
    /// (first caught by the Xcode simulator build, D7).
    @MainActor
    public static func read() -> BatteryState? {
#if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else { return nil }
        let level = Int((raw * 100).rounded())
        let charging: Bool = {
            switch UIDevice.current.batteryState {
            case .charging, .full: return true
            default: return false
            }
        }()
        return BatteryState(level: level, charging: charging)
#else
        return nil
#endif
    }

    /// Refreshes `cache` from `UIDevice` (main thread). The app calls this
    /// on launch + foreground + battery-change notifications; the link's
    /// provider reads the cache without touching MainActor state.
    @MainActor
    public static func refresh(_ cache: BatteryCache) {
        cache.update(read())
    }
}

/// Main-thread-fed battery cache. The link answers `battery.request`
/// through a `@Sendable` provider that must never touch MainActor-isolated
/// `UIDevice` (same queue-trap class as the notification fix): the app
/// refreshes this on the main thread, the provider only reads the lock.
public final class BatteryCache: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var state: BatteryState?

    public init() {}

    public func update(_ state: BatteryState?) {
        lock.withLock { self.state = state }
    }

    public func read() -> BatteryState? {
        lock.withLock { state }
    }

    /// Provider for `LinkRunner.Configuration.batteryProvider`.
    public func provider() -> (@Sendable () -> BatteryState?) {
        { [weak self] in self?.read() }
    }
}

// MARK: - Clipboard

/// Foreground clipboard. Never polled in the background: iOS suspends
/// access off-screen, so sync is manual push + apply-on-receive while
/// the app has focus.
public enum ClipboardBridge {
    /// Reads the clipboard. Returns nil off-screen or when empty
    /// (mirrors Android `clipboardText`, which returns null without focus).
    /// Main-actor: `UIApplication`/`UIPasteboard` are main-isolated on iOS
    /// (first caught by the Xcode simulator build, D7).
    @MainActor
    public static func read() -> String? {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return nil }
        return UIPasteboard.general.string.flatMap { $0.isEmpty ? nil : $0 }
#else
        return nil
#endif
    }

    /// Applies a received clipboard while on screen.
    public static func write(_ text: String) {
#if canImport(UIKit)
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else { return }
            UIPasteboard.general.string = text
        }
#else
        _ = text
#endif
    }
}

// MARK: - Desktop notifications

/// Renders a desktop notification. The content mapping is unit-coverable
/// without prompting; `show` needs user authorization (asked by the app,
/// never by this bridge).
public enum DesktopNotificationBridge {
    public static let categoryId = "org.omarchy.flux.computer"

    /// Builds the content for `n`. Reply/action buttons are intentionally
    /// absent: the desktop does not accept answers to its own notifications.
    public static func content(for n: ComputerNotification) -> Any? {
#if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.text
        content.subtitle = n.subText
        content.categoryIdentifier = categoryId
        return content
#else
        return nil
#endif
    }

#if canImport(UserNotifications)
    /// Shows `n` now. No-op when not authorized.
    /// Runs detached: the settings completion fires on a framework queue,
    /// and a closure created in a MainActor/async context traps there
    /// (`dispatch_assert_queue_fail` — first-device crash 2026-09-27).
    public static func show(_ n: ComputerNotification) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let settings = try? await center.notificationSettings()
            guard let settings, settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            guard let content = content(for: n) as? UNMutableNotificationContent else { return }
            let request = UNNotificationRequest(
                identifier: n.key, content: content, trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Removes the rendered notification for `key` (`deviceId:id`).
    public static func dismiss(key: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
    }
#endif
}

/// Presents desktop notifications while the app is in the foreground.
/// iOS suppresses banners for the foreground app by default — without
/// this delegate `flux notify` is delivered silently to the tray and the
/// user sees nothing (first-device finding 2026-09-27: event arrived,
/// no banner). The center holds its delegate weakly; the app keeps this
/// alive for its lifetime and assigns it on the main thread.
///
/// `.list` is load-bearing (D22 root cause, 2026-09-27): since iOS 14
/// `.banner` alone shows a floating banner WITHOUT adding the entry to
/// Notification Center — both flags are needed for banner + list. Every
/// vanishing notification in the D22 investigation went through this
/// delegate while foreground; everything system-presented
/// (background/locked) stuck.
///
/// It also routes approval lock-screen actions (D21): the Approve/Deny
/// buttons on the prompt notification resolve the held prompt through
/// `onApproveAction`. A plain tap on the notification body opens the app
/// with no verdict (the sheet stays the decision surface there). The
/// biometric gate still runs in the app — answering from the lock screen
/// needs Face ID / Touch ID all the same.
public final class ForegroundNotificationDelegate: NSObject, @unchecked Sendable {
    /// Resolves a held approval prompt from a lock-screen action
    /// (prompt id from `ApproveNotifications.promptId`, verdict from
    /// `ApproveNotifications.verdict`). Nil = no prompt flow active.
    public var onApproveAction: (@Sendable (String, Bool) -> Void)?
}

#if canImport(UserNotifications)
extension ForegroundNotificationDelegate: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Banner AND list: without `.list` the entry never reaches
        // Notification Center (D22). `.badge` is a no-op without a badge
        // number (we set none); `.sound` honors the user's Töne toggle.
        completionHandler([.banner, .sound, .badge, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let content = response.notification.request.content
        guard content.categoryIdentifier == ApproveNotifications.categoryId,
              let promptId = ApproveNotifications.promptId(
                  fromNotificationId: response.notification.request.identifier),
              let approve = ApproveNotifications.verdict(forActionId: response.actionIdentifier)
        else { return }
        onApproveAction?(promptId, approve)
    }
}
#endif

// MARK: - Ringer

/// Find-my-phone sound + haptic. Plays the alert once per call; the
/// `RingState` toggle + 2-minute cap live in `FluxCore` so the loop and
/// the full-screen `RingView` stay in sync. Cannot override the silent
/// switch for third parties — loudest allowed + vibration.
public enum RingerBridge {
    public static func alertOnce() {
#if canImport(AudioToolbox)
        AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_Vibrate, nil)
#endif
    }
}

// MARK: - Pending shares

/// Queued file announcements waiting for the M3 payload fetch
/// (`payloadSize` + `payloadTransferInfo.port/tunnel` already parsed).
/// Files land in the App Group container; text/URL shares bypass the queue.
public actor PendingShareStore {    private var queued: [ShareFile] = []

    public init() {}

    public func put(_ file: ShareFile) {
        queued.append(file)
    }

    public func takeAll() -> [ShareFile] {
        defer { queued.removeAll() }
        return queued
    }

    public var count: Int { queued.count }
}

// MARK: - Calls (M4)

/// One observed call, reduced to what `CallTracker` needs. `CXCall`
/// carries no number (iOS exposes none to third parties), so the
/// telephony packets built from these always fall back to
/// `CallPackets.unknownCaller` on the desktop.
public struct ObservedCall: Sendable, Equatable {
    public var connected: Bool
    public var ended: Bool
    public var outgoing: Bool

    public init(connected: Bool, ended: Bool, outgoing: Bool) {
        self.connected = connected
        self.ended = ended
        self.outgoing = outgoing
    }
}

/// Watches calls through `CXCallObserver` and emits `kdeconnect.telephony`
/// packets, one per `CallTracker` event (Android `service/CallMonitor` +
/// `core/Calls` parity, minus the number: `CallMonitor` reads it via
/// `READ_CALL_LOG`, which has no iOS equivalent).
///
/// Limits, by design (see `docs/ios-plan.md` §4.8):
/// - No number and no contact name ever reach the desktop: `CXCall`
///   exposes neither, so every call shows "Unknown caller" there.
/// - The desktop pauses its players while the phone rings or talks
///   (`pause_media_on_call`) and notifies missed calls — that logic is
///   `fluxd`-side (`internal/core/telephony.go`); this bridge only sends.
/// - Observing needs a running app or background audio/voip time; a
///   suspended link sends nothing until it reconnects.
public final class CallBridge: NSObject, @unchecked Sendable {
    /// Emits one packet per telephony event (the link sends it).
    public var onPacket: (@Sendable (Packet) -> Void)?
    private let tracker = LockedTracker()

    public override init() {}

    public func start() {
        #if os(iOS)
        observer.setDelegate(self, queue: .main)
        #endif
    }

    public func stop() {
        #if os(iOS)
        observer.setDelegate(nil, queue: nil)
        #endif
    }

    #if os(iOS)
    private lazy var observer = CXCallObserver()

    /// Feeds the changed call set (delegate entry point, main queue).
    public func callsChanged(_ calls: [CXCall]) {
        emit(calls.map { ObservedCall(connected: $0.hasConnected, ended: $0.hasEnded, outgoing: $0.isOutgoing) })
    }
    #endif

    /// Feeds one observed snapshot. Pure (no system calls): the unit test
    /// drives the whole call lifecycle through here.
    func emit(_ calls: [ObservedCall]) {
        for event in tracker.events(for: Self.aggregate(calls)) {
            onPacket?(CallPackets.packet(event: event))
        }
    }

    /// Reduces concurrent calls to one line state: any live off-hook call
    /// wins, else any ringing call, else idle.
    static func aggregate(_ calls: [ObservedCall]) -> LineState {
        let live = calls.filter { !$0.ended }
        if live.contains(where: { $0.connected || $0.outgoing }) { return .offHook }
        if live.contains(where: { !$0.outgoing }) { return .ringing }
        return .idle
    }
}

#if os(iOS)
extension CallBridge: CXCallObserverDelegate {
    public func callObserver(_: CXCallObserver, callChanged _: CXCall) {
        callsChanged(observer.calls)
    }
}
#endif

/// Lock-guarded `CallTracker` (the observer delegate and the link both
/// touch the bridge).
private final class LockedTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = CallTracker()

    func events(for state: LineState) -> [CallEvent] {
        lock.withLock { tracker.onState(state) }
    }
}

// MARK: - Focus / Do Not Disturb (M4)

/// Syncs Focus status to the desktop as `flux.dnd` (`INFocusStatusCenter`,
/// Android `core/DndSync` parity minus the set direction).
///
/// Limits, by design (see `docs/ios-plan.md` §§3.1, 4.8):
/// - Focus status is a user-authorized boolean (`NSFocusStatusUsageDescription`,
///   `requestAuthorization`). Denied = silent no-op, never an error.
/// - iOS offers no Focus-change callback, so the app calls `refresh()` on
///   foreground + a foreground timer. No background polling: a suspended
///   app sends nothing until it refreshes (the `DndGuard` still emits on
///   change only).
/// - Desktop→phone `flux.dnd` renders a banner (`DesktopDndBridge`) and is
///   never applied: iOS cannot set Focus programmatically.
public final class FocusBridge: @unchecked Sendable {
    /// Emits `DndMessage.packet(on:)` payloads (the link sends them).
    public var onChange: (@Sendable (Bool) -> Void)?
    /// Diagnostics (auth status, read value, guard decision) for the
    /// status line — Focus reads fail silently by platform design, so a
    /// device run with no `flux.dnd` needs this to tell denied reads
    /// apart from no-change suppression (M4 hardware round, 2026-09-27).
    public var onLog: (@Sendable (String) -> Void)?
    private let guardBox = LockedDndGuard()

    public init() {}

    /// Asks for Focus-status access. Call once at setup; refreshes before
    /// that are silent no-ops. Runs detached (same queue-trap reason as
    /// the notification `show` above).
    public func requestAccess() {
        #if canImport(Intents)
        Task.detached {
            INFocusStatusCenter.default.requestAuthorization { _ in }
        }
        #endif
    }

    /// Reads Focus status and emits on change only. `nowMs` is injectable
    /// for tests (defaults to now).
    public func refresh(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        #if canImport(Intents)
        let auth = INFocusStatusCenter.default.authorizationStatus
        guard auth == .authorized else {
            onLog?("focus refresh: auth=\(auth) (no read)")
            return
        }
        let focused = INFocusStatusCenter.default.focusStatus.isFocused
        let on = focused ?? false
        #else
        let on = false
        #endif
        if guardBox.local(on: on, nowMs: nowMs) {
            #if canImport(Intents)
            onLog?("focus refresh: focused=\(String(describing: focused)) -> send on=\(on)")
            #endif
            onChange?(on)
        } else {
            #if canImport(Intents)
            onLog?("focus refresh: focused=\(String(describing: focused)) (no change)")
            #endif
        }
    }

    /// Notes a desktop `flux.dnd` arrival so its echo never goes back
    /// (the arrival itself only renders a banner).
    public func noteRemote(on: Bool, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guardBox.remote(on: on, nowMs: nowMs)
    }
}

/// Lock-guarded `DndGuard` (refreshes and link callbacks share the bridge).
private final class LockedDndGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var guardState = DndGuard()

    func local(on: Bool, nowMs: Int64) -> Bool {
        lock.withLock { guardState.local(on: on, nowMs: nowMs) }
    }

    @discardableResult
    func remote(on: Bool, nowMs: Int64) -> Bool {
        lock.withLock { guardState.remote(on: on, nowMs: nowMs) }
    }
}

/// Renders desktop Do Not Disturb as a banner. Never touches Focus.
public enum DesktopDndBridge {
    public static let categoryId = "org.omarchy.flux.dnd"

    public static func content(computer: String, on: Bool) -> Any? {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = on ? "Do Not Disturb on \(computer)" : "Do Not Disturb off \(computer)"
        content.body = on
            ? "Calls and notifications stay quiet there."
            : "This computer makes noise again."
        content.categoryIdentifier = categoryId
        return content
        #else
        return nil
        #endif
    }

    #if canImport(UserNotifications)
    /// Shows the banner now. No-op when not authorized.
    /// Runs detached (same queue-trap reason as `DesktopNotificationBridge.show`).
    public static func show(computer: String, on: Bool) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let settings = try? await center.notificationSettings()
            guard let settings, settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else { return }
            guard let content = content(computer: computer, on: on) as? UNMutableNotificationContent else { return }
            try? await center.add(UNNotificationRequest(
                identifier: "\(categoryId):\(computer)", content: content, trigger: nil
            ))
        }
    }
    #endif
}

// MARK: - Now playing (M4)

/// Controls this phone's playback from desktop `mpris.request` actions
/// (`flux media *`) and publishes now-playing state for desktop queries.
///
/// Wiring: the app forwards `LinkRunner` media events here (`handle`) and
/// feeds `nowPlayingProvider` from `current()`. `MPRemoteCommandCenter`
/// handlers drive the app's real player through the `onXxx` closures, so
/// desktop pause/next controls iPhone playback (plan §4.6).
///
/// Limits, by design:
/// - Remote commands work while locked (their purpose) but need a live
///   link: a background-suspended app receives nothing until it reconnects.
/// - The silent switch does not gate remote commands; muted output simply
///   stays muted.
/// - iOS has no remote volume API for third parties: desktop `setVolume`
///   is logged by the link and ignored here.
public final class NowPlayingBridge: @unchecked Sendable {
    /// This phone's player name in answers (fluxd shows it as the player).
    public var playerName: String
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onToggle: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onSeek: ((Int64) -> Void)?

    public init(playerName: String = "Music") {
        self.playerName = playerName
    }

    /// Registers the remote-command handlers. Call on start, `stop()` on end.
    public func start() {
        #if canImport(MediaPlayer)
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }
        cc.stopCommand.addTarget { [weak self] _ in self?.onStop?(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            self?.onSeek?(Int64(pos * 1000))
            return .success
        }
        #endif
    }

    public func stop() {
        #if canImport(MediaPlayer)
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.stopCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        #endif
    }

    /// Routes one desktop action to the player closures. False = unknown
    /// verb or another player's business (the link logs it).
    @discardableResult
    public func handle(player: String, action: String) -> Bool {
        guard player == playerName, let verb = MediaAction(rawValue: action) else { return false }
        switch verb {
        case .playPause: onToggle?()
        case .play: onPlay?()
        case .pause: onPause?()
        case .next: onNext?()
        case .previous: onPrevious?()
        case .stop: onStop?()
        }
        return true
    }

    /// Routes one desktop seek (ms) to the player. False for another player.
    @discardableResult
    public func handleSeek(player: String, positionMs: Int64) -> Bool {
        guard player == playerName else { return false }
        onSeek?(positionMs)
        return true
    }

    /// Publishes state to `MPNowPlayingInfoCenter` (lock-screen + queries).
    public func publish(_ s: MprisState) {
        #if canImport(MediaPlayer)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.artist,
            MPMediaItemPropertyAlbumTitle: s.album,
            MPNowPlayingInfoPropertyPlaybackRate: s.playing ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: Double(s.length) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(s.position) / 1000,
        ]
        if s.playing { info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    /// Reads back the published state for desktop query answers. Nil when
    /// nothing is published (the link answers an empty player list).
    public func current() -> MprisState? {
        #if canImport(MediaPlayer)
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return nil }
        let rate = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double).map { _ in
            (info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? 0
        } ?? 0
        return MprisState(
            player: playerName,
            title: (info[MPMediaItemPropertyTitle] as? String) ?? "",
            artist: (info[MPMediaItemPropertyArtist] as? String) ?? "",
            album: (info[MPMediaItemPropertyAlbumTitle] as? String) ?? "",
            playing: rate != 0,
            position: Int64(((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? 0) * 1000),
            length: Int64(((info[MPMediaItemPropertyPlaybackDuration] as? Double) ?? 0) * 1000),
            canSeek: true
        )
        #else
        return nil
        #endif
    }
}
