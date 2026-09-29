# Flux for iOS

Native iOS app with feature parity to `android/` where iOS allows it.
It speaks the same KDE Connect protocol v8 + Flux extensions to the same
`fluxd`, with no desktop protocol changes. See [`docs/ios-plan.md`](../docs/ios-plan.md).

> Status: M1 pairing + trust, M1b live link, M2 messaging primitives,
> M3 files + browse signalling, M4 media/commands/calls/Focus,
> M5 camera/mic/screen, M6 approval, **M7 hardening (non-device parts)**.
> `FeatureRouter` routes ping/battery/clipboard/share/ring/desktop-notifications
> with pairing + capability gates, `PairApproval` gives `PairView` a manual
> Accept path, and `RingView` ports the Android ring overlay. `TransferEngine`
> fetches payloads (classic + `flux.tunnel`), serves phone→desktop uploads
> (files + captures with `scan`/`photo`/`screenshot` flags), and opens browse
> tunnels; SFTP offers parse with `share_home`-off refusals. M4 adds desktop
> media state + control (`flux media *`), runcommand list/run, telephony
> events, and Focus→`flux.dnd`, with CallKit/Focus/Now-Playing bridges and
> Media + Commands SwiftUI screens. M5 adds `flux.webcam`/`flux.mic`/
> `flux.screen` packets, `StreamEngine` pinned-TLS byte listeners, the full
> capture math (settings, Annex B, geometry, text assembly, codes, ledger),
> PCM/mirror framing, session state machines, a working VideoToolbox H.264
> path, Mic/Camera/Mirror screens, and the ReplayKit extension shape.
> E2E against the
> desktop-role test peer moves 1 KB/10 MB/100 MB byte-identical both ways
> with a byte-identical key, exchanges the full M4 packet set with zero
> "no handler" lines, and streams webcam H.264 + mic PCM + screen H.264 plus
> scanned text/PDF + photo byte-identical with a byte-identical key and an
> `M5 EXPECTATIONS MET` verdict. **M6 adds `flux.approve` enroll/approve/
> deny/cancel/timeout with openssl-verified DER signatures, an
> `M6 EXPECTATIONS MET` verdict.** **M7 adds the honest background-suspended
> banner (`LinkPresence` + `ConnectionBanner`), the App Store pack
> (`ios/AppStore/`: description, review notes, release checklist, formal
> security audit), the `PrivacyInfo`/entitlements/`Info.plist` audit
> (Face ID purpose string, unused API entries removed), a Keychain-residue
> fix, and a CI release-build step.** **Device track 2026-09-27: Touch ID
> enroll/approve/deny proven on hardware (D19 done); approval app wiring
> for D20 (enroll-again error + `.failed` phase), D21 (lock-screen
> Approve/Deny actions), D22 (background grace), and the D23 app-send path
> with M4 bridge wiring (NowPlaying provider, CallKit/Focus observers,
> media/command/DND/transfer/stream status surfacing) — 325 unit tests
> green, M6 loopback re-verified (`M6 EXPECTATIONS MET`, byte-identical
> keys), Keychain-residue-free.** TestFlight
> upload, screenshots, and all on-device runs stay parked (D5/D7/D15–D22;
> see the deferred-work log).

## Layout

| Path | Content |
| --- | --- |
| `Package.swift` | SPM package: `FluxProto`, `FluxNet`, `FluxCore`, `FluxFeatures`, `FluxApprove`, `FluxCamera`, `FluxStream`, `FluxUI` |
| `App/` | `@main` app, `Info.plist`, entitlements, `PrivacyInfo.xcprivacy` |
| `Sources/` | One directory per module above |
| `Extensions/` | Share, Broadcast (ReplayKit), and Notification Service stubs |
| `Tests/` | `XCTest` suites with Go/Kotlin vectors (must stay byte-identical) |
| `AppStore/` | M7 store description, review notes, release checklist, security audit |
| `tools/` | `test_peer.py` (LAN, no `adb`), `shot.sh` (`simctl` screenshots) |

## Prerequisites

- macOS 14+ with Xcode 16+, iOS 17+ device + simulator.
- Apple Developer team (free tier OK for debug; paid for TestFlight,
  broadcast extension, and the multicast entitlement).
- No `ANDROID_HOME`/JDK; instead `xcode-select`, `xcrun simctl`.

Request the multicast entitlement (`com.apple.developer.networking.multicast`)
early — approval can take days. Until granted, discovery uses mDNS-only via
`NWBrowser`; UDP broadcast is an enhancement.

## Build and test

From the repository root:

```sh
make ios          # swift build of the ios/ package
make ios-test     # swift test of the ios/ package
```

Or directly:

```sh
cd ios
swift build
swift test
```

## Xcode project (D7, simulator done, device open)

`ios/Flux.xcodeproj` is generated from `ios/project.yml` (`xcodegen
generate`; xcodegen is installed on the dev Mac). It holds the app target
(`App/FluxApp.swift`, `Info.plist`, debug entitlements) + one framework
per SPM module (so the `import FluxCore` boundaries hold) + unit-test
bundles. **Regenerate after adding/removing files** — a stale project
silently drops them (caught once already: `TestKeychain.swift`).

- Simulator build: `xcodebuild -project Flux.xcodeproj -scheme Flux
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
  (no signing needed). First green 2026-09-26 after fixing three latent
  iOS-only isolation errors SPM macOS builds never see (`DocumentScanner`
  `@MainActor` vs. nonisolated delegate protocol,
  `BatteryBridge`/`ClipboardBridge` UIKit main-actor access,
  `FluxApp.swift` missing `import FluxUI`).
- Simulator tests: same command with `test` → **TEST SUCCEEDED, 303 pass
  + 7 skip, 0 failures.** The 7 skips are the permanent-Keychain tests:
  unsigned simulator bundles get `-34018` (`errSecMissingEntitlement`)
  on permanent writes, so they `XCTSkip` with a message
  (`TestKeychain.loadOrCreateIdentity`, `ApproveKeysTests` probe) and
  execute for real on signed devices. SPM macOS runs cover them fully.
  Test bundles carry `Tests/FluxTests.entitlements` (keychain access
  group); the app target needs the same group on device
  (`App/Flux-Debug.entitlements`).
- Simulator run: install + launch + screenshot works, which also
  validates `shot.sh` end-to-end (first render: Devices + the M7
  "No computers online" banner, dark mode).
- Free-tier shape: no multicast entitlement (mDNS fallback), no
  `aps-environment`, no App Groups, no extensions — all need a paid team
  (D5). Debug installs also need iOS Developer Mode
  (Settings → Privacy & Security → Developer Mode) and re-signing weekly.
- Device run: open the project in Xcode, pick the Apple-ID team in
  Signing & Capabilities, Run on the phone. Then D6 (`flux discover`
  from the Linux host while the app is open) and the D15–D22 backlog.
- Free-tier debug entitlements (`App/Flux-Debug.entitlements`) carry only
  the keychain access group: Time Sensitive was removed 2026-09-27
  (personal teams can't sign it; notifications degrade to regular
  interruption, actions unaffected). A duplicate-key edit briefly broke
  the plist and Xcode fell back to cached entitlements — fixed, `plutil`
  clean; if profile errors persist, Clean Build Folder + nuke
  DerivedData before assuming the App ID is poisoned server-side.

## Device track (D6/D7): app-layer link (stage A+B done, device proof open)

The M1b link stack lived in `FluxTestPeer` only, so `flux discover` saw
nothing. `FluxCore/LinkService.swift` now owns the app link: persisted
identity + cert (Keychain), first-free TCP 1716–1764, mDNS publish of
`_kdeconnect._udp` (instance name = device ID, TXT
`id/name/type/protocol`, Go `mdns.go` contract verbatim — no UDP
broadcast on free tier), one `LinkRunner` per inbound connection
(`autoAccept: false`, prompts held in `pairApproval`), events forwarded.
`FluxApp` starts it on launch + foreground, stops on background
(`.suspended` banner), maps state to `LinkPresence`. Stage B:
`.pairRequested` now carries `peerId`, and the app presents `PairView`
(compare + Accept/Decline → `pairApproval.resolve`); the sheet
auto-dismisses at the 25 s incoming expiry so no stale verdict can
pre-answer a future prompt.

- Simulator evidence: the app runs but the link stays down — unsigned
  simulator binaries get `-34018` on permanent key creation, so `start()`
  throws cleanly (offline banner, no crash, nothing listens on
  1716–1720, no mDNS record). The signed device is the real test.
- First-device finding (2026-09-27): no Local Network prompt appeared
  because the link   died before its first socket — the iOS branch of
  `TLSIdentity.makeIdentity` queried a `kSecClassIdentity` item that
  nothing ever stored. It now persists the certificate under `label`
  (delete-then-add) before the lookup. If the prompt still doesn't
  appear, read the `flux:` lines in Xcode's debug console — `link start
  failed:` names the next suspect (e.g. permanent-key creation).
- Second-device finding: the prompt was still absent after the fix, so
  the link status is now on-screen — `ContentView(status:)` shows the
  last link log line under the banner (`FluxApp` feeds it from link
  events + the `start()` catch), so device debugging no longer needs
  Xcode attached. Report that line verbatim.
- Third-device finding (2026-09-27): status showed `listening tcp=1717`
  but no mDNS record reached the LAN and no prompt appeared — the
  `NetService.publish()` ran on a concurrency Task thread with no
  runloop, so it silently never published (passive BSD bind/listen
  doesn't trigger the prompt either). `LinkService` now hops to the
  main thread for `publish()`; publishing triggers the prompt.
- Fourth-device finding: `publish()` on main, delegate still silent
  across 4+ attempts, so `LinkService` runs a bounded 10 s self-browse
  per start and logs every instance seen (`BrowseDelegate`, names only,
  then stops — no polling). Reading it: Linux's id without ours = RX
  works, publish broken; ours present = publish landed locally (LAN
  visibility/permission next); nothing at all = device mDNS dead
  (check Wi-Fi SSID match + VPN).
- Fifth-device finding (2026-09-27, environment, not code): the phone
  was USB-tethered through the Mac's Internet Sharing (NAT subnet),
  never on the Wi-Fi LAN — zero `browse found` lines, no prompt, TCP
  bound fine. mDNS multicast cannot cross NAT and the desktop cannot
  dial inbound to a NAT'd phone, so **the phone must join the same
  Wi-Fi SSID (same L2) as the Linux host**. Keep USB plugged for the
  Xcode console; Wi-Fi carries the Flux traffic.
- Sixth-device finding (2026-09-27, the actual prompt blocker): the
  installed app had NO `NSLocalNetworkUsageDescription` at all — the
  source `App/Info.plist` had been rewritten to 4 keys (tab-normalized;
  not xcodegen, verified by checksum — likely the Xcode plist GUI), so
  no prompt was possible and LAN access was silently denied (publish +
  browse dead both ways while TCP bound fine). Restored verbatim +
  `GENERATE_INFOPLIST_FILE: NO` on the app target (frameworks keep the
  generated plist), bundle verified with all 7 keys, and `ios.yml` now
  fails fast if a usage description goes missing. If you open
  `Info.plist` in Xcode, check `git diff`-style that no keys vanished
  (no git here — compare against this README list).
- Seventh-device finding (2026-09-27): with generation off, nothing
  injects the bundle fundamentals, and device `installd` rejects the
  app (`MissingBundleExecutable`) — the simulator doesn't validate.
  `App/Info.plist` now carries them explicitly (`CFBundleExecutable`,
  `CFBundleVersion`/`ShortVersionString` from `MARKETING_VERSION 0.1.0`
  + `CURRENT_PROJECT_VERSION 1` in `project.yml`, package type,
  `LSRequiresIPhoneOS`, min OS, device family); the CI guard covers
  the executable/identifier/version keys too.
- Device facts learned from the install log: iPhone SE (2nd gen,
  iPhone12,8), iOS 18.2 — so biometric runs (D20) will be Touch ID,
  not Face ID. Min OS 17 holds.
- Eighth-device finding (2026-09-27, first real interop): prompt
  allowed, mDNS published, self-browse found self, and the Linux host
  dialed in (`plaintext identity: archlinux`) — then every handshake
  died `-50` signing with an `ECPublicKey`. Keygen stores public +
  private items under one tag and iOS identity formation grabbed the
  public half (the M6 two-items finding, now with teeth). Fix:
  `IdentityKeys.loadOrCreate` deletes the public item on both paths
  (nothing reads it — SPKI re-derives), and the iOS `makeIdentity`
  branch does a 1-byte signing self-test to fail fast at startup
  instead of per-connection. Loopback M6   re-verified after the change
  (`M6 EXPECTATIONS MET`, key `BE5B1EF7` byte-identical, zero
  residue) — now the phone needs the reinstall to prove it.
- Ninth-device finding (2026-09-27, **handshake green**): after the
  public-item fix, `TLS identity OK: archlinux` — full mutual-TLS link
  with real `fluxd`, mDNS both ways, packets flowing (desktop
  notification request correctly answered with the no-mirror refusal).
  D6 discovery is proven against hardware; pairing (`flux pair` +
  `PairView` sheet) is next.
- Tenth-device finding (2026-09-27, **paired**): `flux pair` from the
  Linux host showed the key sheet on the phone; user compared + tapped
  Accept → paired. First hardware pairing (D6 pairing half). Key
  byte-identity check + post-pair packet E2E still open.
- Eleventh-device finding (2026-09-27, **D6 done**): unpair + CLI
  re-pair (`flux unpair`/`flux pair "iPhone"`) proved the trust-reset
  path on hardware and gave the byte-identity proof: desktop
  `Confirm 8EF13E39` == phone sheet `8EF13E39` (screenshot on file).
  `flux discover` lists the phone; handshake + packets flow with real
  `fluxd`. Post-pair packet E2E (ping/notify/ring/battery) is next.
- Twelfth-device finding (2026-09-27, app was mute): `flux ping` etc.
  with correct `--device` syntax printed nothing anywhere — not a link
  failure but missing app wiring: `FluxApp.onEvent` only printed `.log`
  events, and the M2 bridges (`DesktopNotificationBridge`,
  `RingerBridge`, `RingView`, clipboard apply) were never called. The
  app now prints every event, renders desktop notifications (auth
  requested on launch), shows the ring overlay + vibrates, and applies
  clipboard/shares to the status line. Packets were arriving all along
  (clipboard.connect + notification-list proved it).
- Thirteenth-device finding (2026-09-27, **startup crash, diagnosed
  via the `.ips` report**): `EXC_BREAKPOINT` on thread
  `com.apple.usernotifications.UNUserNotificationServiceConnection.call-out`
  — `closure #1 in FluxApp.startLink()`, i.e. the notification-auth
  completion created in the async `.task` context and invoked on the
  framework queue (`swift_task_isCurrentExecutor` assert). Any
  framework completion created in a MainActor/async context traps the
  same way. Fixed by detaching all four sites (`FluxApp` auth request,
  both notification `show()`s, approve prompt `show()`,
  `FocusBridge.requestAccess`) to `Task.detached` + await (async
  `notificationSettings()`/`add()`/`requestAuthorization`, min iOS 17
  covers them). Rule: framework   callbacks must never inherit the
  caller's actor.
