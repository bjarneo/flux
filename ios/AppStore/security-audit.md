# Flux for iOS — pre-TestFlight security audit (M7)

Closes the M6 review residual (`ios/README.md` "M6 security review": the
formal audit was still open). Method: `docs/approve.md` §5 threat model
applied to this implementation, verified against `ios/Sources` (not from
memory). Out-of-scope per the design (root on the computer, broken phone
hardware, users who approve without reading) stays out of scope.

## 1. Network attacker (reads/changes/sends Wi-Fi traffic)

- **TLS floor:** `FluxNet/SecureTransport.swift` sets
  `SSLSetProtocolVersionMin(ctx, .tlsProtocol12)` — TLS 1.2 minimum, cipher
  posture mirrors Go `tls.go`. Verified in source, not assumed.
- **Mutual pinning:** both directions compare certificate DER/SHA-256, not
  hostname (`FluxNet.TrustValidation`; M1b/M3/M5 E2E procedure, re-verified
  on every M6 run). A network attacker with a valid CA cert for nothing
  relevant still fails the pin.
- **Approval messages add nothing readable:** the DER signature binds
  host/user/service/tty/rhost/time/nonce, and the helper rebuilds the bytes
  from its own fields. Replay/tamper/wrong-key all `REJECTED` by openssl on
  the wire (M6 E2E), stale/bad-nonce probes answered `failed` on the wire.
