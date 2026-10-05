# Android live terminal: possible fine-tuning

The live pane already supports direct typing, native keyboard dictation, text paste, and
image attachments, tested with OpenCode. These are possible refinements, not requirements
to turn Flux into a general-purpose mobile terminal manager.

## 1. Agent-focused key-row templates

Use Termius as inspiration, but prefer a middle ground: keep one row containing only useful
agent controls that an ordinary phone keyboard cannot provide. Avoid copying its full
terminal-management UI.

The current row has four auxiliary keys and a keyboard button. Possible templates would
replace those four keys; allowing five or six auxiliary keys needs a touch-target and space
review. Candidates include interrupt, newline without submitting, cursor navigation, and
word deletion, depending on the agent's bindings.

One proposed entry point: while the keyboard is visible, temporarily replace its now-redundant
open button with a layout button. This would open a compact template picker/editor. When the
keyboard is hidden, restore the keyboard button. Multiple saved rows could be selected there,
but only one row would appear in the terminal view.

Before implementation, decide the essential keys, default templates, maximum row size,
selection/editing UI, persistence, and how much customization is actually needed. New keys
must retain session ownership and authentication checks, without arbitrary escape injection.

## 2. Precise text-selection gesture

Clipboard transfer back to the phone already exists. In the user's OpenCode trial, double
click copies a word and triple click copies a line; the copied content reaches the phone
through Flux clipboard sync. OpenCode can copy on selection, so another Copy button may not
be necessary.

The missing refinement is a deliberate gesture for selecting an exact range of terminal
text. Define it without breaking the working one-finger scroll, ordinary clicks, or two-finger
zoom/pan. Prefer the application's selection behavior where available; investigate whether
it needs remote pointer dragging or a local terminal-selection mode. Do not assume all agents
copy on selection or handle dragging identically.

## 3. Validate other agents

OpenCode is the only agent used for end-to-end validation so far. Test other Herdr-supported
agents before claiming equivalent behavior: typing, Return, menus, dictation, multiline paste,
image attachments, selection/copy, and interruption. Commands, shortcuts, bracketed-paste
handling, and image clipboard support vary by application.

## Keep what already works

The user is comfortable navigating earlier messages with the current remote scroll gesture
and tapping the application's Jump to latest control. No separate history browser or new
conversation-navigation feature is requested.

Before expanding input controls, review image-transfer cancellation, temporary URI permissions,
decode/conversion memory limits, clipboard races, and disconnect/authentication-expiry behavior.
Keep these checks separate from adding more UI.