- Fourteenth-device finding (2026-09-27, full M2 packet E2E): ping +
  notify + ring all arrive and handle — ring heard, ping/notification
  on console. Notification didn't banner: iOS suppresses banners for
  the foreground app without a `willPresent` delegate (event arrived,
  silent tray delivery). Added `ForegroundNotificationDelegate`
  (banner+sound+badge, weak-held for app lifetime, assigned on main).
  Ping, by design, has no phone UI (console/status line is the proof,
  like Android's toast-less receipt).
- Fifteenth-device finding (2026-09-27, battery wired): `flux status`
  showed `battery:null` — the app had no provider and sent no welcome
  packets. `BatteryCache` (main-fed, Sendable-read, unit-tested) +
  `LinkService` battery provider + Android-parity welcome burst
  (battery state + empty `clipboard.connect`) now answer
  `battery.request` and populate desktop state.
- Sixteenth-device finding (2026-09-27): `flux clip` arrived but was
  dropped (`ignored ... (clipboard sync off)`) — the app hardcoded the
  router gate closed. `clipboardSync: true` is correct: the iOS
  restriction lives in `ClipboardBridge.write` (foreground-active
  only), so router-open + foreground-gated = the designed
  foreground-only sync.
- Eighteenth-device item (2026-09-27, **approve UI for D19**):
  `FluxCore/ApproveFlow.swift` is the production decider (test-signer
  mirror with biometric keys + per-use Touch/Face ID auth, fail-closed
  mapping, enrollment self-check, key-code ledger); `FluxApp` presents
  `ApprovePromptScreen` (ask → enrolled-code / failed phases,
  25 s+ auto-dismiss like pairing) and resolves accept/deny/close.
  `LinkService` takes the decider as a parameter. Next: `sudo flux
  approve enroll` + `sudo -k; sudo true` against real `fluxd` (D19/D20
  Touch ID signing on the SE2).
- Nineteenth-device finding (2026-09-27, **enroll green, D19 half +
  D20 signing proven**): `sudo flux approve enroll` → phone enroll
  prompt → **Touch ID with a real finger** → enrolled reply, key code
  byte-identical both sides (`9338 0F33 1952 6EA4`, phone screenshots)
  → desktop verified the proof signature, user typed `y`, key file
  written. The Secure Enclave biometric gate works on hardware.
  Still open: `sudo flux approve enable` + the `sudo -k; sudo true`
  approval run.
- Twentieth-device finding (2026-09-27, approval prompt renders):
  `sudo -k; sudo true` after `approve enable` shows the full ask
  screen on hardware (service/user/host, TTY `/dev/pts/1`, request
  time, fatigue warning, Deny/Approve). Awaiting the Approve tap +
  Touch ID + sudo result for D19.
- Twenty-first-device finding (2026-09-27, **D19 done**):
  `approvePromptReceived(kind:request, id:a399164f…)` →
  `flux.approve (approved) sent=true` →
  `approveAnswered(result:approved)` → `sudo true` with no password.
  First passwordless sudo via iPhone (Touch ID + Secure Enclave,
  helper-verified). Deny path (fail-closed to password) still open.
- Twenty-second-device finding (2026-09-27, **deny green**):
  `approvePromptReceived` → Deny → `flux.approve (denied)` →
  `approveAnswered(result:denied)` → Linux falls back to the sudo
  password prompt, which still works. Fail-closed to password proven
  on hardware. M6 approve (enroll/approve/deny) fully proven with
  real PAM + real finger.
- Seventeenth-device finding (2026-09-27, **M2 desktop→phone complete
  on hardware**): `clipboardReceived(... "paste me on the phone")` +
  paste works in Notes. Ping/notify/ring/clip/battery all proven
  against real `fluxd`. Next: share URL + `flux send` file receive
  (M3 payload path on device).
- Twenty-third-device item (2026-09-27, **approval + M4 app wiring,
  code-done/device-open**): no user steps yet — Mac-side session.
  `ApproveFlow` learned the D20 remainder (vanished biometrics →
  enroll-again + key deletion, lockout → passcode message with the key
  kept, stale-resolve guard, read-once `failureMessage` for the
  `.failed` prompt phase); `FluxApp` posts/dismisses the time-sensitive
  prompt notification per request (D21), routes lock-screen Approve/Deny
  to the held prompt, shows failures instead of dismissing them, and
  holds a short background-task grace for open prompts (D22); the new
  D23 `LinkService.send` fans phone→desktop packets over live runners
  and `NowPlayingBridge`/`CallBridge`/`FocusBridge` are wired in
  (provider answers desktop player queries; media actions drive the
  command center; Focus changes send; incoming DND banners). Media,
  command-list, DND, transfer, and stream events all surface on the
  status line now. Verified Mac-side: `swift build`, 325/325 SPM tests,
  sim build + 318 pass / 7 skip / 0 fail, M6 loopback re-run after the
  session-flow change (`M6 EXPECTATIONS MET`, enroll + approve
  `openssl Verified OK`, key code `1811 0809 A2D1 097A` both sides,
  pair key `77EBA37A` recomputed byte-identical, zero "no handler" /
  "unadvertised"), `--forget` residue-free. After the user rebuilds in
  Xcode, the next device run must prove: enroll-again after a
  fingerprint change, lock-screen Approve/Deny, backgrounded-prompt
  answer,   `flux media`/player queries, and the Focus boolean.
- Twenty-fourth-device finding (2026-09-27, **Touch ID misread, not a
  dead key**): after adding a fingerprint, `sudo -k; sudo true` showed
  "The phone could not sign the request." That exact string proves Touch
  ID itself never completed (a dead key would show the "biometrics
  changed, enroll again" screen instead) — almost certainly a finger
  misread on the new enrollment. App fix, Mac-verified: one misread now
  answers "Face ID or Touch ID did not succeed. Try the request again."
  (key kept), "Enter Password" on the biometric dialog counts as a
  decline, and every auth/sign failure logs its OS error code to the
  console + status line (`approve auth failed id=…` / `approve sign
  id=…`) so a misread is never again mistaken for an invalidated key.
  The enroll-again run (D20) is still open: retry the sudo first — if it
  succeeds with Touch ID, the key survived the fingerprint change.
- Twenty-fifth-device finding (2026-09-27, **D20 invalidation proven on
  hardware**): the retry logged the smoking gun —
  `SecKeyCreateSignature failed: CryptoTokenKit Code=-3 "unable to sign
  digest", AKSError=-536362999` — Touch ID *succeeded* and then the
  Enclave refused. The new fingerprint killed the key exactly as
  designed; the app just didn't recognize this error shape (it only
  mapped `errSecAuthFailed`). Fix, Mac-verified: CryptoTokenKit `-3`
  maps to the enroll-again error with key deletion (327/327 tests, sim
  build green, residue-free). Rebuild → the next `sudo` shows the
  "biometrics changed, enroll again" screen → `sudo flux approve
  enroll` + code compare + `y` closes D20.
- Twenty-sixth-device finding (2026-09-27, **D20 done**): the full
  invalidation → re-enroll arc on hardware, one console transcript:
  request 1 denied (fail-closed again, incidentally), request 2 Touch ID
  passes → CryptoTokenKit `-3` → now classified `biometryChanged` →
  enroll-again screen confirmed, dead key deleted; enroll request →
  `(enrolled)`, key code compared + `y`; next `sudo` → `(approved)` →
  passwordless sudo. The second Enclave error shape for dead keys is
  mapped with a regression test (`testSignErrorMapping`); the first
  shape (`errSecAuthFailed`) stays mapped too.
- Twenty-seventh-device finding (2026-09-27, **D21 done**): the prompt
  notification arrives over the lock screen; a press-and-hold expands it
  and reveals Approve/Deny (collapsed lock-screen notifications show no
  buttons — standard iOS, now in the runbook so nobody re-reports it);
  Approve → Touch ID → `sudo true` with no password, Deny fails closed
  to the password prompt. Biometric gate runs before any signature in
  both paths.
- Twenty-eighth-device finding (2026-09-27, **D22 first run — the
  desktop timeout is the binding constraint**): backgrounding after the
  prompt, the notification was gone from Notification Center/lock
  screen by the time the user looked. Log shows why:
  `approveAnswered result: "cancelled"` — Linux's ~20 s wait expired,
  `fluxd` cancelled, and the app correctly cleared the dead prompt's
  notification (a late answer would be stale-dropped). Background
  answering therefore has a hard ~20 s window from the prompt, not from
  when the user looks; the retry must answer within ~10–15 s.   Hold
  begin/end/expiry now log to the console for the next run.
- Twenty-ninth-device finding (2026-09-27, **D22 diagnosis round**):
  a delivered prompt notification vanished from Notification Center /
  lock screen on backgrounding, twice. Settle-dismissal is the known
  path (cancel/expire clears it), but the log could not prove or rule
  it out — `show()`/`dismiss()` were silent. They now log every post
  and removal with the prompt id, plus scene foreground/background
  transitions, so the next run shows the exact ordering. Open
  question for that run: wall-clock timing vs. the desktop deadline,
  and whether "close" means Home-background or switcher-kill.
- Thirtieth-device finding (2026-09-27, **D22 root cause — iOS drops a
  mid-presentation banner on backgrounding**): the timed run proved it —
  `shown`, then no `dismissed` until the later Approve, yet Notification
  Center was empty seconds after Home. The prompt was alive the whole
  time (approved from the reopened sheet afterwards), so neither the
  desktop deadline nor settle-dismissal explains it. Difference from
  D21 (which delivered fine): the app was foreground at post time, so
  the notification was an in-app banner mid-presentation when the app
  backgrounded, and that transition lost it. Fixes, Mac-verified: the
  "shown" log is honest now (`do/catch` — a printed shown means the
  store took it), and backgrounding with an open prompt re-posts its
  notification (same identifier = replace, never duplicate), landing
  cleanly while backgrounded. 327/327 tests, sim build green,
  residue-free.
- Thirty-first-device finding (2026-09-27, **D22 differential**: plain
  `flux notify` persists in Notification Center, the approve
  notification banners but never sticks — with all three alert styles
  enabled in Settings, so it is not a Settings issue). Armchair analysis
  is exhausted (every theory contradicts at least one proven data
  point); the next run carries a delivery audit instead: `show` audits
  store membership at post, and backgrounding schedules a second audit
  5 s later. Present at both audits with an empty NC means iOS-side
  removal; absent at post means `add` lied;   present at the audits means
  the user looked too early.
- Thirty-third-device finding (2026-09-27, **D22 bisect — suspect:
  `.timeSensitive` without the entitlement**): the no-background run
  proved the entry never renders as a list item even with no
  backgrounding involved; the control's category is verified
  never-registered (renders plain), and re-read D21 shows that run only
  ever proved the *arrival presentation*, never list persistence. Prime
  suspect is the time-sensitive level the free-tier build cannot sign
  (no Time Sensitive toggle on the app's Settings page). One-variable
  experiment, Mac-verified (327/327, sim green): the level is off, unit
  test asserts `.active`. If NC persistence returns, it stays off on
  free tier; if not, restore and bisect the action category next.
- Thirty-fourth-device finding (2026-09-27, **category AND thread
  exonerated, new prime suspect: foreground presentation**): step 2
  (no category) and step 3 (no thread either) both still hidden — every
  single content variable now tested with no change. Remaining
  systematic difference: everything that ever stuck (control, D21's
  lock-screen arrival) was system-presented while the app was not in
  front; everything that vanished went through the app's own
  `willPresent` delegate while foreground. Zero-code discriminator
  next: post the plain control while foreground and see if IT sticks.
- Thirty-fifth-device finding (2026-09-27, **D22 root cause, for real
  this time: `.banner` without `.list`**): the foreground-posted
  control vanishes too — content fully exonerated. Since iOS 14,
  `.banner` alone shows a floating banner WITHOUT adding the entry to
  Notification Center; both flags are needed. Fix, Mac-verified
  (327/327, sim green, residue-free): the   delegate passes
  `[.banner, .sound, .badge, .list]`, and all diagnostic content
  changes are reverted (category + thread restored with their tests).
  The audit helper + show/dismiss logging stay for future device runs.
- Thirty-sixth-device finding (2026-09-27, **D22 done**): with `.list`,
  the prompt notification lists in NC foreground AND backgrounded, and
  Approve from NC after backgrounding + Touch ID gives passwordless
  sudo. Diagnosis cost five rounds and three exonerated content
  variables; lesson recorded: on iOS 14+, a foreground delegate must
  pass `.list` or nothing it presents ever reaches Notification Center
  (system-presented notifications are unaffected, which is why the
  control and D21 kept working and the trail went cold so long).
- Thirty-seventh-device finding (2026-09-27, **D22 cleanup**): with
  `.list` the foreground post owns a proper NC entry, so the
  background re-post (added mid-diagnosis) is redundant — it only
  double-pings on backgrounding. Removed; the background hold stays.
  Kept deliberately: show/dismiss/hold/scene lifecycle prints,
  the `auditDelivery` helper (dead in production, no git here so
  removal would be permanent loss), and the retry/lockout/gone
  mappings. 327/327, sim green, residue-free.
- Thirty-second-device finding (2026-09-27, **D22 audit says the store
  has it**): `audit[post] present=true total=2` and `audit[bg+5s]
  present=true total=2` — delivered, never dismissed by us (dismiss
  fired only at the later desktop cancel), yet invisible in NC/LS;
   deleting the old control notification made ours flash in the list
   for a split second, then hide again. So NC renders-but-hides the
   entry: a display, not delivery, problem. Open question, zero-code
   test next: does a foreground-posted approve notification EVER reach
   the NC list (no backgrounding at all)?
- Thirty-eighth-device finding (2026-09-27, **M4 hardware first —
  empty-player media actions**): `flux media play-pause/next` arrived
  but logged `no handler for kdeconnect.mpris.request`. Root cause:
  Go `PhoneMediaAction` sends `"player": ""` when the phone publishes
  no state (v1/D13: never — `dev.media` is nil), and `MprisRequest`
  required a non-empty player. The loopback never saw it
  (`test_peer.py --m4` always sends `"player": "Music"`). Fix,
  Mac-verified: the player defaults to `""`, the event still surfaces
  on the status line, and `NowPlayingBridge.handle` no-ops on the
  unknown player (327/327, sim build green). Proven on hardware same
  session: the rebuilt app shows `media Next on  (archlinux)` — the
  empty player renders blank (no state published, D13) and the bridge
  no-ops as designed. Desktop→phone media actions are green.
  Player-query answers: closed by design (D13) — fluxd only queries
  phones advertising *outgoing* `kdeconnect.mpris`
  (`device.go: supports()` → `daemon.go` connect query), which iPhone
  never does (like Android), so with music playing `media` stays
  `null` and the provider is never asked; the answer path itself is
  loopback-proven and fires if ever queried. Companion gap, same run: an incoming carrier
  call backgrounds the app → `link.stop()` → `CallBridge` packets
  drop (`send=false`) — desktop got zero telephony (`flux
  notifications` empty, no journal lines). Retest procedure: switch
  back to Flux mid-ring so the link re-establishes inside the ring
  window; a lasting fix (call grace hold + retained runners) is
  planned, not built. Carrier-call leg postponed (needs a second
  phone); the `flux ring` find-my-phone leg was re-proven
  incidentally (start + toggle-stop across a reconnect).
- Thirty-ninth-device finding (2026-09-27, **desktop→phone DND green,
  status-line spam cut**): `omarchy-shell notifications setDnd on`
  (needs `OMARCHY_PATH=/usr/share/omarchy` over ssh) → fluxd `Do Not
  Disturb is on` → phone shows the `DesktopDndBridge` banner; off leg
  likewise logged. The   arrival never reached the on-screen status
  line — a `browse found` self-browse echo buried it — so raw link
  logs no longer reach the status line at all (console-only; the
  screen keeps user state like approve/media/transfer outcomes plus
  direct failures such as `link start failed`; 327/327, sim build
  green). Phone→desktop Focus (`flux.dnd`) still
  open: every switch is on (per-app toggle, system-wide Fokusstatus
  `Ein` verified by screenshot; no per-Focus toggle exists inside
  Nicht stören on iOS 18.2) and reads return real `Optional(false)`,
  but an active moon still reads false. Decisive round same session:
  a 3 s foreground poll (new; iOS offers no change callback, one
  foreground read also missed open-app toggles — `DndGuard` keeps
  sends change-only, ticks are one locked read) produced ~30 straight
  `focused=Optional(false)` across moon on AND off with Nicht stören
  visibly on the lock screen. Parked as an Apple-side quirk on this
  device/config: the send path (guard → `link.send` → desktop
  `handleDnd`) is unit-covered and fires on the first true read.
- Fortieth-device finding (2026-09-27, **#1 phone→desktop commands proven
  on hardware**): with the rebuilt app, Devices → archlinux → Run commands
  listed the host-configured `Test beep` (`flux commands add` done over
  ssh; status line showed the count); three taps → three journal lines
  `iPhone runs 45c651a6: echo flux-test-beep` (19:34:25/:41/:46). First
phone→desktop command execution from the app. Media-screen proof (music
playing + Pause/Next) still open.
- Forty-first-device finding (2026-09-27, **#2 media control proven
  phone→desktop**): no music on the desktop, so a silent stand-in — mpv +
  `mpv-mpris` looping a generated tone at volume 0. Phone Media screen
  rendered player `mpv` / `flux-tone.wav` playing; Pause tap → host
  `playerctl` reads `Paused` at 66.9 s (full chain: screen → mpris.request
  → fluxd → MPRIS → mpv). Known v1 limitation, not a wire bug: the screen
  shows the last desktop-reported position with no local ticker, so
  elapsed time looks frozen until the next state push (the Pause answer),
  when it jumps to the true value. Play-resume tap confirmed next
  (`playerctl` back to `Playing`); stand-in player killed + wav removed.
  #2 phone→desktop media control fully proven on hardware.
- Network evidence from the Mac: the Linux host's fluxd IS visible here
  (`dns-sd -B _kdeconnect._udp` → `a5cd7a67…`, resolves to
  `archlinux.local.:1716` with `id/name/type/protocol` TXT), so the
  mDNS path between LAN and this Mac works; only the phone's publish is
  still unproven.

## Reverse-direction UI (#1 commands, #2 media — code done, device proof open)

`ContentView` lists connected computers (from `.paired`, minus `.closed`)
with Media + Run-commands destinations. `FluxUI/RemoteScreensState.swift`
is the store (per-computer command lists in desktop config order, player
lists, latest `MprisState`; close drops the cache; empty list = loaded).
`LinkRunner` events now carry the full payloads (`commandListReceived`
the `[RemoteCommand]`, `mediaStateReceived` the `MprisState`), and the
`FluxApp` closures send over the D23 path (`RunCommandMessage.requestList/
run`, `MprisMessage.requestPlayerList/requestNowPlaying/action/seek`;
opening a screen refreshes, unknown action verbs build nothing).

Mac-verified: `swift build`, 334/334 SPM tests (7 new store tests), sim
build + 327 pass / 7 skip / 0 fail, M6 loopback re-run after the session
change (`M6 EXPECTATIONS MET`, key code `9E4B 46B5 3D30 E17B` both sides,
zero "no handler", `--forget` residue-free: approve keys 1), M4 loopback
(`M4 EXPECTATIONS MET`, new event shapes print). Device proof needs the
user rebuild + one configured command (`flux commands add …`) and music
playing on the desktop (player list + state render, tap-to-run executes).

## Wire interop (no firewall rule needed)

Listen for the phone's UDP broadcast, then connect like `fluxd` does
(desktop dials the phone):

```sh
python3 ios/tools/test_peer.py --listen
# or directly:
python3 ios/tools/test_peer.py --host 192.168.1.20 --port 1716
```

Manual QA against a real daemon uses the same CLI as Android
(once the M1b live link lands):

```sh
flux discover
flux pair "iPhone"
flux status --json
flux ping "iPhone"
```

## Pairing (M1)

Desktop `flux pair` (or Qt "+ Pair new device") → 8-char key on both
screens → Accept on iPhone. The key is `SHA-256(larger SPKI ‖ smaller SPKI
‖ timestamp)` truncated to 8 uppercase hex chars — byte-identical to Go
`proto.VerificationKey` and Android `verificationKey` (same test vectors in
all three suites).

- Outgoing requests stay open 30 s, incoming 25 s (mirrors Android/Go);
  outgoing timeouts send `{"pair": false}`, incoming ones just close.
- Protocol v8 requires a timestamp within ±30 min; older peers pair without
  one and their key omits it.
- A peer that re-requests while paired lost its trust (reinstall): local
  trust is dropped first and the key is shown again — never silently
  re-trusted. Invalid re-requests also drop trust and are refused.
- Trust = pinned certificate DER in the Keychain
  (`org.omarchy.flux.trust`, `AfterFirstUnlockThisDeviceOnly`, never synced).
  A changed certificate is a re-pair, never a silent update
  (`FluxNet.TrustValidation`, unit-tested).
- Device ID (32 hex chars) and identity persist in the Keychain, so they
  survive reinstalls **while the Keychain entry is retained**. If the
  Keychain is cleared, the next launch mints a new ID: reinstall = re-pair.
- Device certificate: self-signed ECDSA P-256, serial 10, `CN=device ID`,
  `O=KDE`, `OU=KDE Connect`, validity −1y/+10y, ECDSA-with-SHA512 —
  exactly the Go `generateCert` profile. Verified with Go
  `x509.ParseCertificate` + `CheckSignatureFrom` (self-signature) and
  `openssl x509`/`verify`. Export the PEM for `devices.json` debugging via
  `Certificates.pemEncode`.
- The identity private key prefers the Secure Enclave, falls back to the
  Keychain, and is **not** biometric-gated (TLS must work while locked;
  biometric gates are M6 approve keys only).
- UI: `PairView` (key compare + Accept/Decline), `OutgoingPairView`,
  `UnpairView`, all with previews.

M3 closed this: queued `shareFile` announcements fetch (classic + tunnel)
and the `flux.tunnel` reverse listener serves them.

## Live link (M1b)

`FluxNet` owns sockets + TLS, `FluxCore.LinkRunner` owns one inbound
connection: plaintext identity → TLS-client handshake → TLS identity →
pairing + packets. Verified end-to-end against `tools/test_peer.py`
(desktop role) over loopback:

```sh
swift run FluxTestPeer --name "iPhone" --dump-cert /tmp/phone.der
python3 -u tools/test_peer.py --listen --seconds 10   # discovers, pairs
```

Observed: UDP discovery → plaintext identity → TLSv1.2
ECDHE-ECDSA-AES256-GCM-SHA384 → TLS identity (no `tcpPort`) → 8-char key
compare → PAIRED → battery/runcommand/mpris samples → clean close. The
8-char key was recomputed from both certificate DERs and matched byte for
byte. Pinned reconnect (`--persist` + `--phone-cert`) skips pairing and
goes straight to samples; restarting keeps the same ID + cert.

```sh
swift run FluxTestPeer --persist          # stable ID/cert/trust in Keychain
swift run FluxTestPeer --forget           # fresh-install path (re-pairs)
```

Socket-stack decision (M0 log closed): `Network.framework` cannot do the
acceptor's plaintext-first upgrade (its TLS listeners handshake immediately
as server — the wrong role at the wrong time), and file-based TLS cannot
use Secure Enclave keys without export. The link therefore uses BSD sockets
+ SecureTransport (`FluxNet/SecureTransport.swift`), which gives exact
handshake control and Enclave-compatible client auth with zero
dependencies. SecureTransport is deprecated (macOS 10.15+) but functional;
all framing/pinning/pairing above it is transport-agnostic, and the iOS
`kSecClassIdentity` lookup path is in place (untested on-device yet).
Cipher posture mirrors Go `tls.go`: TLS 1.2 minimum.

## Messaging primitives (M2)

`FluxProto/Messaging.swift` builds + parses every M2 packet (ping default
"Ping", battery threshold ≤15% + change-only gate, clipboard + connect stale
rule, share text/URL/file/update + `sanitize`, connectivity, find-my-phone
toggle, notification builders + `ComputerNotification` port). All field
shapes mirror `internal/core/*.go` and Android `core/` and round-trip
through serialize/parse tests.

`FluxCore/Plugins.swift` (`FeatureRouter`) routes post-pairing packets with
the Go gates: unpaired devices are dropped, types outside the advertised
`incomingCapabilities` are dropped, clipboard needs `clipboardSync`
(`auto_clipboard`, still false by default). Clipboard loop-prevention
(`lastRemoteClip`), the ring toggle + 2-minute cap (`RingState`), and the
share-file queue record live in the router; payload bytes are M3.

`FluxCore/LinkRunner` answers `battery.request` through an injected provider,
sends harness/app `welcomePackets` once per ready link (pinned reconnects
send immediately), and drops unpaired plugin packets with Go's log line.
`PairApproval` is the manual Accept path: the session thread blocks in
`decide` until `PairView` resolves it (`onAccept` → `resolve(accept: true)`,
`onDecline` → `resolve(accept: false)`); timeout declines silently like an
incoming expiry. `FluxTestPeer` keeps `--no-auto-accept` log-only mode.

`FluxFeatures/SystemBridges.swift` binds the events to iOS: `UIDevice`
battery, foreground-only `UIPasteboard`, display-only `UNNotification`
rendering (no reply buttons — the desktop never answers its own
notifications), vibration + loudest-allowed alert, and the `PendingShareStore`
queue that M3 fetches from. `FluxUI/RingView.swift` ports Android's
`RingOverlay` (pulsing bell + "I found it").

E2E (loopback, like M1b):

```sh
swift run FluxTestPeer --name "iPhone" --exercise-m2
python3 -u tools/test_peer.py --listen --seconds 20
```

Desktop→phone after pairing: ping, `battery.request` (answered), clipboard +
`clipboard.connect`, share text + URL, notification render, ring start +
toggle-stop. Phone→desktop (`--exercise-m2`): battery, ping, clipboard,
share text, Flux-internal notification. `test_peer.py` prints every packet;
the 8-char key recomputed from both certificate DERs matches byte for byte
(see the M1b audit procedure). Pinned reconnect (`--persist` + `--phone-cert`)
skips pairing and sends the welcome packets immediately.

```sh
swift run FluxTestPeer --persist --exercise-m2 --battery 82 --clipboard-sync
swift run FluxTestPeer --forget   # fresh-install path (re-pairs)
```

`flux send` file *payloads* are M3: announcements parse into `shareFile`
records (filename/size/port/tunnel) and queue in `PendingShareStore`, but no
bytes move yet. (`runcommand`/`mpris` desktop samples route since M4.)

## Files + browse signalling (M3)

`FluxProto/Transfers.swift` owns the packet shapes (`flux.tunnel`
ready/failed, `sftp` offers, send-side announcements); `FluxNet/Payload.swift`
owns the sockets (classic fetch as TLS client, tunnel/payload listeners as
TLS server with the pinned-peer check, 64 KiB streaming); `FluxCore/Transfers.swift`
(`TransferEngine`) owns the flows off the session thread, and `FluxCore/LinkRunner`
grew a general outbound-send path (`LinkSender`: one reader, lock-serialized
writers, Android `Link` reader/writer parity).

Port-vs-tunnel rule (plan §12 Q3, closed): the **sender** chooses — a tunnel
when the receiver advertises `flux.tunnel` outgoing (`Link.CanTunnel`),
classic otherwise. The receiver follows the packet (`tunnel` → listen +
`flux.tunnel ready`; `port` → connect + fetch). Phone→desktop is always
classic (the desktop never opens tunnel listeners). `share_home` off arrives
as an `sftp` `errorMessage` and surfaces as `sftpErrorReceived`.

Receive lands in `Application Support/Downloads/` via `.part` + rename with
Go's exact-size check, `uniquePath` (`name (2).ext`), and ≤4/s progress
(Go `progress` parity). The SSH session inside browse tunnels is M4+: the
tunnel below it is real and E2E-held, exposed via `takeBrowseTunnel(_:)`.
SSH-lib decision (plan §12 Q4): `apple/swift-nio-ssh` (Apache-2.0) when a
dependency can be vendored, `Citadel` (MIT) fallback, `libssh2` out — no
dependency vendored in M3, license choice stays with the source owner.

E2E (loopback, pinned like M1b):

```sh
swift run FluxTestPeer --persist --dump-cert /tmp/phone.der --downloads /tmp/dl
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --serve-file /tmp/f10m.bin --serve-mode tunnel   # or classic
```

Verified: 1 KB + 10 MB classic and tunnel, 100 MB tunnel, all byte-identical
(`sha256` printed both sides); 0 B announcements dropped without a fetch on
both modes (protocol-level: `hasPayload` needs `size != 0` on Go, Android,
and iOS alike); re-fetch of the same name lands as `name (2).ext`;
phone→desktop upload (`--send-file` + `--expect-file`) byte-identical;
browse tunnel established (`--browse` + `--browse-offer tunnel`, roots
`Home,Downloads`) and `share_home`-off refusal honored (`--browse-offer off`).
The 8-char pair key recomputed from both certificate DERs matches byte for
byte. `FluxTestPeer` flags: `--downloads DIR`, `--send-file PATH`, `--browse`.
Parked follow-ups (SSH bytes, SFTP serving, Share Extension wiring) are
logged in `docs/ios-plan.md` §14, the deferred-work log.

Known protocol finding: 0-byte files transfer on **no** implementation —
Go `HasPayload`, Android `hasPayload`, and iOS `hasPayload` all require
`payloadSize != 0`, so the sender would wait and time out upstream. iOS
drops the announcement with "no handler", matching Android's early return.

## Browse plan (D1 — built 2026-09-28, loopback-proven, device proof open)

Desktop facts (read from `internal/core/sftp.go`, no desktop changes):
the `kdeconnect.sftp` offer carries `tunnel` id + `user: "kdeconnect"` +
a per-session one-time `password` + `path` (home) + `multiPaths` roots.
The phone opens the `flux.tunnel` listener (done, E2E-held); the desktop
dials back and serves **SSH** on it: fresh ed25519 host key per session,
**password auth**, `session` channel + `sftp` subsystem only, **read-only**
SFTP, session-capped (`maxBrowseSession`). The iOS `SftpOffer` already
keeps `user` + `password` — no parser change needed; `takeBrowseTunnel`
hands over the established SecureTransport TLS stream.

Client shape: password-auth SSH + session channel + sftp-subsystem over
that stream, list/download only. **`Citadel 0.9.2 (MIT, exact pin in
`ios/Package.swift` + `project.yml`; license choice stays with the source
owner)** wraps NIOSSH with the SFTP client (`openSFTP`,
`listDirectory`, `withFile`/`openFile` + 64 KiB reads); swift-nio is a
direct dep only for `ByteBuffer`→`Data`. The NIOSSH-direct fallback was
not needed. Citadel 0.9.2 is not Sendable-annotated, so every Citadel
value stays inside the `BrowseSession` actor (`@preconcurrency import` +
actor confinement, no signatures cross isolation).

The bridge question is closed with option (b), the Android parity shape:
a `LoopbackBridge` port binds 127.0.0.1:0 and the NIO client dials it
(stock Citadel, no fork). Hardening vs. Android: the relay is ONE thread
multiplexing both directions with select() — a two-thread relay
heap-corrupted the harness peer (concurrent SSLRead/SSLWrite on one
SecureTransport context, malloc abort; the LiveChannel rule covers reads
too), and `close()` serializes teardown behind an SSL lock with
`shutdown` wakeups (LinkRunner pattern) + `SO_NOSIGPIPE` sockets.
Hand-rolled SSH/SFTP stays out (audit burden). The loopback server is
asyncssh instead of `sshd` (same handshake/auth/channel mechanics:
password auth + sftp subsystem + fresh ed25519 host key per run; fluxd
specifics remain parameter-level); the M3 tunnel harness covers the
bytes below.

UI (built): `BrowseScreen` (roots chips → listing → download, read-only,
up-row, error/offline/empty states + previews) + a `ContentView`
"Browse files" link per computer + `browseStates` in
`RemoteScreensState` (the #1/#2 store pattern); downloads land in
Downloads with the `TransferEngine` non-clobbering rule.
Proven loopback (pinned, like M1b/M3/M4/M5):

```sh
swift run FluxTestPeer --name "iPhone" --dump-cert /tmp/phone.der --exercise-browse
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --browse-ssh --expect-browse --seconds 60
```

Verified: password auth + 2 fixture listings + `hello.txt` sha-identical
both sides (`160e4d9c…`) + subdir list + `BROWSE EXPECTATIONS MET`,
zero "no handler"/"unadvertised" lines, 400/400 tests green (13 new),
sim 382 pass + 18 skip / 0 fail, M4 loopback re-green after the
`sftpOfferReceived` event touch (now carries the whole offer; the
one-time password travels in-memory only, never to logs). Harness
lessons: asyncssh handlers may return sync values (maybe-await them)
and expect str paths; asyncssh stats `..` while listing (the harness
jail clamps escapes to ROOT). Still open: the device proof against
real `fluxd` (needs `share_home` on) — open Browse files on the phone,
list Home/Downloads, download one file.

Device download leg (2026-09-28/29, iPhone SE2 — list green, zip red):
real offer (6 roots) → tunnel → `SFTP connection opened and ready` →
15 entries; 57 B `.txt` downloads fine; the 614 KB `flux-master.zip`
dies deterministically a few 8 KiB DATA replies in (`relay tunnel
read: ioFailed(-50)` → close → desktop RST, no fluxd logs),
immediate AND idle taps, fresh AND reused sessions. 8 KiB + 100 ms
pacing did not save it. Exonerated locally (fragmenting-proxy
loopback, macOS SecureTransport green throughout): TCP segmentation
(MSS 536), small TLS records (1 KiB), the Go client + `pkg/sftp`
stack, file content (the real zip is loopback byte-identical),
TLS 1.2, idle time. Discriminator: the 4.7 MB tunnel receive
(`pipeExactly`, pure reads) and sustained stream writes are
device-green, as is the full SSH handshake — the relay's ST use
audited correct (blocking socket, one thread, serialized teardown),
so the `-50` is iOS-ST-internal; the exact trigger (reply size vs
count vs cumulative bytes) is open. Next build (2026-09-29,
402/402 tests, sim 384 + 18, browse + M6 loopbacks green): relay-up
logs the cipher (`c02c` on loopback — compare on device), `wake`
spam is now size-bearing `t->l n` / `l->t n` lines, pacing tries
300 ms as a single-variable rate experiment, dead sessions evict on
`connectionClosed` (retaps say reopen), `warm ping ok` retired.
Device run: rebuild, tap the zip, paste the relay lines around the
death + the cipher + whether 300 ms completes.

Second device run (2026-09-29 — the new logs worked first try):
cipher `c02c` on device == loopback (cipher exonerated); death
narrowed to `OPEN → HANDLE → READ #1 → t->l 4096` (half of the 8 KiB
DATA) → `-50` on the next read. 300 ms pacing died on the FIRST
data — the rate theory is out; the size/fragmentation theory stands
(partial/split multi-segment reply at death, small-message
alternation always green). Next build: 1 KiB SFTP reads, tight loop
— every round trip mimics the handshake pattern (~6 s for the zip,
loopback green, 402/402, sim 384 + 18). That run went green (see
below). Cleanup afterwards: per-chunk `t->l`/`l->t` logs retired
(relay now logs up/cipher, accepted, EOF, close only), keeper
`noSession` teardown false-alarm silenced, host iptables verified
clean.

