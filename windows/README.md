# Flux for Windows — pairing prototype

Local contribution work welcomed by bjarneo in
https://github.com/bjarneo/flux/issues/87#issuecomment-5948627270.
The repository's license state is unchanged.

This first milestone implements a native WPF shell and an incoming Flux v8
connection, active mDNS/UDP discovery, outgoing connections, certificate-bound
pairing, persistent certificate pins and a
Windows-user-protected identity. Pairing can start on either computer once the
TLS connection is established. It has an Omarchy-style device sidebar and
Overview and Files pages. File sharing and payload tunnels are advertised.
Video rendering, input, clipboard, full notification aggregation,
Windows Hello, tray support and full platform parity are not implemented yet.

## Build and checks

Use .NET 10 SDK. From the repository root:

```powershell
dotnet run --project windows/Flux.Protocol.Tests
dotnet build windows/Flux.Windows
dotnet publish windows/Flux.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o windows/artifacts/win-x64
```

The protocol tests run on Linux as well. WPF builds can be cross-targeted on
Linux; the app itself must be exercised on Windows. Native decoding and input
are the next implementation milestones, not established by a successful build.

## First Windows test

1. Run `Flux.Windows.exe` on the Windows desktop, on the same LAN as Omarchy.
2. If Windows asks about network access, allow the app on the private network
   used for the test. The app does not edit firewall rules itself.
3. Select **Pair new device** to browse mDNS and broadcast the Windows identity.
   Discovered devices appear in the sidebar. Keep Flux open
   on Android while scanning and pairing. Select a device and **Connect**. Omarchy can also initiate the connection after finding
   Windows. The **Pair device** button becomes available after a verified TLS link.
4. Select **Pair device** in Windows. Compare all 16 characters and accept on the other device,
   then confirm the matching key in Windows within 30 seconds. Alternatively,
   start pairing on Omarchy, accept in Windows and confirm on Omarchy.
5. Close and reopen the Windows app. Confirm that the saved certificate matches
   and that the computer reconnects without a new pairing.

Its separate state is under `%LOCALAPPDATA%\Flux.Windows`. The identity PFX is
encrypted with Windows DPAPI for the current user; private bytes are not logged
or stored in the checkout. A corrupt saved identity stops startup instead of
silently replacing a paired key. This is a pairing prototype; unrelated packet
types are ignored. No live VM operations are required to build it.

Prototype v2 fixes the Windows Schannel ephemeral-private-key handshake failure
by importing both new and saved identities into a temporary user key container.
It keeps the same DPAPI-protected identity and certificate pins. The protocol
test project includes a mutual TLS loopback check and should also run on Windows
to exercise Schannel; Linux testing alone does not verify that platform.

Prototype v3 adds actual discovery queries, merges fragmented mDNS records,
shows a device list, and implements UDP identity announcements and both TCP/TLS
connection directions. V2's Find computers button only re-announced Windows.
The network line shows local IPv4 addresses and listening ports. Firewall rules
are never changed automatically. If no devices appear, check that Windows
allows this executable on the private LAN and that the devices share the LAN.

Prototype v4 fixes a race between completed packet reads and local pairing
acceptance: the read timeout now lives for the whole connection. A saved
pairing cannot be cancelled by the pending pairing timer. The local key
confirmation is directly under the verification code, with scrolling for
smaller/scaled windows. After accepting on the phone, Windows explicitly asks
for **The keys match — accept**; until that step, the pairing remains pending
and expires after 30 seconds. Disconnect status distinguishes peer unpairing,
local pairing expiry, idle timeout and TLS closure. It reports packet types,
never packet contents.

Versions v4–v7 allowed only one active connection and refused incoming devices
other than the selected one. V8 replaces that restriction with independent
connections, as described below.

Prototype v5 corrects the device-list status: discovery was previously labelled
not authenticated even after confirmed pairing. Rows now distinguish discovered,
connected awaiting pairing, paired and connected, and saved pairing while
disconnected. Connected status requires the actual TLS peer ID and IP address;
an advertisement with the same ID at another address is not labelled connected.
The list updates when pairing is saved/removed or the connection changes.
Full interface parity is deferred until transport is stable.

Prototype v6 makes Connect report its progress immediately, cancels the old
read before disposing a connection off the UI thread, and serializes requests.
An occupied handshake slot is no longer silently treated as a completed
connection: the requested peer must finish its TLS identity check, or a timeout
is shown. Repeated clicks cannot queue overlapping connection attempts.
Connect also re-announces the Windows service so Omarchy can initiate the link.

