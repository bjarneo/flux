# Flux for iOS — Build Plan

> Companion to [Flux for Android](../docs/android.md), [Architecture](../docs/architecture.md), [Approve design](../docs/approve.md), and the [omarchy-flux skill](../skills/omarchy-flux/SKILL.md).
> Goal: a native iOS app with feature parity to `android/` where iOS allows it, speaking the same KDE Connect protocol v8 + Flux extensions to the same `fluxd`, with no desktop protocol changes.

## 0. Executive summary

Flux today is:

```text
flux CLI ─────────────┐
Qt app ──────────────┼── Unix socket ── fluxd ── TLS + tunnels ── Flux for Android
Omarchy shell plugin ┘
```

`fluxd` owns device state and network (`internal/core/`, `internal/lan/`, `internal/proto/`). The desktop **always opens** TCP/TLS connections to the phone (firewall-friendly). The phone exposes a payload/tunnel listener for reverse transfers and SFTP-over-SSH browsing.

The iOS app is a **new peer** in that diagram:

```text
fluxd ── TLS + tunnels ── Flux for iOS (Swift/SwiftUI, Network.framework, Secure Enclave)
```

No `fluxd`, CLI, Qt, or IPC changes are required for v1 except:

1. Accepting `deviceType: phone` / `tablet` from iOS and an iOS UA in identity (already generic).
2. Optional: accepting an iOS-specific capability subset (graceful degradation for SMS, notification-listener, call-log).
3. Test peer + docs updates.

The hard work is all client-side: re-implementing `android/app/src/main/java/org/omarchy/flux/` (~75 Kotlin files) in Swift, while navigating iOS backgrounding, notification, SMS, DND, and camera/mic/screen restrictions that Android does not have.

**Recommended approach:** native Swift 6 + SwiftUI + `Network.framework` + `CryptoKit`/`Security` + `AVFoundation` + `ReplayKit` + `Vision` + `CallKit`/`CoreTelephony` (limited) + Keychain/Secure Enclave. Minimum iOS 17, target iOS 18 SDK (Xcode 16+). Swift Package Manager only, no CocoaPods. New top-level `ios/` directory mirroring `android/`.

**Phased delivery:**

| Phase | Milestone | Outcome |
| --- | --- | --- |
| 0 | Spike + scaffolding | `ios/` builds, identity + UDP/mDNS discovery against `tools/test_peer.py` and real `fluxd` |
| 1 | Core link + pairing + trust | Pair/unpair with 8-char key, TLS pinning, `devices.json`-equivalent trust store |
| 2 | Messaging primitives | Ping, battery, clipboard, share, notifications (best-effort), find-my-phone |
| 3 | Files + remote I/O | Payload receive/send, `flux.tunnel` reverse listener, SFTP browse stub |
| 4 | Media/commands/calls/DND | MPRIS-equivalent, runcommand, telephony best-effort, Focus/DND sync |
| 5 | Camera/mic/screen | Photo/document/text/QR capture, webcam H.264, mic PCM/Opus, ReplayKit mirror |
| 6 | Approval (Secure Enclave) | `flux.approve` enroll + sign, `LocalAuthentication` + `SecureEnclave` P-256 |
| 7 | Polish + TestFlight + release | Backgrounding, battery, icons, CI signing, App Store submission |

Each phase is independently testable against unmodified `fluxd`.

---

## 1. Source-of-truth inventory (what to port)

### 1.1 Desktop side (do not reimplement, interoperate with)

| Area | Path | iOS relevance |
| --- | --- | --- |
| Packet format | `internal/proto/packet.go` | JSON-line `{"id","type","body","payloadSize","payloadTransferInfo"}`, `MaxPacketSize = 16 MiB`, `id` numeric-or-string tolerant |
| Packet types + capabilities | `internal/proto/identity.go` | 17 `kdeconnect.*` types + 6 `flux.*` extensions; `Incoming`/`Outgoing` lists; `ProtocolVersion = 8` |
| Identity handshake | `internal/proto/identity.go`, `internal/lan/link.go` | Plain-text `kdeconnect.identity` with `targetDeviceId` before TLS, then TLS identity; race-window link preference (`Preferred`) |
| Certs + pinning | `internal/proto/cert.go`, `internal/lan/tls.go` | Self-signed cert per device, pinned after pairing; replacement = re-pair |
| Discovery | `internal/lan/mdns.go`, `internal/lan/provider.go` | mDNS `_kdeconnect._udp` via Avahi + UDP broadcast; desktop opens connection |
| Links | `internal/lan/link.go` | One TLS link per device, JSON lines, out-of-order-safe |
| Payloads | `internal/lan/payload.go` | Receiver fetches from sender's payload port |
| Tunnels | `internal/lan/tunnel.go` | Phone opens `flux.tunnel` listener, desktop connects in (for send-to-phone + SFTP/SSH browse) |
| Feature handlers | `internal/core/*.go` | `pairing`, `clipboard`, `share`, `notifications`, `sms`, `media`, `telephony`, `dnd`, `webcam`, `mic`, `screen`, `approve`, `sftp` |
| IPC (reference only) | `internal/ipc/ipc.go`, `internal/core/api.go` | `state`, `subscribe`, pairing/sharing/commands/media/streams/approve methods — useful for building an iOS debug harness |
| Approval crypto contract | `docs/approve.md` | `flux-approve-v1` 8-line message, `flux-approve-enroll-v1` 7-line message, SHA256withECDSA P-256, nonce + time checks |
| Config defaults | `docs/configuration.md` | `download_dir`, `scan_dir`, `photo_dir`, `share_home`, `auto_clipboard`, etc. — informs iOS defaults |
| CLI for testing | `docs/cli.md` | `flux discover/pair/status/send/clip/url/ring/media/webcam/mic/screen/approve` — manual QA script for iOS |

### 1.2 Android side (line-by-line port reference)

From `android/app/src/main/java/org/omarchy/flux/`:

| Android module | Path | iOS equivalent module |
| --- | --- | --- |
| Packets/identity/certs/verify key | `protocol/Packet.kt`, `protocol/Identity.kt`, `protocol/Certificates.kt` | `FluxProto/` (pure Swift, `Codable`, XCTest) |
| UDP discovery, TCP links, TLS, payloads | `net/` (`LanBackend.kt`, `Link.kt`, `Tls.kt`, `Payload.kt`, `Tunnel.kt`) | `FluxNet/` (`Network.framework`: `NWListener`, `NWConnection`, `NWBrowser`, `sec_protocol_options`) |
| Devices, pairing, trust store, plugins | `core/` (`Device.kt`, `FluxCore.kt`, `Model.kt`, `TrustStore.kt`, `Plugins.kt`, `Settings.kt`) | `FluxCore/` (actor-isolated state, Keychain trust store) |
| Share/receive, notifications, ringer, calls, DND, captures, browse | `core/Share.kt`, `NotificationSync.kt`, `ComputerNotification.kt`, `Ringer.kt`, `Calls.kt`, `CallMonitor.kt`, `DndSync.kt`, `DndGuard.kt`, `CaptureWatch.kt`, `CapturePlan.kt`, `Browse.kt` | `FluxFeatures/` + iOS system bridges (see §4) |
| Approval keys/messages/flows | `core/ApproveKeys.kt`, `core/ApproveMessage.kt`, `core/Approvals.kt` | `FluxApprove/` (Secure Enclave + `LocalAuthentication`) |
| Foreground service + listeners | `service/FluxService.kt`, `service/FluxNotificationListener.kt`, `service/CallMonitor.kt`, `FluxApp.kt` | `FluxService/` (BGTasks + `BGProcessingTask`, PushKit-less LAN keepalive, Notification Service Extension where applicable) |
| Compose screens | `ui/` (`MainActivity.kt`, `HomeScreens.kt`, `RemoteScreens.kt`, `Components.kt`, `Icons.kt`, `Theme.kt`) | `FluxUI/` (SwiftUI: devices/home/media/commands/browse/mic/camera + pair/ring/unpair overlays) |
| Camera (text/QR/photo/doc/webcam) | `camera/`, `scan/`, `webcam/` | `FluxCamera/` (`AVFoundation` + `Vision` + `VisionKit` + `VideoToolbox`) |
| Mic + screen | `mic/`, `screen/`, `stream/` | `FluxStream/` (`AVAudioEngine`, `ReplayKit` broadcast extension) |
| Test peer, shots, icons | `android/tools/` (`test_peer.py`, `shot.sh`, `fetch_icons.py`) | `ios/tools/` ports (see §9) |
| Manifest + perms | `app/src/main/AndroidManifest.xml` | `Info.plist` + entitlements + `PrivacyInfo.xcprivacy` (see §3) |
| Build | `build.gradle.kts`, `gradle/libs.versions.toml` | `ios/Package.swift` / Xcode project + `Makefile` target `make ios` |

Key Android behaviors to preserve exactly:

- Verification key: first 8 chars / 4-group code from SHA-256 of certificate (see `protocol/` tests). iOS must produce **byte-identical** codes or pairing UX breaks.
- `id` tolerance: accept number or numeric string.
- `flux.tunnel` semantics: phone listens, desktop connects (inverted vs. classic KDE Connect payload fetch).
- Capability advertisement: only advertise what iOS actually implements; `fluxd` gates plugins on intersection.
- Demo mode (`FLUX_DEMO=1`) and screenshot pages (`devices/home/media/commands/browse/mic/camera/ring/pair/unpair/empty/icon`) — port as SwiftUI previews + snapshot tests.

---

## 2. Protocol contract for iOS (normative)

Implement exactly; do not "improve" the wire.

### 2.1 Transport

