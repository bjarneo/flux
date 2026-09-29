# Flux for iOS — TestFlight + release checklist (draft, M7)

Mirrors `docs/releasing.md` (desktop/Android). iOS analog of the
"build number + team + bundle ID" fingerprint rule is at the bottom.

## One-time Apple setup (owner; cannot be done from this checkout)

- [ ] Paid Apple Developer team; App ID `org.omarchy.flux` with: multicast
  (`com.apple.developer.networking.multicast`, D5 — request early, takes
  days), App Groups (`group.org.omarchy.flux`), Push, Time-Sensitive
  Notifications, Broadcast Upload Extension. Until granted, discovery is
  mDNS-only and the broadcast extension is unsigned.
- [ ] App Store Connect API key for CI (`ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_BASE64`); store like the Android `KEYSTORE_*` secrets in
  `docs/releasing.md` — never commit `*.p12`, `*.mobileprovision`,
  `AuthKey_*.p8`, or team IDs.
- [ ] Keep one distribution identity across releases (update continuity
  needs the same team + bundle ID and a higher build number, mirroring the
  Android same-certificate + higher-version-code rule).
- [ ] Support + privacy-policy URLs for `description.md`.

## Xcode project (D7 — open)

- [ ] `Flux.xcodeproj` (SPM-only today): app target from `ios/App/`
  (`FluxApp.swift`, `Info.plist`, `Flux.entitlements`,
  `PrivacyInfo.xcprivacy`, assets) + Share/Broadcast/Notification
  extension targets + App Group wiring.
- [ ] Simulator run of every `shot.sh` page; device run for camera, mic,
  ReplayKit, Face ID, lock-screen actions, background delivery (D15–D22).

## Per-release checks (local)

- [ ] `make ios` (debug) + `swift build -c release` (release-only errors,
  the `assembleRelease` analog; also in CI) + `make ios-test` (must stay
  green; count floor is the README number, currently 310).
- [ ] `python3 -m py_compile ios/tools/test_peer.py`.
- [ ] Loopback E2E per `ios/README.md` (pair + M6 minimum): recompute the
  8-char key from both DERs + timestamp (must match byte for byte),
  openssl verify/reject proofs, `M6 EXPECTATIONS MET`, zero "no handler",
  Keychain-residue-free (`security dump-keychain | grep omarchy`).
- [ ] `swiftlint` advisory (no config/CI gate yet — defaults fail on
  pre-existing style; do not gate until a config lands).
- [ ] `Info.plist` audit: purpose strings still match code; `NSFaceID…`
  present (M6 enrollment is dead on device without it); `UIBackgroundModes`
  still minimal (justify any addition in `review-notes.md` first).
- [ ] `PrivacyInfo.xcprivacy` audit: entries match actual API calls
  (M7: UserDefaults + FileTimestamp only).
- [ ] Entitlements audit: `aps-environment` flips to `production` at
  signing (Xcode does this from the distribution profile — verify in the
  archived build, do not hand-edit); keychain-sharing only if extensions
  read keys.
- [ ] Version bump: `CFBundleShortVersionString` from the tag (no `v`),
  `CFBundleVersion` strictly above the previous TestFlight build.
- [ ] Screenshots via `ios/tools/shot.sh` for the page list (needs D7).
- [ ] `flux doctor` note for iOS limitations: PROPOSED TEXT ONLY (v1 rule —
  no CLI changes from this track). Draft for the desktop side:
  `iPhone peers: no SMS, no global notification mirror, Focus share-only,
  background links suspend when the app is closed (open Flux to reconnect).`
  Desktop owner lands it separately.

## TestFlight beta

- [ ] Archive with distribution profile → upload → dSYMs attached.
- [ ] Beta description = `description.md` limitations section verbatim.
- [ ] Internal testers: pair + E2E smoke against Linux `fluxd`
  (`flux discover/pair/status/ping`, `sudo -k; sudo true` Face ID — D19).
- [ ] Record cert-fingerprint analog for the release notes: build number +
  team + bundle ID (compare across releases like
  `android-certificate.txt`).

## Release notes rule

Like `docs/releasing.md`: TestFlight build ≠ App Store release. Report
checks passed, device runs outstanding (D15–D22), and required user
actions separately.
