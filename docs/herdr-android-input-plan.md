# Android Herdr direct-input plan

[Documentation index](README.md) · [Current Herdr behavior](herdr.md)

Status: implemented. [The Herdr guide](herdr.md) describes the current behavior; this page keeps
the design, the wire contract, and the checks behind it.
Baseline: the live-terminal, in-place resize, and automatic reconnect work through `7a7e5ec`.
Inspect the checkout before starting; symbols below matter more than historical line numbers.

## 1. Final product decisions

The user revised the earlier suggestion-enabled direct-input proposal. Follow this version:

1. Android agent **Terminal** gets direct input, without phone-keyboard suggestions/autocorrection.
2. The current phone-side prompt editor is hidden on that live-terminal tab, **not deleted**.
   Keep its implementation and complete-prompt sending path for a later buffered-input mode.
3. There will eventually be two modes: direct terminal input and phone-side buffered composition.
   Only direct input is exposed here. The mode switch and its UX need a separate user spec.
4. Replace the two normal control rows with one:

   ```text
   Esc | Tab | ↑ | ↓ | microphone | keyboard
   ```

   These are six controls, not five. Do not remove a requested control to match an earlier count.
5. Remove the separate **Enter** and **Send** buttons from the direct-input UI.
   The phone keyboard's Return sends a real Enter to the remote program.
6. The keyboard button **shows** the Android keyboard. Pressing it again must not hide it.
   Android's own keyboard-dismiss affordance hides it. Do not map that dismissal to remote Esc.
7. Keep `phoneCols = 60`, authentication expiry, reconnect behavior, and existing terminal gestures.
8. This is Android-only UX. Do not change iOS, macOS, or shared Swift implementations.
   Any daemon protocol extension must remain compatible with their current operations.

### Why direct input matters

OpenCode, not Flux, owns the prompt and its interactive menus. Typing `@` should open the installed
OpenCode version's file/agent suggestions; typing `/` should open its command menu. Subsequent
characters filter those menus, and Tab, arrows, Esc, and Return go to the same remote program.
Do not recreate those menus, query a file index, or integrate the OpenCode SDK for this feature.

### Out of scope

- Phone-keyboard word suggestions/autocorrection and a phone/remote prompt synchronization engine.
- The future mode selector, configurable key layouts, three-dot settings, or modifier buttons.
- Ctrl/Alt shortcut support, arbitrary raw control-byte input, and a new clipboard-paste UI.
- A live-terminal conversion of the separate shell screen or the iOS reader.
- Changing approval security, extending the five-minute unlock, or automatic controller takeover.

## 2. Preserve the existing paths

`TiledAgentScreen` currently mounts `TerminalOutput` for live output and `ReplyControls` below it.
`ReplyControls` owns the local draft, editor expansion, dictation, choices, key bar, authentication,
review feedback prefix, **Send**, and **Send as answer**. It uses `HerdrSync.sendPrompt/sendKeys`.

Only change which controls mount on the live **Terminal** tab:

- Live Terminal: the new direct-input bar, with no local prompt field or legacy Enter/Send row.
- Changes: keep `ReplyControls`, its editor, review feedback, and existing behavior.
- Standalone shells: leave `HerdrScreens.kt` and `TerminalControls` unchanged.
- Older/non-streaming screens and Apple clients: do not change their protocols or reply semantics.

Do not delete `ReplyControls`, `FieldEditor`, `DictationBar`, `sendPrompt`, or their tests.
Do not mount the hidden editor and merely make it transparent: it could retain focus or send input.
Do not copy an old local draft into the remote prompt, or clear it as a direct-input side effect.
Keep the buffered path compiled and tested; do not build phase-two scaffolding just to retain it.

## 3. Findings from the current implementation

Read these files before editing. Android paths below are relative to
`android/app/src/main/java/org/omarchy/flux/`:

- `ui/AgentScreens.kt`: `TiledAgentScreen`, `PaneLayout`, `TerminalOutput`, and `ReplyControls`.
- `ui/HerdrTerminal.kt`: WebView factory, `TerminalFeeder`, baseline, touch routing, and teardown.
- `ui/ReplyLock.kt`: `valid()`, `remainingMs()`, and the process-local five-minute deadline.
- `core/Herdr.kt`: terminal lifecycle, sink, link-bound streams, and legacy prompt/key sending.
- `core/HerdrModel.kt`: bridge capabilities, wire builders, and `terminalControlReady`.
- `voice/Dictation.kt`, `voice/DictationUi.kt`: final-result callback and existing mic/panel UI.

Other important files:

- `android/app/src/main/assets/terminal/index.html`: xterm is output-only (`disableStdin: true`).
- `internal/herdr/terminal_session.go`: `Session.SendInput(text)` already exists.
- `internal/core/herdr.go`: capabilities and `handleHerdr` dispatch.
- `internal/core/herdr_terminal.go`: session ownership, permission checks, and bridge forwarding.
- `internal/core/herdr_terminal_test.go`: `terminalDaemon`, `bridgeEcho`, and ownership tests.
- `internal/herdr/terminal_session_test.go`: queued bridge commands and FIFO-order tests.
- `scripts/herdr-bridge-proof.py`: disposable TUI fixture and direct `terminal.input` commands.
- `docs/herdr.md`, `docs/security.md`, `docs/development.md`: current contract and required checks.

Confirmed gaps:

1. Herdr's controller already accepts `terminal.input`, and the Go adapter exposes `SendInput`.
   Flux currently exposes scroll, mouse, resize, release, and open, but no phone-to-session typing.
2. The current generic `input` kind targets standalone shells and needs `herdr_terminals`.
   It is not a substitute for agent live input under `herdr_control`.
3. `sendPrompt` trims/submits a complete prompt. Calling it per character is incorrect.
4. Legacy keys/prompts run asynchronous reply jobs. Mixing them with streamed text can reorder
   text, Tab, and Enter. All new direct text and keys must use the controller's ordered input path.
5. The WebView is deliberately not focusable, and native touch handling consumes its gestures.
6. `TerminalOutput` owns the authentication/lifecycle state; the footer is a sibling slot.
   Footer availability must come from that actual state, not merely `d.herdr.control`.
7. Stream frames are rendered cells, not a transparent copy of the program's original output.
   Do not assume xterm knows all remote terminal modes or connect its `onData` blindly.

## 4. First checkpoint: prove the controller input contract

Before exposing keyboard controls, extend the existing disposable bridge proof or its fixture.
Use a new disposable named session; never use the default session or a personal agent.

Prove `Session.SendInput`/Herdr controller input preserves:

- `@`, `/`, spaces, punctuation, leading/trailing whitespace, and UTF-8 text.
- Enter (`CR`), Tab, Escape, Backspace (`DEL`), and ANSI arrow sequences.
- The order `@`, filter text, Down, Tab, more text, Enter across consecutive commands.
- One action per key, with no automatic appended Enter, bracketed-paste wrapping, or double echo.
- Read-only observers cannot type, and the other terminal does not receive the input.

Use the fixture to verify received bytes, then test the actual installed OpenCode in the isolated
phone-test agent. Verify that CSI Up/Down work in its menus. Rendered frames do not necessarily
expose application-cursor mode; the phase-one mappings below are not a universal terminal emulator.
If the controller transforms text as paste or OpenCode needs a different key encoding, stop and
resolve that contract before implementing the UI. Do not silently fall back to legacy reply jobs.
Do not modify the separate Herdr repository without explicit user authorization.

## 5. Add a small, session-bound Flux wire extension

Use the existing `flux.herdr` packet type and add `kind: terminal_input`.
Add `input` to `state.bridge` only when this Flux daemon implements the new handler.
Android must require that capability before enabling the new bar; `control` alone is insufficient.