- **Discovery listen:** UDP broadcast on KDE Connect port (check `internal/lan/provider.go` for exact port at implementation time; Android `net/` has the constant) + mDNS browse `_kdeconnect._udp.local`. iOS must **publish** its own `_kdeconnect._udp` record via `NWListener`/`NetService` with TXT fields `deviceId`, `deviceName`, `deviceType`, `protocolVersion`, `tcpPort`.
- **Connection direction:** desktop dials phone's advertised `tcpPort`. iOS runs a persistent `NWListener` (TLS) while in foreground and opportunistically in background (see §3.2 limits). Also support inbound reconnect with the 5-second race-window rule from `Preferred` in `link.go`.
- **Framing:** one JSON object + `\n` per packet over TLS. Enforce 16 MiB cap. Use `newline-delimited JSON`, not length-prefix.
- **Identity (plaintext phase):** first packet each direction is `kdeconnect.identity` with `targetDeviceId` + `targetProtocolVersion`. Close on mismatch.
- **Identity (TLS phase):** re-exchange identity inside TLS, then validate pinned cert (`cert.go`/`Tls.kt` logic: compare DER/SHA-256, not hostname).
- **Payloads:** `payloadSize` + `payloadTransferInfo.port` (classic) or `payloadTransferInfo.tunnel` (Flux reverse). iOS implements **both**: a payload server for desktop-fetch, and a `flux.tunnel` listener for desktop-connect.
- **SFTP/browse:** SSH inside `flux.tunnel` when desktop `share_home` is on. iOS v1 may be read-only client of desktop files; serving iOS files over SFTP is deferred (see §4.7).

### 2.2 Capabilities to advertise (v1 proposal)

```json
{
  "deviceId": "<32-38 chars [a-zA-Z0-9_-]>",
  "deviceName": "<cleaned, max 32 chars, no \"',;:.!?()[]<>>",
  "deviceType": "phone",
  "protocolVersion": 8,
  "incomingCapabilities": [
    "kdeconnect.ping",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.share.request",
    "kdeconnect.notification.request",
    "kdeconnect.notification.reply",
    "kdeconnect.notification.action",
    "kdeconnect.findmyphone.request",
    "kdeconnect.runcommand.request",
    "kdeconnect.mpris",
    "kdeconnect.mpris.request",
    "kdeconnect.sftp",
    "kdeconnect.sftp.request",
    "kdeconnect.sms.request",
    "flux.webcam",
    "flux.dnd",
    "flux.mic",
    "flux.screen",
    "flux.approve"
  ],
  "outgoingCapabilities": [
    "kdeconnect.ping",
    "kdeconnect.battery",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.share.request",
    "kdeconnect.notification",
    "kdeconnect.findmyphone.request",
    "kdeconnect.runcommand",
    "kdeconnect.mpris.request",
    "kdeconnect.sftp.request",
    "kdeconnect.sms.request",
    "kdeconnect.connectivity_report",
    "kdeconnect.telephony",
    "flux.tunnel",
    "flux.webcam",
    "flux.dnd",
    "flux.mic",
    "flux.screen",
    "flux.approve"
  ],
  "tcpPort": 0
}
```

Notes:

- Omit `kdeconnect.sms.messages` incoming unless iOS can actually source SMS (it cannot — see §4.5). Advertise `sms.request` only if implementing send-via-phone relay is punted; safer to omit SMS incoming in v1 and add a `flux.sms.relay` extension later.
- Omit `kdeconnect.telephony` outgoing if call detail is unavailable; or send best-effort ringing/missed events via CallKit.
- `flux.*` types are symmetric (both sides send) except `flux.tunnel` (phone → desktop only).
- Validate `deviceId` with `^[a-zA-Z0-9_-]{32,38}$` and `CleanName` rules from `identity.go`.

### 2.3 Approval wire (must match `docs/approve.md` byte-for-byte)

- Key: EC P-256, SHA256withECDSA, ASN.1 DER. Alias per desktop: `flux-approve-<computer device ID>` (Keychain/Secure Enclave equivalent).
- Approval message (8 lines, each `\n`-terminated):
  ```text
  flux-approve-v1
  host=<host>
  user=<user>
  service=<PAM service>
  tty=<tty or empty>
  rhost=<rhost or empty>
  time=<unix seconds>
  nonce=<64 lowercase hex>
  ```
- Enrollment message (7 lines):
  ```text
  flux-approve-enroll-v1
  host=<host>
  user=<user>
  key=<sha256 DER hex>
  time=<unix seconds>
  nonce=<64 lowercase hex>
  ```
- Field rules: UTF-8, ≤256 bytes, no control chars, `host/user/service` non-empty, `nonce` 64 lowercase hex.
- Phone refuses requests with clock skew >10 min; helper checks ±(wait time / 5 s future).
- Biometric gate: `LAContext` + `SecAccessControl(.biometryCurrentSet)` + `kSecAccessControlBiometryCurrentSet`, per-use auth, invalidate on new biometric enrollment (matches Android `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` + StrongBox-when-available → Secure Enclave-when-available).

---

## 3. iOS constraints analysis (what cannot be 1:1)

### 3.1 Permission / entitlement map (Android → iOS)

