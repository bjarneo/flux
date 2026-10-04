# Plan: phone-first Herdr terminal after the Pixel trial

Status: partly implemented. Priority 1 (PTY resize and desktop recovery) and Priority 3
(terminal theme fidelity) are done and validated on the Pixel. Priorities 2 and 4 remain
proposals. Each status section records what is verified and what is still open.

This plan records the user's observations from the real Pixel trial of
`feat/herdr-interactive-control`. It supersedes the desktop-size, separate-reader,
and optional-control UX decisions in `herdr-interactive-plan.md` for the next iteration.
The previous plan remains the implementation and verification history.

### Platform scope and preserved behavior

The interactive terminal and the replacement UX in this follow-up are Android-only.
The current implementation still retains Android's reader and the Changes/review feature;
the replacement described here has not yet been implemented.

iOS keeps its existing read/output experience and existing actions. Do not replace its
reader, add automatic control there, or delete shared read/diff operations it depends on.
The Go bridge and additive protocol are reusable infrastructure, not an implemented iOS
terminal client. No iOS interactive-terminal implementation is part of this follow-up.

Preserve compatibility with existing Apple clients. Historical reads during an active
terminal stream may still return cached output to avoid moving the controlled pane;
that shared safety rule is not a replacement of the iOS reader.

## 1. What the user observed

- The real connection works partially, but the experience is not the intended one.
- Separate **Read / Terminal** choices are unwanted. The terminal should be the reading
  and interaction surface, not an alternative to a phone-reflowed text reader.
- Control should be the normal behavior when entering that terminal, not an optional
  mode requiring a separate **Control** button on every visit.
- Desktop-size rendering shrunk to fit the phone is not enough. The application must
  redraw for a phone-sized terminal, as it does in the user's Termius experience.
- The temporary desktop layout degradation during phone control is acceptable to the user.
  Releasing phone control must return the desktop to its normal geometry.
- OpenCode's background appears black on the phone, while other colors seem correct.
  Termius shows the background the user expects from the PC. The cause is not confirmed.
- Remote gesture scrolling works, but the user describes the current experience as very poor:
  large or repeated finger movements produce only small, incremental scroll advances.
  It feels insufficiently sensitive and requires too much effort to navigate a conversation.
- Termius is the user's sensitivity reference: a modest finger movement scrolls responsively
  and covers a useful amount of content. Flux should deliver a comparable experience.
- Gesture improvement remains lower priority than geometry and the terminal-first flow,
  but it is a substantial usability requirement, not a minor polish item.

These are user-reported observations, not additional automated verification results.

## 2. Intended experience

1. Open the selected agent pane from Flux Android, directly on the Terminal tab.
2. Automatically invoke the existing local authentication gate, using the phone's configured
   supported authentication method (biometric or device credential), not fingerprint only.
   Preserve its existing valid-unlock policy; do not silently bypass it or change its lifetime.
3. Automatically request control of that terminal, without takeover of another controller.
4. Give the PTY dimensions appropriate to the phone's available terminal area.
5. Display the application's real redraw, with readable text and matching colors.
6. On exit, backgrounding, lock, unlock expiry, or link loss, release control and recover
   desktop geometry. Returning to the screen requires a new safe control session.

Automatic control means the default flow, not bypassing authentication or permissions.
An existing controller must produce a clear refusal, not an automatic takeover.
Show a persistent, concise indication that the phone controls the pane and temporarily
changes its size on the PC. Explain this consequence before the first acquisition.
The user's acceptance of that consequence removes the need for a separate optional
"Adapt to phone" mode in the normal flow.

## 3. Priority 1: real PTY resize and desktop recovery

Do not confuse local font scaling with a PTY resize. The agent must receive the new
terminal dimensions and redraw its own interface; Flux must not hide or rebuild its tabs.

### Verify the geometry contract first

- Use a disposable Herdr session to measure the actual PTY size before, during, and after
  control. `pane.layout` rectangles are not proof of actual PTY geometry.
- Reproduce the user's Termius behavior and establish whether it attaches a whole Herdr
  client or one pane terminal. Those paths may have different resize and recovery semantics.
- Verify release, EOF, controller failure, and desktop window resizing during ownership.
- Determine whether Herdr restores the current desktop geometry on release automatically.
  Do not promise restoration based only on the previously confirmed size lock.

### Minimal implementation path

- Calculate columns and rows from the actual available phone area and measured cell metrics
  at a readable font size. Do not shrink a desktop grid to tiny text by default.
- Extend the additive terminal contract with validated control dimensions and, if needed,
  a bounded resize message routed through the existing ordered bridge input queue.
