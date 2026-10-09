# Flux for Windows — desktop preview

A native WPF client for Flux protocol v8, compatible with the Flux 0.15 port
ranges. This continues the Windows contribution discussed in
[issue #87](https://github.com/bjarneo/flux/issues/87) and
[PR #92](https://github.com/bjarneo/flux/pull/92).
The repository's license state is unchanged.

## Features

- LAN discovery through mDNS and UDP, incoming and outgoing TLS connections,
  certificate-bound pairing and independent connections to multiple devices.
- Saved trust and automatic reconnect after startup. Fresh discovery addresses
  take priority over saved addresses. Attempts are serialized per device, with
  up to four automatic attempts in parallel.
- File sending and receiving, multiple selected files, drag-and-drop onto the
  send card, progress and cancellation. Files go to the selected paired device.
- Persistent transfer history with timestamps, device filtering and 25 entries
  per page. **All devices** means all transfers to/from this Windows computer;
  transfers directly between other devices are not collected.
- Optional Unicode text clipboard sync and a manual **Send now** action. Clipboard
  images are not advertised or supported.
- An Omarchy-style device sidebar and Overview, Clipboard and Files pages,
  square controls and surfaces, readable theme colors and per-device
  `flux.theme` synchronization with a Tokyo Night fallback.
- A tray icon: close hides the window while connections and sync continue;
  double-click reopens it; right-click **Exit Flux** stops the app.
- One instance per Windows user/session. Launching the EXE again opens the existing
  window. Optional login startup launches quietly beside the clock.

Remote control, video/webcam/microphone, messages, notification aggregation and
Windows Hello are not implemented. Unsupported capabilities are not advertised.
The app does not automatically edit firewall rules or enable remote access.

## Build and validation

Use the .NET 10 SDK, from the repository root:

```powershell
dotnet run --project windows/Flux.Protocol.Tests
dotnet build windows/Flux.Windows -c Release
dotnet build windows/Flux.Windows.Ui.Tests -c Release
# Run the WPF harness on Windows:
dotnet run --project windows/Flux.Windows.Ui.Tests -c Release
dotnet publish windows/Flux.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o windows/artifacts/win-x64
```

The protocol tests run on Linux and Windows. They cover mutual TLS, pairing,
certificate changes, concurrent devices, discovery, session lifetimes, direct
and reverse-tunnel payloads, file safety and failure cleanup, theme contrast,
clipboard wire format and echo suppression, reconnect target selection, and
transfer history beyond 50 entries with restart and damaged-tail recovery.

The WPF harness covers connection state, theme changes, transfer rendering,
progress bindings, pagination to the oldest history entry and clipboard
navigation. It must run on Windows; Linux can only cross-build it. The Windows
CI workflow builds the preview and runs that harness.

The owner confirmed live pairing and file transfers, Unicode clipboard sync
between Windows and Omarchy, and automatic reconnect to Chilibot, Pixel and
Omarchy after restarting Windows. The owner also reported that the login-startup
preview works; a separate sign-out/sign-in test was not explicitly recorded.
The first live Omarchy `ristretto` theme application was confirmed. Repeat theme
changes, light themes, saved-theme restart, Forget fallback, display scaling,
tray background behavior and drag/drop still need individually recorded Windows
checks. Local build success does not establish those behaviors.

## Use the preview

1. Exit older previews completely before starting a new executable. For versions
   with a tray icon, use **Exit Flux**; closing the window only hides it. Older
   previews without the instance guard can otherwise keep their sockets open.
2. Unpack the executable into a permanent folder and run `Flux.Windows.exe`.
   If Windows asks, permit access on the private LAN used for the test.
3. Open **Pair new device**, select a discovered device and **Connect**. Keep Flux
   open on Android during initial discovery/pairing.
4. Start pairing on either device. Compare all 16 verification characters before
   accepting. Confirm **The keys match — accept** in Windows when requested;
   accepting only on the phone does not complete the pairing.
5. Existing certificate pins reconnect without a new pairing. **Forget pairing**
   removes trust for the selected device.
6. On **Clipboard**, enable automatic sync on Windows and the other device, then
   copy harmless multiline text in both directions. **Send now** also works with
   automatic sync off and reports the number of compatible devices sent to.
7. On **Files**, choose files or drop them onto the send card. Folders are skipped.
   **Open received folder** opens the destination only on your click.
8. **Overview → Windows startup → Start Flux when I sign in** is off by default.
   Enabling it registers the current user's quoted EXE path with `--background`
   under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. No administrator
   rights are needed. Turning it off removes only Flux's own entry. Opening a
   new preview updates an already enabled entry to that EXE's path. Windows
   Startup Apps can disable it independently of this switch.

Discovery uses UDP 12100; device links use TCP 12100–12108; file payloads use TCP
12070–12099. Other devices must use these ranges too. Old Windows previews used
1716-range ports; saved hints are migrated while retaining trust. Diagnose the
service, version and discovery before changing any firewall rules.

## State and safety

State is stored under `%LOCALAPPDATA%\Flux.Windows`. The identity PFX is protected
by Windows DPAPI for the current user. Certificate pins are the authority for
trust; display metadata and saved addresses do not grant it. A corrupt identity
stops startup rather than silently creating a new paired identity.

Only paired current sessions transfer files or apply queued clipboard copies.
Unpairing, reconnect and shutdown cancel that session's transfers. Payload TLS
requires the exact control-session certificate and peer address. Filenames are
reduced to safe Windows basenames; reserved names and alternate-stream characters
are sanitized. Existing files are never overwritten. Failed or truncated receives
remove temporary files. Files are not automatically opened or executed. File
sizes are limited to 1 byte–8 GiB; empty files are not supported. Outgoing
completion records transport completion, without an independently confirmed
remote save receipt.

`transfer-history.jsonl` retains terminal transfer metadata, including filenames,
paths, device names and dates; file contents are not stored. Active transfers are
not restored as running jobs. History from older previews' discarded in-memory
sessions cannot be recovered.

Clipboard sync is off by default. Its setting survives restarts, but clipboard
text is never persisted in settings, transfer history or diagnostics. Existing
clipboard contents are not sent merely on startup or enabling sync. The Windows
clipboard exclusion marker is respected. Text is limited to 1 MiB of UTF-8;
received copies are not echoed and stale reconnect copies are rejected. A busy
clipboard is retried with only the newest incoming copy retained. Android may
require its explicit **Send clipboard** action due to background restrictions.
