# Windows UI standardization — Astra review

Date: 2026-10-02. Baseline: Windows prototype v12.
Status: phase one implemented in Windows prototype v13; Windows visual validation pending.

Astra reviewed six owner-provided Omarchy screenshots (`flux_oma_1.png` through
`flux_oma_6.png`) and four Windows screenshots (`fluxwin.png` and
`fluxwin_2.png` through `fluxwin_4.png`), together with the Qt and WPF sources.
Private clipboard and message contents are not part of this specification.
The owner has confirmed file transfers in both directions between Windows
and chilibot. Preserve that working transport and certificate-bound pairing.

## Decision

Align Windows with the actual Omarchy desktop: devices in the sidebar, a
compact header, and consistent page names. The first pass contains **Overview**
and **Files**, using the currently implemented Windows features.

Canonical desktop references:

- [Theme.qml](../gui/qml/Theme.qml), [FluxView.qml](../gui/qml/FluxView.qml)
- [Components](../gui/qml/components/), [Pages](../gui/qml/pages/)
- [Desktop host and responsive layout contract](qml.md)

[DESIGN.md](../DESIGN.md) describes the Android/iOS/macOS device-side design.
Its rounded mobile tiles and navigation should not override the actual Qt
desktop reference. Mobile can retain its adapted layout while sharing labels,
icons and the meaning of states.

## Findings and page mapping

Windows already has the core palette, square device rows, monospace text,
green connection status and titleless chrome. Its largest differences are
structural: duplicate device selection, an oversized persistent pairing card,
separate Send and Inbox pages, larger titles and padding, and a text-only logo.

| Current Windows | Proposed Windows | Behavior |
| --- | --- | --- |
| Computers and device selector | Sidebar devices and Overview | Choose one device; show details and supported actions |
| Send and Inbox | Files | Sending and transfer history together |
| Persistent pairing card | Compact status; temporary pairing card | Full verification UI only while pairing is pending |
| Scan again on every page | Pair new device and discovery panel | Keep scanning with device discovery |
| Control placeholder | Omit from initial navigation | Add a page when its functionality exists |
| Diagnostics on every page | Collapsed section in Overview | Keep technical details available for troubleshooting |

Future common page order, as features become implemented:
**Overview → Clipboard → Files → Notifications → Messages → Phone commands**.
Keep the English labels used by both desktop clients.

Do not copy unavailable battery fields or unsupported actions from Omarchy.
Do not infer Windows transparency from screenshots: compositor and host
settings can affect appearance. Start with opaque semantic colors.

## Desktop visual roles

Values are logical WPF units; compare at the same logical window size and theme.

| Role | Reference value |
| --- | --- |
| Background | `bg`, `#1A1B26` |
| Sidebar and cards | `bg2`, `#16161E` |
| Borders and separators | `bg3`, `#292E42`; thickness 1 |
| Main / secondary text | `fg`, `#C0CAF5` / `dim`, `#737AA2` |
| Accent | `accent`, `#7AA2F7`; selected navigation uses subtle accent fill |
| Success / warning / error | `#9ECE6A` / `#E0AF68` / `#F7768E` |
| Corners | 0 for cards, buttons, fields and selections |
| Body / metadata | 13 / 11–12 |
| Page title | 20 bold; 17 in narrow layout |
| Content spacing | 28 side margin, 24 above content, 18 between sections; 16 side margin narrow |
| Button padding | Approximately 14 horizontal and 7 vertical |

Use the shared Flux mark and compact `flux` wordmark. Reuse the canonical
brand geometry/assets; use explicit vector resources or an explicit icon font
for functional icons corresponding to the Qt icon keys. Icons should not
depend on whichever text font Windows happens to resolve.

Qt specifies `monospace`; the exact font resolved on the owner's Omarchy host
is not established. Retain Cascadia Mono → Consolas until that font is identified.
Exact cross-platform typography needs a common named font with suitable rights.
V16 adds live Omarchy theme synchronization for the selected paired device.
The owner confirmed its first application with `ristretto`; other themes and
display scaling still need Windows checks.

## Device, pairing and capability rules

- Represent devices by stable **DeviceId**, never by display name. Distinguish
  identical names with an address or short identity reference.
- Selecting a device controls the header, Overview, send target and Files
  filter. Switching selection must not close other connections.
- Keep alternate endpoints in device details. Preserve the selected device ID,
  IP and port through refreshes, falling back only if that endpoint disappears.
- Show the **active connection's address** as active; discovery is only a hint.
- Green dot plus `connected` means paired and online. Keep separate labels for
  discovered, connecting, not paired and offline.
- Approval remains bound to the displayed DeviceId, connection ID and complete
  verification key. Background updates must not silently retarget approval.
- Keep the chosen recipient captured when a file picker or transfer starts.
- A pending pairing card shows the device, address, four groups of key characters,
  comparison instruction and accept/reject actions. Remove it after completion,
  rejection or expiry. Signal another device's pending request without changing
  the current recipient automatically.

Only expose features implemented locally and supported by the peer in the
relevant direction. If a supported operation is temporarily unavailable,
retain its page/history, disable the action and explain why. Local settings
must be labelled **This computer** when they affect the Windows host.

The Windows identity parser currently retains tunnel support, not a complete
capability catalog. Do not claim full capability-driven navigation before the
needed data exists. A complete list of saved offline devices also needs retained
display metadata; certificate pins remain authoritative for trust.

## Files

Put the existing file chooser at the top and compact transfer rows below it.
Do not show drop instructions before drag-and-drop works. Drag-and-drop and
multiple-file selection can be separate enhancements.

Rows show direction, filename, peer, size, progress and state:

- Sending / Receiving
- Sent — receipt not confirmed
- Received — saved
- Failed

Completed sending is not proof of a remote save. Preserve that distinction.
Successful receives should make the received folder easy to open.

Add **DeviceId** to `FileTransferView` before filtering by selected peer; it
currently stores only a display name and Windows history is global. Offer
**This device / All devices** to retain a global view. History is currently
limited to the current app run; do not promise persistence.

## Responsive layout and Windows behavior

Follow the Qt layout thresholds:

- Width ≥1000: sidebar 260.
- Width 680–999: icon rail 64, full device list in a drawer.
- Width <680: menu button and drawer.
- Compact header actions below 760 content width, with names and tooltips.

Retain titleless WindowChrome, system window controls, dragging, resizing,
maximize/restore, Alt+F4 and system-menu behavior. Keep interactive controls
out of draggable regions. Keyboard actions need visible focus; icon controls
need accessible names. Escape closes the drawer and restores opener focus.

## Implementation phases and acceptance

1. **Main structure:** desktop roles, brand/icons, typography, sidebar devices,
   compact header, Overview and Files. Preserve transport, pins and pairing.
2. **View data and feedback:** stable transfer DeviceId, selected versus active
   endpoint, pairing notifications, accurate transfer and failure states.
3. **Responsive and accessible behavior:** rail/drawer, smaller windows,
   keyboard navigation, display scaling and window operations.

Acceptance requires:

- Comparable structure and styling at equal logical size and theme.
- No full pairing surface during ordinary connected use.
- Correct recipient through device switching and background refreshes.
- Independent simultaneous connections and saved pairing retained.
- File transfers both ways, with accurate completion/receipt wording.
- No navigation to unimplemented functions.
- Approval stays bound to the displayed session and key.
- No clipping at Windows scaling 100%, 150% and 200%; functional window controls.

The exact Omarchy font does not block the first pass. Windows visual and
interaction validation remains necessary; compiling
WPF on Linux does not execute its UI tests.