### Request shape

Exactly one of `text` or `key` is allowed, with a nonempty current session ID:

```json
{"kind":"terminal_input","session":"ts1","text":"@"}
{"kind":"terminal_input","session":"ts1","text":"src/main"}
{"kind":"terminal_input","session":"ts1","key":"down"}
{"kind":"terminal_input","session":"ts1","key":"enter"}
```

Plain text:

- Preserve exact text and UTF-8; do not trim, uppercase, add spaces, or append Enter.
- Bound each text event to 16 KiB UTF-8, matching the existing prompt size ceiling.
- Reject empty text, invalid Unicode, C0/C1 controls, DEL, and embedded line separators.
  Escape/control sequences must not be smuggled through a text event.
- Reject the whole invalid event, rather than silently modifying only part of it.
- Keyboard Return/Tab/Delete are named key events, not controls inside `text`.

Initial named-key allowlist and bridge encoding:

| Key | Controller text bytes |
| --- | --- |
| `enter` | `\r` |
| `tab` | `\t` |
| `esc` | `\u001b` |
| `backspace` | `\u007f` |
| `up` | `\u001b[A` |
| `down` | `\u001b[B` |
| `left` | `\u001b[D` |
| `right` | `\u001b[C` |

Left/Right support the standard cursor events, although they have no phase-one bar buttons.
Only `fluxd` encodes special keys; clients cannot provide arbitrary terminal escape strings.
Do not broaden the legacy agent-key allowlist or add Ctrl-C/Ctrl-D as part of this work.

### Daemon routing and validation

Implement the handler beside `herdrTerminalResize`:

1. Look up the stream with `herdrStreamLocked(dev, link, session)`.
2. Require paired device, current link, control mode, and a stream that has not begun stopping.
3. Recheck global/per-device access with `herdrTerminalAllowed`; respect `t.agent` and terminals.
4. Recheck known agent/pane state, so an already-known agent disappearance cannot accept input.
5. Validate the payload, map its key if applicable, and call that stream's `Session.SendInput`.
6. Keep packet order: no goroutine per character and no parallel legacy API call for special keys.

Follow existing locking discipline. The bridge enqueue is bounded/nonblocking; permission checks,
the stopping check, and acceptance must have a defined order relative to release/revocation.
Do not leave a check-then-enqueue gap that admits input after a recorded release.
Never hold the daemon mutex for process shutdown or network writes.

Keep the current limitation explicit: agent state is asynchronous, so checking it cannot make
agent-to-shell transitions atomic. Do not claim a stronger identity guarantee than Herdr provides.
There must be no intentional fallback into the replacement shell or another pane.

### Failures and ordering

No success acknowledgement or timeout job is needed per keystroke. A frame is not an input ACK.
Use an additive failure-only response for a valid owned stream:

```json
{"kind":"terminal_input_error","session":"ts1","code":"invalid_input",
 "error":"The terminal did not accept this input."}
```

Support fixed safe codes for invalid input and bridge input failure. Never include typed text,
dictated text, or raw bridge diagnostics in logs/errors. An unknown/foreign/stale session gets
no input and no information about somebody else's terminal.

On bridge queue/write failure, stop the affected controller and report the failure, rather than
dropping arbitrary keystrokes and continuing in a misleading state. Android keeps a visible
warning that some input may not have arrived; stream recovery may use the existing reconnect loop.
It must **never** resend the failed text or replay anything from the old session.

Android drops failure events for old session IDs. Do not put direct-input events in `herdrReply`,
run `reply()` per character, or make failures trigger the old **Send as answer** UI.
Preserve FIFO through the existing link writer and `Session` input queue; add no persistent outbox.

### Compatibility behavior

- Old apps keep using the unchanged `prompt`, `keys`, `input`, and read/diff operations.
- New Android with an old daemon may still render the terminal. The implemented fallback keeps the
  existing complete-prompt controls on the live tab until the computer advertises `input`, so the
  screen stays usable; direct mode never silently shows the hidden draft editor.