Device proof (2026-09-29, D1 download leg DONE): 1 KiB tight reads
took `flux-master.zip` end to end — hundreds of `l->t 68` /
`t->l 1076` cycles, short final `t->l 900`, orderly CLOSE,
`browse downloaded flux-master.zip (614219 B)` = host 614219 B
(sha `05b6f743…`, same as the loopback fixture). Root cause:
iOS SecureTransport server-role `SSLRead` fails `-50` on
multi-segment TLS replies; single-record round trips survive
indefinitely; macOS ST tolerates any size. Warts en route (honest):
first tap hit the parked `handshakeFailed(-50)` flake (retry
green), one mid-list `-50` in that churned session, then a fresh
session perfect throughout. Follow-up, not blocking: probe 2–4 KiB
chunks for speed (3444 B reads survive).

## Media/commands/calls/Focus (M4)

`FluxProto/Media.swift` builds + parses every M4 packet beside the M2/M3
ones, with round-trip serialize/parse tests against Go + Android vectors:

- `kdeconnect.mpris` desktop state (`playerList` + `player`/`title`/`artist`/
  `album`/`isPlaying`/`pos`/`length`/`volume`/`canPlay`/`canPause`/`canGoNext`/
  `canGoPrevious`/`canSeek`/`albumArtUrl` — Go `sendNowPlaying` shape).