- Use the existing `Session.Resize` wrapper rather than a new transport or raw CLI JSON.
- Handle orientation and available-area changes deliberately; debounce resize requests and
  cancel active gestures when geometry changes. Define keyboard behavior before enabling IME.
- Keep resize authority exclusive to the authenticated device's active controller.
- Reuse release and process cleanup. If Herdr does not recover the desktop automatically,
  design recovery using verified authoritative geometry, not a guessed layout rectangle.
- Prefer the current desktop geometry on recovery if its window changed during phone control,
  rather than blindly restoring a stale pre-connection size.

Acceptance: the phone gets an application redraw suited to portrait use, and the PC returns
to its normal geometry after every tested release/failure path. Neither neighboring panes
nor personal Herdr settings are changed to fake that result.

### Priority 1 status (2026-10-04)

Implemented and verified against Herdr 0.9.3.

- The geometry contract was measured in a disposable session with the desktop TUI
  attached: control at 40x80 resized the pane to 40x80; `terminal.release` and a
  killed controller (EOF) both gave the desktop size back; a desktop window resize
  during control was blocked, and the release restored the *new* desktop geometry,
  not the stale one. Without a desktop client attached, Herdr keeps the last size,
  and the desktop reclaims it when a client attaches again.
- The phone measures its own cell and asks the computer for the grid that fills the
  view at a readable font (~80 columns on the Pixel). A control stream opens at that
  size, so the program redraws for the phone instead of a shrunk desktop grid. The
  grid is bounded like the frames.
- The phone was validated on the Pixel: taking control resizes the pane, the content
  fills the screen, and the user confirmed it as the expected behavior. This is the
  outcome the user requested first; the remaining test-plan and lifecycle items of
  section 7 still apply to it.

## 4. Priority 2: one terminal surface, control by default

- In Android, replace the existing **Output** tab with **Terminal**, beside **Changes**.
  The intended top-level choices are **Terminal / Changes**, not two nested selectors.
- Remove the additional **Read / Terminal** selector. Keep **Changes**, its diff renderer,
  file-path filtering, and validated review/reply actions; do not fold them into ANSI output.
- Default to **Terminal** when opening a supported agent from the phone. Opening the agent
  initiates authentication and control acquisition automatically, without a separate
  **Control** button or another choice of view.
- If authentication is cancelled or fails, do not acquire control, resize the PTY, or send
  input. Show the result and allow an explicit retry; do not repeatedly trigger system prompts.
- Open a control stream after local authentication and wait for a usable rendered baseline
  before accepting gestures or existing validated input controls.
- Switching to **Changes** releases the terminal controller and recovers desktop geometry.
  Returning to **Terminal** uses the same authenticated acquisition flow. Verify that diff
  retrieval does not depend on the old Output tab or conflict with terminal history exclusion.
- Keep local zoom/pan for inspecting content, but make mobile PTY geometry the default.
- Preserve reply drafts and existing input validation; removing the reader does not authorize
  arbitrary ANSI input, Ctrl-C, or unrestricted keyboard passthrough.
- Release pending acquisitions as well as active controllers if the screen leaves or locks.
  A late unlock callback or open response must not acquire control for a closed screen.
- Check authorization at each input, not only when the stream opens.
- Decide the visible behavior for unavailable control, old daemons, and contention. Do not
  silently restore the two-choice UX or claim observation is control.
- Limit any legacy reader fallback to compatibility needs; do not delete code used by Apple
  clients or other Android screens as a side effect of this UI change.

Acceptance: opening a supported Android agent leads to the authenticated, phone-sized terminal
without selecting a second view or pressing a separate Control button. The visible tabs are
**Terminal / Changes**, Changes still works, and iOS retains its existing read/output flow.

## 5. Priority 3: background and terminal theme fidelity

Investigate before choosing a fix:

- Compare the same application's background in the PC, Termius, and Flux.
- Determine whether OpenCode paints explicit background SGR values or uses the terminal's
  default background through reset/default-color sequences.
- Inspect whether Herdr's rendered frames retain explicit cell backgrounds or omit them.
- Check xterm's default background and palette: the host page currently defaults to black.
- Distinguish the terminal's default colors from Flux's UI theme. They need not be identical.
- If default-color metadata is needed, identify an authoritative source and transport it
  explicitly; do not infer the background from arbitrary frame text or invert colors.
- Keep OSC clipboard operations, automatic link opening, and terminal-query replies disabled.

Acceptance: explicit and default backgrounds match the reference in dark and light terminal
themes, including blank cells and erased regions. The app chrome may keep its own theme.

### Priority 3 status (2026-10-04)

Implemented and confirmed by the user on the Pixel: the terminal background matches the
computer theme.