- Additional capability strings and kinds are additive. Verify Apple parsing tolerates them;
  do not implement this UI or new input sending in Swift.

The current shared Apple `HerdrWire.state` reads known fields from a JSON dictionary, and
`HerdrPlugin.receive` ignores unknown kinds. Use those unchanged paths for compatibility checks.
Direct input intentionally operates native agent dialogs as well as prompts; the legacy
complete-prompt `blocked` refusal remains on the buffered path, not on individual live keystrokes.

## 6. Android keyboard: native input, no prompt mirror

Keep xterm as the renderer with `disableStdin: true`. Do not enable an HTML text field, forward
all xterm `onData`, or forward terminal-generated device/status/query replies back to Herdr.
Do not add a terminal-emulator dependency or copy third-party terminal code.

Preferred implementation: create a small native-input subclass of the existing terminal WebView.
Override `onCheckIsTextEditor`, `onCreateInputConnection`, and supported key event handling.
Use Android's `BaseInputConnection`/`Editable` support for temporary composition, not a hidden
phone-side draft editor. A separate attached native input view is only a fallback if WebView
integration demonstrably interferes with gestures; keep one IME owner, not two.

### EditorInfo and focus

- Start with `TYPE_CLASS_TEXT | TYPE_TEXT_FLAG_NO_SUGGESTIONS`.
- Clear automatic correction/capitalization flags. Do not use a password disguise or `TYPE_NULL`
  merely to disable suggestions; retain Unicode and normal Android input-connection support.
- Request a Return-capable IME configuration without fullscreen/extracted text editing.
  Validate actual Return behavior on Gboard; do not rely only on the keyboard's visual label.
- Disable autofill for this input adapter; do not expose terminal contents as an editable document.
- Keep the existing consumed native touch stream. Taps/scrolls must not implicitly open the IME.
- A keyboard-button press requests native focus and shows the IME only when control is ready.
  Repeated presses refocus/show or do nothing; they never call hide or send a remote key.
- Do not reopen the keyboard because a frame arrived or the user dismissed it with Android.
  System Back/dismiss and system keys must remain system actions, not terminal Esc/Enter.
- A bar-key press must not steal the IME focus or hide the keyboard.

Suggestions are an IME hint, not control over every third-party keyboard. Verify the actual target
keyboard, document exceptions, and do not change the user's global keyboard settings automatically.

### InputConnection rules

Support the paths keyboards actually use; `onKeyDown` alone is insufficient:

| Android operation | Required effect |
| --- | --- |
| `commitText` with ordinary text | Send the committed text once, immediately |
| `setComposingText` / `setComposingRegion` | Keep only uncommitted composition locally |
| `finishComposingText` | Send any unsent composition once, then clear it |
| `deleteSurroundingText` / code-point variant | Edit unsent composition or send remote deletion |
| `sendKeyEvent` / native supported key | Route to the same named-key/text path |
| IME Return delivered as action or a lone newline | One named `enter`, not a complete prompt |
| Key-up | Do not duplicate the key-down action |
| Input connection teardown/session invalidation | Discard unsent composition; send nothing |

Do not keep the remote prompt in the `Editable`, and do not diff whole words against remote output.
Clear locally committed text without producing remote deletions. Late composition callbacks from
an old connection must be invalidated by a session/connection generation token.

Dead accents and non-Latin IMEs still compose without suggestions. Waiting for their committed
character is correct; ordinary Latin characters, especially `@` and `/`, must not wait for a word,
space, focus loss, or Send. If Gboard batches ordinary typing into words despite the flags, the
phone proof has failed: investigate the native configuration instead of accepting buffered input.

Handle Enter arriving via action, newline commit, or key event without producing two Enters.
Flush valid pending composition before a deliberate supported key when the connection is current.
Do not flush it during expiry, backgrounding, a link change, or disposal.