| Android permission | iOS equivalent | Verdict |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE`, sockets | `com.apple.developer.networking.multicast` entitlement for UDP/mDNS; Local Network privacy prompt | Feasible; must add Bonjour `NSBonjourServices = _kdeconnect._udp` + `NSLocalNetworkUsageDescription` |
| `CHANGE_WIFI_MULTICAST_STATE` | Multicast entitlement (request from Apple, can take days) | Plan lead time; fallback to mDNS-only via `NWBrowser` if denied |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` + `FluxService` | No FG-service equivalent; `UIBackgroundModes`: `audio`, `voip` (PushKit), `external-accessory` n/a, `fetch`, `processing`, `remote-notification` | **Biggest risk.** Persistent LAN link in background requires: audio keepalive (mic/webcam streaming only), `BGAppRefresh`/`BGProcessingTask` opportunistically, PushKit-less design (no Apple push server). Expect background link to suspend; design for fast reconnect + APNs relay later (optional server component, out of scope v1) |
| `POST_NOTIFICATIONS`, `NotificationListenerService`, `QUERY_ALL_PACKAGES` | `UNUserNotificationCenter`, Notification Service Extension (only for own pushes), no global notification read API | **Cannot mirror all iPhone notifications to desktop.** Best-effort: mirror Flux-originated + CallKit + Focus status; document as known gap |
| `SEND_SMS` (implied), SMS provider | No SMS send/read API for third parties | **Cannot send SMS through iPhone.** Provide desktop→iPhone share fallback + document gap; consider relay via paired Mac? No — out of scope |
| `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS` | `CallKit`, `CoreTelephony` (limited), `Contacts` (opt-in) | Best-effort: report ringing/connected via `CXCallObserver`; number only if in contacts + granted; no call-log history |
| `ACCESS_NOTIFICATION_POLICY` (DND) | Focus status via `INFocusStatusCenter` (opt-in, boolean only, no set) | One-way: iOS→desktop Focus boolean; desktop→iOS DND **cannot be set** programmatically. Advertise accordingly |
| `READ_MEDIA_IMAGES`, photo picker | `PHPhotoLibrary`, `PHPickerViewController` | Feasible; auto-upload new screenshots/camera needs `PHPhotoLibraryChangeObserver` + Background Tasks; "all photos" permission prompt |
| `CAMERA`, CameraX + ML Kit | `AVFoundation` + `Vision` (`VNRecognizeTextRequest`, `VNDetectBarcodesRequest`) + `VisionKit` document scanner | Feasible; on-device, no Play Services dependency |
| `RECORD_AUDIO`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` | `AVAudioSession`/`AVAudioEngine`, `ReplayKit` Broadcast Upload Extension | Feasible in foreground; background audio needs `audio` mode; screen mirror needs separate broadcast extension target |
| `USE_BIOMETRIC`, Keystore StrongBox | `LocalAuthentication`, Keychain + Secure Enclave (`SecureEnclave.P256.Signing`) | Feasible; use `CryptoKit` where possible, `Security` for `kSecAttrTokenIDSecureEnclave` |
| `RECEIVE_BOOT_COMPLETED` | No autostart; `BGAppRefreshTask` on next launch | Document; instruct user to launch once after reboot |
| Share sheet (`SEND`/`SEND_MULTIPLE`) | Share Extension (`com.apple.share-services`) + `NSItemProvider` | Feasible; separate extension target with App Group |
| Clipboard background sync | `UIPasteboard` foreground-only; no background clipboard daemon | Foreground + manual push only; `auto_clipboard` defaults off on iOS or foreground-gated |

### 3.2 Backgrounding strategy (detailed)

iOS will suspend a plain TCP listener within ~30 s of backgrounding. Plan:

1. **Foreground:** full `NWListener` + per-device `NWConnection`, same as Android `FluxService`.
2. **Brief background (≤30 s–3 min):** request `beginBackgroundTask` + `BGProcessingTask` to finish in-flight payloads; send `kdeconnect.connectivity_report`-style offline hint if link drops.
3. **Audio-streaming background:** when mic/webcam active, enable `audio` background mode; link stays alive as a side effect (legitimate VoIP/media use).
4. **ReplayKit background:** screen broadcast extension runs independently of host app suspension.
5. **Wake/reconnect:** `BGAppRefreshTask` periodic re-announce (mDNS + UDP); silent push via APNs **only if** a future Flux relay is built — explicitly out of scope for v1, note as follow-up.
6. **UX contract:** show "Background suspended — open Flux to stay connected" banner mirroring Android's "Turn off Flux" semantics; do not fake presence. `flux status` on desktop will show offline, which is correct.

Test with Xcode "Simulate Background Fetch" + device Sysdiagnose + `flux watch` event stream.

### 3.3 Privacy manifests + entitlements checklist

- `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryUsageDescription` (+ `NSPhotoLibraryAddUsageOnlyDescription`), `NSContactsUsageDescription` (optional), `NSFocusStatusUsageDescription`, `NSSpeechRecognitionUsageDescription` (if using on-device dictation), `PrivacyInfo.xcprivacy` (required reason APIs: `UserDefaults`, `FileTimestamp`, `SystemBootTime`, `DiskSpace`).
- Entitlements: `com.apple.developer.networking.multicast`, `aps-environment`, `com.apple.security.application-groups`, `com.apple.developer.usernotifications.time-sensitive`, keychain sharing if extensions need keys.
- No private API. No `QUERY_ALL_PACKAGES` equivalent — do not attempt notification scraping via workarounds; will fail App Review.

### 3.4 App Store risks

- Background socket persistence → must not claim VoIP unless using PushKit + CallKit correctly. Use `audio` mode only while streaming.
- SMS/call-log/DND gaps → must not over-promise in store copy; list iOS limitations explicitly.
- Crypto: self-signed TLS + custom pinning is allowed; document in review notes. Secure Enclave signing is allowed.
- Screen broadcast extension + camera/mic require clear purpose strings.

---

## 4. Feature-by-feature port plan

### 4.1 Pairing / trust / identity

- Port `protocol/Identity.kt` + `core/TrustStore.kt` + `core/Device.kt` to `FluxProto/Identity.swift` + `FluxCore/TrustStore.swift` (Keychain-backed, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Pairing UX mirrors Android: desktop `flux pair` or Qt "+ Pair new device" → 8-char key on both screens → Accept on iPhone. Implement `PairView` + `UnpairView` + lateral `RingView` overlay (`showWhenLocked` equivalent: `UNNotificationAction` + Live Activity).
- Verification-key function must be unit-tested against Android JVM vectors (copy `protocol` test fixtures into `FluxProtoTests`).
- Device ID: `UUID`-derived 32–38 char `[A-Za-z0-9_-]` stable across reinstalls? Prefer Keychain-persisted random ID (survives reinstall if Keychain retained) with regenerate-on-wipe. Document that reinstall = re-pair if Keychain cleared.
- Certificate: self-signed P-256/ECDSA (or RSA-4096 to match desktop? check `cert.go` at build time — implement what `cert.go` generates; default to P-256 + SHA-256). Private key in Secure Enclave when available, else Keychain. Export cert PEM for `devices.json` pinning on desktop.

Acceptance: `flux discover` sees iPhone; `flux pair` + key compare + accept works; `flux status --json` shows online; restart survives; unpair both directions works.

### 4.2 Connectivity / battery / ping / ring

- `kdeconnect.battery`: `UIDevice.batteryLevel` + `batteryState` → charging flag; throttle to change-only (Android behavior).
- `kdeconnect.ping`: message passthrough.
- `kdeconnect.findmyphone.request`: play ringtone + haptic + full-screen-equivalent notification (`UNNotification` + critical? no — time-sensitive). `flux ring` must ring iPhone even when muted? iOS cannot override silent switch for third parties — document; use loudest allowed + vibration + flash.
- `kdeconnect.connectivity_report`: send network reachability (`NWPathMonitor`: wifi/cellular/constrained).

### 4.3 Clipboard / share / links

- Clipboard: `UIPasteboard.general.string` foreground sync both directions; `auto_clipboard` iOS default `false` or foreground-only. Implement `clipboard.send` equivalent + `clipboard.connect` handshake. No background polling.
- Share desktop→iPhone: receive `kdeconnect.share.request` text/URL/files via payload fetch; route to Files (App Group container) + share sheet + clipboard opt-in.
- Share iPhone→desktop: Share Extension (`ShareViewController` + `NSItemProvider` for text/URL/image/file) → host app via App Group → `share.request` + payload serve. Also in-app file picker (`UIDocumentPickerViewController`) + photo picker.
- `flux clip`, `flux url`, `flux send` from desktop must land on iPhone; verify with files 0 B–100 MB.

### 4.4 Notifications (scoped)

- iPhone→desktop: **no full mirror.** Implement: (a) Flux-internal notifications (pair/approve/transfer states), (b) missed-call events via CallKit observer, (c) optional manual "Share notification" via Siri Shortcut / Share Extension? Document gap vs. Android `NotificationSync.kt` + `FluxNotificationListener`.
- Desktop→iPhone: `kdeconnect.notification.request` → `UNMutableNotificationContent` on "From computers" channel-equivalent category; support reply (`notification.reply`) via text-input action and actions (`notification.action`) via buttons.
- Icon/album-art payloads: fetch + cache in App Group `Caches/`.

Do not build MDM/ANCS hacks. Revisit only if Apple adds an API.

### 4.5 SMS (explicit non-goal for v1)

- Android: `sms.request`, `request_conversations`, `request_conversation`, `sms.messages` + telephony integration.
- iOS: **no third-party SMS access.** Do not advertise `kdeconnect.sms.messages` incoming. Options: (a) hide Messages page when peer is iOS (desktop already gates on capabilities), (b) show "Not supported on iOS" empty state mirroring `<page>@offline`/`empty` patterns, (c) future: relay via Continuity-paired Mac — out of scope. Document in UI + store copy.

### 4.6 Media + commands

- Desktop media control from iPhone (MPRIS): port `RemoteScreens` media page to SwiftUI; send `kdeconnect.mpris.request` (`play-pause/play/pause/next/previous/stop`); render `kdeconnect.mpris` metadata + album art.
- iPhone media control from desktop (`flux media *`): integrate `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter` so desktop pause/next actually controls iPhone playback. Scope to AV-playback apps that honor remote commands.
- Run commands: desktop advertises `kdeconnect.runcommand` list; iPhone lists + runs (`flux commands add/remove`, `flux run`). Read-only execution (phone requests, desktop runs) — no iOS-side command execution.

### 4.7 Files + SFTP browse

- Payload server: `NWListener` ephemeral port per transfer; announce `port` (classic) for desktop-fetch of iPhone files; open `flux.tunnel` listener for desktop-connect when sending to iPhone.
- Receive: stream to `Application Support/Downloads/` (or App Group), resume/overwrite semantics matching `Payload.kt`; surface progress in Transfers UI + Live Activity.
- Browse desktop from iPhone: SSH-over-`flux.tunnel` read-only when desktop `share_home` on. Use `swift-nio-ssh` or `Citadel`/`SwiftSH` via SPM (evaluate: `Citadel` NIOSSH wrapper vs. `shh` + `libssh2` XCFramework). v1: file list + download only; no write.
- Serve iPhone files to desktop over SFTP: deferred (iOS Files provider + sandboxing makes this heavy). Document.

### 4.8 Calls + DND/Focus

- Calls: `CXCallObserver` → `kdeconnect.telephony` (`ringing/talking/missed`) with number only if contacts-granted + matched; otherwise "Unknown caller" (same string as Android). Desktop pauses media on call start per `pause_media_on_call` (no iOS work — desktop logic reused).
- DND/Focus: `INFocusStatusCenter.focusStatus` (boolean, user-authorized) → `flux.dnd {"on": bool}` on change only. Desktop→iOS direction: display banner "Desktop DND on" but **do not** attempt to set Focus (no API). Gate `sync_dnd` setting text for iOS ("Share Focus status" vs. "Sync").

### 4.9 Auto screenshots/photos

- Android watches `Pictures/Screenshots`, `DCIM/Screenshots`, `DCIM/Camera` and pushes each completed image once to every connected computer.
- iOS: `PHPhotoLibraryChangeObserver` on smart albums (`PHAssetCollectionSubtype.smartAlbumScreenshots`, `.smartAlbumCameraRoll`); filter `creationDate > optInDate`; upload once per desktop (persist sent `localIdentifier` set in SwiftData). Requires "Full access" prompt; handle Limited-access gracefully (no auto-upload, manual picker only). HEIC→JPEG compat: send original + UTI hint; desktop `photo_dir/screenshots` routing reused.
- Background upload: `BGProcessingTask` + `URLSession` background configuration for payload socket? Payloads are raw TCP, not HTTP — must foreground-upload or tunnel via extension. v1: foreground/queued ("waits for computer to connect" semantics preserved: queue until link up).

### 4.10 Camera modes (text/QR/photo/document/webcam)

Map Android `camera/` + `scan/` + `webcam/`:

| Android mode | iOS implementation |
| --- | --- |
| Text (ML Kit Latin bundled) | `VNRecognizeTextRequest` (on-device, `.accurate`, Latin + device locales) → `TextAssembly`-equivalent grouping → send to `scan_dir` |
| QR/barcode (ML Kit bundled) | `VNDetectBarcodesRequest` (QR, Aztec, Code128, EAN, PDF417…) + `AVCaptureMetadataOutput` live |
| Photo | `AVCapturePhotoOutput` (HEIC/JPEG) → `photo_dir` |
| Document (Play Services scanner) | `VisionKit VNDocumentCameraViewController` / `VNDocumentCameraScan` → PDF/JPEG → `scan_dir` |
| Webcam settings + H.264 | `AVCaptureVideoDataOutput` → `VideoToolbox` H.264 (`AnnexB` port) → `flux.webcam` + existing `WebcamConfig`/`WebcamProtocol` keys (`aspect/resolution/camera/mirror/zoom/exposure/whiteBalance/brightness/contrast/saturation/warmth`); `flux webcam [set/reset/stop]` must work unchanged |

Reuse desktop `flux webcam` CLI + PHONE CAMERA card without modification. Port `FrameGeometry.kt` math + `H264Encoder` SPS/PPS handling with unit tests.

### 4.11 Mic + screen

- Mic: `AVAudioEngine` tap → PCM 48 kHz mono → same `MicProtocol` framing as `mic/MicSession.kt`; "Also send mic with webcam" flag honored. `flux mic [stop]` works. Background `audio` mode while streaming.
- Screen: `ReplayKit` Broadcast Upload Extension (`RPBroadcastSampleHandler`: H.264 + AAC) → `ScreenProtocol`/`ScreenSession` port → desktop `mpv/ffplay` window (`flux screen [stop]`). Host app + extension share config via App Group. No input control (same as Android).

### 4.12 Fingerprint approval → Face ID / Touch ID

Port `core/Approve*` + `ui/ApproveActivity.kt` per `docs/approve.md` (see §2.3). iOS specifics:

- Key gen: `SecKeyCreateRandomKey` with `kSecAttrKeyTypeECSECPrimeRandom`, `kSecAttrKeySizeInBits: 256`, `kSecAttrTokenIDSecureEnclave` when `SecureEnclave.isAvailable`, `SecAccessControlCreateWithFlags(.biometryCurrentSet, .privateKeyUsage)`, `kSecAccessControlBiometryCurrentSet`, per-use `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.
- Key invalidation on new biometric: automatic with `biometryCurrentSet`; surface "enroll again" error matching Android behavior.
- Signing: `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256, ...)` → DER passthrough to `flux.approve` reply. Verify enrollment self-check locally before sending pubkey.
- UI: `ApproveActivity` equivalent full-screen prompt showing service/user/host/tty/rhost/time + Approve/Deny; must work over lock screen via time-sensitive notification + `LAContext` (no `showWhenLocked` flag — use notification actions).
- PAM/helper/`fluxd` unchanged; test with `sudo -k; sudo true` against iPhone.

Security review required before TestFlight (threat model §5 of `approve.md`: network attacker, malicious user-land code, unlocked-phone person).

---

## 5. Proposed iOS repo layout

