# Plan: an interactive Herdr agent terminal in Flux Android

Follow-up after the real Pixel trial: [phone-first terminal plan](herdr-mobile-terminal-follow-up.md).
That plan is now the active plan for the next iteration and has precedence where the two differ.
It supersedes the desktop-size, separate-reader, and optional-control UX decisions below.
The interactive terminal replaces the reader on Android only; iOS keeps its read/output flow.
This document retains the original implementation history and the verified phase results.

Date: 2026-10-03. Status: Phases 0-4 are implemented and recorded below. The follow-up plan
above is the active plan for what comes next; this document is history and the verified record.

This document defines an initial integration using the Herdr 0.9.3 CLI bridge.
It does not authorize installations, Pixel changes, or control of personal agent sessions.

## 1. Intended outcome

Open an agent from Android and control only its terminal:

- See its live screen without the Herdr sidebar or neighboring panes.
- Swipe over the conversation to send wheel events to the agent running on the PC.
- See the resulting conversation position on both devices.
- Send clicks and permitted keys with explicit consent.
- Initially retain desktop dimensions and use local zoom/pan on Android.
- Keep the existing phone-reflowed reading view as a separate alternative.
- Leave the PC's OpenCode configuration and vertical session tabs unchanged.

Two bullets above are superseded by the follow-up: the phone gets PTY dimensions of its
own instead of desktop dimensions, and the terminal is the only surface instead of a
separate reader. Both apply to Android only; iOS keeps its existing read/output flow.

The interactive terminal retains OpenCode's own tabs: they belong to its screen.
Hiding them or rebuilding them horizontally is outside the MVP. Do not break the mapping
between displayed coordinates and actual terminal coordinates. Reading mode may still hide them.

## 2. Investigated baseline and confidence

Local sources inspected:

- Flux: commit `681738af2ec27e7654e3e408cc0cbc3bd315a96e`.
- Herdr: commit `5da0a01e1eedda054db0c81dd3a780000c40d9f0`.
- Earlier research checked the documentation and wheel routing against `v0.9.3`.
- This review adds CLI, socket, Flux transport, and existing test details.

### Confirmed by code and documentation

| Requirement | Existing contract |
| --- | --- |
| Observe one terminal | `herdr terminal session observe <target>` |
| Control one terminal | `herdr terminal session control <target>` |
| Live ANSI screen | JSONL `terminal.frame` records |
| Input | JSONL `terminal.input` commands on stdin |
| Wheel events | `terminal.scroll`, with source and coordinates |
| Mouse events | `terminal.mouse`, with action, button, and coordinates |
| Release control | `terminal.release` or EOF on stdin |

The target can identify a pane, terminal, or agent. Flux must resolve and pin terminal identity,
not depend on focus or automatically follow a reassigned agent name.

Frames contain `seq`, `encoding`, `width`, `height`, `full`, and base64 `bytes`.
The stream emits `terminal.closed` with a reason; EOF can also end it without that record.
The inspected CLI ignores graphics messages: this route does not provide inline images.

Observe allows multiple observers without input, resize, or scroll ownership.
Control allows one direct owner per terminal. Never use `--takeover` automatically.
The controller acquires a size lock and resizes the terminal when connecting.
Connecting with current dimensions avoids an intentional initial size change, but does NOT
guarantee that the desktop can freely resize the pane while control is active.

### Important wheel-event detail

`apply_scroll` chooses routing according to the application's terminal mode:

1. `MouseReport`: encode and send a wheel event to the application.
2. `AlternateScroll`: use the terminal's negotiated alternate-scroll encoding.
3. `HostScroll`: scroll emulator history according to `lines`.

In the inspected code, the first two branches do NOT repeat events according to `lines`.
Therefore, `lines: 3` does not necessarily mean three wheel events for OpenCode.
The MVP should send discrete steps with `lines: 1`, repeating them within bounded limits.
Do not globally replace wheel events with arrows: they may change a choice or prompt instead.
With a `page_key` source, Herdr uses PageUp/PageDown or host history according to the mode.

### Still requires demonstration; do not present as solved

- Real OpenCode V2 scrolling and its simultaneous visible effect on the desktop.
- Actual PTY geometry versus layout rectangles and observer dimensions.
- Desktop resize behavior during control and restoration after disconnecting.
- Exact `full`, sequence, and baseline semantics after reconnecting.
- Practical compatibility between the chosen Android emulator and Herdr frames.
- Safe detection of agent exit and replacement by a shell in the same pane.
- Performance and competition with other packets on the Flux link.