Backspace needs explicit tests: unsent composition deletion must not also delete remote text;
deletion with no local text must still reach the remote cursor; repeat and code-point deletion
must not split UTF-16 surrogates. Do not interpret an IME offset as a terminal column count.
Unsupported selection/replacement/reconversion must not erase guessed remote text. Keep the direct
mode limited; advanced word editing belongs to the later local composer.

Accept printable single-line text inserted by an IME, subject to the size limit. Treat a standalone
newline commit as Return. Reject mixed/multiline pasted text with a clear error in phase one;
do not turn a clipboard paste into a series of unintended prompt submissions. Do not add paste UI.

## 7. Share the real control gate with the footer

Keep authentication and reconnect ownership in `TerminalOutput`. Expose only a small shared handle
or callbacks to the footer: availability, show keyboard, send text, and send named key.
Do not introduce a second session opener, a general controller framework, or per-key authentication.

Every direct event, including mic completion, must check the current state at dispatch:

- Correct device and pane, non-demo, still paired/online, and direct-input capability present.
- Foreground lifecycle, existing authorization, and `ReplyLock.valid()` **right now**.
- Current open control session, not sending/released/stopped, with its own first baseline drawn.
- Matching session/connection generation, so stale IME or speech callbacks cannot type elsewhere.

UI-enabled state is not enough: the deadline or session may change before a queued callback runs.
Use current callbacks/state in the AndroidView update path, not captures fixed in its factory.
Keep the per-character send path small; do not publish the entire device state per successful key.

On expiry, leaving Terminal, closing the screen, backgrounding, unpairing, or losing the link:
invalidate the input connection, discard unsent composition, cancel direct dictation, and release
control as appropriate. Reconnect may reacquire only under the original unexpired unlock.
It must not reopen a buffered draft, replay keys, extend authorization, or take over another owner.

The five-minute gate remains an Android-local check, not a cryptographic assertion to `fluxd`.
The daemon still enforces pairing, link ownership, and access settings independently.

### Geometry and keyboard visibility

The screen already has `imePadding` and debounced in-place `terminal_resize`. Reuse them:

- Opening/dismissing the IME changes the remaining height and reports a new grid.
- Keep the 60-column density, selected font, and active stream ID.
- Do not reconnect or authenticate merely because keyboard visibility changed.
- In-place resize must not recreate the input connection or finish composition accidentally.
- Text/keys do not use cell coordinates; avoid turning a routine resize into a queued key replay.
  Keep pointer gestures gated by valid geometry and the current rendered baseline.
- After real session recovery, no input is accepted until the new session's baseline is drawn.

The normal footer stays one row above the IME. Use existing button styles and accessible labels.
Keep touch targets at least 48 dp. `KeyBar` currently wraps on narrow widths; for this new bar,
use one horizontally scrollable row if six targets do not fit, rather than shrinking or wrapping.
The current agent header, Terminal/Changes tabs, and Close action remain unchanged.

## 8. Microphone in direct mode

Reuse `Dictation`, mic availability/permissions, language selection, and the existing listening UI.
Do not reimplement recognition or stream audio to the computer.

1. Start only under the same ready/authenticated control gate as typing.
2. Record the device, pane, session ID, and input generation when dictation starts.
3. Keep partial and revised recognition results on the phone; never stream hypotheses remotely.
4. On deliberate completion, send the final transcript once as plain single-line terminal text.
   Normalize spoken line breaks to spaces; add no terminal controls or automatic Enter.
   Do not infer a remote cursor boundary or automatically prepend/append a space.
5. Recheck the gate and recorded identity at completion. Discard on expiry, disconnect,
   backgrounding, tab change, cancellation, or session replacement; never insert after recovery.
6. Let the user inspect the transcript in OpenCode and submit with the keyboard's Return.

