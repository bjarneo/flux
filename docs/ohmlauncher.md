# OhmLauncher integration

[Documentation index](README.md)

OhmLauncher can use the existing paired Flux connection for Omarchy themes,
wallpapers and desktop input. The daemon remains the owner of desktop effects.
Headless daemons reject these desktop-effect extensions before admission.
The extensions below are opt-in capabilities; a client that does not advertise
them keeps the existing Flux behavior. The `flux.theme` palette contract used by
Flux for Android, iOS and macOS is unchanged.

## Themes and backgrounds

A paired client receives the installed Omarchy theme IDs and bounded color data
through `flux.omarchy_theme`, version 1. Choosing a theme sends
`flux.omarchy_theme.select` with a version, a fresh UUID request ID and an
advertised theme ID. The daemon validates the current catalog, then runs the
canonical Omarchy theme setter. `flux.omarchy_theme.selected` acknowledges the
result and the actual current theme. Re-selecting the current theme also runs the
setter, so its background is restored.

The background selector receives the active theme's image album through
`flux.wallpaper.v2`. It contains bounded JPEG previews and opaque selection IDs,
not filesystem paths. Choosing an album entry changes only the background;
choosing a theme changes both its palette and its background. A custom image is
sent as its original JPEG, PNG or WebP bytes. Desktop background changes, including
a manually selected image, are sent to the paired phone through the same original
image channel. A preview is never applied or uploaded as an original wallpaper.

Each original is limited to 32 MiB and 32 million pixels. Transfers use 24 KiB
chunks and validate MIME type, dimensions, length and SHA-256 before committing.
A state frame carries the current theme and revision; the receiving commit must
match that revision. The daemon stores incoming originals separately from theme
albums, so a later theme change selects that theme's own background.

A gallery request is `gallery_request` with a fresh 32-character lowercase hex
operation ID. The response is `gallery_begin`, zero or more `gallery_item` frames,
and `gallery_end`, all tied to the same operation. The begin frame names the
current theme, revision, current image ID and item count. An item contains an
opaque ID, label and a base64 JPEG preview. A selection sends `gallery_select`
with a fresh operation, theme, revision and image ID; `gallery_selected` reports
success. Invalid or stale requests fail without changing desktop state.

Albums contain only regular JPEG, PNG and WebP files from the current theme's
background directories. The daemon re-resolves opaque IDs and content hashes at
selection time. Symbolic links, oversized files and images outside that album
cannot become selections. Catalogs contain at most 1,024 images, each with a JPEG
preview no larger than 16 KiB or 320 by 180 pixels. Custom desktop backgrounds are
read only through Omarchy's canonical active-background link, never through a
path supplied by a peer.

Theme selection, original commits and gallery selection share a daemon mutex
and Omarchy's filesystem lock. Commits use revision compare-and-swap, immutable
content-addressed storage, an atomic active-background link and fixed compositor
IPC. Failed compositor notification rolls back the link. A durable receipt
ledger makes retries idempotent. A successful upload returns updated state to
its source without echoing the original back. Gallery selection still delivers
the selected original to its source, which initially has only a preview.

## Temporary desktop input

A client advertising `flux.input.request.v2` requests a temporary pointer and
keyboard lease with an exact boolean `request` and fresh UUID `requestId`.
The desktop shows **Approve** and **Deny** through its native notification
service. Approval must come from the notification server's current D-Bus owner
and the action registered for that exact request. Clicking the notification body
does not approve it. The service must display explicit action buttons.

The request expires after 20 seconds. An approved lease lasts at most five
minutes and ends on cancellation, timeout, disconnect, unpairing or connection
replacement. It does not change `remote_input` in the configuration and does not
authorize shortcuts or arbitrary desktop commands. Disabling remote input also
revokes any current temporary lease. Each queued native effect rechecks the
exact lease. Cancellation joins in-flight effects and releases only buttons held by that lease;
failed cleanup quarantines native input instead of granting a later request.

The phone's credential prompt remains a client-side check. It cannot substitute
for the daemon's paired-link checks or the desktop's explicit approval.

## Validation

Run from the repository root:

```sh
make test vet build-go
```

The tests cover capability direction, malformed requests, stale links, replay,
revocation, headless isolation, queue overflow, button ownership, native cancellation,
bounded palette and image
parsing, album enumeration, compare-and-swap conflicts, rollback and receipt
replay. The existing two-daemon tests continue to use isolated sockets and trust
stores. Running a development daemon against an active user's trust store or
socket is unnecessary.

A physical test with OhmLauncher should confirm pairing, explicit approval,
mouse movement, theme selection, album selection, custom-image selection,
desktop-to-phone changes and reconnect. Compare original image hashes on both
sides, and confirm that selecting a background leaves the palette unchanged.