## 3. Scope and initial decisions

First platform: Android. Apple clients retain their existing behavior.
First integration: CLI JSONL, not decoding Herdr's binary protocol.
Keep the current JSON API for lists, state, notifications, and existing actions.
Do not build a complete Herdr client or a terminal emulator from scratch.

Delivery order:

1. Isolated proof of the contract and coexistence with the desktop.
2. An ANSI observation view without remote input.
3. Explicit control mode, initially supporting wheel events only.
4. Clicks and existing controls after passing security tests.

Initially exclude mobile resize, raw keyboard input, automatic control reacquisition,
terminal images, unlimited history synchronization, and tab rearrangement.
The follow-up makes phone-driven PTY resize with desktop recovery its priority 1, and
control by default on entry its priority 2; the other exclusions stand.

## 4. Proposed architecture

```text
Android: ANSI view + gestures + local unlock
                     ↕
               Flux TLS link
                     ↕
fluxd: authorization + session + limits + ordering
                     ↕
herdr terminal session observe/control subprocess
                     ↕
       selected pane's stable terminal
```

Do not add SSH, new ports, firewall rules, or parallel pairing.
Use one subprocess per open stream, initially limited to one stream per device.
Allow one Flux controller per terminal; other devices may observe without input.

### Files likely to change during implementation

- `internal/herdr/`: CLI wrapper, typed frames, lifecycle, and subprocess tests.
- `internal/core/herdr.go`: capabilities, authorization, and arbitration with existing reads.
- A small new `internal/core/` file for stream lifecycle if needed.
- `internal/proto/`: additive `flux.herdr` contract and compatibility tests.
- Android `core/Herdr.kt` and `core/HerdrModel.kt`: session state and commands.
- Android `ui/AgentScreens.kt`: Read / Terminal / Control selection.
- A separate Android view for the terminal component and coordinate transformation.
- Android dependencies, only if an external terminal library is selected.
- `docs/herdr.md`, `docs/security.md`, and `docs/development.md`: contract and checks.

This list is indicative: reuse existing helpers before creating new files.
Do not modify cryptographic approval or Qt to implement the first Android client.

## 5. Phase 0: isolated proof and blocking decisions

Prepare a disposable Herdr session, never the default personal session.
First confirm syntax with the installed CLI and follow the Herdr skill's safety rules.
Do not launch external agents or chargeable tasks without specific authorization.

Record Herdr, Flux, and agent versions, system details, dimensions, and terminal modes.
Create fixtures containing no private conversations or tokens.

### Experiments

1. Observe a plain-text pane and verify the absence of surrounding Herdr UI.
2. Observe an alternate-screen TUI with cursor updates.
3. Check the initial frame and continuity; capture a small, anonymized JSONL trace.
4. Obtain current size without changing it: investigate `pane.layout`, runtime, and observer.
5. Connect control at that size, without takeover, and compare dimensions before and after.
6. Send one wheel event over the conversation and verify the result on both screens.
7. Test wheel routing over input, tabs, panels, and modals without approving operations.
8. Distinguish shell history, alternate scroll, and application-internal scrolling.
9. Resize the PC window and record the size-lock limitation.
10. Release control, close stdin, and simulate process failure; verify recovery.
11. Try a second controller: it must be rejected without removing the first.
12. End the agent and verify that input does not continue into a shell.

Exit gate: reproducible evidence of pane-specific wheel input and correct ANSI rendering.
If size handling or coexistence fails the requirements, retain observe and document the limit.
Do not describe the MVP as control without size authority if the contract does not support it.

### Phase 0 results (2026-10-03)

Harness: `scripts/herdr-bridge-proof.py`. It creates a disposable named Herdr
session, runs a fixture TUI in its pane, and asserts the bridge contract.

```sh
python3 scripts/herdr-bridge-proof.py          # 14 checks, self-cleaning
python3 scripts/herdr-bridge-proof.py --keep   # keep the session for manual use
```

Evidence lands in `/tmp/opencode/herdr-bridge-proof/results.json`.
Run against Herdr 0.9.3: 14 passed, 0 failed. Existing sessions were not touched.

Proven at contract level with the fixture TUI:

1. `observe` streams `terminal.frame` JSONL at the observer viewport (80x24)
   and does NOT resize the PTY: the pane stayed 120x40 with zero size events.
2. `control` owns PTY size: connecting at 80x24 resized the application
   (`pane layout` kept its own workspace rect, so the PTY size is the ground
   truth, not the layout rect). The size-lock limitation is now confirmed.
3. Wheel routing with `source: wheel`, `lines: 1`:
   - mouse report: one SGR event per command, `ESC[<64;X;YM` up and
     `ESC[<65;X;YM` down. Coordinates are 1-based: sent cell (col,row)
     arrives as (col+1,row+1). `lines` does not repeat events; a separate
     command is needed per step, which matches the planned 30 events/s budget.
   - alternate scroll (1007, no mouse reporting): arrow encodings `ESC[A`
     and `ESC[B` arrive, one per command.
   - neither: host scrollback moves by exactly `lines` and the app receives
     nothing. `pane get` exposes `scroll.offset_from_bottom` for verification.
4. Controller exclusivity: a second `control` without `--takeover` is rejected
   with `terminal attach failed: ... already has an attached client`; the
   first controller keeps working.
5. `terminal.resize` in the same stream resized the app to 100x30.
6. `terminal.release` closes with `{"reason":"detached"}` and the process
   exits cleanly; no orphans remain.
7. An observer keeps receiving frames while a controller is active.
8. `workspace create` and `pane get` expose `terminal_id`, so Phase 1 can
   pin terminal identity through the JSON API.
9. `herdr --session NAME server` gives an isolated headless server;
   `session stop` plus `session delete` clean it up.

Still unproven and still Phase 0 open items:

- OpenCode V2 itself reacting to the wheel: its own mouse mode decides
  between the three routings. The fixture proves the routing, not OpenCode.
- Desktop TUI behavior while control holds the size lock (the probe was
  headless).
- Frame baseline and recovery after a dropped connection.
- Rendering these frames on Android (Phase 3 work).

So the exit gate passes for the bridge contract, and the MVP may proceed to
Phase 1. The MVP must still state that control acquires PTY size ownership.

## 6. Phase 1: CLI wrapper in fluxd

### Safe session and executable selection

- Resolve a trusted local executable from the daemon's environment.
- Use `exec.CommandContext` and separate arguments; never use `sh -c`.
- Derive the client socket from the SAME API path used by `d.herdrPath`.
- Herdr derives `herdr-client.sock` from `herdr.sock` through `HERDR_SOCKET_PATH`.
- Validate client socket ownership and type, as already done for the API socket.
- Do not accept socket paths, environment variables, or session names from the phone.
- Revalidate pane and terminal against the current snapshot before opening.
- Resolve `terminal_id` through the API; the current Flux model does not retain it yet.

### Process lifecycle

- Separate stdout reading, stdin writing, and bounded stderr draining.
- Parse each record with an explicit limit; do not use Scanner's default limit.
- Validate base64, encoding, and dimensions before forwarding to the phone.
- Do not interpret `terminal.closed` as successful delivery of the last input.
- Log only sanitized reasons and metrics, never private screen bytes.
- Use one ordered stdin queue; do not interleave JSON from different goroutines.
- Release by sending `terminal.release`, closing stdin, and waiting with a bounded deadline.
- If it does not exit, terminate only Flux's own subprocess and call `Wait`.
- Never close a pane, agent, workspace, or server to release a stream.
- Cancel on view close, link loss, unpairing, permission revocation, or fluxd shutdown.

Fake-CLI tests: initial frame, EOF, errors, blocked stdin, excessive stderr,
oversized records, invalid JSON, timeout, and absence of orphaned processes.

### Phase 1 status (2026-10-03)

Implemented in `internal/herdr/`, not yet wired into fluxd or the protocol:

- `terminal_session.go`: `OpenSession` runs one
  `herdr terminal session observe|control <target> --cols N --rows M`
  subprocess. The CLI gets no session name and no socket argument; only
  `HERDR_SOCKET_PATH` in its environment selects the session, and the
  redirect variables are removed. Both the API socket and the derived
  `*-client.sock` pass `CheckSocket` (Unix socket of this user) first.
- Frames are validated before they could reach a phone: `ansi` encoding,
  base64 bytes, and dimensions within 1..1000. A frame is never truncated:
  an invalid record ends the stream with a clear error.
