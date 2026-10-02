# Windows prototype status — 2026-10-02

Upstream base: `1605304` (PRs #88–#90 checked for Windows capability parity;
#91 changes a Go test only).
Local source: `windows/`.
SDK: .NET 10.0.401.

Current artifact: Windows prototype v16, paired Omarchy theme sync and per-device cache. The owner confirmed
simultaneous connections, reconnect without new pairing, and Windows → chilibot
and chilibot → Windows file transfers on earlier builds. The owner also confirmed
v16 applied Omarchy's `ristretto` colors after its daemon was updated locally.
Other Windows visual and interaction checks remain.

Passed:

- Protocol checks: certificate and connection swaps, wrong/expired approval
  keys, verification-key order, identity binding, packet roundtrip, overlong
  packets/frames and the plaintext/TLS parser boundary.
- V2 checks: outgoing acknowledgements bound to the certificate/connection,
  rejection of early or expired approvals, identity reload preservation, and
  mutual TLS loopback transport on Linux.
- Release compilation of WPF Windows target: 0 warnings, 0 errors.
- Self-contained win-x64 publish.
- V7 checks: delayed return connection through idle slots, unrelated-peer
  exclusion, bounded timeout and shutdown cancellation. Protocol tests and
  self-contained Windows Release publish passed for this version.
- V8 checks: two simultaneous mutual TLS transports, independent approval/read
  state, transport survival after one peer closes, guarded session replacement,
  stale cleanup and crossed-dial preference. Protocol tests and self-contained
  win-x64 Release publish passed for this version.
- V9 checks: file payload envelopes, direct and reverse TLS file transfers,
  outgoing phone tunnels, wrong-certificate rejection, safe names, collisions
  and failed-file cleanup. Protocol tests and self-contained win-x64 Release
  publish passed for this version. Live device file transfer was still required at v9.

Owner desktop test of v1:

- App launches and receives a connection attempt from Omarchy.
- TLS fails because Schannel rejects the ephemeral private key.
- Pair initiation was missing from the Windows interface.

V2 corrects identity import for Schannel, adds Find computers and Pair, and
supports pairing initiated from Windows with remote acknowledgement followed
by the user's local key confirmation. Existing identity and trust are retained.

Not yet verified:

- Sustained paired connection on Windows (loopback checks run on Linux here).
- Persisted Omarchy/Windows pairing and sustained connection with the updated app.
- Reconnect persistence on a real Windows computer.

Owner desktop test of v2: app starts, but no devices appear and pairing cannot
start. Source inspection found that Find computers only re-announced Windows;
there was no browse query, device list, UDP identity discovery, or outgoing
connection path. V3 implements those paths and shows addresses and connection
stages. Discovery parser tests cover fragmented responses, multiple service
pointers, missing-record queries, stale records, self suppression, and invalid
protocol/port/address hints.

Owner desktop test of v3: Windows discovers phone and Omarchy; Android connects
to Windows and pairing completes far enough to appear paired on the phone.
Soon afterward the phone loses its trust and must pair again. Omarchy has not
established a connection. The exact disconnect status/local confirmation step
is not yet known. Do not claim a verified root cause for the observed drop.

V4 fixes a proven read-cancellation lifetime race, guards a saved pairing from
the pending timer, moves local confirmation next to the code, and explains
local confirmation expiry versus peer unpairing or TLS closure. Read-lifetime
tests cover promotion between packets, idle timeout removal and shutdown.
Selecting another device closes the old link without unpairing it and rejects
incoming links from other IDs while the selected device is being tested. Only
one active connection is supported. Android and Omarchy live validation remain.

Owner desktop test of v4: Windows discovers Omarchy and Pixel immediately;
the phone discovers Windows after retries and keys are accepted. Omarchy still
does not discover/connect to Windows. The device-list text "not authenticated"
was hardcoded and unrelated to the saved pairing. V5 fixes the presentation
and tests that confirmed status is bound to the active peer ID and address.
Omarchy connectivity is still unresolved; Windows Connect error, its actual
IPv4 addresses, and Omarchy discovery/status output are needed next. Do not
claim a firewall, address-selection or TLS cause without those observations.
The user explicitly deferred UI parity until connectivity works.

Owner reports clicking Connect has no visible result. V6 fixes a silent return
when another handshake occupies the slot and makes UI feedback immediate.
Switching cancels the previous read and disposes TLS outside the UI thread.
Connect waits for the selected peer's verified TLS identity, with explicit
phase/failure status. Tests cover unrelated/busy handshakes, an eventual target
connection, an idle slot, a permanently blocked slot and cancellation.

A credential-free mDNS probe on chilibot's LAN observed Windows advertising
both 192.168.1.42 and 100.71.227.3 for the same service. It also found Omarchy
at 192.168.1.102:1716 and Pixel at 192.168.1.34:1716. TCP reachability from
chilibot succeeded to Windows and timed out to Omarchy. V6 filters overlay
addresses from LAN advertisements and re-announces on Connect. Avahi's actual
chosen address and the reason Omarchy TCP is unreachable are not established.
End-to-end Omarchy connection from the updated Windows build remains unverified.

Not yet implemented: video rendering, remote input, full
notification aggregation, clipboard and local Windows unlock checks. V6's four
navigation destinations were a shell for the pairing milestone, not a claim of
full parity. Do not advertise the current prototype as a finished Flux client.

V16 advertises incoming `flux.theme`, accepts it only on the current paired
TLS session, stores the last valid theme by device ID and applies the selected
device's colors to WPF brushes. Forget removes its cached theme; Tokyo Night
remains the fallback. A contrast guard covers text and status colors on app
surfaces. The full protocol suite passed on chilibot, including mutual TLS,
multi-peer and file payload tests; the direct sandboxed run could not open
local TCP. The WPF app and UI harness compiled with zero warnings, but the
WPF harness cannot run on Linux. A live Windows ↔ Omarchy theme-change test
remains. The first live theme application
was confirmed on Windows with `ristretto`; repeated switches, a light theme,
cache persistence, Forget fallback and display scaling remain unverified.
Omarchy currently runs a reversible user-level `fluxd-theme-preview` override;
its installed `omarchy-flux 0.8.0-1` package is unchanged and predates
`flux.theme`. Remove the override after a package with theme sync is installed.

V6 owner photos show direct TCP to Omarchy timing out before TLS. Omarchy's
logs show that it discovered Windows and attempted return connections: some
ended with TLS EOF; later TCP dials timed out. Chilibot observed a verified
Windows link at 12:31 followed by EOF. This proves a successful handshake
with the Go implementation, but does not identify the subsequent EOF cause.
The prototype deliberately refuses incoming peers while its single slot is
occupied or a different device is selected; these refusals were previously
silent in the Windows interface. V7 makes those reasons visible in a bounded
in-memory diagnostic history. A failed direct TCP dial also waits for the
selected peer's verified return connection for 35 seconds, covering Omarchy's
observed 30-second retry. Live Windows validation remains required.

Chilibot's mDNS was initially unavailable. After Avahi became active and the
Flux user service restarted, Omarchy connected to chilibot over TLS. The owner
confirmed the full pairing code, and status then showed both Omarchy and Pixel
paired and online. This native-client path works without opening Omarchy's
inbound Flux port; it does not establish Windows interoperability on Omarchy.

Owner test of v7: Windows diagnostics show incoming chilibot/Pixel connections
refused because Omarchy is selected, with no incoming Omarchy attempt in the
return-connection window. Restarting Omarchy's Flux service immediately
established an unpaired Windows link. The owner then accepted the matching-key
request in Windows and reported success. Saved trust after restarting Windows
and sustained connection without restarting the Omarchy daemon remain to be
verified. Local investigation notes record the possible interaction between
Avahi's ItemNew event, unpaired-device eviction and paired-only mDNS refresh;
that cause has not been reproduced in an isolated test.

Next: run the pairing test on the owner's desktop; resolve discovered transport
issues, then implement/prove desktop decoding and input. Preserve RDP and the
working Android release throughout.

V8 addresses the owner's report that connecting Pixel disconnected Omarchy.
The single global stream/pairing state is replaced by per-device sessions.
Per-session pairing/read/write locks avoid routing approval or timeout events
to another device. The UI retains each peer's connection status and binds
approval to the selected device and displayed connection ID. Active peers
remain listed even when discovery records expire. Incoming devices are no
longer refused merely because another row is selected. Existing saved identity
and certificate pins remain in place.

The session registry guards removal/replacement by object identity. Verified
reconnects and crossed dials follow Go lan.Preferred, including the five-second
larger-initiator rule; replaced readers cannot publish stale UI state over the
new session. There are bounds of 16 active devices and eight TLS handshakes.
The tests use two concurrent mutual TLS connections, verify pairing/read
isolation, close one transport and prove the other can still receive data,
and check capacity, duplicate IDs, reconnect cleanup and crossed-dial agreement.
Live reconnect persistence and multi-device Windows behavior remain unverified.

The owner subsequently confirmed both devices stay connected and reconnect
after restarting Windows without re-pairing. This closes the reported v8
multi-device/reconnect test on the owner's desktop.

V9 adds flux.share.request payload envelopes, direct payload TLS sockets and
incoming/outgoing Flux tunnels. Each payload verifies the control peer's exact
certificate, uses its control LAN address, and runs only while that session is
paired. Unpairing and reconnect cancel that session's transfers. Windows saves
received files in Downloads/Flux without overwrite or automatic opening.
Tests passed for exact byte roundtrips through direct/reverse/phone-tunnel TLS,
wrong certificate rejection, Windows-safe filenames, name collisions and cleanup
after short/oversized/cancelled/untrusted receives. TLS close_notify plus draining
post-handshake records fixes a connection reset found by the payload tests.
Actual Windows/Go/Android file interoperability is not established by those
Linux/.NET tests; the owner's live transfer test is required next.

V10 reorganizes the WPF interface into working Computers, Send and Inbox pages,
with a clearly marked unavailable Control page. Pixel reference screenshots and
DESIGN.md inform the central semantic theme, device cards, transfer cards and
master tile. The selector and device cards share the same selected peer; page
navigation does not replace pending approval state or change connections.
Diagnostics are collapsed by default. Transport and pairing implementations
are unchanged. Release compilation and self-contained win-x64 publish passed;
Windows visual/interaction testing and live v9/v10 file transfer remain required.

Owner v10 test: both send and receive close the Windows application; Connect
also remains enabled for an already connected device. V11 fixes the read-only
Progress property's binding to ProgressBar.Value by explicitly using OneWay.
The prior default inherited a two-way binding from WPF RangeBase.Value, which
is a concrete runtime error missed by cross-target compilation. It plausibly
explains the symmetric transfer crashes but has not been confirmed on Windows.
Connect now reflects the selected peer's active connection and re-enables after
disconnect. A Windows-only harness exercises actual transfer templates and
connection state without network or saved identity. The harness compiles here;
its runtime result remains unverified until run on Windows.

At the owner's request, desktop styling now follows actual Omarchy Qt surfaces:
monospace, square cards/buttons, and a green dot plus connected text for paired
online devices. The native title bar is replaced using WindowChrome with a
drag area, resize borders and system minimize/maximize/restore/close commands.
Windows font fallback is Cascadia Mono then Consolas; the exact Omarchy font
is not known. An unexpected UI exception produces a bounded type/method-only
report and an error dialog before shutdown. Windows window behavior, display
scaling and live transfers still require the owner's test.

V11 validation here: protocol/file payload regression checks passed; Windows
app and WPF UI harness Release compilation passed with zero warnings/errors;
self-contained win-x64 publish passed. The Windows-only UI harness was not run.

V12 resolves the three Astra review findings: malformed numeric protocol
versions now produce InvalidDataException, caught per UDP message; list refresh
restores selection by device ID, IP address and port, falling back to another
address only if the selected endpoint disappears; the shared Card style now
uses zero corner radius. Protocol regression cases cover fractional, overflow,
wrong-type and missing versions, plus endpoint metadata/order/port changes and
fallback. The Windows-only harness also checks actual selector refresh and
square rendered cards. Windows UI execution and live file transfer validation
remain required; the earlier OneWay transfer-progress fix is retained.

V12 validation: protocol and file payload regression suite passed, including
new malformed-version and endpoint-selection cases. Release build of app and
WPF harness passed with zero warnings/errors; self-contained win-x64 publish
passed. WPF runtime checks have not been executed on this Linux host.

V13 reorganizes the WPF shell around a device sidebar, compact selected-device
header, Overview and Files. It preserves certificate identity, saved trust,
per-device sessions and transfer transport. A pending verification key is shown
only during pairing. Files keeps send and history together and filters by
DeviceId rather than display name; completed sending still distinguishes
transport completion from receiver storage confirmation. The WPF harness now
checks one sidebar row per device, alternate endpoint retention, and DeviceId
history filtering. WPF runtime checks and display scaling need Windows.

V13 checks here: Release builds of the app, protocol suite and WPF harness
passed with zero warnings and errors; self-contained single-file win-x64
publish passed. The protocol suite started and passed malformed-discovery
cases, then stopped when this sandbox denied creation of a local TCP socket.
The remaining socket tests did not run here. The WPF harness cannot execute
on Linux. Live Windows pairing, transfers, window controls and 100/150/200%
scaling remain to be retested on v13.

V14 adds per-transfer cancellation with distinct Cancelled and Failed states,
and keeps outgoing transport completion separate from a receiver save receipt.
Saved certificate pins now have separate authenticated display/reconnect
metadata; offline devices stay in the sidebar and can be forgotten individually.
An older pin without metadata appears by short ID until its peer reconnects.
Forgetting a connected peer revokes only that session's file transfers and sends
`flux.pair=false`; other peers remain connected. A Windows-only CI job is
prepared for protocol and rendered WPF checks on PRs touching `windows/`.
The source archive excludes local identity, trust, binaries and build output.

V14 checks here: WPF app and UI harness Release builds passed with zero
warnings/errors; self-contained win-x64 publish and both archive integrity
checks passed. Protocol checks started and passed malformed discovery cases,
then the local sandbox denied TCP socket creation; the remaining tests did not
run here. WPF runtime tests and the Windows CI job have not run yet. Live
Windows cancellation, offline restart, unpairing, reconnect, transfers and
window/scaling checks remain for the owner's Windows machine.

V15 addresses the independent review of v14. The WPF fixture now publishes a
connected PeerView before clearing discovery, matching the actual connection
event sequence. Forget removes the pin and deauthorizes the current session
under the same state lock, retrying if the session was replaced. Any subsequent
handshake sees no saved pin. A bounded follow-up sends `flux.pair=false` to the
current session when one exists. The remote unpair and re-pair paths also check
current-session identity while revoking trust.

Transfer stop reasons distinguish local Forget, explicit Cancel, reconnect,
connection close, timeout and shutdown. Unicode filename validation happens
before slot reservation, and the transfer worker always releases a reserved
slot. Control announcements and tunnel requests now take the transfer's
cancellation token. Protocol checks for malformed Unicode and transfer status
pass before this sandbox's TCP-socket restriction; the rest of the protocol
suite and the WPF runtime harness still require a Windows runner.