LAN mDNS advertisements omit Tailscale's 100.64/10 overlay addresses. The
network line shows the addresses actually advertised. A LAN probe on chilibot
observed v4 advertising both 192.168.1.42 and 100.71.227.3. Windows TCP 1716 was
reachable from chilibot; a direct connection to Omarchy 192.168.1.102:1716 timed
out. Omarchy initiating the connection is therefore important. These checks
do not prove which address Avahi selected, or the specific firewall cause.

## Next milestone

Prototype v9 adds file sending and receiving for paired devices. Select a
connected paired device, open **Send** and use **Choose file and send**.
Received files are saved under the displayed `Downloads/Flux` folder; **Open
received folder** opens it only on a user click. The transfer list shows the
current run's progress, failures and completed receives. A sent transfer reports
transport completion, not an independently confirmed remote save receipt.

Files use an independently authenticated payload TLS socket, pinned to the
control connection's exact peer certificate and address. Android receives via
its advertised tunnel capability. Omarchy can send via a Windows return listener,
so its inbound firewall need not change. Direct payload ports are restricted to
1739–1764. There are at most four transfers per device, a 20-second listener wait,
15-second outgoing TLS/connect deadline and 60-second inactivity deadline.
Files must be between 1 byte and 8 GiB; empty files are not yet supported.

Only paired current sessions can transfer. Unpairing, reconnecting or shutdown
cancels the old session's transfers. Incoming names are reduced to a safe Windows
basename, reserved device names and alternate-stream characters are sanitized,
and existing destinations are never overwritten. A temporary file is renamed
only after receiving the exact declared size; failed/truncated/oversized transfers
are removed. Files are not automatically opened or executed.

Local tests cover direct payloads, incoming reverse tunnels, outgoing phone
tunnels, a wrong certificate preceding the valid sender, exact bytes, collision
handling and cancellation/failure cleanup. Live Windows/Omarchy/Android file
transfers remain to be confirmed on the owner's devices. The Go SDK installed
on this host is older than the upstream module requirement; no Go/Android/Swift
source was changed or built for this Windows feature.

Prototype v8 supports up to 16 connected devices and eight simultaneous TLS
handshakes. Selecting or connecting the phone leaves Omarchy and chilibot
connected. Each device owns its stream, pairing key, deadline, write lock and
read lifetime. The selected row determines which device Pair, Accept and Reject
operate on; acceptance is bound to the displayed connection ID and key. Other
devices' events do not replace that key. Existing DPAPI identity and pins are
preserved.

Crossed dials follow Go's five-second preference for the socket opened by the
larger device ID. Reconnecting replaces only that device, and stale cleanup
cannot remove its replacement or another device. Tests use two concurrent
mutual TLS transports, verify approval/read isolation and exercise transport
survival after one connection closes. Release compilation and protocol tests
are separate from live Windows validation.

For the v8 desktop test, close v7 and launch v8. Connect Omarchy, then Pixel;
both rows should remain connected. Switch between rows without pressing Connect
and confirm that their pairing controls refer to the selected device. Close and
reopen Windows and check both saved pairings reconnect without starting over.
If a pairing expires on one device, the other must remain connected and paired.

Prototype v7 keeps listening for up to 35 seconds after a direct TCP dial
fails, so Omarchy's observed 30-second retry can establish the return link.
This avoids ending Connect just because the desktop's inbound port is blocked.
Only the selected peer's verified TLS identity and IP can complete that wait.
Connection diagnostics retain the last 16 events in memory and distinguish
an occupied slot, a different selected device, TLS failures and secure identity
checks. No packet contents, private keys or pairing verification codes are
included. Close the old executable before starting v7. Test **chilibot** first,
then select Omarchy and Connect; send the diagnostic text if either fails.

Native Flux on chilibot and Omarchy now discovers, connects and pairs after
Avahi became active on chilibot. Chilibot also recorded a completed Windows
TLS connection followed by EOF. That establishes one successful Windows/Go
handshake, not sustained pairing or the cause of later failures.

Implement TLS desktop reception against the existing `flux.desktop` packets,
prove Windows H.264 decoding, then pointer/text input. Match the updated Omarchy
theme and master/stack UI once transport is proven. Read DESIGN.md and the Apple
surface brief before adding interface behavior. Preserve the existing clients'
local unlock boundary before enabling remote control.