- Input goes through one ordered queue of at most 128 commands, and only
  the writer goroutine touches stdin. An observe stream refuses input and
  resize. `SendScroll` fixes `source: wheel` and a caller-chosen `lines`;
  Phase 2 fixes `lines: 1` as daemon policy.
- `Close` queues `terminal.release`, closes stdin (the CLI detaches when
  its input ends), waits 5 seconds, and then kills and reaps only the
  subprocess that Flux started. `OpenSession` uses `exec.CommandContext`,
  so the ctx of the link or daemon also ends the bridge.
- `GetPane` (`pane.get`) returns `terminal_id` and the scroll state, so a
  caller can pin terminal identity before it opens a stream.

Fake-CLI tests in `terminal_session_test.go` cover: first record, attach
refusal, EOF without `terminal.closed`, invalid JSON, oversized records,
bad base64 and encoding, command order and validation, read-only observe,
blocked stdin with a full input queue and a bounded kill, bounded stderr,
the child environment and argv, `ClientSocketPath`, `CheckSocket`, and
`GetPane`.

Checks: `go test -race ./internal/herdr/`, `go vet ./internal/herdr/`,
and `go build ./...` all pass.

Not part of Phase 1: Flux protocol messages, permission checks, and any
phone UI. Those are Phase 2 and Phase 3.

## 7. Phase 2: additive Flux contract

The following names are proposals, not messages that Flux already supports.
Reuse `flux.herdr` with new `kind` values; do not change existing operations.

### Capabilities

Add an optional terminal-capabilities section to state.
Advertise observe/control/scroll/mouse only when verified for the installed bridge.
Do not infer these capabilities solely from `MinProtocol = 22`: that is a separate interface.
Do not use mutating probes on a real pane to discover support.
Old clients ignore new fields and continue using `read`.
New Android clients hide interactive mode when the daemon does not advertise support.

### Proposed messages

| Direction | Proposed kind | Main fields |
| --- | --- | --- |
| Android → fluxd | `terminal_open` | request, pane, mode: observe/control |
| fluxd → Android | `terminal_opened` | request, session, pane, mode, width, height |
| fluxd → Android | `terminal_frame` | session, seq, encoding, full, width, height, bytes |
| Android → fluxd | `terminal_scroll` | session, input_seq, direction, column, row |
| Android → fluxd | `terminal_mouse` | session, input_seq, action, button, column, row |
| Android → fluxd | `terminal_release` | session, request |
| fluxd → Android | `terminal_closed` | session, code, reason |

Do not expose arbitrary CLI JSON or `terminal.input.bytes` to the phone.
The daemon fixes `source: wheel`, `lines: 1`, and permitted modifiers for the MVP.
fluxd generates the session ID and binds it to the device, link, and terminal.
Reject all stale or cross-session messages; never redirect them to a new pane.
Use correlated requests for opening failures and cancellation races too.
Do not claim a frame acknowledges a specific input event.

### Ordering, recovery, and backpressure

- Preserve strict per-session ordering of frames and inputs.
- ANSI frames may be incremental: NEVER arbitrarily drop intermediate frames.
- Check whether `seq` is contiguous per stream before treating gaps as missing frames.
- On corruption or baseline loss, stop input, discard state, and open a fresh observer.
- Never replay input from an earlier connection: it could approve or duplicate actions.
- Apply frame and queue limits below the transport limit.
- Flux Go accepts packets up to 16 MiB; check Kotlin and Swift limits too.
- `Link.Send` serializes writes and may close the link when its queue grows too large.
- Use a bounded stream queue; do not create a goroutine for each frame.
- If the consumer cannot keep up, close that stream before saturating the entire Flux link.
- Measure first; add an existing payload transport only if the results require it.
- Initial test policy: 1 MiB per record and a 4 MiB queue; adjust using fixtures.
- Never truncate an ANSI frame: reject the entire frame and show a recoverable error.

### Phase 2 status (2026-10-04)

Implemented in `internal/core/herdr_terminal.go` and the dispatch of
`handleHerdr`, with `pane.get` and `pane.layout` helpers in
`internal/herdr/`. The messages are the contract of the plan:
`terminal_open`, `terminal_opened`, `terminal_frame`, `terminal_scroll`,
`terminal_mouse`, `terminal_release`, and `terminal_closed`.

