# Windows client parity audit

Date: 2026-10-02. Windows baseline: prototype v16. Repository baseline:
`1605304` (Inbox PRs #84 and #86; webcam/mic requests and Control changes
in PRs #88–#90; test cleanup in #91). Compare any newer merged PRs before treating this as a
current upstream checklist.

Windows is a device peer of the Omarchy computer, like the Mac. Compare its
wire behavior and feature meaning with Android, iOS and macOS. Use `gui/qml/`
for its desktop layout; `DESIGN.md` describes the other device apps and is
not a desktop layout template.

## Method

For each feature, record: which direction works; the peer capability and wire
packet; device-ID scope and target capture; pending, success, failure and
offline states; any unlock or approval boundary; automated checks; and a live
Windows ↔ Omarchy check. A feature is complete only when the behavior, state
and failure path are verified. Hide or disable unavailable actions, and do not
advertise unsupported capabilities.

Use `macos/App/Shell/`, `macos/Sources/FluxKit/Inbox/`, `ios/App/Shell/`,
`android/app/src/main/java/org/omarchy/flux/ui/Nav.kt` and
`docs/macos.md#inbox-and-navigation` as the current device-side references.
Use `gui/qml/` for the Windows desktop visual comparison. Check upstream PRs
again before each contribution branch is ready to review.

## Current gap map

| Area | v16 evidence | Parity work and proof |
| --- | --- | --- |
| Identity and connections | Protocol v8 discovery, mutual TLS, certificate-bound pairing, DPAPI identity, saved pins, reconnect and concurrent peers; live owner checks. | Retest against the latest merged clients. Keep approval bound to the exact device, connection and key. |
| Computers | Sidebar lists discovered, connected and saved offline peers; authenticated last-known metadata and per-device Forget action; alternate addresses and status. | Local settings and capability-aware actions. Verify duplicate names, stale discovery, offline reconnect and Forget on Windows. |
| Scope and navigation | One selected device controls header and send target; Files offers this device/all devices by DeviceId. | Compare common Inbox, Send, Control and Computers meanings. Add an all-computers scope where an implemented feature needs it. Keep Windows desktop layout adapted to QML. |
| Inbox and attention | Pending pairing card and transfer history exist on separate surfaces. | Shared attention order, cross-device notices and counts, master/stack behavior for implemented item types; do not show agent, approval, media or clipboard items until their data exists. Verify new urgent items and device switches. |
| Send and files | File send/receive, progress, per-transfer Cancel, failure states and received-folder opening. Outgoing completion says receipt is unconfirmed. | Verify cancellation and failure on Windows and compare target selection with current peer clients. Text, links, clipboard, photos, Explorer share and drag/drop are absent. |
| Control | No control actions exposed in v16. | Remote desktop/input, agents, commands, media, microphone and webcam need separate transport, permission, unlock and live checks before exposure. The new computer-initiated webcam/mic flow uses `flux.stream.request` and device confirmation; Windows does not advertise or expose it. |
| Theme | V16 advertises `flux.theme`, accepts it only on the current paired TLS session, saves themes by device ID and changes WPF brushes for the selected device. Tokyo Night remains the fallback; text and status colors have contrast checks. Owner confirmed live application of Omarchy's `ristretto` colors after a local daemon update. | Run repeated live theme switches on Windows, including light themes; verify saved-theme restart, Forget fallback, 100/150/200% scaling and window controls. The installed Omarchy package predates theme sync; a reversible daemon preview currently supplies it. |
| Build and distribution | Release WPF build, self-contained win-x64 and source-only archives; UI harness compiles on Linux. A Windows PR workflow is prepared. | Run the workflow after source contribution, verify the WPF harness on Windows and decide whether to build release archives in CI. Do not commit `bin/`, `obj/`, or local test archives. |

## Review gate

1. Update this table after fetching the current upstream `master`; note any
   new packet, capability, Inbox item, navigation or theme contract.
2. Run protocol tests and the WPF harness on Windows. Use source fixtures and
   isolated identity data, never the owner's saved trust store.
3. Exercise live pairing, restart/reconnect, two concurrent peers, and file
   transfers in both directions. Check identity/recipient retention while
   discovery refreshes and selection changes.
4. Compare same-size Windows and QML desktop screens with sample data; check
   keyboard use, window controls and display scaling. Do not include private
   messages, contacts, clipboard contents or real addresses in captures.
5. Report what is implemented, what is platform-limited, what is still absent
   and which checks were actually run. Label a partial build as a preview.