- `kdeconnect.mpris.request` both ways: phone→desktop control
  (`requestPlayerList`, `requestNowPlaying` + `requestVolume`, `action`,
  `SetPosition`, `setVolume` — Go `handleDesktopMediaRequest` fields, with
  `Seek` accepted too) and desktop→phone queries + `flux media *` actions.
  Only the six Go verbs are valid actions
  (`PlayPause/Play/Pause/Next/Previous/Stop`, from `PhoneMediaAction` and
  the `flux media` map in `cmd/flux/main.go`).
- `kdeconnect.runcommand` list: `commandList` arrives as a JSON **string**
  (Go `sendCommandList`) and parses in desktop config order —
  `canAddCommand` is false (commands live in `config.toml`).
- Phone→desktop `kdeconnect.runcommand.request` (`requestCommandList`,
  `key`): phone-requests/desktop-runs only, like Android.
- `kdeconnect.telephony` builder (ringing/talking/missedCall + `isCancel`
  in all four Go `flexString` spellings, "Unknown caller" fallback) plus a
  `CallTracker` port of Android's line-state machine.
- `flux.dnd` builder/parser (`{"on": bool}`) plus a `DndGuard` port of Go
  `dndGuard` (change-only, 3 s settle).

`FluxCore/Plugins.swift` (`FeatureRouter`) routes them with the usual
gates: desktop player lists re-seat the controlled player and trigger the
Android-parity `requestNowPlaying` follow-up (a `.send` action the link
writes); state updates switch control to a player that started playing;
desktop `mpris.request` actions/seeks/volume/queries surface as events and
album-art requests log as deferred; command lists arrive in order;
desktop `flux.dnd` surfaces as a banner event (never applied).

One capability changed: incoming `kdeconnect.mpris.request`. `flux media *`
sends it ungated (Go `PhoneMediaAction` → `d.send`), and plan §4.6 requires
desktop pause/next to control iPhone playback — so the phone now advertises
what it implements (plan §2.2 already listed it). Android does not (its
`flux media` actions drop). Everything else is pre-advertised and unchanged.

`FluxCore/LinkRunner` answers player queries through a `nowPlayingProvider`
(same pattern as `batteryProvider`: player-list query → `playerList`
packet, `requestNowPlaying` → state packet, nothing playing → empty list)
and emits media/command/DND events for the UI and harness.

`FluxFeatures/SystemBridges.swift` binds the events to iOS:

- `CallBridge` (`CXCallObserver`, device only) → telephony packets. **iOS
  exposes no call number to third parties** (`CXCall` carries none, and
  there is no `READ_CALL_LOG` equivalent), so every call reaches the
  desktop as "Unknown caller". Desktop media pause + missed-call
  notifications are `fluxd`-side and need no iOS work.
- `FocusBridge` (`INFocusStatusCenter`) → `flux.dnd` on change only
  (`DndGuard`). iOS offers no Focus-change callback, so the app calls
  `refresh()` on foreground + a foreground timer — no background polling.
  Desktop→phone DND renders a banner (`DesktopDndBridge`) and never sets
  Focus (no API exists).
- `NowPlayingBridge` (`MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`):
  desktop actions drive the app's player through closures, and `current()`
  feeds the query provider. Remote commands work while locked but need a
  live link; the silent switch does not gate them; desktop `setVolume` is
  ignored (no remote volume API for third parties).

`FluxUI/MediaCommandsViews.swift` ports Android's Media + Commands screens
(player chips, artwork placeholder, seek, Previous/Play-Pause/Next;
command list in config order with loading/empty/offline states) as
state + closure views with previews. `FluxTestPeer` gains `--exercise-m4`
(the four phone→desktop types in one welcome burst) and `--now-playing
TITLE` (stub provider); `test_peer.py` gains `--m4` (now-playing state +
`flux media` action + player-list query + desktop DND samples) and
`--expect-m4` (fails the run unless all four phone→desktop types arrive).

E2E (loopback, pinned like M1b/M3):

```sh
swift run FluxTestPeer --persist --dump-cert /tmp/phone.der --exercise-m4
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --m4 --expect-m4 --seconds 25
```

Verified: pair run shows key `8523123E` (recomputed from both DERs +
timestamp, byte-identical); pinned reconnect skips pairing and sends the
welcome burst immediately; peer prints `M4 EXPECTATIONS MET` for
`mpris.request` + `runcommand.request` + `telephony` + `flux.dnd`; phone
logs `MEDIA PLAYERS/STATE/ACTION`, `COMMANDS`, `DND`, answers queries
(`-> kdeconnect.mpris`), and the whole transcript has zero "no handler"
lines. Parked follow-ups (phone `mpris` state publishing, call numbers)
are logged in `docs/ios-plan.md` §14.

Dev-harness note: rebuilding `FluxTestPeer` changes its ad-hoc signature,
so a `--persist` restart can fail Keychain access (`signingFailed`). Run
`swift run FluxTestPeer --forget` and re-pair — the documented
fresh-install path (device builds keep a stable signature).

## Camera/mic/screen (M5)