- One stream per device, and one controller per pane. Other devices may
  observe the same pane while one of them controls it.
- An open needs `herdr` and a paired device. Control additionally needs
  `herdr_control`, and a pane without an agent also needs
  `herdr_terminals`.
- The stream is bound to the device, the link, and the pane. A message
  with another session, another connection, or an unknown session is
  ignored and logged. The terminal is pinned with `pane.get` before the
  bridge opens.
- The daemon fixes `source: wheel` and `lines: 1` for every gesture, so
  a phone cannot turn a scroll into another key.
- The frames of one stream go out from one goroutine in order, and
  `terminal_opened` goes before the first frame and `terminal_closed`
  after the last one. The phone always gets the frames before the end.
- While a stream is open on a pane, the history reads of every device
  return the cached history: herdr scrolls the terminal to collect the
  history, which would move the live stream and the desktop.
- The streams close when the agent leaves the pane, the pane closes, the
  herdr server stops, the link drops, the device is unpaired, or
  `herdr`/`herdr_control` turns off.
- The state announces the `bridge` capabilities when the installed herdr
  has the CLI bridge (0.9.3 and newer). An older herdr gives no caps and
  no terminal button.

Checks: `go test -race ./internal/herdr ./internal/core ./internal/proto
./internal/lan`, `go vet ./...`, and `go test -race ./...` all pass. The
9 tests in `internal/core/herdr_terminal_test.go` use a fake bridge
script and cover frames, permissions, the input policy, stale sessions,
history blocking, pruning, link loss, and the capabilities.

Not part of Phase 2, as the plan says: `input_seq` is not in the
messages. The Flux link is ordered and reliable, and a frame is not an
acknowledgement of an input event, so per-event numbers would add state
without a use.

The macOS and iOS clients ignore the new kinds, which are additive. The
Swift checks of the protocol run on a Mac or in CI and still need a run
before merge.

## 8. Phase 3: ANSI observation on Android

### Select a component rather than building another partial parser

There is currently no terminal dependency in `android/app/build.gradle.kts`.
Run a short spike with a maintained ANSI-emulation component compatible with Android.
Evaluate a native terminal library; consider WebView plus a JS terminal only as an alternative.
Compare integration effort, APK size, maintenance, accessibility, and fixture rendering.
Review dependency licensing: Flux has no selected license; do not choose one on its behalf.
If a library requires a subprocess or local PTY, verify that it accepts remote bytes.

Minimum features to validate with real fixtures:

- Cursor operations, erasure, insertion, scroll regions, and alternate screen.
- ANSI/truecolor, styles, Unicode, and double-width cells.
- UTF-8 and escape sequences split across frame boundaries.
- Consistent dimension changes and initial baseline reset.
- No automatic link opening or execution of unsafe OSC sequences.

Do NOT forward emulator-generated terminal-query responses without filtering.
Herdr already emulates the application: avoid duplicate replies, OSC clipboard, or input injection.
Do not feed frames through `TermText.kt`, `cleanANSI`, or reflow: they lose state and coordinates.

### Presentation

- Retain the real cell grid with local scaling, zoom, and pan.
- Phone rotation or opening the IME must not resize the PTY.
- Do not arbitrarily invert colors; respect contrast and the actual terminal theme.
- In observe mode, all scrolling/panning is local and never transmitted as input.
- Show read-only and connecting/connected/disconnected indicators.
- Keep copy and selection local; do not turn a long press into a remote click.
- Keep agent notifications and lists on their existing path.
- Keep emulator state outside expensive whole-application recomposition on every frame.
- Allow returning to Read without losing reply drafts.

Exit gate: stable fixtures in light/dark themes, portrait/landscape, and with the IME open.

### Phase 3 status (2026-10-04)

The terminal view is `xterm.js 5.3.0` (MIT, with its license in the APK)
inside a local WebView page. The page is `android/app/src/main/assets/terminal/`
and loads nothing from the network. This follows the decision to use xterm.js
and a WebView instead of an in-house renderer: the frames are Herdr's own
rendering dialect, but Unicode, styles, and incremental updates are still a
terminal's job, and a maintained emulator handles them once.