```text
ios/
├── README.md                    # iOS setup, signing, run, test (mirrors docs/android.md)
├── Makefile / scripts/          # thin wrappers; root Makefile adds `make ios`
├── Flux.xcodeproj / Flux.xcworkspace
├── Package.swift (optional root SPM) 
├── App/
│   ├── FluxApp.swift            # @main, lifecycle, BGTask registration
│   ├── Info.plist
│   ├── Flux.entitlements
│   ├── PrivacyInfo.xcprivacy
│   └── Assets.xcassets
├── Sources/
│   ├── FluxProto/               # Packet, Identity, Certificates, VerifyKey (Codable, no deps)
│   ├── FluxNet/                 # Discovery (Bonjour+UDP), TLSLink, PayloadServer, TunnelListener
│   ├── FluxCore/                # DeviceStore, TrustStore (Keychain), Pairing, Settings, Plugins router
│   ├── FluxFeatures/            # Battery, Clipboard, Share, Notifications, Ringer, Calls, DND, Captures, Browse
│   ├── FluxApprove/             # ApproveMessage, ApproveKeys (Secure Enclave), Approvals flow
│   ├── FluxCamera/              # Capture modes, TextAssembly, Codes, CameraSource-equivalent
│   ├── FluxStream/              # Webcam (VTEncode), Mic (AudioEngine), Screen protocol framing
│   └── FluxUI/                  # SwiftUI screens: Devices/Home/Media/Commands/Browse/Mic/Camera/Ring/Pair/Unpair
├── Extensions/
│   ├── ShareExtension/          # ShareViewController + Info.plist + entitlements
│   ├── BroadcastExtension/      # RPBroadcastSampleHandler (screen mirror)
│   └── NotificationExtension/   # Notification Service Extension (desktop→iOS rich content, optional)
├── Tests/
│   ├── FluxProtoTests/          # packet/identity/cert/verify-key vectors from Android + Go tests
│   ├── FluxNetTests/            # loopback link, race-window, payload round-trip
│   ├── FluxCoreTests/           # pairing state machine, trust store (mock keychain)
│   ├── FluxApproveTests/        # message formatting, field validation, signature vectors
│   └── FluxCameraTests/         # geometry, Annex B, capture-plan
├── tools/
│   ├── test_peer.py             # symlink or iOS-aware fork of android/tools/test_peer.py
│   ├── shot.sh                  # simctl screenshot helper (mirrors android/tools/shot.sh)
│   └── fetch_icons.py           # SF Symbols mapping helper (instead of Material Symbols)
└── fastlane/ (optional)         # TestFlight + App Store automation
```

Conventions:

- Swift 6 strict concurrency (`actor FluxCore`, `Sendable` packets, `async/await` + `AsyncStream` for links).
- `Network.framework` for all sockets (not POSIX/`URLSession` for wire protocol).
- `CryptoKit` + `Security` for TLS identity/certs; custom `SecTrust` pinning callback (no default PKI validation for peer certs).
- `SwiftData` or `GRDB` for sent-photo ledger, transfers, commands cache; Keychain for identity + trust + approve keys.
- SF Symbols (not Material Symbols) for icons; keep names in `FluxUI/Icons.swift` mirroring `ui/Icons.kt`.
- SwiftUI + `@Observable` (iOS 17+), no UIKit except extensions + document scanner bridge.

Dependencies (SPM, pinned):

- `apple/swift-nio` + `apple/swift-nio-ssh` (only if needed for SFTP browse; else Citadel).
- `apple/swift-certificates` / `swift-crypto` for test vectors (wire uses Security at runtime).
- No third-party networking/crypto single-points; wrap so `fluxd` interop tests catch drift.

---

## 6. Build, test, CI plan

### 6.1 Local prerequisites (mirror `docs/android.md` tone)

- macOS 14+ with Xcode 16+, iOS 17+ device + simulator, Apple Developer team (free tier OK for debug, paid for TestFlight/broadcast extension + multicast entitlement).
- No `ANDROID_HOME`/JDK; instead `xcode-select`, `xcrun simctl`, `brew install swiftlint swiftformat` (optional).
- Commands:
  ```sh
  make ios              # xcodebuild -scheme Flux -destination generic/platform=iOS
  make ios-test         # xcodebuild test -scheme Flux -destination 'platform=iOS Simulator,name=iPhone 16'
  xcrun simctl ...      # screenshots per tools/shot.sh port
  python3 ios/tools/test_peer.py  # pair + battery/theme/command/media packets without desktop firewall rule
  ```

### 6.2 Test matrix (port Android checks)

| Check | Android equivalent | iOS command |
| --- | --- | --- |
| Unit (packets/identity/certs/verify-key) | `:app:testDebugUnitTest` | `xcodebuild test -only-testing:FluxProtoTests` (+ approval/capture/stream suites) |
| Lint | `:app:lintDebug` | SwiftLint (error on new warnings) |
| Debug build | `:app:assembleDebug` | `xcodebuild -configuration Debug` |
| Release/R8 build | `:app:assembleRelease` | `xcodebuild -configuration Release` + `EXPORT_METHOD=app-store` + bitcode/symbol check |
| Wire interop | `tools/test_peer.py` | Same peer + Go `internal/e2e` two-daemon test with iOS simulator loopback |
| Screenshots | `tools/shot.sh <page>` | `ios/tools/shot.sh <page>` via `simctl` for `devices/home/media/commands/browse/mic/camera/ring/pair/unpair/empty/icon` |
| Manual QA | `flux doctor/status/pair/send/...` | Same CLI script against iPhone on same LAN |

Add `FLUX_DEMO=1`-equivalent launch arg (`-FLUX_DEMO 1`) rendering sample computers with no backend, for App Review + screenshots.

### 6.3 CI (extend `.github/workflows/build.yml`)

