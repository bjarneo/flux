# Flux for iOS — App Store description (draft, M7)

Source text: `ios/README.md` "iOS limitations" + the M6 biometric note.
D8 (`docs/ios-plan.md` §14) closes with this file. Do not over-promise in
store copy: every platform gap below is enforced in the app by
capability-gated UI (`docs/ios-plan.md` §§3.1, 4.4–4.5).

## Name / subtitle

Flux — Omarchy desktop companion

## Description

Flux connects your iPhone to your Omarchy Linux desktop on the same local
network: share files and clipboard, control media, run desktop commands,
mirror notifications from your computer, use your phone as a webcam,
microphone, or screen mirror, and approve `sudo` with Face ID.

Pairing is verified both ways: compare the 8-character key on both screens
before you accept. Your connection is pinned — a changed certificate is a
re-pair, never a silent update.

## iOS limitations (shown in store copy AND in-app)

- No SMS send/receive on iPhone — Messages shows "Not supported on iOS".
- No global notification mirror — only Flux-internal, missed-call, and
  desktop→iPhone requests render.
- Focus/DND is share-only (a boolean your computer sees); the desktop
  cannot set iOS Focus. Focus refreshes when Flux is open.
- Calls report ringing/talking/missed with no number — the desktop always
  shows "Unknown caller" (iOS exposes no call number to third parties).
- Desktop volume changes are ignored (no remote volume API for third
  parties); album art from the phone is deferred.
- Background links suspend ~30 seconds after backgrounding — open Flux to
  stay connected. Audio/ReplayKit streams keep the link alive while active.
- Clipboard sync is foreground + manual push only.
- SFTP file browse from the computer is read-only; serving iPhone files
  back to the desktop is deferred.
- Sudo approval needs a paired computer with Flux configured, an enrolled
  Face ID / Touch ID, and Flux open or reachable; a new Face ID enrollment
  invalidates the key and you enroll again.

## Keywords

omarchy, linux, kde connect, file share, webcam, sudo, companion

## Support / privacy URLs

(TODO, owner fills in at submission: support site + privacy policy URL.
The app collects no analytics; see `review-notes.md`.)