- `ui/HerdrTerminal.kt` hosts the WebView and a JS bridge. The stream events
  arrive in order: `Opened` resets the terminal to the grid of the pane,
  `Frame` writes its ANSI bytes, and a frame with a new size resets first.
  A view that leaves the screen releases the stream; a rotation opens it
  again after the new page is ready, so no frames are replayed or lost.
- The page disables stdin, never answers terminal queries, and opens no
  links. The WebView cannot load the network and does not cache the page,
  so the terminal content stays inside the app.
- The grid keeps the size that the pane has on the computer. The page
  shrinks the font until the whole grid fits the view (the WebView reports
  its real CSS size: its layout viewport is wider than its window), and
  pinch zoom and drag pan over it.
- The agent screen now has a **Read / Terminal** choice. Terminal is
  read-only in this phase; the reply controls and the reading view stay as
  they were. The follow-up replaces this choice on Android with a
  **Terminal / Changes** pair and keeps Changes; iOS keeps the reader.
- Debug builds accept `flux.debug.terminal` (an ANSI sample) and
  `flux.debug.terminal_grid` ("120x40") next to `flux.debug.output`, so
  screenshots need no pairing.

Checks: the JVM tests (including `HerdrTerminalTest` for the wire shapes),
`lintDebug`, the debug build, and the release build all pass.

Emulator evidence, with a real OpenCode screen captured through the bridge:

- `/tmp/opencode/flux-terminal-dark.png`: the whole screen of OpenCode at
  120x40 in the dark theme, with its logo, prompt, model line, and status
  line. The colors of the terminal are the colors of the program.
- `/tmp/opencode/flux-terminal-light.png`: the same in the light theme. The
  app chrome turns light and the terminal keeps its own colors.

Not part of Phase 3, as the plan says: gestures, control mode, and resize.
The IME never opens here because the view is read-only and not focusable.

## 9. Phase 4: explicit control and remote scrolling

### State machine

```text
Read → Observing → Requesting control → Controlling
                        ↓ error             ↓ release / lock / failure
                     Observing ←──────── Observing or Disconnected
```

Observe cannot upgrade on the same CLI connection: open a new control subprocess.
Cancel stale opens; release a session if its response arrives after leaving the screen.
Do not allow input until a valid open response and usable baseline have arrived.
When releasing control, close the controller before opening replacement observation.
Never perform background takeover or automatically reacquire control after reconnecting.

### Gestures and coordinates

- One finger while Controlling: remote vertical wheel input.
- Two fingers: local pan/zoom, without wheel events or clicks.
- Enable remote taps in a later stage and distinguish them from drag/long press.
- Transform pixels using grid origin, padding, scale, and local viewport offset.
- `column = floor(x_terminal / cell_width)`; `row = floor(y_terminal / cell_height)`.
- Coordinates are zero-based; reject margins and cells outside current dimensions.
- Keep the gesture location in the area touched by the user, not always at `(0, 0)`.
- Accumulate fractional movement and emit steps after a calibrated threshold.
- Cancel gestures when dimensions or session change; never reinterpret old coordinates.
- Start with at most 30 events/s and a burst of 10, with bounded queues and sensitivity tests.
- Initially disable remote inertia to avoid scrolling after the finger is lifted.
- Move content only when real frames arrive, not through optimistic local scrolling.
- Clearly indicate that this gesture also changes the desktop conversation position.

### Phase 4 status (2026-10-04)

The terminal screen now has explicit control, and the gestures follow the
contract above. The phone asks for control with a **Control** button
behind the existing phone lock (`ReplyLock`, valid five minutes), and
**Stop** closes the controller before the phone watches again. The
follow-up changes this flow: entering the terminal acquires control
automatically behind the same local authentication, without a separate
button.

- The daemon changes the mode of a stream by replacing its bridge: one
  CLI stream cannot change its mode, so a `terminal_open` in another
  mode closes the old bridge first, waits until it let go of the
  terminal, and opens a new one. The phone sees the end of the old
  session and a fresh `terminal_opened`, and input only reaches the new
  session. There is no takeover and no reacquisition after a reconnect.
- One finger while Controlling sends one wheel step per `max(cell height,
  14 px)` of movement, at the cell where the finger landed. The steps
  leave at most 30 per second with a burst of 10, nothing is queued
  behind a spent budget, and the steps stop when the finger lifts: there
  is no remote inertia. A drag that begins outside the grid sends
  nothing, and a change of the grid ends the gesture at once.