Keep permission callbacks equally guarded: a permission grant after navigation must not start
recording on another pane. A stopped recognizer can still invoke completion, so invalidate the
generation before stopping/cancelling it during lifecycle changes.

The existing draft mode deliberately keeps words after backgrounding. Do not change the shared
recognizer's policy globally to implement direct-mode cancellation; guard this caller instead.
Use the existing temporary dictation panel for status/cancel/language controls, not a second
permanent prompt/Send row. The six-control row is the normal idle layout.

## 9. Implementation order and files

### A. Contract proof

- Extend the existing bridge fixture for printable/Unicode text, special keys, and mixed ordering.
- Validate native OpenCode `@` and `/` menus in the isolated test environment.
- Record any mode/encoding limitation before moving on.

### B. Daemon and Kotlin protocol

- Add the capability, input handler, validation, failure event, and ordered enqueue.
- Add Kotlin builders, capabilities, a small `HerdrSync` send entry point, and error parsing.
- Keep legacy `reply`, `sendPrompt`, and standalone `sendInput` behavior unchanged.
- Extend existing ownership, permission, stream-close, size-limit, and FIFO tests.

### C. Android native adapter and bar

- Implement the small InputConnection adapter, preferably in `ui/HerdrTerminal.kt` or a nearby
  `ui/HerdrTerminalInput.kt` if keeping it separate makes the view readable.
- Connect its gate to `TerminalOutput`; add the direct footer branch in `TiledAgentScreen`.
- Preserve the local editor branch for Changes and its eventual second mode.
- Add the six-control bar and idempotent keyboard-open action.
- Check keyboard show/dismiss, in-place resizing, composition, deletion, and Return on the phone.

### D. Direct dictation and regressions

- Wire final-only speech insertion with the same generation/gate checks.
- Reuse existing mic/panel components; avoid refactoring unrelated dictation clients.
- Exercise reconnect/expiry during typing and speech before declaring the feature ready.

### E. Documentation and rollout

- Update `docs/herdr.md` only after implementation: live input, current vs retained buffered editor,
  capabilities, input/error wire kinds, limits, keyboard dismissal, and Android-only scope.
- Update security wording where it describes key filtering or the local authentication gate.
- Commit settled source changes with Conventional Commits; keep local Flux Test config excluded.
- Install only the isolated debug app without uninstalling it, and request user validation.
- Do not push, tag, release, or change official services as part of this feature.

## 10. Verification matrix

### Automated checks

Use existing JVM tests under `android/app/src/test/java/org/omarchy/flux/`:

- `core/HerdrTerminalTest.kt`: input/error bodies, capability detection, stale-session errors,
  and gates for expired/background/not-drawn/observe/released sessions.
- Add a focused JVM test for the pure input mapping/composition state where needed.
  Real InputConnection behavior needs the phone or Android instrumentation; JVM mocks alone
  cannot prove Gboard behavior. Do not add a new test framework just for this feature.
- Existing prompt, review, dictation-text, and reply tests must continue passing.

Go tests should cover:

- Exact text and key mapping, payload exclusivity, Unicode, spaces, and UTF-8 size boundaries.
- Rejection of controls/escape injection, invalid keys, and multiline text.
- Foreign device/link, stale ID, observer, released/stopping session, revoked per-device access,
  disabled Herdr/control, and agent-to-shell disappearance already present in daemon state.
- `herdr_control` allows input to agents without granting standalone-terminal permissions.
- Rapid mixed text/key ordering through `bridgeEcho`, with no legacy API calls or added Enter.
- Queue overflow/write failure is visible; no retry or input leak into a newly opened stream.
- Additional capabilities do not change legacy prompt/input/read/diff responses.

Run from the main repository, not a worktree:

```sh
go test -race ./internal/core ./internal/herdr
go vet ./internal/core ./internal/herdr
python3 scripts/herdr-bridge-proof.py
```

From `android/`, with the SDK environment already configured:

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug \
  :app:assembleRelease --no-daemon --console=plain