- New `ios.yml` job (macos-15 runner): `xcodebuild build + test`, SwiftLint, `xcodegen`-diff check if used, unsigned IPA artifact.
- Release (`release.yml` analog): signed IPA + dSYMs + `SHA256SUMS`; TestFlight via App Store Connect API key secrets (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`); no AUR equivalent — App Store + optional ad-hoc IPA asset.
- Secrets hygiene: never commit `*.p12`, `*.mobileprovision`, `AuthKey_*.p8`, team IDs (mirrors "Keep SDK paths and keystores out of Git").

---

## 7. UX plan (SwiftUI, parity with Compose)

Screens (from Android `shot.sh` pages + desktop window pages in `docs/cli.md`):

- `Devices` (list + connection state + Turn off/Turn on Flux) → `Home` (per-computer overview) → `Media` (album art + controls) → `Commands` (runcommand list) → `Browse` (SFTP read-only) → `Mic` (level + Start/Stop) → `Camera` (+ `camera:<mode>` subpages: `text/qr/photo/document/webcam`) → overlays: `ring`, `pair` (key compare + Accept), `unpair`, `<page>@offline`, `empty` (no computers), `icon`.
- Desktop window pages (`overview/clipboard/files/notifications/media/messages/browse/commands`) stay desktop-side; iPhone Messages page shows iOS-unsupported state (see §4.5).
- Theming: match desktop theme watcher semantics where sensible (light/dark + accent); SF Dynamic Type + VoiceOver from day one.
- Navigation: `NavigationStack` + deep links (`flux://pair`, `flux://approve/<id>`, `flux://camera/<mode>`) for notification actions + Siri Shortcuts ("Send clipboard to Desktop", "Ring phone" is desktop-side).

Preview strategy: `#Preview` per screen with `FLUX_DEMO` fixtures + snapshot tests (mirror `make snapshot` for QML).

---

## 8. Milestones + acceptance criteria

### M0 — Spike (1 week)

- [x] `ios/` skeleton builds (SPM `swift build`/`swift test` on macOS; Xcode project + simulator/device run still open).
- [x] UDP/mDNS discovery helpers + plaintext identity exchange logic (unit-tested; live capture still open).
- [ ] Decision log: SSH lib choice, persistence choice, min iOS version.
- Acceptance: screenshot of discovered desktop in Xcode console + doc note of blocked entitlements.

### M1 — Pairing + trust (2–3 weeks)

- [x] Key/cert gen, `kdeconnect.pair` request/accept/reject, 8-char key match with Android vectors, Keychain trust store, unpair.
- [x] Live link (M1b): BSD sockets + SecureTransport do the acceptor's plaintext-first upgrade (see `ios/README.md` for the `Network.framework` rationale); E2E pairs against the desktop-role test peer with a byte-identical key, pinned reconnect skips pairing, restarts keep ID + cert. Real-`fluxd` CLI check still needs a Linux host or device (macOS cannot build `fluxd`).
- [ ] `flux discover/pair/status` green against real `fluxd` from the device (needs M1b on iOS hardware).

### M2 — Messaging primitives (2 weeks)

- [x] Ping/battery/clipboard/share/ring + desktop→iOS notifications with reply/actions.
  - Verified E2E through the loopback harness: desktop→phone ping,
    `battery.request` (answered via provider), clipboard + `clipboard.connect`,
    share text + URL, notification render, ring start + toggle-stop;
    phone→desktop battery, ping, clipboard, share text, Flux-internal
    notification (`--exercise-m2`); 8-char key recomputed from both DERs
    matches byte for byte; pinned reconnect skips pairing and sends welcome
    packets immediately. 108/108 tests green, Keychain-residue-free.
  - Reply/action scope (honest): desktop→phone `notification.reply`/`.action`
    packets parse and are logged+dropped (no mirror on iOS); phone→desktop
    reply/action builders exist for future Flux-internal use. `flux send`
    file *payloads* are M3: announcements parse (`payloadSize` +
    `payloadTransferInfo` port/tunnel) and queue in `PendingShareStore`.
  - Also done: `PairApproval` manual Accept path (`PairView` resolves it;
    timeout declines silently), `RingView` port of `RingOverlay`,
    `battery.request` added to advertised incoming (Android handles it too).
- Acceptance: `flux ping/clip/url/notify/ring` equivalents verified through
  the E2E harness; `flux send` file bytes need M3; `MaxPacketSize` +
  id-tolerance tests pass (extended with a 1 MiB clipboard round-trip).

### M3 — Files + browse (3 weeks)

- [x] Payload fetch + `flux.tunnel` send, progress UI events, SFTP browse signalling.
  - Verified E2E through the loopback harness (pinned, like M1b): desktop→phone
    1 KB + 10 MB classic and tunnel, 100 MB tunnel — all byte-identical
    (`sha256` both sides, `.part`+rename, exact-size check, `uniquePath`
    `name (2).ext`, ≤4/s progress); 0 B announcements dropped fetch-free on
    both modes (protocol-level: every implementation's `hasPayload` needs
    `size != 0`); phone→desktop upload byte-identical; browse tunnel
    established with `Home,Downloads` roots and `share_home`-off refusal
    honored. 8-char key recomputed from both DERs matches byte for byte.
    126/126 tests green, Keychain-residue-free.
  - Honest scope: the SSH session + SFTP list/download inside browse tunnels
    is M4+ (`takeBrowseTunnel(_:)` seam, `swift-nio-ssh` picked per Q4, no
    dependency vendored); serving iPhone files over SFTP stays deferred;
    Share Extension host wiring stays stubbed (in-app/`--send-file` path
    is what E2E covers).
- Acceptance: 0 B/1 KB/10 MB/100 MB round-trips; `share_home` on/off honored; tunnel tests vs. `internal/lan/tunnel_test`-equivalent fixtures.

### M4 — Media/commands/calls/Focus (2 weeks)

- [x] Packet layer: `mpris` state parse + `mpris.request` builders both
  ways (six Go verbs, `Seek`/`SetPosition`/`setVolume` fields),
  `runcommand` ordered-list parse + `runcommand.request` builders,
  telephony builder + `CallTracker` + `isCancel` flex, `flux.dnd`
  builder/parser + `DndGuard` — round-trip tests against Go/Android vectors.
- [x] Router: capability-gated routes + follow-up `requestNowPlaying`
  send (Android parity); desktop `mpris`/`runcommand` no longer log
  "no handler" in E2E (zero occurrences across the M4 transcripts).
- [x] `LinkRunner`: `nowPlayingProvider` answers player queries (same
  pattern as `batteryProvider`), emits playback/command/DND events.
- [x] Bridges: `CallBridge` (`CXCallObserver` → telephony),
  `FocusBridge` (Focus boolean → `flux.dnd` on change only),
  `NowPlayingBridge` (`MPRemoteCommandCenter` handlers + query read-back),
  desktop-DND banner (never sets Focus). Media + Commands SwiftUI screens.
- [x] Harness: `FluxTestPeer --exercise-m4`/`--now-playing`,
  `test_peer.py --m4`/`--expect-m4`; loopback E2E pairs with a
  byte-identical key, pinned reconnect skips pairing, `M4 EXPECTATIONS
  MET`, 163/163 tests green, Keychain-residue-free.
- [ ] `flux media *`, `flux commands`/`run` green against real `fluxd`
  from hardware (needs a Linux host or device; `fluxd` doesn't build on
  macOS). Loopback covers the wire both ways; the desktop side is
  unchanged Go (`PhoneMediaAction`, `handleRunCommand`, `handleTelephony`).
- [ ] CallKit on hardware: ringing/talking/missed flow, number
  unavailable by platform design (desktop shows "Unknown caller").
  Call-start media pause is `fluxd`-side (`pause_media_on_call`).
- [ ] Focus on hardware: authorization prompt + foreground refresh
  propagate the boolean; desktop→phone DND banners only.
- Acceptance: loopback E2E green (see `ios/README.md` "Media/commands/
  calls/Focus (M4)"); real-`fluxd`, on-device CallKit/Focus, and
  background behavior need hardware (same gate as D6/D7).

### M5 — Camera/mic/screen (4 weeks)

- [x] Packet layer: `flux.webcam` start/stop/config/error + `live`/`stop`/
  `config` replies, `flux.mic` start/stop + `live`/`stop`, `flux.screen`
  start/stop + `live`/`stop`, scan-text + `scan`/`photo`/`screenshot`
  capture flags — builders/parsers round-trip-tested against Go/Android
  vectors (11 settings keys, `micStart.check` defaults, Go config/reset
  shapes, Android reply defaults).
- [x] Router: capability-gated routes + reply events; a phone-side `start`
  stays unhandled. Desktop `flux.webcam`/`flux.mic`/`flux.screen` no
  longer log "no handler" in E2E (zero occurrences across the M5
  transcripts, `unadvertised` likewise zero).
- [x] `LinkRunner` + `StreamEngine`: pinned-TLS byte listeners off-thread
  (10 s connect timeout, Android `PinnedStream` parity), chunked writes
  through `LinkSender`, capture uploads with routing flags
  (`sendCaptures`, Android `sendCapture` parity), per-kind stream events.
- [x] Capture math: `WebcamConfig` (frame sizes, bitrates, merge/clamp/
  reset/restart), `AnnexB` + framer (Android golden frames byte-identical),
  `FrameGeometry`, `TextAssembly`, `Codes` + capture names, `CapturePlan`
  ledger — all ported with Android vectors.
- [x] Stream framing + sessions: PCM encode/peak/sine, `MirrorSize`
  fit/bitrate, per-kind session state machines + mic-with-webcam flag.
  `VideoToolbox` H.264 → shared-framer path passes a real on-machine
  encode spike (SPS/PPS before IDR); `AVAudioEngine` tap, Vision/code
  mapping, photo settings, VisionKit scan (iOS only), and
  `PhotoLibraryWatch` compile clean, hardware-gated.
- [x] UI: Mic, Camera (5 modes), and Mirror SwiftUI screens (state +
  closures + previews); Broadcast extension wired to an App Group config
  with a pinned out-connection (Xcode/iOS target).
- [x] Harness: `FluxTestPeer --exercise-m5`, `test_peer.py --m5`/
  `--expect-m5` (+ repeatable `--expect-file`, stream caps in the desktop
  identity like Go); loopback E2E serves webcam H.264 + mic PCM + screen
  H.264 plus scanned text/PDF + photo byte-identical (checksums match both
  sides), gets every desktop reply (live/config), sends every stop, and
  prints `M5 EXPECTATIONS MET`; pair key recomputed from both DERs +
  timestamp matches byte for byte; 260/260 tests green,
  Keychain-residue-free.
- [ ] `flux webcam/mic/screen [stop]` green against real `fluxd` from
  hardware (needs a Linux host or device; `fluxd` doesn't build on macOS).
  Loopback covers the wire both ways; the desktop side is unchanged Go
  (`runWebcam`, `runMic`, `runScreen`, `saveScan` routing).
- [ ] On-device runs: camera capture (AVFoundation + Vision + VisionKit),
  VideoToolbox webcam encode, mic tap, ReplayKit mirror into desktop
  `mpv`, photo-library watch uploads, background behavior (see D15–D18).
- Acceptance: loopback E2E green (see `ios/README.md` "Camera/mic/screen
  (M5)"); real-`fluxd`, on-device capture/encode/mirror, and background
  behavior need hardware (same gate as D6/D7).

### M6 — Approval (2–3 weeks + audit)

- [x] Packet layer: `flux.approve` request/enroll/cancel parsers + reply
  builders (approved/denied/failed/enrolled) — round-trip-tested against
  Go (`internal/approve/message_test.go`) + Android (`ApproveMessageTest`)
  vectors, including id/timeout defaults + clamp, question strings, and
  the 200-char error cut.
- [x] Keys: per-desktop P-256 alias `flux-approve-<computer device ID>`,
  Secure Enclave + `biometryCurrentSet` attribute builder, DER sign/verify
  round-trips with real keys, fail-closed matrix (wrong key, tampered
  field, replayed nonce, enrollment-proof-as-approval, P-384 refusal),
  `--forget` index coverage. The biometric touch itself is hardware-gated.
- [x] Router + `LinkRunner`: capability-gated routes, one-at-a-time store
  (busy/clock/no-key/invalid refusals answered on the wire), cancel,
  local timeout, off-thread decider with stale-answer drop. Desktop
  `flux.approve` no longer logs "no handler" (zero occurrences).
- [x] UI: full-screen prompt (ask / key-code / failed + previews) and the
  time-sensitive lock-screen notification + Approve/Deny category
  (content mapping unit-tested; over-lock delivery is device-gated).
- [x] Harness: `FluxTestPeer --exercise-m6`/`--approve-deny`/
  `--approve-delay`, `test_peer.py --m6`/`--m6-delay`/`--expect-m6`;
  loopback E2E verifies every phone signature with openssl against the
  enrolled pubkey (`Verified OK` over helper-made nonces), rejects
  replay/tamper/wrong-key, and proves stale/bad-nonce/cancel/timeout on
  the wire with matching key codes both sides; 304/304 tests green,
  Keychain-residue-free.
- [ ] `sudo -k; sudo true` approves via Face ID against real `fluxd`
  (needs a Linux host or device; `fluxd` doesn't build on macOS).
  Loopback covers the wire both ways; the desktop side is unchanged Go
  (`flux-approve` helper, `handleApprove` states).
- [ ] On-device runs: per-use biometric signing, enrollment-change
  invalidation + re-enroll, lock-screen notification actions, background
  approval delivery (see D19–D22).
- Acceptance: loopback E2E green (see `ios/README.md` "Approval (M6)");
  real-`fluxd` PAM, on-device biometrics/lock-screen/background, and the
  pre-TestFlight security audit need hardware (same gate as D6/D7).

### M7 — Hardening + TestFlight (2 weeks)

- [x] Background-reconnect UX: `LinkPresence` + `ConnectionBanner` (honest
  "Background suspended" copy), previews, 5 `FluxUITests`, `ContentView`
  seam (live source wiring needs the Xcode project, D7).
- [x] Battery audit: static pass (no background polling in `ios/Sources`);
  device Energy Log procedure documented, run needs hardware.
- [x] App Store metadata + review notes (`ios/AppStore/`: description with
  iOS limitations, review notes, release checklist mirroring
  `docs/releasing.md`, formal security audit closing the M6 review).
  Closes D8.
- [x] `PrivacyInfo`/entitlements/`Info.plist` audit (§3.3): Face ID purpose
  string added (M6 enrollment was dead on device without it), unused
  SystemBootTime/DiskSpace entries removed, background-modes gate
  documented, CI gains `swift build -c release`.
- [x] Keychain-residue fix (empty enrolled-index deletes the item) +
  M6 E2E re-verified after the change (`M6 EXPECTATIONS MET`, key codes
  match both sides, 310/310 green, `--forget` residue-free).
- [x] Screenshots via `ios/tools/shot.sh`: flow validated on the
  simulator (install + launch + screenshot renders Devices + banner).
  Device screenshots still open (needs the device install below).
- [x] Device install + run (D7 remainder): free-tier team + Developer
  Mode — app installs, launches, renders (Time Sensitive stripped for
  the free tier; duplicate-key plist incident fixed + documented).
- [x] App-layer link wired (unblocks D6): `LinkService` (TCP + mDNS
  publish + `LinkRunner`, `autoAccept: false`), `FluxApp` lifecycle +
  `PairView` sheet with 25 s auto-dismiss. Simulator: link stays down
  cleanly (`-34018` unsigned); Linux fluxd visible from the Mac via
  mDNS. Device publish + `flux discover` still open.
- [ ] D6 `flux discover` sees the phone from the Linux host (needs the
  device install above with the app open).
- [ ] TestFlight beta upload (needs paid team + App ID incl. D5, plus D7).
- [ ] `flux doctor` note for iOS limitations (proposed text in
  `ios/AppStore/release-checklist.md`; v1 rule — desktop owner lands it,
  no CLI changes from this track).
- Acceptance: partial. Checklist + audit + metadata + non-device
  hardening done; the TestFlight build itself needs D5/D7/hardware
  (same gate as D15–D22).

---

## 9. Ports of Android tooling

| Android `tools/` | iOS port | Notes |
| --- | --- | --- |
| `test_peer.py` | `ios/tools/test_peer.py` (fork with `--ios` identity + `flux.*` probes) | Must run over `adb forward`-equivalent? No — direct LAN or `simctl`-bridged networking; document simulator multicast limits (test on device) |
| `shot.sh <page>` | `ios/tools/shot.sh <page>` via `xcrun simctl io booted screenshot` + `FLUX_DEMO=1` launch args | Same page list + `@offline`/`empty`/`icon` variants |
| `fetch_icons.py` + `ICONS` + `ui/Icons.kt` | SF Symbols catalog + `FluxUI/Icons.swift` | No fetch needed; audit Apache-2.0 Material Symbols removal |
| `FLUX_DEMO=1` + `ANDROID_SERIAL` | `-FLUX_DEMO 1` launch arg + `SIMCTL_CHILD_` env / device UDID flag | Release builds ignore extras (same rule) |
| JVM tests | XCTest suites (see §6.2) | Import Android/Golden vectors verbatim |

---

## 10. Risks + mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Background link unsustainable | Phone shows offline when locked; approval requests missed | Fast-reconnect + honest UX + time-sensitive approval notifications; APNs relay as explicit v2 proposal, not silent scope creep |
| Multicast entitlement denied/delayed | No UDP discovery on device | Ship mDNS `NWBrowser` first; UDP as enhancement; document simulator-vs-device matrix |
| Notification/SMS/DND gaps disappoint | 1-star reviews "doesn't do what Android does" | Capability-gated UI + store copy + in-app "iOS limitations" page linked from Devices screen |
| Secure Enclave absence (older devices) | Approval keys fall back to Keychain | Graceful fallback + attestation note (mirrors "No key attestation" open risk in `approve.md`) |
| H.264 interop drift (Annex B, SPS/PPS, rotation) | Webcam/mirror black screen | Golden-frame tests from Android `H264Encoder` + live test against `ffmpeg/v4l2loopback` desktop path |
| SSH/SFTP lib bloat or license conflict | Browse delayed or rejected | Spike two options early; prefer Apache/MIT/BSD; keep license choice with source owner (repo currently `LicenseRef-unknown`) |
| App Review rejection (background modes, crypto) | Release slip | Minimal entitlements at M1–M4; add `audio`/broadcast/APNs justifications late with review notes + demo video |
| Scope creep (watchOS/macOS Catalyst) | Plan never lands | Explicit non-goals for v1 (§11) |

---

## 11. Non-goals (v1)

- No `fluxd`/CLI/Qt/shell-plugin changes beyond capability tolerance (already generic).
- No APNs relay server, no iCloud sync, no watchOS app, no Mac Catalyst port (revisit after iOS v1).
- No serving iPhone files over SFTP to desktop (client-only browse in v1).
- No SMS send/receive on iPhone, no global notification mirror, no programmatic DND-set.
- No Android Keystore StrongBox attestation parity beyond Secure Enclave best-effort (documents existing "No key attestation" open risk, does not fix it).

---

## 12. Open questions (resolve in M0)

1. ~~Exact UDP discovery port + broadcast payload~~ — confirmed: UDP 1716, TCP first-free 1716–1764 (`internal/lan/tls.go`); broadcast identity carries `tcpPort`, post-TLS identity must not. Implemented + E2E-verified in M1b.
2. ~~Cert profile~~ — confirmed `internal/proto/cert.go`: ECDSA P-256, serial 10, `CN=device ID`, `O=KDE`, `OU=KDE Connect`, −1y/+10y, ECDSA-with-SHA512. iOS issuer matches it; verified with Go `x509` + `openssl`.
3. Payload `port` vs `tunnel` selection rule — closed in M3: the sender
   chooses (tunnel iff the receiver advertises `flux.tunnel` outgoing, i.e.
   Go `Link.CanTunnel`); the receiver follows the packet's transfer info;
   phone→desktop is always classic (`ios/Sources/FluxProto/Transfers.swift`).
4. SFTP/SSH lib — decided in M3: `apple/swift-nio-ssh` (Apache-2.0) when a
   dependency can be vendored, `Citadel` (MIT) fallback, `libssh2` out (C
   interop). No dependency vendored in M3 (SSH bytes deferred to M4+);
   license choice stays with the source owner.
5. ~~Min iOS~~ — 17 (SwiftUI `@Observable` + `Network`/Security baselines); SecureTransport path compiles against the iOS 18 SDK (deprecated, functional).
6. Approval UX over lock screen — notification-action + `LAContext` flow approved by design review against `docs/approve.md` threat model.
7. Multicast entitlement lead time — submit Apple request in M0.
8. License — repo has no selected license; iOS plan must not preempt owner's choice; new `ios/` files inherit "preserve owner's choice" rule from `AGENTS.md`.

---

## 13. Immediate next actions

- [x] Create `ios/` skeleton per §5 + root `Makefile` `ios`/`ios-test` targets + `ios/README.md`.
- [x] Port `FluxProto` + vectors first (pure Swift, no entitlements) — unblocks all later phases.
- [x] `ios/tools/test_peer.py` loopback harness for identity + pair + ping (LAN direct, no `adb`).
- [x] Add `build.yml` iOS job (build + test, no signing) so PRs cover `ios/`.
- [x] M1 core: `kdeconnect.pair` session, Keychain trust + identity, P-256 cert (Go-profile, Go/openssl-verified), TLS pinning validator, Pair/Unpair SwiftUI.
- [ ] Request multicast entitlement + create App ID (multicast, App Groups, Push, Time-Sensitive Notifications, Broadcast Extension).
- [ ] M1b live link: STARTTLS-upgrade spike (plaintext identity before TLS on the acceptor), then `flux pair` green against a device.
- [ ] Draft App Store copy with iOS limitations section (notifications/SMS/DND/background) to avoid review/user-expectation debt.

---

## 14. Deferred-work log

One consolidated list of everything parked with a target. Code comments
(`M4+`, `deferred`, `stub`) and `ios/README.md` point here; this section is
the authority. Move an item out only by doing the work and checking it off
in its milestone section — never by deleting the row.

| # | Item | Parked in | Target | Status + pointer |
| --- | --- | --- | --- | --- |
| D1 | SSH session + SFTP list/download inside browse tunnels (read-only v1) | M3 | M4+ | Done 2026-09-28 (loopback E2E green; device proof open): Citadel 0.9.2 (MIT, exact pin in `ios/Package.swift` + `project.yml`, NIOSSH-direct fallback not needed) + swift-nio (ByteBuffer); `FluxProto/Browse.swift` (entry mapping/sort/kind + parent path, Android+Go parity); `FluxCore/BrowseSession.swift` (`LoopbackBridge` port + actor session: password auth, accept-any host key like Go `InsecureIgnoreHostKey`, 10 s connect timeout, 64 KiB downloads); take seam (`LinkRunner`/`LinkService.takeBrowseTunnel`, full offer on `sftpOfferReceived`); `FluxTestPeer --exercise-browse` + `test_peer.py --browse-ssh`/`--expect-browse` (`tools/browse_sftp_server.py`: asyncssh fixture server, fresh ed25519 key, one-time password); `BrowseScreen` + store + app wiring (request/list/download/close, 10 s no-answer, unique Downloads names). Proven: password auth + 2 fixture listings + `hello.txt` sha-identical both sides (`160e4d9c…`) + subdir list + `BROWSE EXPECTATIONS MET`, zero no-handler/unadvertised, 400/400 SPM tests, sim 382 pass + 18 skip, M4 re-green after the event touch, M3 `--browse` path intact. Lessons: SecureTransport read+write need ONE thread (two-thread relay heap-corrupted → malloc abort in SSLRead; the LiveChannel rule covers reads too); `SftpOffer` rides the whole offer on the event (creds never logged); asyncssh handlers may return sync values (maybe-await) and expect str paths; asyncssh stats `..` while listing (the harness jail clamps escapes to ROOT). Still open: device proof vs real `fluxd` (`share_home` on). Device 2026-09-28 (iPhone SE2, first run): list leg green — real offer (6 roots) → tunnel → `SFTP connection opened and ready` → `browse archlinux /home/ed: 15 entries`, screenshot shows roots chips + folders; re-open (new tunnel, 15 entries) green too. Download leg FAILED on hardware: tap 20 s after list → `open file` → instant `tcpShutdown` → `connectionClosed` (retry: `I/O on closed channel`); a previous session also closed after ~20 s idle with no tap. Diagnosis: the desktop dials browse tunnels WITHOUT keepalive (`internal/lan/tunnel.go` `OpenTunnel` has no `KeepAliveConfig`; main links have 10 s/5 s/×3) — an idle listing rots silently on Wi-Fi/NAT until the next tap trips over the corpse. Loopback idle repro first blamed the harness (its own pump timeouts, fixed), then went green at 25 s idle — the phone stack survives idle; the kill needs the LAN path. Fix (no desktop change, v1 rule): the phone arms its own end — `TunnelKeepalive` (10 s/5 s/×3, provider.go parity) in `BrowseSession.connect` + honest guard-fail status lines; loopback fixture gains a 600 KB `big.bin` (device-size proof, sha-identical). Retest with keepalive: STILL dead at 55 s idle — keepalive insufficient. Relay lifecycle logging (new build) names the killer: the phone's SecureTransport SSLRead on the tunnel fails `ioFailed(-50)` at the post-idle tap (desktop sees RST, zero logs) — the parked phone-as-Server `-50` shape, now with first evidence. Theory: iOS SecureTransport server-role sessions rot over ~20 s+ idle in a way kernel TCP keepalive cannot touch (it never reaches the TLS layer). Next fix in the same build: `BrowseSession` SSH warm-keeper (`getRealPath(".")` every 15 s while connected; failures ignored, next real op reports) + negotiated-TLS-version in the relay-up line (loopback forces 1.2/green; device negotiates with fluxd — version on record next run). Loopback re-green with keepalive+warm-keeper (REALPATH pings observed server-side). Companion notes: capture upload in the same window hit the parked `-50` (phone-as-Server, after heavy TLS activity) and stayed queued by design; Focus still reads false. Download leg 2026-09-28/29 (iPhone SE2, ~8 runs): 8 KiB + 100 ms pacing did NOT save the 614 KB zip — deterministic death a few DATA replies in (OPEN reply + several 8 KiB replies forwarded, counts vary), immediate AND 20–60 s idle taps, fresh AND reused sessions; 57 B txt + 15-entry lists + warm pings x3 stay green; loopback byte-identical incl. the real zip (sha `05b6f743...`). Exonerated locally (fragmenting-proxy loopback, macOS ST green throughout): TCP segmentation (MSS 536 clamp), small TLS records (1 KiB slicing), Go client+pkg/sftp stack (exact-lib repro), file content, TLS 1.2, idle time. Key discriminator: the 4.7 MB desktop-to-phone tunnel receive (`pipeExactly`, pure 64 KiB reads, full blast) is device-green, live-stream sustained writes are green, and the full SSH handshake (dozens of small R/W alternations) is green — while the relay (32 KiB reads + interleaved writes, paced) dies. Relay ST usage audited correct (blocking socket completes every record inside one SSLRead, one thread, serialized teardown), so the -50 is iOS-ST-internal, not a usage error; exact trigger still open (reply size vs count vs cumulative bytes). Next device build 2026-09-29 (Mac-verified): relay-up gains the cipher (`SSLGetNegotiatedCipher`; loopback `c02c` = ECDHE-ECDSA-AES256-GCM, compare on device), bare `wake t=/l=` spam replaced by size-bearing `t->l n` / `l->t n` lines, pacing 100->300 ms as a single-variable rate experiment (~23 s worst case for the zip; session cap is 1 h), dead-session evict (`BrowseError.isSessionDead`: `connectionClosed` drops the corpse so retaps say reopen), `warm ping ok` retired (keeper proven). Verified: 402/402 SPM, sim 384 pass + 18 skip, browse E2E green, M6 re-green, release green. Device run 2026-09-29 (new logs worked first try): cipher `c02c` on device == loopback `c02c` (ECDHE-ECDSA-AES256-GCM) — cipher EXONERATED. Death signature narrowed: `l->t 100` (OPEN) → `t->l 52` (HANDLE) → `l->t 68` (READ #1) → `t->l 4096` (HALF of the 8 KiB DATA) → `-50` on the next read. 300 ms pacing did NOT save it (died on the FIRST data, earlier than the 100 ms runs) — rate theory weakened decisively; size/fragmentation theory strengthened (a partial/split multi-segment reply at death, while every small-message alternation — handshake, 3444 B list, pings — survives). Evict worked (`session dropped (downloadFailed(connectionClosed))`), no `warm ping ok`, no wake spam. Next build 2026-09-29 (Mac-verified): 1 KiB SFTP reads, tight loop, no pacing — every round trip mimics the proven-green handshake pattern (single-segment/single-record W,R alternation; ~600 trips ≈ 6 s for the zip, session cap 1 h). Loopback green at 1 KiB (all three files sha-identical, BROWSE DONE). 402/402 SPM, sim 384 + 18, release green; M4/M6 exempt (untouched). Device proof 2026-09-29 (iPhone SE2, D1 DONE): 1 KiB tight reads downloaded `flux-master.zip` end to end — hundreds of `l->t 68` / `t->l 1076` cycles (full 1 KiB DATA replies, zero splits), short final `t->l 900`, orderly CLOSE, `browse downloaded flux-master.zip (614219 B)` = host `stat` 614219 B (sha `05b6f743...`, same as the loopback fixture). Root cause, stated with evidence: iOS SecureTransport server-role `SSLRead` fails `errSecParam (-50)` on multi-segment TLS replies (8 KiB DATA: partial 4096 then death; same cipher `c02c`, same server, same code), while single-segment/single-record round trips survive indefinitely (handshake, 3444 B lists, pings, now ~600 1 KiB reads); macOS ST tolerates any size. Fix shipped: 1 KiB SFTP download chunks, tight loop (handshake pattern). Honest warts on the way: first tap hit the parked `handshakeFailed(-50)` flake (retry green), and one mid-list `-50` in the churned session after it — the fresh session was perfect throughout. Follow-up (not blocking): probe 2–4 KiB chunks for speed (3444 B single reads survive, so headroom likely exists); tcpdump record-forensics only if it ever regresses. Cleanup 2026-09-29: per-chunk relay logs + `warm ping ok` retired after diagnosis (relay now logs 4 lifecycle lines per session: up/cipher, accepted, EOF, close); keeper `noSession` false alarm on teardown suppressed (cancelled tasks stay silent, genuine failures still log); frag-proxy scratch removed; host iptables verified clean (stock ufw only, no LOG rules). Re-verified after cleanup: 402/402 SPM, sim 384 pass + 18 skip, browse E2E green, M4/M6 exempt (untouched).
| D2 | SSH dial for classic `ip`+`port` SFTP offers | M3 | M4+ | Open. Only tunnel offers are E2E-held; classic logs and waits for D1. `LinkRunner` line `classic sftp offer`. |
| D3 | Serving iPhone files over SFTP (answer `sftp.request` with an offer) | pre-v1 (§4.7, §11) | post-v1 | Open. Phone logs `sftpServeRequested` and answers nothing. |
| D4 | Share Extension → host-app wiring (App Group handoff) | M3 | M4+ | Open. Extension stub receives; only the in-app/`--send-file` upload path is E2E-covered (`TransferEngine.sendFiles`). |
| D5 | Multicast entitlement request + App ID creation | M0 (§13) | before device testing | Declined by owner 2026-09-28 (staying on the free tier): discovery stays mDNS/`NWBrowser`-only (proven fine on hardware), App Groups + broadcast/share/notification extensions + Time-Sensitive + TestFlight stay gated until the owner revisits. |
| D6 | `flux discover/pair/status` green against real `fluxd` from hardware | M1 (§8) | device testing | Done (2026-09-27, iPhone SE2 + Linux `fluxd` on one Wi-Fi): discover lists the phone, pair shows byte-identical key both sides (`8EF13E39`, phone sheet screenshotted), Accept completes; unpair + CLI re-pair also proved the trust-reset path (key shown again, never silently re-trusted). |
| D7 | Xcode project + simulator/device run | M0 (§8) | device testing | Partially done: `ios/Flux.xcodeproj` generated from `ios/project.yml` (xcodegen; app + 8 frameworks + test bundles, free-tier debug entitlements); simulator build + `xcodebuild test` green (303 pass + 7 `-34018` XCTSkips that run on signed devices); sim install/launch/screenshot validated (`shot.sh` flow works). Fixed 3 latent iOS-only isolation errors SPM never sees. Device install (free-tier team + Developer Mode) still open. |
| D8 | App Store copy with iOS limitations section | M0 (§13) | M7 | Done (M7). `ios/AppStore/description.md` drafted from `ios/README.md` limitations + the M6 biometric note; review notes + release checklist + security audit beside it. |
| D9 | APNs relay server for background wake | pre-v1 (§3.2, §10) | v2 proposal | Open by design. Background links suspend; UX must stay honest. |
| D10 | watchOS app, Mac Catalyst port, iCloud sync | pre-v1 (§11) | post-v1 | Non-goal. Revisit after iOS v1. |
| D11 | SMS send/receive, global notification mirror, programmatic DND-set | pre-v1 (§§3.1, 4.4–4.5) | never on current iOS APIs | Platform gap, documented in-app + store copy. Revisit only if Apple adds an API. |
| D12 | Camera/mic/screen (M5), approval (M6), hardening/TestFlight (M7) | plan phases | M5–M7 | Partially done: M5 wire + logic + harness are E2E-held (see §8); M6 wire + logic + harness are E2E-held with openssl signature proofs (see §8), hardware runs split into D19–D22; M7 non-device work is done (banner UX, battery audit, App Store pack, PrivacyInfo audit, security audit, release checklist, CI release step — see §8), TestFlight upload + screenshots need D5/D7/hardware. Stubs in `FluxCamera/`, `FluxStream/`, extensions are now real code (hardware-gated where noted). |
| D13 | Phone `mpris` state publishing (outgoing `mpris` unadvertised, like Android; desktop media tab stays hidden for iPhone; album-art payloads ride on it) | M4 | post-v1 | Open. Query answers (`playerList`/state via `nowPlayingProvider`) are real + E2E-held; unsolicited publishing is not. |
| D14 | Call number for telephony (iOS exposes none to third parties; desktop always shows "Unknown caller") | M4 | never on current iOS APIs | Platform gap, documented in-app + README. Revisit only if Apple adds an API. |
| D15 | On-device camera capture runs: AVFoundation sessions, Vision text/QR (live + still), VisionKit document scan | M5 | device testing | Code-done 2026-09-28, device proof open: one-shot `Text/Code/PhotoCaptureSession` drains (30 s timeout, preview-bound via `CameraPreview`, result gates unit-tested) + `DocumentScanner` self-dismiss + `ContentView` closures wired (scan → review → Send; photo/doc → stage → outbox → `sendCaptures`); the upload half is loopback-proven (bytes + flags). Live runs need hardware: Vision/VisionKit/photo runs + preview render. Device proven 2026-09-28 (iPhone SE2): text scan → review → Send lands in `scan_dir` (57 B file on host), QR scan → Open + Copy actions confirmed on the desktop, two photo taps → 3.5 + 5.3 MB `photo_dir` uploads byte-count-identical with JPEG magic, re-scanned doc → valid 2.4 MB PDF in `scan_dir` (kill-proof queue unit-tested; hardware kill-reopen round-trip proven 2026-09-28: staged offline → swipe-kill → reopen → flushed on `.paired`, host file byte-identical). |
| D16 | On-device VideoToolbox webcam encode + AVAudioEngine mic tap runs (`flux webcam/mic` against a computer) | M5 | device testing | Producer seam built 2026-09-27 (`LiveOffer` chunks, per-kind cancel, `LiveStreamBox` + `LinkService` inlet, 5 tests, `--exercise-m5-live` loopback green with identical checksums); mic app wiring + device proof done same session (Start → 268800 B to desktop `live` → Stop → idle, host `microphone stopped` clean — via 5 device-driven fixes: stale listener fd, stop-first ordering, `LiveChannel`, SIGPIPE ignore, generation guard). Webcam app wiring code-done same session (Mac-verified): `WebcamProducer` (AVCapture drain → shared `H264VideoEncoder` → chunks, front/back switch + zoom/exposure/WB/mirror live, center-crop to the announced size, `CameraAccess` gate; 8 tests incl. real-buffer crop proofs), `WebcamPreferences` persistence, `LinkRunner.webcamConfigReceived` now carries the desktop partial, `RemoteScreensState` webcam status, `ContentView` Camera screen (webcam tab live; text/QR/photo/document tabs render with honest next-run stubs), `FluxApp` session wiring mirroring the mic (generation guard, 3 s RST-echo grace, companion mic via the withWebcam flag, geometry-change restart, encoder-death announce).   Verified Mac-side: `swift build`, 355/355 SPM tests, sim build + 344 pass / 11 skip / 0 fail, M5-live + M6 loopbacks re-run (`M5 EXPECTATIONS MET` with a desktop config partial flowing, `M6 EXPECTATIONS MET`, zero residue).   Device proof 2026-09-27/28 (iPhone SE2, see README findings 47–51): Start → `live` on `/dev/video0` as Flux Camera, sustained 15.4/5.7/8.8 MB sessions, legible 1280x720 frame grabs, `set zoom=2` live + `reset` visual, desktop-initiated restart fully console-proven (`config` partial → `done` → fresh offer → `live` at 1920x1080 with frames), `webcamStopReceived` console-proven via a coordinated host stop, withWebcam companion proven (auto mic start mid-stream + same-second joint stop in the journal), host + phone stops clean, no crash (six transient `handshakeFailed(-50)`s along the way, never twice in a row — retries always succeed; root cause parked with a candidate fix direction). Done 2026-09-28. Known v1 gap: color-matrix keys (brightness/contrast/saturation/warmth) are stored + reported but not image-applied (no `AVCapture` control; Android does it in GL). Mirror-screen presenting still open. |
| D17 | ReplayKit Broadcast Upload Extension run: picker, App Group `screen.json`, pinned out-connection, desktop `mpv` mirror | M5 | device testing | Hard-gated on D5 (verified by code read 2026-09-27, no device needed): the extension is excluded from the free-tier project, and without the App Group entitlement `containerURL` returns nil → `ScreenBroadcastConfig.load()` fails → broadcast ends "not configured". Needs paid team + App ID + hardware. No input control, same as Android. |
| D18 | PhotoLibraryWatch live run: full-access prompt, screenshots/camera-roll mapping, foreground/queued upload | M5 | device testing | Done 2026-09-28 (iPhone SE2 + Linux `fluxd`): full-access grant + toggles on; foreground scan `found=4 uploaded=4 unresolved=0 sent=0`, all four screenshots staged/sent/completed on the phone and byte-identical with PNG magic in `~/Pictures/flux/screenshots/` (flag routing proven); offline queue proven by the doc round; Limited-access honestly manual-only. Predicate-fetch rewrite (was quadratic) + screenshot exclusivity + scan logging + kill-proof outbox along the way. |
| D19 | Real-PAM approval check: `sudo -k; sudo true` approves via Face ID against Linux `fluxd` | M6 | device testing | Done (2026-09-27): enroll green (key code `9338 0F33 1952 6EA4` byte-identical, proof verified) and `sudo -k; sudo true` approved via Touch ID — `approvePromptReceived(kind:request)` → `flux.approve (approved) sent=true` → `approveAnswered(result:approved)` → sudo succeeded with no password. First passwordless sudo via iPhone. |
| D20 | On-device biometric runs: per-use Face ID / Touch ID signing, enrollment-change invalidation + re-enroll flow | M6 | device testing | Done (2026-09-27, iPhone SE2 Touch ID + Linux `fluxd`, real PAM): per-use signing proven (D19); after adding a fingerprint, Touch ID passes and the Enclave refuses (CryptoTokenKit `-3`, AKSError=-536362999 — a second error shape for dead keys besides `errSecAuthFailed`), the app shows the enroll-again screen, the dead key is deleted, `sudo flux approve enroll` re-enrolls with a user-compared key code, and the next `sudo -k; sudo true` approves passwordless. Full console transcript on file (`denied` → `failed(biometryChanged)` → `enrolled` → `approved` across four requests). |
| D21 | Lock-screen notification actions for approval prompts | M6 | device testing | Done (2026-09-27, iPhone SE2 + Linux `fluxd`): time-sensitive prompt notification arrives over the lock screen; long-press reveals Approve/Deny (collapsed notifications show no buttons — normal iOS behavior, documented in the runbook); Approve → Touch ID → `sudo true` passwordless, Deny fails closed to the password. The biometric gate runs before any signature in both paths. |
| D22 | Background approval delivery (link suspended, notification wakes app) | M6 | device testing | Done (2026-09-27, iPhone SE2 + Linux `fluxd`): after a five-round diagnosis the root cause was the `willPresent` delegate passing `.banner` without `.list` (banner-only, never reaches Notification Center) — fixed, diagnostic content changes reverted. Proven: prompt notification lists in NC foreground and backgrounded, Approve from NC after backgrounding + Touch ID gives passwordless sudo. Grace + honest password fallback intact. |
| D23 | App-originated packet send path (phone→desktop telephony, Focus `flux.dnd`, runcommand requests) | M4 | device testing | Partially done (2026-09-27): `LinkRunner.liveSend` publishes each session's lock-serialized sender and `LinkService.send` fans app packets out over live runners (false with no link up, never half-sent); `CallBridge`/`FocusBridge`/`NowPlayingBridge` are wired in the app (provider answers desktop player queries, media actions drive the command center, Focus changes send). Unit-tested (`LiveSendBox` cycle, no-session send false) + M6 loopback re-verified after the change (`M6 EXPECTATIONS MET`, key codes match, zero residue). Still open: CallKit ringing/talking/missed + Focus boolean flows on hardware; Commands-screen run proven on hardware 2026-09-27 (list renders, 3 taps = 3 journal `iPhone runs` lines); Media-screen phone→desktop control proven same session (mpv stand-in: Pause → `Paused`, Play → `Playing` via playerctl); M5 live stream start rides on this path next. Captures upload fan-out built 2026-09-28 (`LiveUploadBox` per runner + `LinkService.sendFiles/sendCaptures`, the D23 packet pattern for uploads; `TransferEngine` now takes a send closure like `StreamEngine`): loopback-proven (`UploadLiveTests` 4/4 byte-identical + flags, pre-attach hold, detach drop) with M5 + M6 loopbacks re-green after the refactor (371/371 tests, `--forget` clean). CallKit fully proven on hardware 2026-09-28 (mid-ring foreground over the fast redial; `ringing` → desktop pause, decline → `missedCall` + cancel → resume, answer → `talking` → hangup → cancel + resume — journal + playerctl verified throughout, "Unknown caller" by design). Still open: Focus boolean flows on hardware (device reads false — parked Apple quirk). |

---

## Appendix A — Packet-type checklist (from `identity.go`)

`kdeconnect.identity`, `kdeconnect.pair`, `kdeconnect.ping`, `kdeconnect.battery`, `kdeconnect.clipboard`, `kdeconnect.clipboard.connect`, `kdeconnect.share.request`, `kdeconnect.share.request.update`, `kdeconnect.notification`, `kdeconnect.notification.request`, `kdeconnect.notification.reply`, `kdeconnect.notification.action`, `kdeconnect.findmyphone.request`, `kdeconnect.runcommand`, `kdeconnect.runcommand.request`, `kdeconnect.mpris`, `kdeconnect.mpris.request`, `kdeconnect.sftp`, `kdeconnect.sftp.request`, `kdeconnect.sms.messages`, `kdeconnect.sms.request`, `kdeconnect.sms.request_conversations`, `kdeconnect.sms.request_conversation`, `kdeconnect.connectivity_report`, `kdeconnect.telephony`, `flux.tunnel`, `flux.webcam`, `flux.dnd`, `flux.mic`, `flux.screen`, `flux.approve`.

iOS v1 implements all except `kdeconnect.sms.*` incoming and full `kdeconnect.notification` outgoing mirror (see §§4.4–4.5).

## Appendix B — Android manifest surface to cover

`INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `CHANGE_NETWORK_STATE`, `FOREGROUND_SERVICE(+CONNECTED_DEVICE)`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`, `USE_FULL_SCREEN_INTENT`, `VIBRATE`, `WAKE_LOCK`, `QUERY_ALL_PACKAGES`, `CAMERA`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS`, `ACCESS_NOTIFICATION_POLICY`, `READ_MEDIA_IMAGES` (+`VISUAL_USER_SELECTED`, legacy `READ_EXTERNAL_STORAGE`), `RECORD_AUDIO`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `USE_BIOMETRIC` — each mapped in §3.1; activities (`Main/Share/Ring/Approve`), services (`FluxService/ScreenMirrorService/NotificationListener`), and `BootReceiver` mapped in §§4–5.

## Appendix C — References

- `README.md`, `docs/README.md`, `docs/architecture.md`, `docs/android.md`, `docs/cli.md`, `docs/features.md`, `docs/camera.md`, `docs/configuration.md`, `docs/approvals.md`, `docs/approve.md`, `docs/ipc.md`, `docs/development.md`, `docs/releasing.md`
- `skills/omarchy-flux/SKILL.md` + `references/`
- `internal/proto/`, `internal/lan/`, `internal/core/`, `internal/approve/`, `cmd/flux-approve/`
- `android/app/src/main/java/org/omarchy/flux/` (protocol/net/core/service/ui/camera/scan/webcam/mic/screen/stream)
- `android/app/src/main/AndroidManifest.xml`, `android/app/build.gradle.kts`, `android/tools/`