## Prototype v10 interface

The Windows layout uses `gui/qml/` as its Omarchy desktop reference. Colors live in
`Flux.Windows/Theme.xaml`; this is the Tokyo Night fallback for devices without a saved theme.

**Computers** shows device cards with connection state and address. Select a
card or use the device selector above any page. Selection does not close other
connections. **Send** opens the file picker for that selected paired device.
**Inbox** shows this run's file transfers, progress, failures and the received
folder. **Control** explains that remote control is not implemented yet.
Connection diagnostics are collapsed by default. Pairing approval remains bound
to the selected device's displayed connection and all 16 verification characters.

Close the older app before launching v10. Check navigation, device selection,
key confirmation, file transfers, and readability at your Windows display scale.
The WPF Release build is checked here; actual rendering and interactions require
the owner's Windows test. The Omarchy desktop reference has not been received yet.

## Prototype v11 fixes and desktop styling

The owner reports that v10 closes on both file sending and receiving. Source
inspection found a concrete WPF runtime defect: the transfer ProgressBar used
the default two-way Value binding against a read-only Progress property. V11
explicitly uses OneWay. This is a UI rendering fix, not a protocol change; the
owner's Windows retest is still needed to establish that it resolves the crash.

Connect is disabled and labelled Connected while the selected peer already has
a connection, including when pairing is still pending. It becomes available
after disconnect. Finishing a Connect attempt updates the button without
replacing a connection failure message.

Desktop styling now follows `gui/qml/Theme.qml` and `components/Card.qml`, with
square surfaces and monospace text. Windows uses Cascadia Mono when available,
then Consolas; it does not bundle or claim the exact font resolved by Omarchy's
fontconfig. Paired online devices show a green dot with connected text. The
native title bar is replaced by an untitled drag area and minimize, maximize/
restore and close buttons, retaining WindowChrome resizing and system commands.

A Windows-only regression harness renders the actual transfer templates in both
directions with zero, partial and complete progress and checks Connect state:

```powershell
dotnet run --project windows/Flux.Windows.Ui.Tests -c Release
```

The harness avoids discovery, identity and pairing side effects. It is compiled
here but requires Windows to run. If another unexpected UI exception occurs,
the app displays an error before closing and writes `%LOCALAPPDATA%\Flux.Windows\last-crash.txt`.
The report contains only exception types and method names, not exception
messages, file names, packet contents, keys or local variable values.

## Prototype v12 review fixes

Astra's three findings are addressed. Invalid fractional, overflowing, missing
or wrong-type protocol versions are rejected as InvalidDataException, keeping
them inside UDP discovery's existing per-message rejection path. Refreshing
device rows preserves the selected device ID, IP and port even if names,
capabilities or row ordering change. If that endpoint disappears, selection
falls back to another address for the same device, then to the first device.
The shared Card style now has square corners as well as the buttons/list rows.

Regression checks cover the protocol rejection and selection rules. The WPF
harness additionally exercises both selectors and rendered card corners,
but requires Windows to execute. Close the older app before launching v12.

## Prototype v13 desktop UI phase one

The wide WPF layout now follows `gui/qml/`: the shared Flux mark and wordmark,
a 260-unit device sidebar with explicit icons, status and short device IDs,
and only **Overview** and **Files** navigation. The titleless Windows chrome
and its window controls remain. The compact header shows the selected device
and active connection address; Overview keeps alternate discovered endpoints,
connection actions and collapsed diagnostics. A key comparison card appears
only during an active pairing request. Another device's pending request is
signalled in the sidebar without changing the selected recipient.

Files contains the chooser and this run's transfer history. **This device**
filters by certificate-bound DeviceId; **All devices** shows the whole run.
The chooser captures its recipient before opening. A completed outgoing
transport still says **Sent — receipt not confirmed**; a successful incoming
transfer says **Saved**. The received folder can be opened from Files.

Close the earlier executable before testing v13. On Windows, check sidebar
selection and alternate address retention while discovery updates, two live
connections, pairing on either device, send and receive, both history filters,
minimize/maximize/restore and scaling. Run the Windows UI harness with
`dotnet run --project windows/Flux.Windows.Ui.Tests -c Release`. The WPF
harness is compiled here but cannot execute on Linux.
Check file transfer both ways, selection stability, and window controls/scaling
on the owner's Windows desktop. Saved identity and pairing storage are retained.

## Prototype v14: file controls and saved devices