```

Follow `docs/development.md` for full daemon/protocol regression checks, including two-daemon
integration and existing Swift compatibility tests on a supported host. Report checks that cannot
run locally rather than claiming cross-platform validation. No Apple feature implementation.

### Phone acceptance checks

Use the existing isolated Flux Test pairing and isolated Herdr agent, not personal sessions.

- No local prompt box, standalone Enter, or Send appears on the live Terminal tab.
- One row contains Esc, Tab, Up, Down, mic, and keyboard, with accessible touch targets.
- Keyboard appears only on request; repeated keyboard taps do not hide it.
- Android's dismiss arrow/Back hides only the IME; no remote Esc or prompt submission occurs.
- Gboard suggestions/autocorrection/capitalization are off in direct mode; Changes retains them.
- Ordinary typing is visible remotely per committed character; no wait for a complete word.
- `@` opens native suggestions; typing filters them, arrows navigate, Tab/Return select as OpenCode
  normally does, and Esc closes the menu. Return selects a menu item rather than forcing Send.
- `/` opens the native command menu and remains usable while the keyboard changes terminal height.
- Spaces, punctuation, accents, non-Latin characters, and emoji are neither lost nor duplicated.
- Backspace works with/without local composition, on long press, and on non-BMP text.
- A Return produces exactly one remote Enter and keeps the keyboard available for more input.
- Keyboard show/dismiss retains the stream, 60-column density, readable sizing, and prompt state.
- Terminal gestures work while the keyboard is open and after it is dismissed.
- Dictation inserts only its final text once, adds no Enter, and cancels safely on state changes.
- App switching before expiry recovers control without replay; after expiry input stays blocked.
- Link recovery cannot deliver old queued keys or speech callbacks into the new session.
- Changes still supports local editing, suggestions, dictation, review feedback, and complete Send.
- Standalone shells and iOS retain their existing behavior.

## 11. Safe test deployment

Do not put SDK paths, test device IDs, local daemon identity/data paths, or pairing secrets in Git.
Discover the current isolated environment instead of copying old PIDs or creating a fresh identity.

- Preserve the paired daemon's existing XDG directories and socket when rebuilding/restarting it.
- Keep the isolated daemon and test Herdr server in two separate background shells.
- Restart only the test daemon when its binary changes; leave the official daemon and Herdr alone.
- Do not remove the test agent's working directory or stop/delete the existing phone-test session.
- Preserve local `.dev`/Flux Test Gradle edits uncommitted; never reset or stage them accidentally.
- Install the latest APK by absolute path with `adb install -r`, never uninstall to update it.
- Verify the APK's application ID before installing. Update only `org.omarchy.flux.dev`.
- Force-stop/start only that test package after installing, and confirm pairing/online status.
- Keep runtime setup operations uncommitted and do not publish the branch without authorization.

## 12. Definition of done and future handoff

Phase one is done only when direct Android typing, native OpenCode menus, one-row controls,
final-only dictation, authentication, recovery, and the retained buffered code pass the checks.
Passing a Kotlin build alone does not prove per-character IME input or native menu interaction.

Phase two remains explicitly unimplemented: the user will specify how the local buffered composer
is reopened and how the two modes coexist, including any Termius-like settings/layout behavior.
Keep that conversation separate; do not guess another button, overflow menu, or mode preference.

## References

- [Herdr controller contract](https://herdr.dev/docs/persistence-remote/#direct-terminal-attach)
- [Android InputConnection][input-connection]
- [Android InputType](https://developer.android.com/reference/android/text/InputType)
- [Android EditorInfo](https://developer.android.com/reference/android/view/inputmethod/EditorInfo)

These establish the native APIs and controller transport. The actual installed keyboard/program
behavior still needs the contract and phone checks; no Termius implementation details are assumed.

[input-connection]: https://developer.android.com/reference/android/view/inputmethod/InputConnection
