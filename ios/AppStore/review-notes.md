# Flux for iOS — App Review notes (draft, M7)

## What the app does

Flux for iOS is a local-network companion for the user's own Omarchy Linux
desktop (`fluxd`). It speaks the KDE Connect protocol v8 + Flux extensions
over TLS on the LAN. There is no Flux cloud, no account, and no analytics.

## Demo path (no computer needed)

Launch with `-FLUX_DEMO 1` to render sample computers with no backend
(same rule as Android `FLUX_DEMO=1`; release builds ignore extras). Pages
mirror Android `shot.sh`: `devices home media commands browse mic camera`,
`camera:<mode>`, `ring pair unpair`, `<page>@offline`, `empty`, `icon` —
see `ios/tools/shot.sh`.

## Self-signed TLS + certificate pinning

Both sides use self-signed ECDSA P-256 certificates (Go `generateCert`
profile: serial 10, `CN=device ID`, `O=KDE`, `OU=KDE Connect`, −1y/+10y,
ECDSA-with-SHA512). There is no PKI to validate against, so the app pins
the certificate DER after the user compares the 8-character verification
key on both screens (`SHA-256(larger SPKI ‖ smaller SPKI ‖ timestamp)`,
byte-identical to the desktop and Android implementations). A changed
certificate triggers re-pair, never a silent update. This is not an
attempt to bypass ATS — it is the protocol's trust model, shared with the
shipped Android app.

## Secure Enclave signing (sudo approval)

Sudo approval signs with a per-computer P-256 key in the Secure Enclave
where available (Keychain fallback on older devices), gated by per-use
biometric authentication (`biometryCurrentSet` + `LAContext`), invalidated
by a new biometric enrollment (re-enroll flow). See `docs/approve.md` for
the full design and `ios/AppStore/security-audit.md` for the pre-TestFlight
audit. Purpose string: `NSFaceIDUsageDescription`.

## Background modes: none claimed

`UIBackgroundModes` is empty in v1. The link suspends ~30 s after
backgrounding by design, and the app says so (`ConnectionBanner`:
"Background suspended — open Flux to stay connected"). No VoIP, no PushKit,
no `audio` mode claimed. If `audio` is added later (streams keep the link
alive while active), it ships with a justification + device evidence, not
silently.

## Permissions and purpose strings

| String | Used for |
| --- | --- |
| `NSLocalNetworkUsageDescription` + `NSBonjourServices=_kdeconnect._udp` | Pairing/discovery on the LAN |
| `NSCameraUsageDescription` | Scan text/QR/photo/document; webcam stream |
| `NSMicrophoneUsageDescription` | Microphone stream |
| `NSPhotoLibraryUsageDescription` / `…AddUsageOnly` | Send chosen photos; save incoming files |
| `NSFocusStatusUsageDescription` | Share Focus boolean with the desktop |
| `NSFaceIDUsageDescription` | Biometric-gated sudo approval |

No contacts, speech-recognition, or tracking APIs. `PrivacyInfo.xcprivacy`
declares only required-reason APIs the code calls (`UserDefaults` CA92.1,
file timestamps C617.1); M7 removed the unused SystemBootTime/DiskSpace
entries (see the file comment).

## Crypto notes

- TLS 1.2 minimum, cipher posture mirrors desktop `tls.go`.
- Approval signatures: SHA256withECDSA P-256, ASN.1 DER end-to-end (never
  transcoded). Nonces are 32 fresh random bytes per request; replay/tamper/
  wrong-key all fail closed (openssl proofs in `ios/README.md`, M6).
- No custom crypto implementations: `Security`/`CryptoKit` only.

## Entitlements needing Apple approval

- `com.apple.developer.networking.multicast` (UDP discovery; mDNS-only
  fallback until granted — D5).
- Broadcast Upload Extension (screen mirror; needs the broadcast
  entitlement + App Group `group.org.omarchy.flux`).
- Time-Sensitive Notifications (pairing + sudo-approval prompts).