- Two fingers zoom and pan locally and send nothing. The zoom changes
  the font of the page, so the grid keeps its real cells and the text
  stays sharp at every level, and it keeps the cell under the pinch
  where it is. In observe mode a one-finger drag pans the same view.
- The coordinates come from the drawn grid: the page reports the size
  and the origin of its xterm screen, and the touches of the page map to
  zero-based cells of it. The margins beside the grid take no input.
- No input goes out before `terminal_opened` and a full frame: only a
  full frame is a baseline to read the screen against.
- When the unlock ends or the app goes to the back, the phone goes back
  to watching and sends no more input. Leaving the screen releases the
  stream, which also fixes a Phase 3 gap: the stream used to outlive the
  screen.

Checks: `go test -race ./...` with the new `TestHerdrTerminalModeSwitch`,
and the JVM tests with the new `HerdrGesturesTest` for the cells, the
threshold, the budget, the pinch, and the margins, plus `lintDebug` and
the debug and release builds.

Emulator evidence, with a real OpenCode screen captured through the
bridge and the state row of the new control:

- `/tmp/opencode/flux-terminal-control.png`: the terminal of the pane
  with "Watching" and its **Control** button in the dark theme.
- `/tmp/opencode/flux-terminal-control-light.png`: the same in the light
  theme. The app chrome turns light and the terminal keeps the colors of
  the program.

Not part of Phase 4, as the plan says: remote taps and clicks, raw
typing and the IME, and mobile resize. The phone keeps the size that the
pane has on the computer; herdr gives the controller a size lock at that
size, so a phone-driven resize would also resize the computer and needs
its own design first. The follow-up takes that design as its priority 1:
phone-sized PTY geometry while controlling, with verified recovery of the
desktop geometry on every release path. The lifecycle cases of the test
plan (rotation, backgrounding, IME) use the same mechanisms as the
touchpad screen and still take the manual tests of section 11.

### Existing input

Initially retain existing prompts and the keybar with their current validation.
Serialize actions that may compete with wheel/mouse input; do not mix unordered channels.
Do not expand the allowlist to Ctrl-C or arbitrary ANSI bytes as a side effect.
If migrating a key to the CLI, encode it in fluxd from a validated enum.
Raw typing and bidirectional IME integration require a later phase with their own review.

## 10. Security and coexistence

Daemon checks at opening and before each input:

- The device is paired and the current link is authenticated.
- `herdr = true`; any input additionally requires `herdr_control = true`.
- The destination is still the same terminal in the selected session.
- Close control when the target stops being an agent; do not automatically fall back to a shell.
- A terminal without an agent additionally requires `herdr_terminals = true`.
- In the MVP, close on agent disappearance even when terminals are enabled.
- Do not follow a moved pane or replaced terminal without a new explicit open.

Agent classification can race with agent exit: document this limitation.
A strong guarantee against writing into a shell would require atomic validation upstream.
Do not claim that a previous snapshot completely eliminates this risk.

Biometrics/screen lock uses the existing local unlock mechanism, valid for five minutes.
Android verifies it; fluxd does NOT cryptographically verify it. Do not imply otherwise.
On lock, backgrounding, or unlock expiry, stop gestures and release control.
Changing that guarantee requires a separate design and reading `docs/approve.md`.

### Historical reads: mandatory exclusion

`readAgentHistory` may scroll the agent to extract history.
Disabling polling only in the Android screen does not prevent this conflict:

1. Reserve interactive mode by terminal in the daemon.
2. Finish or cancel already-running mutating reads before acquiring control.
3. Prevent new historical reads from ANY device while control is active.
4. Return existing cached data or an explicit error, never hidden scroll/reset operations.
5. Do not block safe state/list reads or notifications.
6. After release, permit normal history retrieval without an automatic cleanup scroll.

Also review historical reads during observe: genuinely passive observation requires
screen-only/cache reads while streams exist, or explicit reporting of the conflict.

## 11. Test plan and acceptance criteria

### Automated

- Go: fake CLI wrapper, permissions, identity, rate limits, ordering, and cleanup.
- Go race detector: concurrent open/close/disconnect/reload and two-device scenarios.
- Contract: optional fields, ignorable new kinds, limits, and invalid base64.
- Kotlin: lifecycle, stale messages, baseline reset, and coordinate transformation.
- Kotlin: expired unlock, backgrounding, rotation, IME, and absence of input replay.
- Emulator: shell, OpenCode, diff, modal, color, and Unicode fixtures.
- Two-daemon E2E: stream competes with state, notifications, and transfers.
- Compatibility: Go, Kotlin, and Swift checks for protocol changes in `docs/development.md`.