- **No new network surface:** the phone sends no packet type the desktop
  does not already accept (`flux.approve` is in Go's `Incoming`); framing
  enforces the 16 MiB cap; packet `id` tolerance is number-or-numeric-string
  only.
- **Discovery:** mDNS `_kdeconnect._udp` + UDP broadcast carry the same
  plaintext identity the desktop already broadcasts; no secrets in TXT
  fields (deviceId/name/type/version/port only).

## 2. Code that runs as the user (malicious fluxd, key-file writes)

Unchanged from the design — verified against this code:

- It can stop approvals (fail closed to the password), send bogus prompts
  (the phone shows service/user/host/time; signing still needs the finger),
  and start `sudo` hoping for fatigue approval (open risk, shown on the
  prompt screen itself).
- It **cannot** forge a signature: production keys are created with
  `biometryCurrentSet` + `privateKeyUsage` (`ApproveKeys.keyAttributes`
  `biometric:true`) and sign only through a per-use `LAContext`
  (`ApproveKeys.sign(message:computerId:context:)`; nil context only works
  for keys without access control, i.e. test keys).
- It **cannot** reuse a signature: nonce-bound (helper-made 32 random
  bytes), proven `REJECTED` on replay; helper checks ±(wait/5 s future),
  phone refuses >10 min skew.
- It **cannot** redirect the trust anchor: helper key path is fixed
  (`/etc/flux/approve/<user>.pub`, no flags/env); enrollment key-code
  comparison is the user's job, shown on both screens.
- **Test-mode containment (audited 2026-09-26, re-audited 2026-09-27):**
  `createTestKey` call sites are `FluxTestPeer/ApproveTestMode.swift` (2,
  harness-only, every reply logged `TEST MODE (no biometric)`),
  `FluxApproveTests` (12), and `FluxCoreTests/ApproveFlowTests` (3, all
  memory-only `stored:false` — zero Keychain residue, verified after the
  run). No app, extension, or production path calls it. Production
  `create` is the only Keychain path and always sets
  `biometryCurrentSet`. Re-audit with
  `grep -rn createTestKey ios/Sources ios/Tests`.

## 3. A person with the locked/unlocked phone

- No approval without the biometric: production keys sign only through a
  per-use `LAContext`; the invalidated-key path (`errSecAuthFailed` →
  `.biometryChanged`) deletes the key and reports the enroll-again error
  (`ApproveKeys.mapSignError`, Android
  `KeyPermanentlyInvalidatedException` parity).
- Deny is always available (notification action + prompt button); deny
  answers `{"kind": "response", "denied": true}` and fails closed.
  **Proven on hardware 2026-09-27** (D19, iPhone SE2 Touch ID + Linux
  `fluxd`, real PAM): `sudo flux approve enroll` → Touch ID → enrolled
  reply, key code byte-identical both sides (`9338 0F33 1952 6EA4`,
  desktop openssl-verified the enrollment proof); `sudo -k; sudo true`
  → ask screen (service/user/host/TTY/time + fatigue warning) → Approve
  + Touch ID → `flux.approve (approved)` → passwordless sudo; Deny →
  `flux.approve (denied)` → desktop falls back to the password prompt,
  which still works. Fail-closed to password proven both ways.
- Enrollment-change handling (D20, **done on hardware 2026-09-27**):
  sign-time `errSecAuthFailed` → `.biometryChanged` deletes the key and
  answers enroll-again; a second dead-key shape found on device
  (Touch ID passes, Enclave refuses: CryptoTokenKit `-3`,
  AKSError=-536362999) maps the same way with a regression test; a
  vanished biometric set maps to enroll-again with deletion, biometric
  lockout answers a passcode-unlock message with the key kept,
  stale UI verdicts are ignored, and the app shows failures in a
  `.failed` prompt phase. Proven end to end: invalidation screen →
  re-enroll with compared key code → passwordless sudo.
- Lock-screen actions (D21, **done on hardware 2026-09-27**): the
  time-sensitive prompt notification arrives over the lock screen,
  long-press reveals Approve/Deny, Approve → Touch ID → passwordless
  sudo, Deny fails closed to the password — the biometric gate runs
  before any signature in both paths.
- Background delivery (D22, **done on hardware 2026-09-27**):
  the prompt notification lists in NC foreground and backgrounded
  (root cause found on device: the `willPresent` delegate passed
  `.banner` without `.list`, so nothing presented foreground ever
  reached Notification Center — fixed), an open prompt gets a short
  `beginBackgroundTask` grace to finish signing + sending, and past
  the grace (or the request timeout) the desktop fails closed to the
  password. Approve from NC after backgrounding + Touch ID gives
  passwordless sudo.
- **Hardware-verified biometric gate (D19, 2026-09-27):** per-use Touch ID
  signing from a Secure Enclave-gated key through `LAContext` with a real
  finger (iPhone SE2) — enroll proof + approval signatures, helper-side
  openssl verification. The Face ID vs Touch ID difference is UI-only
  (`LAContext` abstracts it); the SE2 runs Touch ID, so Face ID over the
  lock screen stays formally unproven but shares the code path.
- Keychain posture (this audit): identity, trust, and approve keys use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (TLS works while
  locked; biometric gates are approve-keys-only) and
  `kSecAttrSynchronizable = false` everywhere (`FluxCore/Keychain.swift`,
  `ApproveKeys` index + key attrs) — keys   never leave the device via
  iCloud. M7 fix: the enrolled-computer index item is deleted when empty
  (`saveIndex`), so `--forget` and test runs leave zero residue (verified:
  `make ios-test` leaves no `org.omarchy.flux.approve` item; the
  2026-09-27 M6 loopback re-run ended `--forget` residue-free).
- **Device-validated TLS identity path:** the `-50` signing death from the
  public-half keygrab is fixed (`IdentityKeys.loadOrCreate` deletes the
  public item + 1-byte signing self-test fails fast at startup); full
  mutual-TLS link + mDNS both ways + packets proven against real `fluxd`
  on hardware (D6).

## 4. Phone-side input validation (fail-closed)

- `ApprovePackets` parse enforces the Android rules: kind allow-list,
  id ≤64 chars, required host/user/service-per-kind, tty/rhost/timeout
  defaults, 5…120 s clamp, field + nonce rules (`validField`,
  `validNonce`), `id`/timeout defaults. Invalid → `failed(id:
  invalidRequest)`, never a crash, never a signature.
- `ApprovalsStore` one-at-a-time machine: busy/clock-skew/no-key/invalid
  refusals answered on the wire; cancel by id; local timeout closes the
  prompt; the off-thread decider drops stale answers by id (never sent).
- `SecKeyCreateWithData` rejects valid P-256 SPKIs with `-50` on this Mac,
  so verification uses CryptoKit (`P256.Signing`, DER in/out) — the same
  cross-library shape as production (Security signs, Go verifies).

## 5. Privacy / App Review surface (M7 audit)

- Purpose strings match code; unused ones stay out (`NSContacts…` and
  speech recognition correctly omitted — CallBridge uses `CXCallObserver`
  only, no numbers ever).
- `PrivacyInfo.xcprivacy` declares only called required-reason APIs
  (`UserDefaults` CA92.1 — capture ledger + mic prefs; file timestamps
  C617.1 — `attributesOfItem` in `Transfers.swift`). M7 removed the
  unused SystemBootTime/DiskSpace entries.
- `UIBackgroundModes` empty (no VoIP/PushKit/audio claimed); the app
  discloses suspension honestly (`ConnectionBanner`). The one exception
  is a short `beginBackgroundTask` grace for an open approval prompt
  (D22, ends on the answer/expiry/close) — allowed with no modes, and
  the banner copy still says suspended means suspended.
- No analytics, no tracking domains, no webviews, no private API.

## Extensions audit (2026-09-27, per new device evidence)

All three extensions (`Share`, `Broadcast`, `Notification`) are excluded
from the free-tier Xcode project (D5) — they cannot install or run today,
so they add no attack surface to the current device build. Audited as
source for the paid-team enablement:

- **Broadcast** (`SampleHandler`): reads `screen.json` (port, desktop cert
  DER, frame size) from the App Group container the host app writes, dials
  out with the pinned desktop cert (same pin the listeners enforce), sends
  Annex-B video only, drops app audio, no input control. Trust boundary is
  host-app↔extension inside one team (same signer); the desktop side is
  the already-pinned peer. Without the App Group entitlement the config
  load fails closed ("not configured" broadcast error). Re-audit on
  enablement: confirm the extension target links (not duplicates)
  `H264VideoEncoder`, so the SPS/PPS-per-IDR framing stays one
  implementation.
- **Share / Notification**: stubs (Share receives into the extension
  sandbox; host wiring via App Group is D4-open). No credentials, no
  keychain access, no network in either stub. Audit again when D4 lands.
- Device evidence incorporated: free-tier shape confirmed on hardware
  (no App Groups, no Time Sensitive — notifications degrade to regular
  interruption, approval actions unaffected), `.banner`+`.list` required
  for Notification Center persistence, Keychain posture unchanged
  (trust + identity + per-desktop approve keys, `--forget`-clean).

## Residual risks (carried, not closed)

1. No key attestation (design open risk — trusted, not proven, that the
   phone made the key with the gated settings).
2. Approval fatigue (UI mitigations only: service/user/host/tty/time shown).
3. Enrollment depends on the user comparing key codes.
4. Background approval delivery proven on hardware (D22, done 2026-09-27:
   prompt lists in Notification Center foreground + backgrounded, NC
   Approve + Touch ID gives passwordless sudo within the desktop
   deadline; APNs relay stays an explicit v2 non-goal).
5. This audit is source + harness + partial-device evidence, not a full
   device run: D15–D18 (camera/mic/ReplayKit runs) still need hardware
   before an App Store release. TestFlight beta is the vehicle, not the
   verdict.
6. App-originated packet fan-out (`LinkService.send` over live runners,
   D23) is unit-tested (no-session send is false) and loopback-regression
   green; runcommand run + media play-pause/play are now device-proven
   (journal + `playerctl` evidence 2026-09-27). Still unverified on
   hardware: CallKit ringing/talking/missed + the Focus boolean (carrier
   retest skipped by user decision; Focus parked as an Apple-side quirk).