`FluxProto/Streams.swift` builds + parses every M5 packet beside the
M2/M3/M4 ones, with round-trip serialize/parse tests against Go + Android
vectors:

- `flux.webcam` phone→desktop `start` (port/width/height/fps/h264) + `stop`
  + `error` + `config` (full settings + caps, like Android sends after
  `start`); desktop→phone `live` (device/label, default `Flux Camera`),
  `error`, `stop`, `config` (partial and/or `reset`, Go `ConfigureWebcam`
  shapes).
- `flux.mic` phone→desktop `start` (port/rate 48000/channels 1/s16le —
  exactly Go `micStart.check`'s accepted values) + `stop` + `error`;
  desktop→phone `live` (source, default `Flux Microphone`), `error`, `stop`.
- `flux.screen` phone→desktop `start` (port/width/height/h264) + `stop` +
  `error`; desktop→phone `live` (player), `error`, `stop`.
- Capture shares: scanned text (`text`+`scan`) and file announcements with
  the `scan`/`photo`/`screenshot` flags Go routes to `scan_dir`/`photo_dir`
  (screenshot sends `photo` too, so older `fluxd` still saves it).

`FluxCore/Plugins.swift` routes the desktop answers with the usual gates
(a `start` arriving phone-side is meaningless and stays unhandled);
`FluxCore/LinkRunner` emits stream events for the UI and harness, and
`FluxCore/StreamEngine` serves the byte listeners off-thread (pinned-TLS
accept like the browse tunnels, 10 s connect timeout like Android): chunked
writes through the same `LinkSender`, so transfers keep their progress
semantics while a stream flows. `TransferEngine` also learned `sendCaptures`
(the classic upload path with routing flags, Android `sendCapture` parity).

Capture + stream logic (all Android-vector-tested):

- `FluxCamera/WebcamConfig.swift`: all 11 settings keys, `frameSize` short
  side (even sides for H.264), `bitrateFor` pixel scaling, tolerant partial
  merge (numbers/bools as text, `NaN` dropped), caps clamp (EV step, zoom
  floor), `reset` (shape/quality/camera stay), `restartsStream`.
- `FluxCamera/AnnexB.swift`: NAL scan + SPS/PPS-per-IDR framer, golden-frame
  tested against the Android `H264Encoder` vectors.
- `FluxCamera/FrameGeometry.swift`: output→camera matrix (rotation, center
  crop, front-mirror), upright rotation, quarter-turn snap, axis-swap
  detection.
- `FluxCamera/TextAssembly.swift`: reading order + hyphen healing
  (`VNRecognizeTextRequest` lines in, `scan_dir` text out).
- `FluxCamera/Codes.swift`: format/kind/sheet/desktop-text + `IMG_…`/`
  scan-…` file names.
- `FluxCamera/CapturePlan.swift`: the auto-upload ledger (switch baselines,
  sent set, pending images, `MAX_SENT` cap).
- `FluxStream/StreamFraming.swift`: s16le PCM encode/peak/sine + `MirrorSize`
  fit/bitrate (screen text bitrate floor).
- `FluxStream/StreamSessions.swift`: `StreamSession` per-kind state machines
  (device match, active-only live, silent error/stop, webcam config action,
  notify-only-with-stream stop) + the mic-with-webcam flag.
- `FluxStream/AudioCapture.swift` (`AVAudioEngine` voice tap → 48 kHz mono)
  + `FluxStream/VideoEncoding.swift` (`VideoToolbox` → Annex B through the
  shared framer): compile-verified, hardware-gated; the encoder path also
  has a passing on-machine spike test (real SPS/PPS/IDR bytes out).
- `FluxCamera/CapturePipelines.swift`: Vision text/code mapping, live
  metadata symbologies, photo settings (HEIC→JPEG compat note),
  VisionKit document scan (iOS only), and `PhotoLibraryWatch`
  (`PHPhotoLibraryChangeObserver` + sent-`localIdentifier` ledger +
  foreground/queued upload, Android `CaptureWatch` parity).
- `FluxUI/CameraMicViews.swift`: Mic, Camera (all 5 modes), and Mirror
  screens as state + closure views with previews.
- `Extensions/BroadcastExtension`: `RPBroadcastSampleHandler` wired to an
  App Group `screen.json` config + pinned-TLS out-connection (Xcode/iOS
  target, needs the broadcast entitlement + hardware).

`FluxTestPeer` gains `--exercise-m5` (deterministic H.264/PCM/screen bytes
through the real framer, full webcam config, scanned text, a scan PDF + a
photo with routing flags, stops after each stream) and `test_peer.py` gains
`--m5` (connects like `fluxd` `DialPeer`, checksums bytes, answers live + a
webcam config change; requires `--phone-cert`, since an unpinned server
requests no client cert and the pin has nothing to check) plus
`--expect-m5` (all three starts, non-empty byte-identical streams, scanned
text, both captures landed) and repeatable `--expect-file`. Desktop
`incomingCapabilities` in the peer script now include the three stream
types, like Go's `Incoming`.

E2E (loopback, pinned like M1b/M3/M4):

```sh
swift run FluxTestPeer --persist --dump-cert /tmp/phone.der   # pair first
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --seconds 30
swift run FluxTestPeer --persist --dump-cert /tmp/phone.der --exercise-m5
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --m5 --expect-m5 --expect-file scan-20260925-101500.pdf --expect-file IMG_20260925_101500.jpg --seconds 60
```

Live producer seam (D16 groundwork, 2026-09-27): `LiveOffer`
(`AsyncStream<Data>` chunks instead of fixed `Data`) + `StreamEngine`
per-kind tasks with cancel/close (`stopLive`, `stopAllLive`, listener
tracked so stops unblock a waiting `accept`) + `LiveStreamBox`
(runner inlet; pre-attach offers held per kind, served on attach) +
`LinkService.offerStream`/`stopStream` (false with no link, no
ping-pong on desktop stops). Progress carries `size: -1` (status line
shows bytes-so-far). Proven: 5 new tests (in-process loopback TLS:
chunk reassembly + incremental SHA-256, silent stop, box queue/drop;
sim skips them `-34018` like the other Keychain tests) and
`--exercise-m5-live` (`M5 EXPECTATIONS MET` with identical checksums:
webcam 8192, mic 192000, screen 2304). Fixed serves untouched
(regression green). Hardware producers (tap/drain/picker) still open.

Mic app wiring (D16, code-done 2026-09-27, device proof open):
`FluxStream/MicProducer.swift` bridges the `MicCapture` tap into live
chunks + level (injectable source, stub-tested; permission via
`MicAccess`). `StreamSession.markLive` maps the parsed desktop `live`
event (the app never sees the raw packet). `FluxApp` owns the session:
Start asks permission → tap → `offerStream` (every failure lands in the
session status); Stop/teardown paths never double-send (`session.send`
stays nil — packets go over `link` only). `ContentView` shows
Microphone per computer (`MicScreen` + level + withWebcam pref).
344/344 SPM tests, sim 333 + 11 skip. Device proof: Start on the phone,
`fluxd` journal `iPhone: microphone …` + status-line byte counts, Stop
→ `microphone stopped`.
- Forty-second-device finding (2026-09-27, **mic Start reaches the
  desktop, then RST**): tap → permission → offer → desktop dialed 1739
  (TLS ok) → `read: connection reset by peer`, phone showing the
  desktop's error text. Two fixes, Mac-verified: (a) `acceptTunnel`
  closes the listener fd but the live registry kept it, so a later
  `stopLive` could close a recycled fd out from under a live socket —
  the registry now drops the listener on accept; (b) stop packets go
  out BEFORE the close (desktop stops reading first instead of RSTing
  on in-flight bytes), and a desktop error within 3 s of our own Stop
  shows the idle screen, not the error screen. Pre-fix, the same
  session also exposed a stale-desktop-link incident (old `fluxd`
  held a dead socket with no redial; `systemctl --user restart fluxd`
  reconnected instantly — worth a desktop-side keepalive note).
  Retest (rebuild) still open: does one Start stream cleanly, and does
  Stop land idle instead of red?
- Forty-third-device finding (2026-09-27, **mic Stop crashes the app —
  heap corruption, diagnosed from the Xcode console**): meter moving
  (268800 B streamed, desktop `live`), then Stop → `malloc: pointer
  being freed was not allocated`. Root cause: `stopLive` closed the
  `TLSConnection` on the MainActor while the engine task was mid-`write`
  — SecureTransport contexts are not thread-safe and `close()` re-closes
  the fd, so this was the first concurrent close in the codebase (every
  prior close was same-thread). Fix, Mac-verified: `LiveChannel`
  funnels each live stream's write + close through one serial queue
  with run-once close (a blocked writer delays a concurrent close by
  one 64 KiB chunk; the writer never waits on the closer, so no
  deadlock). 344/344 tests, sim green, M5-live + M6 loopbacks
  re-verified after the change (`M5 EXPECTATIONS MET`, `M6 EXPECTATIONS
  MET` key `3E90 428E 4A2F E4D2` both sides, `--forget` clean).   Retest
  (rebuild) still open: Start → speak → Stop must land idle with no
  crash, and the desktop journal should show `microphone stopped`
  without a preceding RST error.
- Forty-fourth-device finding (2026-09-27, **mic EOF instead of RST —
  crash fixed, stream still dies early**): after the `LiveChannel`
  rebuild, one Start streamed, then `mic error: … tunnel TLS: EOF`
  (clean close, app alive — the heap fix held). Prime suspect is a
  stale error killing a live stream: a replaced/previous attempt's
  desktop error lands while the current stream runs, and the teardown
  cannot tell them apart. Guard, Mac-verified: `StreamSession.generation`
  (bumped on every start/stop) recorded per Start, and every mic event
  site + teardown ignores older generations and other devices
  (`micCurrent`). 345/345 tests, sim green (which caught two more
  MainActor-isolation errors SPM mac never sees). No loopback re-run:
  additive-only change, no wire/session-flow touch. Retest (rebuild)
  still open — and this time please note the exact taps (single Start?
  double-tap? Stop before the error?) plus the `flux:` console lines
  from Start to error, so a spontaneous close can be told apart from a
  replace cascade.   Remaining wart if it is the cascade: a double-tap
  still RSTs the first stream (unavoidable on kill) — the second stream
  now survives it.
- Forty-fifth-device finding (2026-09-27, **mic Stop kills the app with
  SIGPIPE**): single Start streamed 268800 B to desktop `live`, Stop →
  `Terminated due to signal 13`. Root cause: our stop packet races our
  own in-flight write — the desktop closes on the stop, the pending
  write hits the dead socket, and SIGPIPE terminates by default (a
  different crash from the heap race before it). Fix, Mac-verified:
  `SIG_IGN` for SIGPIPE at startup (app + test peer), so dead-peer
  writes surface as normal errors on the existing failure paths.
  345/345 tests, sim build green. Retest (rebuild): Start → speak →
  Stop must land idle with `microphone stopped` on the host and no
  crash.   (Also noted in passing: the Focus `DNDErrorDomain 1004`
  "missing Communication Notifications entitlement" lines are
  system noise — the boolean read still works; the Focus quirk itself
  stays parked.)
- Forty-sixth-device finding (2026-09-27, **mic Start→live→Stop green
  on hardware, D16 mic half done**): single Start → 268800 B to desktop
  `live` (`Flux Microphone`) → Stop → idle "Microphone off.", app
  alive, host journal `iPhone: microphone stopped` with no RST/EOF
  error after it. Three device-driven fixes went into this arc: the
  stale listener fd, stop-packet-first ordering, `LiveChannel`
  serialization (malloc crash), SIGPIPE ignore, and the generation
  guard. Still open in D16: the webcam half (code-done below —
  needs its device proof: Camera-tab Start, `flux webcam set/reset/
  stop`, the withWebcam companion run, Stop → idle) and Mirror-screen
  presenting.
- Webcam app wiring (D16, code-done 2026-09-27, device proof open):
  no user steps yet — Mac-side session. `FluxStream/WebcamProducer.swift`
  is the camera drain (new): `AVCaptureSession` (720p/1080p preset by
  short side) → `H264VideoEncoder` at the announced size → `LiveOffer`
  chunks, with a center-crop to the announced size for non-16:9 aspects
  (the desktop fixes its virtual camera to the `start` dimensions),
  front/back switching + zoom/exposure/WB/mirror applied live without a
  restart, `CameraAccess` permission gate, and an injectable source
  (stub-tested like `MicProducer`: chunks flow, failed start holds
  nothing, restart stops first, live-apply forwards, caps flow, plus
  real-buffer crop proofs). `WebcamPreferences` persists the settings
  (Android `WebcamSettings` parity, caps excluded — they come from the
  live camera). `LinkRunner.webcamConfigReceived` now carries the desktop
  partial (the router always had it; the event dropped it), so `flux
  webcam set/reset` applies: reset-first merge, clamp to live caps, save,
  restart on frame-size change (`stop` + fresh `start`, Android
  `restart` parity), live-apply otherwise. `RemoteScreensState` grew the
  webcam status; `ContentView` shows Camera per computer (the webcam tab
  drives `StreamSession`; text/QR/photo/document tabs drive one-shot
  capture sessions — code-done 2026-09-28, device proof open, see the
  fifty-second finding). `FluxApp` mirrors the mic
  exactly (generation guard, 3 s RST-echo grace, `session.send` nil so
  the stop goes out once via `link`, encoder-death announce) and consumes
  the withWebcam flag: webcam Live auto-starts an idle mic and the
  webcam stop ends that companion mic (a user-started mic is never
  touched — Android `WebcamPanel` parity). Known v1 gap: color-matrix
  keys (`brightness`/`contrast`/`saturation`/`warmth`) are stored +
  reported but not image-applied (no `AVCapture` control; Android does
  it in GL). SDK note: `videoMaxZoomFactor` is gone from
  the current SDK (sim build caught it — SPM mac builds never see iOS
  API removals); the code uses `maxAvailableVideoZoomFactor` (iOS 11+).
  Verified Mac-side: `swift build`, 355/355 SPM tests (10 new:
  producer, prefs, store), sim build green, sim 344 pass / 11 skip /
  0 fail, project regenerated, M5-live loopback re-run (`M5 EXPECTATIONS
  MET`, desktop config partial flows: `WEBCAM CONFIG ... partial=
  brightness`) + M6 loopback re-run (`M6 EXPECTATIONS MET`, zero
  residue, `--forget` clean). After the user rebuilds in Xcode, the
  device run must prove: Camera-tab Start → `flux webcam` shows the
  stream, `set`/`reset`/`stop` from the host, the withWebcam companion
  mic, and Stop → idle with `webcam stopped` on the host.
- Forty-seventh-device finding (2026-09-27, **webcam Start reaches the
  desktop, which has no virtual camera — phone side fully green**):
  Camera-tab Start (after a rebuild + Devices-banner-connected check;
  the previous tap had landed in a reconnect window with Start
  disabled and no reason shown — the tab now prints "The webcam needs
  a connection." like Mic/Mirror) → permission → drain → offer →
  `streamStarted kind=webcam port=1739` → desktop answered `error`:
  "the v4l2loopback module is not loaded…", and the tab shows it in
  red with the config + Start, app alive, session idled without
  announcing (the desktop already knows). So the whole phone chain
  (capture → encode → offer → serve → desktop dial) works on hardware;
  the bytes died on the host, which never had v4l2loopback (no module,
  no `/dev/video*`). Host fix, same session: `pacman -S
  v4l2loopback-dkms` (DKMS built clean for 7.2.5-3-omarchy) — but the
  desktop's own prescription (`modprobe v4l2loopback devices=0`) yields
  NO `/dev/v4l2loopback-control` on this kernel/module combo (0.15.4:
  `devices=0` creates nothing, `devices=1` creates only `/dev/video0`,
  never the control node), so the dynamic-add ioctl path is dead here.
  Workaround: a pre-labeled static device — `modprobe v4l2loopback
  devices=1 card_label="Flux Camera" exclusive_caps=1` + `chmod 666
  /dev/video0` (user `ed` is not in `video`; fluxd reuses the label
  match via `findLoopback` and never touches the control node).
  Side note: every host `sudo` prints "Approve on iPhone…" (flux-approve
  PAM) and falls back to the piped password after ~20 s — plan one
  approve cycle per sudo, or approve on the phone to go faster.
  Retest still open: tap Start → desktop `live` on `/dev/video0`.
- Forty-eighth-device finding (2026-09-27, **webcam live green on
  hardware, sustained — D16 webcam half done**): after two transient
  `handshakeFailed(-50)`s (phone killed the server handshake twice;
  never reproduced since — mic stayed green throughout on the same
  engine/identity/dialer, then three green webcam sessions, so filed
  as transient-undiagnosed, prime suspect a fresh-link race), one tap
  → `streamStarted port=1739` → bytes → `webcamLiveReceived(
  /dev/video0, "Flux Camera")` → tab "Live on archlinux as Flux
  Camera". Three sessions: 20841 B (sha `bcf1…`, quick Stop), 15409394
  B (sha `18bf…`, sustained), 5772263 B (sha `ef98…`, sustained) —
  every byte H.264 through the shared framer. Image integrity proven
  with three host frame grabs off `/dev/video0` (1280x720 YU12,
  ffmpeg consuming at 30 fps): the phone was filming the dev Mac, and
  terminal text is legible in all three. `flux webcam set zoom=2`
  applied live mid-stream (2x grab), `reset` restored 1x (grab) —
  desktop→phone config fully green (silent in console by design: it
  surfaces on the status line only). Host `stop` ends clean (ffmpeg
  exits, journal `webcam stopped`, no crash). Phone-side Stop ends
  clean every time (`streamDone` + idle, app alive).   Wart noted (not
  fixed): user-Stop can race the end-of-stream announcement and send
  the stop packet twice — the desktop treats it idempotently; fix
  batched with the next session-code touch. Still open in D16:
  geometry-change restart (`set resolution`/`aspect`), desktop-stop
  console proof (`webcamStopReceived` has never appeared in a device
  console — all session ends so far came from phone taps), and the
  withWebcam companion run.
- Forty-ninth-device finding (2026-09-27, **the `-50` pattern:
  server-handshake flake after recent TLS activity**): sixth
  occurrence, this time tapping webcam Start with the mic already
  streaming (meter moving) — `streamStarted` → `handshakeFailed(-50)`,
  mic unaffected. Unified theory, fits all six reds and all nine
  greens: the phone-as-Server SecureTransport handshake flakes when
  another TLS context was used seconds before (fresh link handshake +
  welcome burst in #1/#4, teardown closes in #2/#3, continuous mic
  writes in #6), and succeeds on a quiet system (all greens had
  minutes-idle links; mic re-offer EOFs in finding 44 read as the same
  instability with a different symptom). Client-role handshakes are
  100% (dozens, including every link).   Candidate robustness fix
  (NOT built): one quiet re-offer inside `serveLiveOne` on
  handshake failure instead of surfacing red — needs care so the
  desktop's EOF-error doesn't poison the retry. Workaround for
  device runs: pace the taps (30 s quiet before Start).
- Fiftieth-device finding (2026-09-27, **restart proven at 1080p,
  sixth `-50`, mic-echo ambiguity**): the evening's biggest console
  shows the desktop-initiated restart end to end —
  `webcamConfigReceived(resolution: 1080)` → `streamDone(1969357)`
  → fresh `streamStarted(1739)` → `webcamLiveReceived(/dev/video0)`
  → sustained 1080p (host: `live … 1920x1080 at 30 fps`, format +
  black frame — phone face-down, then legible frames after uncovering;
  the 1080p encoder path is green). Same console shows the sixth
  `-50`: tapping webcam Start with the mic already streaming (meter
  moving) → `streamStarted(1739)` → `handshakeFailed(-50)` → desktop
  RST, mic unaffected at first — then `streamFailed(mic, "closed")`
  minutes later with four desktop `microphone stopped` lines for one
  phone mic session. `closed` from a write means the desktop stopped
  reading first, so the mic death is someone's echo (user Stop taps
  vs. desktop audio death — taps unconfirmed, user signed off before
  clarifying). Still open after tonight: desktop-stop console proof
  (`webcamStopReceived` never captured — every host stop raced a
  phone-side end), the withWebcam companion run, and the `-50`
  root cause (tally 6 red / 9 green; retries always succeed).
- Fifty-first-device finding (2026-09-28, **desktop-stop console
  proof + withWebcam companion green — D16 webcam half done**):
  fresh session, one webcam Start → `live` on `/dev/video0`, 8.8 MB
  streamed — with the withWebcam toggle on, the mic started **on its
  own** mid-stream (no mic tap; `streamStarted(mic)` + progress
  interleaved with webcam progress + `micLiveReceived(Flux
  Microphone)`, both live concurrently with no `-50`). Coordinated
  host `stop` during the live stream finally captured
  `webcamStopReceived` on-device → teardown → `streamDone(webcam,
  8807970 B)`. The companion stopped with it: Mic screen reads
  "Microphone off.", and the host journal shows `webcam stopped` +
  `microphone stopped` in the same second (15:55:04) — the joint
  stop. D16 device remainder is now fully proven: live (720p/1080p,
  sustained), image integrity (legible frame grabs), `set`/`reset`
  (+1080p restart, all console-proven), phone + desktop stops,
   companion start + joint stop — no crash anywhere. Parked, not
   blocking: the `-50` root cause, the duplicate-stop wart, the
   color-matrix gap. Mirror-screen presenting still open (D17-gated
   extension work aside, the app side has no Mirror entry yet).
- Fifty-second-device item (2026-09-28, **captures build code-done,
  Mac-verified, device proof open**): no user steps yet. The seam first
  (D23 pattern for uploads): `LiveUploadBox` per runner (pre-attach
  batches held, served on attach, dropped on detach) +
  `LinkService.sendFiles/sendCaptures` fanning over live runners (false
  with no link — the caller queues or says offline, never half-sent);
  `TransferEngine` now takes a send closure like `StreamEngine` (same
  contract as `LiveSendBox.publish`). Then the sessions (D15):
  one-shot `Text/Code/PhotoCaptureSession` drains (back camera, 30 s
  timeout, `usableText`/`codeIsLink` result gates, `previewSession` bound
  by the new `CameraPreview` — one drain, never two) +
  `DocumentScanner` self-dismiss. Then the library half (D18):
  production `dataForAsset` (`PHImageManager` + HEIC→JPEG +
  `jpegName`), the app `PhotoLibraryWatch` instance with persisted
  auto-upload switches (photo tab; Limited access stays manual-only,
  honestly), and `CaptureOutbox` (offline queue, flush on `.paired` +
  after each capture). Then the closures: text sends as
  `scan:true` shares, code actions as url/text/scan shares, photo/doc go
  staged → outbox → `sendCaptures` (`photo`/`scan` flags); every outcome
  lands on the status line + `flux:` console. Verified Mac-side: `swift
  build`, **371/371 SPM tests** (16 new: `UploadLiveTests` 4/4
  loopback byte-identical + flags, pre-attach hold, detach drop;
  outbox/staging/UTI/gate/prefs units; box-hold + no-session-false
  units), sim build green (2 Xcode-only fixes: `dismiss` main-hop,
  `@unchecked Sendable` drains), sim **356 pass / 15 skip / 0 fail**
  (11 prior + 4 new Keychain-gated), `swift build -c release` green,
  project regenerated, M5 loopback re-run (`M5 EXPECTATIONS MET`,
  zero "no handler") + M6 re-run (`M6 EXPECTATIONS MET`, openssl
  proofs) after the `TransferEngine` refactor, `--forget`
  residue-free. After the user rebuilds in Xcode, the device run must
  prove: text scan → review → Send (desktop `scan_dir`), QR scan →
  action (open/copy/save), photo tap → `photo_dir`, document scan →
  `scan_dir`, library toggle → full-access prompt → new screenshot
  auto-uploads, Limited-access → manual only, offline tap → queued →
  sends on reconnect. Pace taps ~30 s (the `-50` workaround stands).
- Fifty-third-device finding (2026-09-28, **text/QR/photo green on
  hardware, doc queued offline, Limited-access proven**): rebuilt app,
  link up first try (publish → self-browse → desktop dial → TLS OK →
  pinned `paired`, battery 85% charging, command list). Text tab: `text
  scanned (51 chars)` → `scanned text sent to archlinux` — host file
  `~/Documents/flux/scanned/scan-2026-09-28-164641.txt` (57 B) present;
  content is garbled Vietnamese diacritics = a genuine angled Vision
  read, path proven, quality is aim not wire. QR tab: `code scanned
  (qrCode, url)` → `Open on archlinux` + `Copy on archlinux` both sent
  (host effects need user confirm: browser tab? clipboard?). Photo tab:
  `photo captured IMG_20260928_164814.jpg (3516606 B)` → progress
  0/65536/done → `transferCompleted` — host file
  `~/Pictures/flux/IMG_20260928_164814.jpg` byte-count-identical with
  valid JPEG magic (FF D8 FF E1). Toggles: `photo access
  PHAuthorizationStatus(rawValue: 4) — manual picker only` twice =
  Limited access correctly refused with honest status (that leg proven;
  full-access auto-upload still open, user's call). Document tab:
  `document scan staged scan-20260928-164928.pdf (1976874 B)` →
  `flushing 1 capture(s)` → `no link — 1 capture(s) stay queued` (scan
  landed in a no-link window during foreground/background permission
  juggling; the queue behaved exactly as designed — flush pending on
  the next `.paired`). No `-50`, no crash anywhere; the `[C:x]` /
  `DNDErrorDomain 1004` / font-daemon lines are the known system noise.
  fluxd journal confirms link up 16:45:51, one EOF 16:46:06, up since
  16:46:14 (the churn is app foreground/backgrounding, not a bug).
- Fifty-fourth-device finding (2026-09-28, **QR host effects confirmed,
  SIGKILL ate the doc queue — outbox is now kill-proof**): user confirms
  the QR Open opened the desktop browser tab and the QR Copy landed on
  the desktop clipboard — both phone→desktop code actions fully proven
  end to end. The reopened app never flushed the queued doc PDF because
  the process died first: `Message from debugger: Terminated due to
  signal 9` — and the outbox was in-memory `@State`, so the queue died
  with it (the staged tmp file survives, orphaned). Fix, Mac-verified:
  the outbox persists to `UserDefaults` on every mutation and restores
  on launch (missing files dropped — tmp purge across reboot), so the
  next kill-then-reopen resumes the queue and flushes on `.paired`
  (372/372 tests, sim build green). The pre-fix PDF needs one re-scan.
  Same round: access is still Limited (`rawValue: 4`, Full is `3`) —
  the "done" was more Limited taps (eleven `manual picker only` lines);
  iOS won't re-prompt, so the toggle now points at Settings → Apps →
  Flux → Photos → Full Access. Bonus inbound proof in the screenshot:
  `saved IMG_20260928_165848.jpg (4775468 B) from archlinux` —
  desktop→phone receive healthy.
- Fifty-fifth-device finding (2026-09-28, **doc flush + second photo
  green on hardware**): after the rebuild, the re-scanned document
  arrived — host `~/Documents/flux/scanned/scan-20260928-170455.pdf`
  (2,427,723 B, `%PDF-` magic valid). D15 document leg host-proven
  (the queue-durability fix itself is unit-tested; a kill-reopen
  round-trip on hardware stays open). A second photo arrived the same
  minute — host `~/Pictures/flux/IMG_20260928_170438.jpg` (5,283,999 B,
  JPEG magic valid). Its `IMG_<timestamp>` name is the manual-photo
  shape, so the screenshot auto-upload leg still needs one
  screenshot-shaped proof (asset filename + `screenshot` flag).
- Fifty-eighth-device finding (2026-09-28, **D18 done: screenshot
  auto-upload green end to end**): the rewritten scan fired on
  foreground — `watch: scan found=4 uploaded=4 unresolved=0 sent=0`
  — and all four phone screenshots staged + sent + `transferCompleted`
  (126485 / 60205 / 1014732 / 69722 B). Host: all four land in
  `~/Pictures/flux/screenshots/` byte-count-identical with valid PNG
  magic — the `screenshot` flag routes to the screenshots folder, not
  `photo_dir`. Full-access prompt run, smart-album mapping,
  foreground upload, offline queue (doc round), and Limited-manual-only
  are all proven on hardware: D18 is done.
- Fifty-sixth-device item (2026-09-28, **watch silent while switches
  look on — observability fix, no code proof yet**): two screenshots
  (app-open + backgrounded-then-reopened) never uploaded and the
  console shows why nothing explains it — `scanNow` logged nothing on
  any skip path. The link itself is fine (paired, then a clean
  background/foreground republish with no desktop dial yet when
  pasted). Prime suspect is switch/baseline state, not the wire: every
  successful toggle enable was refused under Limited, so "still on"
  needs one fresh enable under Full to reseed the baseline anyway.
  Fix, Mac-verified: `PhotoLibraryWatch.log` sink (app prints it with
  `flux:`) covering observe start/stop plus per-scan
  found/uploaded/unresolved/old/sent counts; screenshot assets now map
  exclusively to the screenshot kind (they live in the user library
  too — without this every screenshot would upload twice, Android
  folder parity). 372/372 tests, sim build green. Next round needs the
  `watch:` lines, which name the exact skip.
- Fifty-seventh-device item (2026-09-28, **the watch scan was
  quadratic — rewritten to predicate fetches**): the new `watch:
  observing (screenshots=true photos=false)` line proved the switch is
  on, but no scan summary ever followed. Root cause, code-read: the
  old `scanNow` enumerated the whole library and re-fetched entire
  albums per asset (`inAlbum`) — on a real-size library the first scan
  never finishes, so the end-of-scan summary never prints (every
  earlier silent round was this, not missing logs). Rewrite,
  Mac-verified: album membership once per scan (`ids(in:)`), arrivals
  via `creationDate > baseline` predicate fetches per album (the scan
  is proportional to new arrivals, not library size), screenshot
  exclusion by ID set (keeps the no-double-upload fix). 372/372
  tests, sim build green. The two test screenshots postdate every
   baseline (off+on never reseeds by design — only nil entries seed),
   so no new screenshot is needed: reopen the app and they should go
   within seconds.
- Sixtieth-device item (2026-09-28, **scan-tab preview blank on
  hardware, fixed by code read**): the user reported spinner + hint only,
  no camera image, on the text/QR tabs. Root cause: `CameraPreview` sized
  its `AVCaptureVideoPreviewLayer` once in `makeUIView`, when the view
  bounds are still zero — nothing ever resized it afterwards, so the layer
  stayed zero-sized over a live running session. Fix, Mac-verified: a host
  view (`PreviewHostView`, iOS + macOS) owns the layer and tracks bounds
  in `layoutSubviews`/`layout`. 384/384 SPM, sim 369 + 15 skip / 0 fail,
  release green. The next device scan must show the live preview.
- Sixty-first-device finding (2026-09-28, **mirror live on the host,
  then a zombie with no Stop button — both fixed**): the user confirmed
  the live camera preview renders AND the mirror Start shows the phone
  screen on the Linux host (mpv) — the image path is green end to end.
  But the Mirror screen then showed "needs a connection" with no buttons
  while bytes still flowed (`streamStarted screen`, `screenLiveReceived
  (mpv)`, progress to 90 KB). Root cause: `link.stop()` (background +
  every foreground restart) closes the listener and clears the runner
  registry while the live session socket survives (deliberate — D22
  approval needs it), so presence stuck at `reconnecting` with a live
  stream the UI couldn't see or stop, and `sendCaptures` refused with
  "no link" (the staged `IMG_9051.PNG` stayed queued — the outbox working
  as designed; it flushes on the next `.paired`). The desktop side
  self-resolved via EOF (`screen mirror stopped`, no mpv left). Fixes,
  Mac-verified: Stop is now first and never presence-gated on
  Mirror + Mic screens (the webcam tab already was), and backgrounding
  ends all three live captures BEFORE `link.stop()` so the announces go
  out (each stop no-ops when idle; approvals untouched). 384/384 SPM,
  sim 369 + 15 skip / 0 fail, release green. Still open: mirror Stop
  proof, a background/foreground round-trip, and the photo leg.
- Sixty-second-device finding (2026-09-28, **Stop flow green, then the
  `.inactive` hole — fixed**): rebuilt app, mirror Start live + Stop
  button visible while live (Fix 1 proven), Stop tap → clean
  `streamDone(screen, 19173 B, sha)` ending, Mirror screen correctly idle
  ("needs a connection" with presence reconnecting). But the console shows
  `scene foreground` twice with NO `scene background` between — `.active`
  also fires on `.inactive` blips (notification shade, switcher), which
  restarted the link without the background teardown: same orphan, and
  presence stuck `Reconnecting...` with two screenshots queued behind
  "no link" again. Fix, Mac-verified: `startLink()` returns early under
  any live mic/webcam/mirror session (relaunch + background return +
  idle recovery unaffected — teardown idles every session first). 384/384
  SPM,   sim 369 + 15 skip / 0 fail, explicit app-target sim build green
  (SPM never compiles `App/` — the earlier runs didn't cover `FluxApp`;
  now checked), release green. Host shows iPhone online with no stuck
  runner and no mpv. Still open: the two queued screenshots' flush on the
  next `.paired`, the background round-trip, and the photo leg.
- Sixty-third-device item (2026-09-28, **queued screenshots never
  flushed — take-then-send loss, fixed delivery-tracked**): after a fresh
  launch + `.paired` with an empty-looking outbox (no `flushing` line) and
  `sent=5` (ledgered arrivals, baseline never advances, ledger survives
  rebuilds). Diagnosis: `flushCaptures` did `takeAll()` (queue emptied +
  persisted) BEFORE sending, and `.transferFailed` only set the status
  line — a transfer dying mid-flight in the link churn lost the capture
  permanently (ledger already says sent, tmp file orphaned). That is what
  ate `IMG_9051/9052` (flushed into the churn, host never got them, watch
  will never retry them — they are gone; fresh screenshots re-prove the
  leg). Fix, Mac-verified: peek-only flushes, an in-flight path set,
  items leave the outbox only on `transferCompleted` (matched by staged
  path — inbound Downloads paths can never qualify), failures stay queued
  for the next flush, `.closed` forgets outcomes (at-least-once, the host
  renames dups), delivered staged files are deleted (tmp hygiene), and the
  outbound completion finally says "sent … to …" instead of the
  inbound "saved … from …". 387/387 SPM (3 new outbox units), sim 372 +
  15 skip / 0 fail, app-target build + release green.
- Reconnect analysis (2026-09-28, code-read, no change): the desktop
  redials only on discovery AND only with no live link
  (`HasLink` gate in `provider.go` — a stale socket blocks redial until
  TCP keepalive kills it, ~10 s idle + 3×5 s ≈ 25 s; plus `dialKnown()`
  every 30 s); the phone sends no UDP on the free tier, so foreground
  returns wait on keepalive + mDNS re-resolve + dial. The 13-minute gap
  in the journal is background time (no publish, correctly dead). A timed
  background/foreground experiment will pin the real number before any
  further work.
- Sixty-fourth-device item (2026-09-28, **reconnect stalemate proven,
  background FIN built**): Home 18:35 → reopen 18:36 → still
  Reconnecting at 18:37 with the phone publishing and the desktop never
  dialing (exactly one `plaintext identity` + one `.paired` in the
  console). Mechanism: suspend leaves a half-open socket neither
  keepalive kills (probes get ACKed), desktop `HasLink` stays true, and
  the identical mDNS republish triggers no fresh resolve — both sides
  idle forever. Relief: `systemctl --user restart fluxd` → `link up
  paired=true` in seconds (iPhone online). Fix, Mac-verified:
  `LinkRunner.close()` (takes-and-clears the session fd, then
  `shutdown(SHUT_RDWR)` — a kernel-serialized reader wakeup, never a raw
  cross-thread close, so the teardown still closes exactly once; the
  LiveChannel lesson) + `LinkService.closeSessions()` + the app calls it
  on background after the stream stops, unless an approve/pair prompt is
  open (the D22 answer and the handshake still need their session).
  387/387 SPM, sim 372 + 15 skip / 0 fail, app-target build + release
  green; M5 loopback re-run (`M5 EXPECTATIONS MET`, all three LIVEs,
   zero no-handler) + M6 re-run (`M6 EXPECTATIONS MET`, openssl proofs,
   `--forget` residue-free) after the `LinkRunner` touch. Still open: the
   device proof (background → journal EOF → foreground → fast redial),
   fresh screenshots, and the photo leg.
- Sixty-fifth-device finding (2026-09-28, **reconnect + uploads + photo
  leg all green on hardware**): background → `closed(archlinux)` on the
  phone (the FIN works) → foreground → republish → dial → paired, banner
  flipped within 1 s (user-timed, 19:16); journal shows the EOF→redial
  cycle repeating cleanly (17–24 s worst case on the desktop tick).
  Screenshot leg re-proven through the new delivery tracking:
  `IMG_9055.PNG` staged → progress → `transferCompleted` → "delivered,
  dropped from outbox", host file byte-identical (66,598 B, PNG magic)
  in `screenshots/`. Photo leg proven: a Camera-app photo taken while
  backgrounded staged on return (`IMG_9056.jpg`, 4,887,060 B — the
  HEIC→JPEG transcode on a real asset), queued honestly behind the dead
  link ("no link — stay queued"), flushed on `.paired`, delivered +
  dropped; host file byte-identical with JPEG magic in `photo_dir/`.
  Ledger advances (`sent=5` → 6 → 7), outbox empty, no dupes. Mirror
  app-side, preview fix, zombie fixes, outbox durability, and reconnect
  are all device-proven; remaining open device work: D15 kill-reopen
  round-trip, CallKit/Focus flows (D23), screen desktop-stop console
  proof, and the M7 TestFlight remainder.
- Sixty-eighth-device finding (2026-09-28, **CallKit ringing + missed
  proven end to end, with media pause/resume**): carrier call from a
  second phone, Flux reopened mid-ring over the fast redial. Phone:
  `call ringing sent=true`, then on decline `call missedCall sent=true`
  + `call ringing (end) sent=true` — the exact tracker-spec sequence.
  Desktop journal: `call ringing cancel=false` → `call missedCall
  cancel=false` + `call ringing cancel=true`; mpv paused on ringing and
  resumed on end (`pause_media_on_call` chain green both ways, verified
  via playerctl; stand-in player killed + wav removed after). Number
  nowhere by design ("Unknown caller"). Side note: the rebuild minted a
  fresh device ID (`ff44…`, Keychain cleared — reinstall = re-pair per
  the M1 contract), so the desktop now lists a stale offline `366f…`
  iPhone beside the live one. Still open: the `talking` leg (answer
  instead of declining) and the Focus boolean (device still reads
  false).
- Sixty-ninth-device finding (2026-09-28, **CallKit `talking` leg proven
  — telephony complete**): answered the carrier call, talked, hung up.
  Phone: `call ringing sent=true` → `call talking sent=true` → `call
  talking (end) sent=true`. Desktop journal: `ringing` 19:58:10 →
  `talking` 19:58:13 → `talking cancel=true` 19:58:21; mpv paused on
  ring and resumed on hangup (playerctl; stand-in cleaned after).
  Ringing + talking + missedCall + both cancels are now green with
  pause/resume both ways. Only the Focus boolean remains (this device
  still reads false — parked Apple quirk).
- Sixty-seventh-device finding (2026-09-28, **D15 kill-reopen round-trip
  proven on hardware**): staged `IMG_9058.PNG` offline ("no link — stay
  queued"), swipe-killed the app, reopened — the file arrived with no
  re-scan (the watch ledger already called it sent, so the only path is
  outbox restore → flush on `.paired` → delivery). Host file
  byte-identical (83,044 B, PNG magic). The staged tmp file survived the
  kill and the persisted queue resumed. D15 device work is done.
- Sixty-sixth-device finding (2026-09-28, **screen desktop-stop proven,
  mirror chapter closed**): coordinated host `flux screen stop` during a
  live 450 KB mirror → `screenStopReceived(archlinux)` on-device →
  teardown → idle, recorder stopped, app alive; host journal `screen
  mirror stopped`, no mpv left. Same console also shows `link restart
  skipped (live session)` firing on an `.inactive` blip mid-stream with
  the mirror surviving it — the startLink guard working in production.
  No `-50`, no crash anywhere. Remaining open device work: D15
  kill-reopen round-trip, CallKit/Focus flows (D23), and the M7
  TestFlight remainder.
- Fifty-ninth-device item (2026-09-28, **mirror app-side code-done,
  Mac-verified, device proof open**): no user steps yet. The seam is the
  D16 mic/webcam pattern, foreground-only, free-tier compatible (no
  extension): `FluxStream/ScreenProducer.swift` (new) bridges the in-app
  `RPScreenRecorder.startCapture` drain (video buffers only — audio
  dropped, the screen protocol carries H.264 video) through the shared
  `H264VideoEncoder` into `LiveOffer` chunks; the announced size fits the
  screen (`MirrorScreenSize` → `MirrorSize.fit`, long side ≤1080,
  16-aligned) with vImage scaling for mismatched frames (absorbs a
  mid-stream rotation; the desktop window stays fixed). `RemoteScreensState`
  grew the mirror status, `ContentView` lists Mirror screen per computer,
  and `FluxApp` owns the session (generation guard, 3 s RST-echo grace,
  recorder-death announce, `.closed` teardown — every rule the webcam
  session has). Verified Mac-side: `swift build`, **384/384 SPM tests**
  (11 new producer/size/scale + 1 store), sim build green (1 Xcode-only
  fix: `UIScreen.main` MainActor isolation SPM never sees), sim **369
  pass / 15 skip / 0 fail** (no new skips), `swift build -c release`
  green, project regenerated. Additive-only (no packet/session/wire
  touch), so no loopback re-run. After the user rebuilds in Xcode, the
  device run must prove: Mirror-screen Start → desktop `mpv` window,
  Stop → idle, desktop-stop console proof. The broadcast-extension path
  stays D17-gated (paid team).

Verified: pair run shows key `F709B1DD` (recomputed from both DERs +
timestamp, byte-identical); pinned reconnect skips pairing; peer prints
`M5 EXPECTATIONS MET` for all three starts + scanned text + both captures;
checksums match both sides (webcam 8192 B, mic 192000 B / 2 s sine, screen
2304 B; scan PDF 82895 B, photo 8202 B); peer logs every desktop reply
(`WEBCAM LIVE`, `WEBCAM CONFIG`, `MIC LIVE`, `SCREEN LIVE`); the desktop
sees all three stops + the `photo`/`scan` flags; mutual-TLS pin checks pass
on all five byte connections; zero "no handler"/"unadvertised" lines.
Parked follow-ups (on-device capture/encode/ReplayKit runs, background
behavior) are logged in `docs/ios-plan.md` §14.

## Approval (M6)

`FluxApprove/` owns the M6 wire beside the M0 message bytes: `ApprovePackets`
parses desktop→phone `request`/`enroll`/`cancel` (Android `parse` rules:
kind allow-list, id ≤64 chars, required host/user/service-per-kind,
tty/rhost/timeout defaults, 5…120 s clamp, field + nonce rules) and builds
the phone→desktop replies (`approved` DER, `denied`, 200-char `failed`,
`enrolled` pubkey + proof — Go `handleApprove` shapes). `ApproveKeys`
manages one P-256 key per desktop under the Android alias
`flux-approve-<computer device ID>`: production keys use Secure Enclave +
`biometryCurrentSet` + per-use `LAContext` (per-use Face ID / Touch ID,
invalidated by a new biometric enrollment → enroll-again error, Android
`KeyPermanentlyInvalidatedException` parity); `createTestKey` is the
harness-only non-biometric path (same alias + DER wire, every reply logged
`TEST MODE (no biometric)`). Signatures are DER end-to-end
(`ecdsaSignatureMessageX962SHA256`, never transcoded); verification
(enrollment self-check + unit fail-closed matrix) uses CryptoKit, because
`SecKeyCreateWithData` rejects even openssl-made P-256 SPKIs with `-50`
on this Mac. `ApprovalsStore` is the one-at-a-time machine (busy/clock/
no-key/invalid refusals, cancel, local timeout — Android `Approvals`
parity); `FeatureRouter` runs it with capability + pairing gates
(refusals go straight back on the wire); `LinkRunner` emits prompt events,
runs the decider off the session thread (late answers for closed prompts
are dropped by id, never sent), and schedules the local timeout.
`FluxUI/ApproveViews.swift` ports the prompt (ask / key-code / failed
phases + previews); `FluxFeatures/ApproveNotifications` builds the
time-sensitive lock-screen notification + Approve/Deny category
(content mapping unit-tested; over-lock delivery is device-gated).

`FluxTestPeer` gains `--exercise-m6` (enroll + approve with test-mode
signatures), `--approve-deny` (deny approvals; enrollments still approved),
and `--approve-delay N` (answer N seconds late, so cancel/timeout win the
race); `--forget` also deletes every enrolled approval key (reported count).
`test_peer.py` gains `--m6` (helper role like `cmd/flux-approve`: fresh
32-byte nonces, openssl verify of each phone signature against the enrolled
pubkey, replay/tamper/wrong-key must-REJECT checks, stale/bad-nonce wire
probes, cancel-safety) plus `--m6-delay` (strict cancel: the cancelled
request is never answered while the next is approved) and `--expect-m6`
(`M6 EXPECTATIONS MET` or exit 1). The desktop identity now advertises
`flux.approve` incoming, like Go's `Incoming`.

E2E (loopback, pinned like M1b/M3/M4/M5):

```sh
swift run FluxTestPeer --persist --dump-cert /tmp/phone.der   # pair first
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --m6 --expect-m6 --seconds 120
# strict cancel-clear variant (prompt still open when cancel lands):
swift run FluxTestPeer --persist --approve-delay 5
python3 -u tools/test_peer.py --host 127.0.0.1 --port 1716 --phone-cert /tmp/phone.der \
  --m6-delay --expect-m6 --seconds 240
```

Verified: pair keys recomputed from both DERs + timestamp match byte for
byte on every run (`21949B6D`, `050214A3`, `1915E65C`, `EA6AB5CB`);
`M6 EXPECTATIONS MET` for enroll + approve (both `openssl Verified OK`
over helper-made nonces) + replay/tamper/wrong-key `openssl REJECTED` +
stale/bad-nonce failure packets + cancel-safe/cancel-cleared; the deny run
gets `{"kind": "response", "denied": true}` and fails closed; the key code
on both sides matches (`1309 4DBF CE15 F8BD`); local timeout expiry observed
(`APPROVE EXPIRED`, next request held instead of busy-failed); zero
"no handler"/"unadvertised" lines; 304/304 tests green,
Keychain-residue-free (`--forget` removes identity + trust + approve keys;
ephemeral runs self-clean on SIGTERM). Re-verified 2026-09-27 after the
pinned-reconnect `.paired` emit below: `M6 EXPECTATIONS MET`
(enroll + approve `openssl Verified OK`, key code `C31D 4407 EC84 2F6F`
both sides), with the new `PAIRED with <device> key=` line on the pinned
reconnect by design; `--forget` residue-free (approve keys: 1). Parked follow-ups (real-PAM check,
on-device biometric runs, lock-screen actions, background delivery) are
logged in `docs/ios-plan.md` §14.

M6 platform findings (do not rediscover):
- Python's `makefile()` buffered TLS reader can lose packets that arrive
  around a socket-timeout boundary (missed answers in delay runs with
  `sent=true` on the peer). `test_peer.py` now reads through a manual
  `TLSLines` buffer that preserves bytes across timeouts — if E2E misses a
  packet the peer log says it sent, suspect the reader first.
- Expiry needs a live clock: freezing the store clock to the packet's
  `nowMs` (for deterministic freshness tests) also freezes the timeout
  deadline — the phone then never expires prompts locally (caught by a wire
  probe: second request busy-failed past the first timeout; fixed by
  reading the live clock in `routeApprove`).
- `swift build --target X` may not relink the executable: after changing
  peer sources, run plain `swift build` (or `swift run`) and check the
  product under `.build/debug/` (a symlink to the arch dir). A stale peer
  binary mimics a hung decider (prompts, no answers).
- An executable target with `@main` in `main.swift` breaks when a second
  file joins the target; the entry now lives in `FluxTestPeer.swift`.
- Ad-hoc signature churn vs. Keychain: every rebuild changes the signature
  and old ACLs stop matching — persist reads then fail (`signingFailed`)
  or, with a stuck `SecurityAgent` prompt, hang. `--forget` + re-pair
  recovers; prefer ephemeral peers for iteration, `kill` (TERM, never
  `kill -9`, which also orphans the ephemeral key) for shutdown, and ask
  the user to clear a lingering approval dialog before persist runs.

### M6 security review (harness scope, per `docs/approve.md` §5)

Done as analysis against this implementation, not a formal audit (which
M7 still requires before TestFlight). Attacker by attacker:

- **Network attacker** (reads/changes/sends Wi-Fi traffic): covered by
  the existing link — TLS 1.2 with pinned certificates both ways
  (M1b/M3/M5 E2E procedure, re-verified on every M6 run). Approval
  messages add nothing readable: the signature binds host/user/service/
  tty/rhost/time/nonce, and the helper (here: `test_peer.py --m6`)
  rebuilds the bytes from its own fields — replay/tamper/wrong-key all
  `REJECTED` by openssl on the wire. No new network surface: the phone
  sends no new packet type the desktop doesn't already accept
  (`flux.approve` is in Go's `Incoming`).
- **Code that runs as the user** (malicious `fluxd`, key-file writes):
  unchanged from the design — it can stop approvals (fail closed to the
  password), send bogus prompts (the phone shows service/user/host/time;
  signing still needs the finger), and start `sudo` hoping for fatigue
  approval (open risk, documented on the prompt screen itself). It cannot
  forge a signature (key is biometric-gated), reuse one (nonce-bound,
  proven), or redirect the trust anchor (helper key path is fixed;
  enrollment code comparison is the user's job, shown on both screens).
  iOS-specific: test-mode keys (`createTestKey`) share the alias scheme
  but never the biometric gate — grep `createTestKey`; production
  `create` is the only Keychain path and always sets `biometryCurrentSet`.
- **A person with the locked/unlocked phone**: no approval without the
  biometric (production keys sign only through a per-use `LAContext`;
  the invalidated-key path deletes + reports enroll-again). Deny is
  always available (notification action + prompt button). Not verified on
  hardware: Face ID prompt over the lock screen, enrollment-change
  invalidation on a real Secure Enclave (D20/D21).

Out of scope (unchanged): root on the computer, broken phone hardware,
and users who approve without reading. Residual risks carried to M7:
no key attestation (design open risk), approval fatigue (UI mitigations
only), and the formal pre-TestFlight audit itself.

## Hardening + TestFlight (M7)

Non-device M7 work is done; anything needing hardware, Apple approvals,
or the Xcode project stays parked (D5/D7/D15–D22):

- **Background-reconnect UX** (plan §3.2): `FluxUI/ConnectionBanner.swift`
  adds `LinkPresence` (`connected`/`reconnecting`/`suspended`/`offline`)
  + a display-only `ConnectionBanner` with the honest copy ("Background
  suspended — open Flux to stay connected"), previews per state, and 5
  `FluxUITests` contract tests. `ContentView` takes a presence value; the
  Xcode project wires a live source later (D7).
- **Battery audit:** static pass finds no background polling in
  `ios/Sources` (clipboard is foreground-only, Focus refreshes on
  foreground + foreground timer, capture queues wait for the link, no
  BGTasks registered). Device Energy Log procedure: install the TestFlight
  build, run the link foreground 30 min + background 2 h, compare Energy
  impact against the Android app; still open (needs hardware).
- **App Store pack** (`ios/AppStore/`, closes D8): `description.md`
  (store copy with the iOS-limitations section, sourced from below + the
  M6 biometric note), `review-notes.md` (self-signed TLS + pinning,
  Enclave signing, background-modes justification, crypto notes, demo
  path), `release-checklist.md` (mirrors `docs/releasing.md`: version/
  build bumps, bundle ID + team, `aps-environment`, screenshots,
  TestFlight beta, `flux doctor` proposed text), `security-audit.md`
  (formal pre-TestFlight audit closing the M6 review: TLS 1.2 floor,
  mutual pinning, test-mode containment re-audited, Keychain posture,
  input validation, residuals incl. D19–D22).
- **`PrivacyInfo`/entitlements/`Info.plist` audit** (plan §3.3):
  `NSFaceIDUsageDescription` was **missing** — without it Face ID
  evaluation fails and M6 enrollment is dead on device — now present;
  unused SystemBootTime/DiskSpace `PrivacyInfo` entries removed (only
  UserDefaults + FileTimestamp are called); `UIBackgroundModes` stays
  empty with the TestFlight gate documented in-file; Contacts/Speech
  correctly omitted; `aps-environment` production + keychain-sharing
  rules captured in the release checklist.
- **Keychain-residue fix:** `ApproveKeys.saveIndex` deletes the
  enrolled-computer index item when empty instead of storing `[]`
  (previously every `make ios-test` left an orphan item; found + removed
  one dated 2026-09-26). New `testEmptyIndexDeletesItem` proves it.
- **CI:** `ios.yml` gains `swift build -c release` (the `assembleRelease`
  analog). SwiftLint stays advisory-only: no config exists and defaults
  fail on pre-existing style — gating would break the build.

Re-verified E2E after the `ApproveKeys` change (loopback, pinned, fresh
pair): pair key `F036D020` recomputed from both DERs + timestamp
byte-identical; `M6 EXPECTATIONS MET` (enroll + approve `openssl Verified
OK`, replay/tamper/wrong-key `REJECTED`, stale/bad-nonce/cancel-safe);
peer-side key code `F702 58E0 45C1 3941` matches the desktop side; zero
"no handler"/"unadvertised"; 310/310 tests green; `--forget` leaves zero
residue (approve keys: 1 removed, index gone).

Open M7 gates (owner/hardware): D5 multicast entitlement + App ID, D7
Xcode project + simulator/device run (blocks `shot.sh` screenshots —
Xcode 16 + iOS 18.4 simulators exist on this Mac, but `ios/` is SPM-only
with no app target yet), TestFlight upload + beta, `flux doctor` note
(proposed text in the checklist; v1 rule — no CLI changes from this
track), D15–D22 device runs.

## Screenshots

```sh
ios/tools/shot.sh media /tmp/media.png
ios/tools/shot.sh home /tmp/home.png "iPhone 16"
```

Pages mirror Android: `devices home media commands browse mic camera`,
`camera:<mode>` (`text qr photo document webcam`), `ring pair unpair`,
`<page>@offline`, `empty`, `icon`. Release builds ignore the extras.

## iOS limitations (v1, by design)

- No SMS send/receive on iPhone — Messages shows "Not supported on iOS".
- No global notification mirror — only Flux-internal, missed-call, and
  desktop→iOS requests render.
- Focus/DND is share-only (boolean); the desktop cannot set iOS Focus.
  Focus refreshes on foreground (iOS offers no change callback).
- Calls report ringing/talking/missed with no number — the desktop always
  shows "Unknown caller" (iOS exposes no call number to third parties).
- Desktop volume changes are ignored (no remote volume API); album-art
  payloads are deferred (the phone publishes no `mpris` state in v1).
- Background links suspend ~30 s after backgrounding — open Flux to stay
  connected. Audio/ReplayKit streams keep the link alive while active.
- Clipboard sync is foreground + manual push only (`auto_clipboard` off).
- SFTP browse is read-only; serving iPhone files over SFTP is deferred.
  Received files (browse downloads + `flux send`) land in the app's
  Downloads folder and are reachable in-app: the Devices list has a
  "This iPhone" section with a plain Downloads row (same style as the
  per-computer rows) listing them with QuickLook preview, share sheet
  (Save to Files, AirDrop, Open In), and delete.
- M5 needs hardware for live runs: camera/mic capture, the VideoToolbox
  encoder (spike-tested on a Mac, not on a phone), the ReplayKit broadcast
  extension (Xcode target, broadcast entitlement, App Group config), and
  the photo-library watch. The wire, framing, sessions, and bytes are
  E2E-held through the harness; on-device focus, background, and App Review
  behavior are open items in the deferred-work log, not verified here.
- M6 needs hardware for the biometric gate: per-use Touch ID signing,
  enrollment-change invalidation, re-enrollment, lock-screen
  Approve/Deny, and background approval are all proven on the SE2
  (D19/D20/D21/D22 done 2026-09-27). The harness exercises the full
  wire with explicitly labeled non-biometric test keys.

## Icons

SF Symbols (not Material Symbols). Keep names in
`Sources/FluxUI/Icons.swift` (later phase), mirroring `ui/Icons.kt`.