Files now shows **Cancel transfer** only while a send or receive is active.
Cancellation stops that transfer's payload work and marks its row **Cancelled**;
connection loss and timeout remain **Failed**. Successful incoming files say
**Saved**; outgoing transport completion still says **Sent — receipt not
confirmed**. **Open received folder** remains a user action.

Paired devices remain in the sidebar after discovery and connection disappear.
The app stores their last authenticated name, address and port in
`%LOCALAPPDATA%\Flux.Windows\peers.json`; this is display and reconnect
metadata, not a second trust source. Older saved pairings without metadata
appear by short device ID until they reconnect or are discovered. **Forget
pairing** on Overview removes only the selected device's certificate pin and
metadata, cancels its active transfers and asks the connected peer to unpair.
If the peer is offline, it will need a fresh pairing on the next connection.

The source-only archive is `windows/artifacts/flux-windows-source-v14.zip`.
It contains `windows/`, the Windows CI workflow and Windows parity documents,
without local build output, archives or saved identity. The separate
`flux-windows-pairing-prototype-v14.zip` contains the self-contained executable
and these test instructions. The workflow runs protocol and real WPF UI checks
on a Windows runner for a PR that changes `windows/`, then verifies publish.
No workflow result exists until that source is proposed upstream.

On the owner's Windows PC, close the earlier app and test an active transfer's
Cancel button, offline saved rows after restarting with discovery unavailable,
reconnect using a saved address, and forgetting one of two paired devices.
Check that the other connection and pairing remain intact. Run
`dotnet run --project windows/Flux.Windows.Ui.Tests -c Release` from the
source checkout to exercise rendered templates and list state.

## Prototype v15: review fixes

The Windows UI harness now sends the same peer-view event as a real connected
session before removing discovery records. Its offline-device check can then
verify the connected and saved rows instead of failing on incomplete test data.

**Forget pairing** serializes pin removal with session registration and retries
if the selected session changes. It revokes the current session before returning;
handshakes after removal cannot inherit the deleted pin. The app makes a bounded
best-effort attempt to send `flux.pair=false` on the current connection. Remote
unpairing and a remote request to pair again use the same atomic current-session
check.

File transfers retain the reason for a stop. A transfer stopped by **Forget
pairing** says **Cancelled — Pairing removed**; a connection replacement says
**Failed — Connection changed**. Explicit Cancel says **Cancelled by you**.
Malformed Unicode filenames are rejected before a file slot is reserved. The
transfer worker releases its slot even if setup fails before payload I/O, and
Cancel now reaches the control-packet write and tunnel request.

Use `windows/artifacts/flux-windows-pairing-prototype-v15.zip` for the next
Windows check. `windows/artifacts/flux-windows-source-v15.zip` is the matching
source-only contribution package. The WPF runtime harness and live cancellation
and Forget races still need a Windows run; compiling them on Linux is not a
substitute.

## Prototype v16: Omarchy theme on Windows

Windows now advertises incoming `flux.theme`. A verified, paired Omarchy
connection can supply the active colors; Windows applies them to the selected
device's Overview, Files, sidebar and window controls. Theme packets from an
unpaired or replaced connection are ignored. The most recent valid theme is
saved by device ID under `%LOCALAPPDATA%\Flux.Windows\themes.json`; Forget
pairing removes it. Selecting a device without a saved theme shows the Tokyo
Night fallback. Incoming colors are adjusted for readable text and status.

Use `windows/artifacts/flux-windows-pairing-prototype-v16.zip` for the Windows
test. Close the old app, start v16, connect to paired Omarchy, then change the
Omarchy theme twice. Check that Windows follows each change without reconnecting,
including one light theme. Select a second device and return: each device should
show its own last received theme. Restart Windows Flux to check the saved theme,
then Forget pairing to check the Tokyo Night fallback. Check the titleless
window buttons and text readability after each switch.

The owner confirmed that v16 changed to Omarchy's `ristretto` colors on a real
Windows desktop once Omarchy ran a daemon built from the newer source. The
installed `omarchy-flux 0.8.0-1` on that computer was built September 30, before
`flux.theme` was added; its version number alone did not reveal this gap. A
temporary user-level `fluxd-theme-preview` service override enabled the live
check without replacing the packaged binary. Theme changes without reconnect,
light themes, saved-theme restart, Forget fallback, scaling and the WPF harness
still need Windows checks. Remove the override after an official Omarchy package
contains theme sync.