- A full frame from the pane was captured through the bridge and rendered cell by cell:
  nearly every cell carries an explicit RGB background (for example `48;2;12;12;19`), so
  the program's own colors do arrive. Few cells use the default background (`49`).
- The page created xterm with a hardcoded `background: "#000000"` and never applied the
  computer's theme to it, so default and erased areas drew black instead of the terminal
  theme. The theme packet already reaches the phone; only the terminal did not use it.
- Fix: the phone builds an xterm theme from the Omarchy theme of the computer (background,
  foreground, cursor, selection, and the 16 ANSI colors), applies it before the first frame
  and on each theme change, and paints the page and stage with the same background. Explicit
  RGB colors of a frame still win, and no color is inferred from frame text.
- The first attempt crashed when the terminal opened: the theme JSON was quoted with
  `android.util.JsonWriter`, which refuses a bare string root (`IllegalStateException`).
  Quoting with `kotlinx.serialization.json.JsonPrimitive` fixed it; the user then confirmed
  the result as perfect.
- The black was not treated as a confirmed cause before; the hardcoded value in the page is
  the concrete finding. If a program paints an explicit black, that is preserved.

The light-theme check and a theme change while the terminal is open still deserve a pass.


## 6. Priority 4: gesture refinement

### Reported problem and expected result

The user confirms that control gestures already cause remote scrolling. The problem is how
little content moves relative to finger travel: repeated, exaggerated swipes are needed and
the conversation advances a small amount at a time. The result feels laborious rather than
like native terminal navigation. This observation does not establish whether the main cause
is the movement threshold, event budget, gesture delivery, or OpenCode's wheel handling.

Use Termius as the practical reference, on the same phone and conversation where possible.
A normal short swipe should produce immediately perceptible, useful scrolling; a longer or
faster swipe should cover substantially more content without requiring repeated exaggerated
movements. Keep precision for small adjustments, rather than simply maximizing scroll speed.

### Investigation and tuning

- Measure finger travel, gesture duration, emitted wheel steps, rate-limited steps, and actual
  application scroll movement. Distinguish low sensitivity from slow frame delivery or latency.
- Review the current threshold of `max(cell height, 14 CSS px)` and its interaction with font
  zoom, cell geometry, and phone density. A local font change should not unpredictably change
  the effort needed to scroll the remote conversation.
- Review the 30 events/second budget and burst of 10 against normal short and fast swipes.
  Keep bounded input, but do not assume the original limits deliver adequate responsiveness.
- Tune the movement-to-wheel mapping against real OpenCode behavior. Herdr's mouse-report
  route sends one event per command: increasing `lines` alone does not multiply wheel events.
- Check gesture event delivery and cancellation for lost movement or premature termination.
- Start with a well-calibrated default rather than requiring the user to fix an unusable
  default through settings. Add a sensitivity adjustment only if real device/app differences
  demonstrate a need for it.
- Do not add post-lift inertia without an explicit decision and safety review; responsive
  scrolling during a swipe must not depend on continuing input after the user stops.

Tune after geometry is corrected. Do not optimize against the old tiny desktop-size grid
and assume those settings suit the new mobile layout.

Retain the safety rules: correct cells after zoom/pan, margins rejected, no input replay,
bounded wheel events, no universal arrow-key substitution, and no accidental remote taps
or approvals. Revisit one-finger scrolling and two-finger local navigation with the user.

Acceptance: on the Pixel, ordinary short, long, and fast swipes navigate a real OpenCode
conversation comfortably, without excessive finger travel or repeated swipes for tiny advances.
Compare directly with Termius and obtain the user's validation of sensitivity; static frames
and gesture unit tests alone cannot establish that the experience is good.

## 7. Verification and boundaries

- Start with a disposable Herdr session and isolated daemon; keep the installed PC daemon intact.
- Continue Pixel testing with the separate `org.omarchy.flux.dev` app, not the official app.
- Validate real OpenCode conversation scrolling on phone and PC, not only static sample frames.
- Test unlock expiry, lock/background during acquisition, rotation, link loss, agent exit,
  competing controllers, and repeated connect/disconnect cycles.
- Test Go protocol validation, permission revocation, resize ordering, and process cleanup;
  Kotlin lifecycle, geometry, stale callbacks, and baseline handling; Android debug/release
  builds and lint. Run Swift compatibility checks on Mac/CI for additive protocol changes.
- Record real results and remaining limitations before marking this follow-up complete.
- Verify the Android **Terminal / Changes** flow, authentication cancellation, diff retrieval,
  controller release on tab changes, and compatibility with Apple's unchanged reader.

No implementation, release, additional installation, chargeable agent prompt, or changes to
personal sessions are authorized solely by this planning document.
