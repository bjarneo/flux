# Plan: an interactive Herdr agent terminal in Flux Android

Date: 2026-10-03. Status: proposal only; no implementation or live-session testing.

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

- [ ] Phase 0 demonstrates real scrolling and coexistence in an isolated session.
- [ ] Initial geometry and size recovery are verified.
- [ ] Terminal dependency selected after license and fixture review.
- [ ] Observe works without input, resize, or scroll ownership.
- [ ] Control is explicit, without automatic takeover or unrestricted raw input.
- [ ] Wheel input targets only the selected pane with correct coordinates.
- [ ] Historical reads are excluded for other devices too.
- [ ] Permission, lock, background, EOF, and connection-loss shutdowns are tested.
- [ ] No replay, dropped incremental frames, or orphaned subprocesses.
- [ ] Go/Kotlin tests and Swift compatibility verified where applicable.
- [ ] Installed PC and Pixel software unchanged without additional agreement.
- [ ] Actual limitations and measurements documented before proposing a merge.