### Manual tests in a disposable session

| Case | Required result |
| --- | --- |
| OpenCode with vertical tabs | PC layout unchanged; mobile terminal faithfully shows the pane |
| Scroll over conversation | Application scroll changes on PC and Android |
| Scroll with an open modal | Routing respected; no accidental approval |
| Shell or application without mouse | History or negotiated behavior; no stray click input |
| Neighboring pane and Herdr sidebar | Neither displayed nor targeted by input |
| Existing controller | Error without takeover |
| Slow network or connection loss | No replay; control released; Flux remains usable |
| Agent exits | Control stops; no intended continuation into a shell |
| Read from another phone | Does not scroll the agent during control |
| Rotation, IME, and zoom | No remote resize or incorrect coordinates |
| PC resize | Limitation observed and explained; recovery after release |
| Disable herdr/control or unpair | Prompt shutdown; no orphaned processes |

Measure gesture-to-screen latency, bytes/s, daemon/Android CPU and memory, and peak queue size.
Initial usability target: p95 below 250 ms on LAN during sustained scrolling.
This is a measurement target, not a Herdr or Tailscale guarantee.
If it fails, optimize using profiles; do not change transport based on intuition.

### Future verification commands

Run in the main repository with valid build permission; never build inside worktrees:

```sh
go test -race ./internal/herdr ./internal/core ./internal/proto ./internal/lan
make test vet
```

From `android/`:

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug --no-daemon
./gradlew :app:assembleDebug :app:assembleRelease --no-daemon
```

Verify Swift compatibility on Mac/CI; do not claim unavailable local coverage.
No build is needed to create or review this plan.

## 12. Isolated development, rollout, and reversibility

- Use a temporary daemon with isolated XDG paths and ports per `docs/development.md`.
- Use `/tmp/opencode/` for temporary fixtures where permitted.
- Start with the Android emulator; do not replace signed Flux on the Pixel.
- The current debug `applicationId` matches release: do not install over the official app.
- Do not stop or replace the user's `fluxd.service` to test the prototype.
- The current checkout and installed Flux 0.10.1 may use different ports: pair compatible
  test versions without changing the everyday installation.
- Deliver focused commits: wrapper, observe, scroll, mouse/controls, and documentation.
- Retain the existing reader for rollback and clients without stream support.
- Enable experimentally through capabilities; avoid permanent settings without a real need.
- Document verified behavior, including size locking and app-local biometric checks.

## 13. Questions for Herdr, only if the proof requires them

Do not block the first proof while waiting for a new API.

- Terminal control without acquiring resize ownership: a real limitation of the current bridge.
- Frame continuity, baseline, and recovery guarantees.
- Input atomically conditioned on agent identity, if that guarantee is required.
- Recommended external-client contract and evolution of the CLI JSONL bridge.
- Graphics support if it later becomes necessary for the user.

Existing discussions:

- https://github.com/herdrdev/herdr/discussions/3913
- https://github.com/herdrdev/herdr/discussions/4852
- https://github.com/herdrdev/herdr/discussions/4682

Provide versions, minimal reproductions, and results; do not submit unsolicited PRs.
Endpoint generation 1 is a later alternative, not an MVP requirement.

## 14. Delivery checklist

- [x] Phase 0 demonstrates real scrolling and coexistence in an isolated session.
- [ ] Initial geometry and size recovery are verified.
- [x] Terminal dependency selected after license and fixture review.
- [x] Observe works without input, resize, or scroll ownership.
- [x] Control is explicit, without automatic takeover or unrestricted raw input.
- [x] Wheel input targets only the selected pane with correct coordinates.
- [x] Historical reads are excluded for other devices too.
- [ ] Permission, lock, background, EOF, and connection-loss shutdowns are tested.
- [x] No replay, dropped incremental frames, or orphaned subprocesses.
- [ ] Go/Kotlin tests and Swift compatibility verified where applicable.
- [x] Installed PC and Pixel software unchanged without additional agreement.
- [ ] Actual limitations and measurements documented before proposing a merge.
