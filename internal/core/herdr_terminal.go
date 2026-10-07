package core

// Terminal sessions give one phone the live terminal of one herdr pane.
// fluxd runs the herdr terminal-session bridge as its own subprocess and
// forwards its frames over the Flux link. The phone never touches a herdr
// socket and never sees another pane or the herdr UI.
//
// One device streams one pane at a time, and one device controls a
// terminal at a time. Other devices can observe the same pane. A stream
// needs herdr, and a control stream also needs herdr_control. A pane
// without an agent also needs herdr_terminals, in each mode, as a read
// of that pane does. Control resizes the terminal for the phone, and
// herdr gives the desktop its size back when the controller releases it.
//
// While a phone controls a pane, fluxd does not read the history of that
// pane for any device. herdr scrolls the terminal to collect the history,
// which would move the terminal of the phone and the desktop screen.
// Such reads use the last cached history.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/png"
	"strings"
	"time"
	"unicode/utf8"

	"flux/internal/desktop"
	"flux/internal/herdr"
	"flux/internal/lan"
	"flux/internal/proto"
)

// The close codes that a phone gets in terminal_closed.
const (
	herdrTermReleased  = "released"    // the phone released the terminal
	herdrTermBridge    = "bridge"      // the bridge stream ended
	herdrTermAgentGone = "agent_ended" // the agent left the pane
	herdrTermPaneGone  = "pane_closed" // the pane closed or moved
	herdrTermStopped   = "stopped"     // permissions or the link changed
)

// herdrOpenTimeout limits the work for one terminal_open: the release of
// an earlier stream, the wait for reads, the herdr calls, and the attach.
// fluxd answers each terminal_open within 15 seconds, and the phone waits
// 20 seconds. Tests make it shorter.
var herdrOpenTimeout = 14 * time.Second

// herdrAttachTime is the part of herdrOpenTimeout that the wait for reads
// keeps for the layout call and the attach.
const herdrAttachTime = 6 * time.Second

// The errors of terminal_opened that do not name a pane or a permission.
// errHerdrOpenBusy, errHerdrOpenLate, and errHerdrStreams are transient,
// so their answer also has "retry": true. errHerdrStreams shows while the
// release of the last stream of the device is still in progress.
const (
	errHerdrOpenBusy = "fluxd already opens a terminal for this device. Try again."
	errHerdrOpenLate = "fluxd could not open the terminal in time. Try again."
	errHerdrStreams  = "fluxd already streams a terminal to this device"
	errHerdrNoBridge = "The live terminal needs herdr " + herdr.MinBridgeVersion + " or newer on this computer."
)

// herdrOpenFailed returns the terminal_opened answer with an error. A
// transient error also gets "retry": true, so the phone can open again
// after a short wait and does not have to match the error text.
func herdrOpenFailed(pane, mode, err string) *proto.Packet {
	body := map[string]any{"kind": "terminal_opened", "pane": pane, "mode": mode, "error": err}
	if err == errHerdrOpenBusy || err == errHerdrOpenLate || err == errHerdrStreams {
		body["retry"] = true
	}
	return proto.New(proto.TypeFluxHerdr, body)
}

// herdrTerminal is one open terminal-session bridge for one phone.
type herdrTerminal struct {
	id      string
	dev     *Device
	link    *lan.Link
	pane    string
	agent   bool
	mode    string
	width   int
	height  int
	session *herdr.Session
	cancel  context.CancelFunc
	release json.Number
	stop    string

	// warned is true after fluxd logged a failed input event of the
	// stream. A gesture sends many events, so the next failures of the
	// stream do not go to the log. d.mu guards it.
	warned bool

	// typed counts the characters that the phone typed or pasted since its
	// last Enter, for the log line of that Enter. d.mu guards it.
	typed int

	// imaging is true while an image paste of the stream runs. d.mu guards
	// it.
	imaging bool

	// imageCancel stops the transfer of that image when the stream ends.
	// d.mu guards it.
	imageCancel context.CancelFunc

	// held keeps the events that came during an image paste, in order,
	// until the agent had time to attach the image. d.mu guards it.
	held []herdrTermEvent

	// overflowed is true after fluxd refused an event because held was
	// full. The phone gets one error for each image, not one for each
	// key. d.mu guards it.
	overflowed bool
}

// target names the pane of the stream for the log, in the words of the
// replies in herdr_control.go.
func (t *herdrTerminal) target() string {
	if t.agent {
		return "the herdr agent in " + t.pane
	}
	return "the herdr terminal " + t.pane
}

// herdrBinName is the herdr CLI that fluxd runs for terminal sessions.
func (d *Daemon) herdrBinName() string {
	if d.herdrBin != "" {
		return d.herdrBin
	}
	return "herdr"
}

// validTermSize reports whether a phone can ask for this terminal size.
// It is in cells, and bounded like the frames of the bridge.
func validTermSize(cols, rows int) bool {
	return cols >= 1 && rows >= 1 && cols <= 1000 && rows <= 1000
}

// startHerdrOpen reserves the one terminal_open that can run for the
// device at a time, before any herdr call. It returns false when an open
// of the device runs. Each open starts a herdr subprocess, so a flood of
// opens must not start more of them.
func (d *Daemon) startHerdrOpen(dev *Device) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.herdrJobs.opening[dev.ID] {
		return false
	}
	if d.herdrJobs.opening == nil {
		d.herdrJobs.opening = map[string]bool{}
	}
	d.herdrJobs.opening[dev.ID] = true
	return true
}

// endHerdrOpenLocked ends the reservation of startHerdrOpen. d.mu must
// be held.
func (d *Daemon) endHerdrOpenLocked(dev *Device) {
	delete(d.herdrJobs.opening, dev.ID)
}

// herdrTerminalOpen opens one terminal-session bridge for the phone. The
// answer is terminal_opened with the session ID, or with the error,
// within herdrOpenTimeout. A control stream can name the terminal size
// that it wants. herdr then draws the pane for the phone and gives the
// desktop its size back when the stream ends. Watching keeps the size of
// the pane, because its viewport would only show part of the desktop
// screen. The caller reserved the open with startHerdrOpen, and
// herdrTerminalOpen ends that reservation.
func (d *Daemon) herdrTerminalOpen(dev *Device, l *lan.Link, req json.Number, pane, mode string, cols, rows int) {
	deadline := time.Now().Add(herdrOpenTimeout)
	registered := false
	endOpen := func() {
		if registered {
			return
		}
		registered = true
		d.mu.Lock()
		d.endHerdrOpenLocked(dev)
		d.mu.Unlock()
	}
	// The reservation ends before the answer goes out. A new open that the
	// phone sends after the answer then does not find the old reservation.
	fail := func(err string) {
		endOpen()
		d.herdrSend(dev, l, withRequest(herdrOpenFailed(pane, mode, err), req))
	}
	defer endOpen()
	defer d.herdrRecover("terminal open", func() { fail("fluxd could not open the terminal of that pane") })

	width, height := 0, 0
	if mode == "control" && (cols > 0 || rows > 0) {
		if !validTermSize(cols, rows) {
			fail("fluxd does not accept that terminal size")
			return
		}
		width, height = cols, rows
	}
	// A mode change on the same pane replaces the bridge. One CLI stream
	// cannot change its mode, so control opens a new subprocess. The
	// check skips the stream that the open replaces.
	d.mu.Lock()
	old := d.herdrSwapLocked(dev, l, pane, mode)
	why := d.herdrTerminalErrorLocked(dev, pane, mode, old)
	d.mu.Unlock()
	if why != "" {
		fail(why)
		return
	}
	if old != nil {
		// The old bridge closes first, so the phone never sees two
		// streams of its pane, and the terminal is free again before the
		// new bridge attaches.
		d.stopHerdrTerminal(old, herdrTermReleased)
		select {
		case <-old.session.Exited():
		case <-time.After(time.Until(deadline)):
			fail(errHerdrOpenLate)
			return
		}
	}
	if mode == "control" {
		// Reserve the pane while the control stream attaches, so a read
		// that starts during the attach already serves the cache. The
		// wait then covers only the reads that began before, and no new
		// read can make herdr scroll the terminal under the stream.
		defer d.reserveHerdrStream(pane)()
		d.waitHerdrReads(pane, deadline.Add(-herdrAttachTime))
	}
	if width == 0 {
		lctx, lcancel := context.WithTimeout(d.ctx, min(herdrCallTimeout, time.Until(deadline)))
		layout, err := herdr.GetLayout(lctx, d.herdrPath, pane)
		lcancel()
		if err != nil {
			d.logf("%s: pane.layout of %s: %v", d.nameOf(dev), pane, err)
			fail("fluxd could not read the size of the pane")
			return
		}
		width, height = layout.Width, layout.Height
	}
	wait := time.Until(deadline)
	if wait <= 0 {
		fail(errHerdrOpenLate)
		return
	}
	ctx, cancel := context.WithCancel(d.ctx)
	session, err := herdr.OpenSession(ctx, herdr.SessionConfig{
		Path: d.herdrBinName(), Socket: d.herdrPath, Target: pane,
		Cols: width, Rows: height, Control: mode == "control",
		OpenTimeout: wait,
	})
	if err != nil {
		cancel()
		d.logf("%s: terminal session of %s: %v", d.nameOf(dev), pane, err)
		fail("fluxd could not open the terminal of that pane")
		return
	}
	t := &herdrTerminal{dev: dev, link: l, pane: pane, mode: mode,
		width: width, height: height, session: session, cancel: cancel}
	d.mu.Lock()
	// The state can change during the herdr calls above, so check again.
	if why := d.herdrTerminalErrorLocked(dev, pane, mode, nil); why != "" {
		d.mu.Unlock()
		// The release can take time, so it runs in the background.
		go func() {
			if err := session.Close(); err != nil {
				d.logf("%s: the terminal of %s did not open: %v", d.nameOf(dev), pane, err)
			}
			cancel()
		}()
		fail(why)
		return
	}
	if d.herdrStreams == nil {
		d.herdrStreams = map[string]*herdrTerminal{}
	}
	d.herdrStreamSeq++
	t.id = fmt.Sprintf("ts%d", d.herdrStreamSeq)
	t.agent = d.herdrAgentLocked(pane)
	d.herdrStreams[t.id] = t
	d.endHerdrOpenLocked(dev)
	registered = true
	d.mu.Unlock()

	if mode == "control" {
		d.logf("%s took control of %s at %dx%d", d.nameOf(dev), t.target(), t.width, t.height)
	} else {
		d.logf("%s watches %s at %dx%d", d.nameOf(dev), t.target(), t.width, t.height)
	}
	// The phone gets terminal_opened before the first frame.
	_ = l.Send(withRequest(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_opened", "pane": pane, "mode": mode, "session": t.id,
		"width": t.width, "height": t.height}), req))
	go d.runHerdrTerminal(t)
	// The loss of the link and a change of a permission end the stream
	// like a release of the phone. The bridge lets go of the terminal
	// first, and fluxd kills only a bridge that does not exit.
	d.watchSession(ctx, func() { d.stopHerdrTerminal(t, herdrTermStopped) }, dev, l,
		func() bool { return d.herdrTerminalAllowed(t) })
}

// herdrTerminalErrorLocked reports why the phone cannot open the stream.
// skip is a stream of the device that the open replaces, or nil. d.mu
// must be held.
func (d *Daemon) herdrTerminalErrorLocked(dev *Device, pane, mode string, skip *herdrTerminal) string {
	v := d.herdrViewForLocked(dev.ID)
	switch {
	case !v.Enabled:
		return errHerdrDisabled
	case !dev.Paired:
		return "this device is not paired"
	case mode != "observe" && mode != "control":
		return "fluxd does not know that terminal mode"
	case !d.herdrBridge:
		return errHerdrNoBridge
	// A pane without an agent needs herdr_terminals in each mode. A pane
	// that the device cannot see gets the same answer as an unknown pane,
	// so a device cannot find the IDs of hidden panes.
	case !d.herdrAgentLocked(pane) && !(v.Terminals && d.herdrTerminalLocked(pane)):
		return "fluxd does not know that pane"
	case mode == "control" && !v.Control:
		return "replies are off on this computer"
	}
	for _, t := range d.herdrStreams {
		switch {
		case t == skip:
		case t.dev == dev:
			return errHerdrStreams
		case t.pane == pane && t.mode == "control" && mode == "control":
			return "another device controls that terminal"
		}
	}
	return ""
}

// herdrTerminalAllowed runs with d.mu held and ends a stream when the
// user turns the feature or a permission of the stream off. It applies
// the rules of herdrTerminalErrorLocked to a running stream.
func (d *Daemon) herdrTerminalAllowed(t *herdrTerminal) bool {
	v := d.herdrViewForLocked(t.dev.ID)
	switch {
	case !v.Enabled:
	case !t.agent && !v.Terminals:
	case t.mode == "control" && !v.Control:
	default:
		return true
	}
	t.stop = herdrTermStopped
	return false
}

// herdrSwapLocked returns the stream that a new open replaces: the
// stream of this device and link on the same pane in another mode. A
// mode change cannot reuse a CLI stream, so it opens a new bridge. d.mu
// must be held.
func (d *Daemon) herdrSwapLocked(dev *Device, l *lan.Link, pane, mode string) *herdrTerminal {
	for _, t := range d.herdrStreams {
		if t.dev == dev && t.link == l && t.pane == pane && t.mode != mode {
			return t
		}
	}
	return nil
}

// herdrStreamLocked returns the stream only for the device and the link
// that opened it, so a message of another connection cannot reach it.
// d.mu must be held.
func (d *Daemon) herdrStreamLocked(dev *Device, l *lan.Link, id string) *herdrTerminal {
	t := d.herdrStreams[id]
	if t == nil || t.dev != dev || t.link != l {
		return nil
	}
	return t
}

// reserveHerdrStream marks the pane as having a control stream in the
// middle of its attach. It returns the release, which the caller must
// call exactly once. The count keeps the reservation while more than one
// stream attaches to the pane. A stream that fails ends only its own
// reservation.
func (d *Daemon) reserveHerdrStream(pane string) func() {
	d.mu.Lock()
	if d.herdrStreamWait == nil {
		d.herdrStreamWait = map[string]int{}
	}
	d.herdrStreamWait[pane]++
	d.mu.Unlock()
	return func() {
		d.mu.Lock()
		if n := d.herdrStreamWait[pane]; n <= 1 {
			delete(d.herdrStreamWait, pane)
		} else {
			d.herdrStreamWait[pane] = n - 1
		}
		d.mu.Unlock()
	}
}

// herdrStreamFor returns the stream of the device and the link for an
// input event, or nil. A stream that its permissions do not allow now
// ends at once, so no event goes out before the next check of
// watchSession.
func (d *Daemon) herdrStreamFor(dev *Device, l *lan.Link, id string) *herdrTerminal {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	allowed := t == nil || d.herdrTerminalAllowed(t)
	d.mu.Unlock()
	if !allowed {
		d.stopHerdrTerminal(t, herdrTermStopped)
		return nil
	}
	return t
}

// herdrControlled reports whether a phone controls the pane, or a
// control stream attaches to it.
func (d *Daemon) herdrControlled(pane string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.herdrControlledLocked(pane)
}

// herdrControlledLocked reports whether a phone controls the pane, or a
// control stream attaches to it. An observe stream does not count,
// because it does not change the terminal. d.mu must be held.
func (d *Daemon) herdrControlledLocked(pane string) bool {
	if d.herdrStreamWait[pane] > 0 {
		return true
	}
	for _, t := range d.herdrStreams {
		if t.pane == pane && t.mode == "control" {
			return true
		}
	}
	return false
}

// herdrTerminalScroll sends one wheel step to the terminal. fluxd fixes
// the source and the step size, so a phone cannot turn a gesture into
// another key. An event for an unknown session writes no log line,
// because the phone can still scroll a stream that just ended.
func (d *Daemon) herdrTerminalScroll(dev *Device, l *lan.Link, id, direction string, column, row int) {
	t := d.herdrStreamFor(dev, l, id)
	if t == nil {
		return
	}
	if err := t.session.SendScroll(direction, 1, column, row); err != nil {
		d.warnHerdrInput(t, "terminal.scroll", err)
	}
}

// herdrTerminalMouse sends one pointer event to the terminal. An event
// for an unknown session writes no log line, as for a scroll.
func (d *Daemon) herdrTerminalMouse(dev *Device, l *lan.Link, id, action, button string, column, row int) {
	t := d.herdrStreamFor(dev, l, id)
	if t == nil {
		return
	}
	if err := t.session.SendMouse(action, button, column, row); err != nil {
		d.warnHerdrInput(t, "terminal.mouse", err)
		return
	}
	// A click can press a button in the agent, for example an approval,
	// so each one goes to the log like a key reply.
	if action == "down" {
		d.logf("%s clicked the %s button at the cell %d,%d of %s", d.nameOf(dev), button, column, row, t.target())
	}
}

// warnHerdrInput logs the first failed input event of the stream. The
// phone sends up to 90 scroll steps a second, so one log line for each
// event would fill the journal.
func (d *Daemon) warnHerdrInput(t *herdrTerminal, what string, err error) {
	d.mu.Lock()
	first := !t.warned
	t.warned = true
	d.mu.Unlock()
	if first {
		d.logf("%s: %s: %v. fluxd does not log the next input errors of this stream", d.nameOf(t.dev), what, err)
	}
}

// herdrTerminalResize changes the grid of an active controller without
// replacing its stream. The phone owns only its paired control session.
func (d *Daemon) herdrTerminalResize(dev *Device, l *lan.Link, id string, cols, rows int) {
	// Flux for Android never sends an invalid size. Such a packet gets no
	// log line, as a scroll for an unknown session does, so a device
	// cannot fill the log.
	if !validTermSize(cols, rows) {
		return
	}
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	if t == nil || t.mode != "control" {
		d.mu.Unlock()
		return
	}
	if !d.herdrTerminalAllowed(t) {
		d.mu.Unlock()
		d.stopHerdrTerminal(t, herdrTermStopped)
		return
	}
	d.mu.Unlock()
	if err := t.session.Resize(cols, rows); err != nil {
		d.warnHerdrInput(t, "terminal.resize", err)
	}
}

// herdrTerminalInputMax is the largest text event that a phone may type in
// one terminal_input. It matches the prompt limit.
const herdrTerminalInputMax = 16 << 10

// herdrTerminalInputKeys maps a named key from a phone to the bytes that
// the controller types. fluxd encodes each special key, and a text event
// cannot hold a control character. So one event cannot hold an escape
// sequence.
var herdrTerminalInputKeys = map[string]string{
	"enter": "\r", "tab": "\t", "shift+tab": "\x1b[Z", "esc": "\x1b", "backspace": "\x7f",
	"up": "\x1b[A", "down": "\x1b[B", "left": "\x1b[D", "right": "\x1b[C",
}

// The codes of terminal_input_error.
const (
	herdrInputInvalid = "invalid_input" // fluxd refused the event
	herdrInputFailed  = "input_failed"  // the bridge failed, and the stream ended
	herdrPasteFailed  = "paste_failed"  // an image paste did not finish, and the stream stays
)

// herdrTerminalHidden reports whether r is a control character or a
// directional control. A terminal reads a control character as a key. A
// directional control can reorder text on a screen.
func herdrTerminalHidden(r rune) bool {
	switch {
	case r < 0x20 || r == 0x7f || r >= 0x80 && r <= 0x9f:
		return true
	case r == 0x061c || r == 0x200e || r == 0x200f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069:
		return true
	case r == 0x2028 || r == 0x2029:
		return true
	}
	return false
}

// herdrTerminalInputText reports whether text is a valid text event: not
// empty, within the limit, valid UTF-8, and without a control or a
// directional character. A line break and a tab are control characters,
// so a text event stays on one line.
func herdrTerminalInputText(text string) bool {
	if text == "" || len(text) > herdrTerminalInputMax || !utf8.ValidString(text) {
		return false
	}
	return !strings.ContainsFunc(text, herdrTerminalHidden)
}

// herdrTerminalInputPayload validates one typed event and returns the bytes
// that the controller types. Exactly one of text or key is set. An invalid
// event returns an empty payload and the reason for the phone.
func herdrTerminalInputPayload(text, key string) (string, string) {
	switch {
	case text != "" && key != "":
		return "", "Send text or a key, not both"
	case key != "":
		encoded, ok := herdrTerminalInputKeys[key]
		if !ok {
			return "", "fluxd does not know that key"
		}
		return encoded, ""
	case herdrTerminalInputText(text):
		return text, ""
	}
	return "", "The terminal did not accept this input"
}

// herdrTerminalPasteMax is the largest paste that a phone may send in one
// terminal_paste. A paste is often a code block, so it is larger than one
// typed event.
const herdrTerminalPasteMax = 64 << 10

// herdrTerminalPasteText prepares the text of a paste. A paste keeps its
// line breaks and tabs, because the program reads them as pasted content
// and not as keys. fluxd drops each other control character and each
// directional control, so a paste cannot end its own bracketed paste or
// type a key. It returns an empty text and the reason when it refuses the
// paste.
func herdrTerminalPasteText(text string) (string, string) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	switch {
	case text == "":
		return "", "The paste is empty"
	case len(text) > herdrTerminalPasteMax:
		return "", fmt.Sprintf("The paste is longer than %d KB", herdrTerminalPasteMax>>10)
	case !utf8.ValidString(text):
		return "", "The paste is not valid text"
	}
	out := strings.Map(func(r rune) rune {
		if r != '\n' && r != '\t' && herdrTerminalHidden(r) {
			return -1
		}
		return r
	}, text)
	if out == "" {
		return "", "The paste has no text that the terminal can show"
	}
	return out, ""
}

// herdrTermEvent is one validated event for the controller session.
type herdrTermEvent struct {
	bytes string // the bytes that the controller types
	key   string // the named key, or empty
	chars int    // the count of typed or pasted characters
	paste bool   // true for a bracketed paste of text
	image int    // the size of a pasted image in bytes, for its paste key
}

// herdrTermMaxHeld is the number of events that a stream keeps while an
// image paste runs. It stays below the input queue of the session, so the
// events fit in the queue after the paste key.
const herdrTermMaxHeld = 96

// herdrControlStream reports whether the session is a current control
// stream of the device and the link. Each input event checks this first,
// so a foreign, unknown, or released session gets no answer and learns
// nothing about the terminal of another device.
func (d *Daemon) herdrControlStream(dev *Device, l *lan.Link, id string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	t := d.herdrStreamLocked(dev, l, id)
	return t != nil && t.mode == "control" && t.stop == "" && t.release == ""
}

// herdrTerminalInput types one event in the controller session of the
// phone. Exactly one of text or key is set.
func (d *Daemon) herdrTerminalInput(dev *Device, l *lan.Link, id, text, key string) {
	if !d.herdrControlStream(dev, l, id) {
		return
	}
	payload, why := herdrTerminalInputPayload(text, key)
	if payload == "" {
		herdrTerminalInputError(l, id, herdrInputInvalid, why)
		return
	}
	ev := herdrTermEvent{bytes: payload, key: key}
	if key == "" {
		ev.chars = utf8.RuneCountInString(text)
	}
	d.herdrTerminalSend(dev, l, id, ev)
}

// herdrTerminalPaste types text as one bracketed paste in the controller
// session of the phone. A program that turned on bracketed paste reads the
// text as pasted content and does not submit on its line breaks. herdr
// sends the text without the markers to a program that did not turn it on.
func (d *Daemon) herdrTerminalPaste(dev *Device, l *lan.Link, id, text string) {
	if !d.herdrControlStream(dev, l, id) {
		return
	}
	body, why := herdrTerminalPasteText(text)
	if body == "" {
		herdrTerminalInputError(l, id, herdrInputInvalid, why)
		return
	}
	d.herdrTerminalSend(dev, l, id, herdrTermEvent{
		bytes: "\x1b[200~" + body + "\x1b[201~", chars: utf8.RuneCountInString(body), paste: true})
}

// herdrTerminalInputError answers a refused event. It carries no typed or
// pasted text, so a failure never shows what the phone sent.
func herdrTerminalInputError(l *lan.Link, id, code, msg string) {
	_ = l.Send(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input_error", "session": id, "code": code, "error": msg,
	}))
}

// herdrTerminalImageError answers a refused image paste. The image field
// tells the phone to stop the upload that waits for fluxd.
func herdrTerminalImageError(l *lan.Link, id, code, msg string) {
	_ = l.Send(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input_error", "session": id, "code": code, "error": msg, "image": true,
	}))
}

// herdrTerminalSend puts one validated event in the controller stream of
// the phone. The events go to the bridge of the stream in order, so a
// character, a Tab, and an Enter stay in order. While an image paste of the
// stream runs, the stream holds the event until the paste key of the
// image is in the queue. A paste that the user typed before Enter then
// reaches the prompt before Enter.
//
// A foreign, unknown, or released session gets no input and no answer. A
// bridge failure ends the stream, so the phone does not keep typing into a
// dead controller.
func (d *Daemon) herdrTerminalSend(dev *Device, l *lan.Link, id string, ev herdrTermEvent) {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	if t == nil || t.mode != "control" || t.stop != "" || t.release != "" {
		d.mu.Unlock()
		return
	}
	if t.imaging {
		full := len(t.held) >= herdrTermMaxHeld
		first := full && !t.overflowed
		if full {
			t.overflowed = true
		} else {
			t.held = append(t.held, ev)
		}
		d.mu.Unlock()
		if first {
			herdrTerminalInputError(l, id, herdrPasteFailed, "fluxd still pastes an image. Type again when it ends")
		}
		return
	}
	code, logs, err := d.herdrTermEnqueueLocked(t, []herdrTermEvent{ev})
	d.mu.Unlock()
	d.herdrTermSent(t, code, logs, err)
}

// herdrTermEnqueueLocked checks the stream and puts the events in the
// input queue of its session. The enqueue is bounded and does not block,
// so it is safe under the lock. A release that this lock serializes
// cannot come between the check and the enqueue. It returns the close code
// when the stream must end, and the log lines of the events. d.mu must be
// held.
//
// The stream opened for the agent or the shell that it found, so the
// input may not follow that identity into another pane. This mirrors
// pruneHerdrStreamsLocked, which ends the stream on the same state.
func (d *Daemon) herdrTermEnqueueLocked(t *herdrTerminal, evs []herdrTermEvent) (string, []string, error) {
	if !d.herdrTerminalAllowed(t) {
		return herdrTermStopped, nil, nil
	}
	agent := d.herdrAgentLocked(t.pane)
	switch {
	case !agent && !d.herdrTerminalLocked(t.pane):
		return herdrTermPaneGone, nil, nil
	case t.agent && !agent:
		return herdrTermAgentGone, nil, nil
	}
	blocked := d.herdrStatusLocked(t.pane) == herdr.StatusBlocked
	var logs []string
	for _, ev := range evs {
		if err := t.session.SendInput(ev.bytes); err != nil {
			return "", logs, err
		}
		if line := t.noteLocked(ev, blocked); line != "" {
			logs = append(logs, line)
		}
	}
	return "", logs, nil
}

// noteLocked returns the log line of one event, or an empty string. The
// log gets each Enter and Esc, each paste, each image, and each text that
// the phone types while the agent waits for a choice, because a digit can
// select a choice. It gets counts and never the text. d.mu must be held.
func (t *herdrTerminal) noteLocked(ev herdrTermEvent, blocked bool) string {
	who := t.dev.Name
	switch {
	case ev.image > 0:
		return fmt.Sprintf("%s pasted an image of %d bytes in the live terminal of %s", who, ev.image, t.target())
	case ev.paste:
		t.typed += ev.chars
		return fmt.Sprintf("%s pasted %d characters in the live terminal of %s", who, ev.chars, t.target())
	case ev.key == "enter":
		n := t.typed
		t.typed = 0
		return fmt.Sprintf("%s pressed Enter after %d typed characters in the live terminal of %s", who, n, t.target())
	case ev.key == "esc":
		return fmt.Sprintf("%s pressed Esc in the live terminal of %s", who, t.target())
	case ev.key == "backspace":
		t.typed = max(0, t.typed-1)
	case ev.chars > 0:
		t.typed += ev.chars
		if blocked {
			return fmt.Sprintf("%s typed %d characters in the live terminal of %s while it waits for a choice", who, ev.chars, t.target())
		}
	}
	return ""
}

// herdrTermSent writes the log lines of the sent events and ends the
// stream when herdrTermEnqueueLocked asked for it. A bridge failure also
// gets terminal_input_error.
func (d *Daemon) herdrTermSent(t *herdrTerminal, code string, logs []string, err error) {
	for _, line := range logs {
		d.logf("%s", line)
	}
	switch {
	case code != "":
		d.stopHerdrTerminal(t, code)
	case err != nil:
		d.logf("%s: terminal input: %v", d.nameOf(t.dev), err)
		herdrTerminalInputError(t.link, t.id, herdrInputFailed, "The terminal did not accept this input")
		d.stopHerdrTerminal(t, herdrTermBridge)
	}
}

// herdrTerminalPasteKey is the paste key of the controlled program. A
// terminal reads 0x16 as Ctrl+V. opencode, Claude Code, and Codex then read
// an image/png from the clipboard, so the image on the clipboard of the
// computer reaches the prompt as an attachment instead of typed text.
const herdrTerminalPasteKey = "\x16"

// herdrImageMaxSide and herdrImageMaxPixels limit the size of a pasted
// image. Flux for Android sends at most 2048 pixels on the long side. The
// limits stop a small file with a very large size from reaching the
// program, which decodes it.
const (
	herdrImageMaxSide   = 8192
	herdrImageMaxPixels = 40_000_000
)

// herdrImageAttach is the time after the paste key of an image during
// which the stream still holds the typed events. The agent reads the
// clipboard after the paste key, and an Enter in that time would submit
// the prompt without the image.
var herdrImageAttach = 500 * time.Millisecond

// herdrImageSettle is the time that the clipboard keeps a pasted image
// after its paste key. The program reads the clipboard in that time. No
// other image paste can replace the image before that.
var herdrImageSettle = time.Second

// herdrTerminalPasteImage puts a PNG image from the phone on the clipboard
// of the computer and pastes it into the agent of the controller session.
// The image travels as the payload of the packet, so the paste does not
// depend on clipboard sync or on the clipboard of the phone. The phone
// converts each image to PNG. fluxd reads only the PNG header and never
// decodes the pixels, so a payload that is not a PNG cannot reach the
// clipboard.
func (d *Daemon) herdrTerminalPasteImage(dev *Device, l *lan.Link, p *proto.Packet, id string) {
	// The ownership check runs first, so a foreign, unknown, or released
	// session gets no answer.
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	owned := t != nil && t.mode == "control" && t.stop == "" && t.release == ""
	d.mu.Unlock()
	if !owned {
		return
	}
	switch {
	case !t.agent:
		herdrTerminalImageError(l, id, herdrInputInvalid, "Only an agent takes a pasted image")
		return
	case !p.HasPayload() || p.PayloadSize <= 0:
		herdrTerminalImageError(l, id, herdrInputInvalid, "The image is empty")
		return
	case p.PayloadSize > desktop.MaxClipboardImage:
		herdrTerminalImageError(l, id, herdrInputInvalid, fmt.Sprintf("The image is larger than %d MiB", desktop.MaxClipboardImage>>20))
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, clipImageTimeout)
	switch d.startHerdrImage(t, cancel) {
	case herdrImageBusy:
		cancel()
		herdrTerminalImageError(l, id, herdrPasteFailed, "fluxd still pastes an image. Paste again when it ends")
		return
	case herdrImageGone:
		cancel()
		return
	}
	cancelOnLinkDown(ctx, l, cancel)
	go func() {
		size := 0
		defer func() { d.endHerdrImage(t, size) }()
		defer cancel()
		defer d.herdrRecover("terminal image paste", func() {
			size = 0
			herdrTerminalImageError(l, id, herdrPasteFailed, "fluxd could not paste the image")
		})
		data, err := fetchAll(ctx, l, p)
		if err != nil {
			d.logf("%s: terminal paste image: %v", d.nameOf(dev), err)
			// The end of the stream also stops the transfer. The phone then
			// gets terminal_closed and no error for the image.
			d.mu.Lock()
			open := d.herdrStreams[t.id] == t && t.stop == ""
			d.mu.Unlock()
			if open {
				herdrTerminalImageError(l, id, herdrPasteFailed, "fluxd could not receive the image")
			}
			return
		}
		if why := herdrTerminalPNG(data); why != "" {
			herdrTerminalImageError(l, id, herdrInputInvalid, why)
			return
		}
		// The transfer can take a minute. The stream must still be current
		// and allowed before the clipboard of the computer changes.
		if !d.herdrImageCurrent(t) {
			return
		}
		if err := d.clip.SetImage(data, "image/png"); err != nil {
			d.logf("%s: terminal paste image: %v", d.nameOf(dev), err)
			herdrTerminalImageError(l, id, herdrPasteFailed, "fluxd could not put the image on the clipboard")
			return
		}
		size = len(data)
	}()
}

// herdrTerminalPNG returns why fluxd refuses the image, or an empty string
// for a PNG within the size limits. It reads only the header.
func herdrTerminalPNG(data []byte) string {
	if clipImageType(data) != "image/png" {
		return "The image is not a PNG. Update Flux on the phone"
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return "fluxd could not read that image"
	}
	switch {
	case cfg.Width > herdrImageMaxSide || cfg.Height > herdrImageMaxSide:
		return fmt.Sprintf("The image is larger than %d pixels on a side", herdrImageMaxSide)
	case cfg.Width*cfg.Height > herdrImageMaxPixels:
		return fmt.Sprintf("The image has more than %d million pixels", herdrImageMaxPixels/1_000_000)
	}
	return ""
}

// The results of startHerdrImage.
const (
	herdrImageStarted = iota
	herdrImageBusy    // another image paste runs
	herdrImageGone    // the stream ended
)

// startHerdrImage reserves the one image paste of the computer for the
// stream. It refuses while another image paste runs, because the
// clipboard of the computer holds one image at a time. The stream keeps
// cancel, so its end stops the transfer. Call endHerdrImage when the
// paste ends.
func (d *Daemon) startHerdrImage(t *herdrTerminal, cancel context.CancelFunc) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case d.herdrStreams[t.id] != t || t.stop != "" || t.release != "":
		return herdrImageGone
	case d.herdrJobs.imaging || t.imaging:
		return herdrImageBusy
	}
	d.herdrJobs.imaging = true
	t.imaging, t.imageCancel, t.overflowed = true, cancel, false
	return herdrImageStarted
}

// herdrImageCurrent reports whether the stream of an image paste is still
// current and allowed. A stream that its permissions do not allow now
// ends at once.
func (d *Daemon) herdrImageCurrent(t *herdrTerminal) bool {
	d.mu.Lock()
	current := d.herdrStreams[t.id] == t && t.stop == "" && t.release == "" && t.dev.Paired
	allowed := !current || d.herdrTerminalAllowed(t)
	ok := current && allowed && d.herdrAgentLocked(t.pane)
	d.mu.Unlock()
	if !allowed {
		d.stopHerdrTerminal(t, herdrTermStopped)
	}
	return ok
}

// endHerdrImage ends the image paste that startHerdrImage reserved. With a
// size above 0, the image is on the clipboard, so the paste key goes out.
// The stream holds the typed events for herdrImageAttach more, so the
// agent can attach the image before an Enter arrives. The reservation of
// the computer stays for herdrImageSettle after the paste key, so another
// paste cannot replace the image before the agent reads it.
func (d *Daemon) endHerdrImage(t *herdrTerminal, size int) {
	if size == 0 {
		d.flushHerdrHeld(t)
		d.mu.Lock()
		d.herdrJobs.imaging = false
		d.mu.Unlock()
		return
	}
	d.mu.Lock()
	t.imageCancel = nil
	var code string
	var logs []string
	var err error
	if d.herdrStreams[t.id] == t && t.stop == "" && t.release == "" {
		code, logs, err = d.herdrTermEnqueueLocked(t, []herdrTermEvent{{bytes: herdrTerminalPasteKey, image: size}})
	}
	d.mu.Unlock()
	d.herdrTermSent(t, code, logs, err)
	time.AfterFunc(herdrImageAttach, func() { d.flushHerdrHeld(t) })
	time.AfterFunc(herdrImageSettle, func() {
		d.mu.Lock()
		d.herdrJobs.imaging = false
		d.mu.Unlock()
	})
}

// flushHerdrHeld ends the hold of an image paste and sends the events that
// the stream held, in order. A stream that ended drops them.
func (d *Daemon) flushHerdrHeld(t *herdrTerminal) {
	d.mu.Lock()
	evs := t.held
	t.held, t.imaging, t.imageCancel = nil, false, nil
	var code string
	var logs []string
	var err error
	if len(evs) > 0 && d.herdrStreams[t.id] == t && t.stop == "" && t.release == "" {
		code, logs, err = d.herdrTermEnqueueLocked(t, evs)
	}
	d.mu.Unlock()
	d.herdrTermSent(t, code, logs, err)
}

// herdrTerminalRelease ends the stream of the phone and lets its
// forwarder answer with terminal_closed. fluxd ignores a release for an
// unknown session. That session can belong to another device or to a
// stream that already ended.
func (d *Daemon) herdrTerminalRelease(dev *Device, l *lan.Link, req json.Number, id string) {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	if t != nil {
		t.release = req
	}
	d.mu.Unlock()
	if t == nil {
		d.logf("%s: ignored terminal.release for an unknown session", d.nameOf(dev))
		return
	}
	d.stopHerdrTerminal(t, herdrTermReleased)
}

// stopHerdrTerminal records why the stream ends and releases its bridge.
// Each end of a stream comes here: a release of the phone, the loss of
// the link, a failed send, a change of a permission, and the end of the
// pane or its agent. The bridge lets go of the terminal first, so herdr
// gives the desktop its size back, and only a bridge that does not exit
// gets killed. The wait runs in the background, so it holds neither d.mu
// nor the reader of the link. The forwarder goroutine sends
// terminal_closed after the last frame, so the phone always gets the
// frames before the end of the stream.
func (d *Daemon) stopHerdrTerminal(t *herdrTerminal, code string) {
	d.mu.Lock()
	if t.stop == "" {
		t.stop = code
	}
	// A new stream can open at once. The forwarder of this one still
	// sends its last frames and the end.
	delete(d.herdrStreams, t.id)
	stopImage := t.imageCancel
	d.mu.Unlock()
	// The image of an ended stream cannot reach its agent, so its
	// transfer stops.
	if stopImage != nil {
		stopImage()
	}
	go func() {
		_ = t.session.Close()
		t.cancel()
	}()
}

// runHerdrTerminal forwards the frames of one bridge until its stream
// ends. ANSI frames are incremental, so none can be dropped. The bridge
// waits instead, and a link that cannot take them ends the stream. It is
// the only sender of terminal_closed.
func (d *Daemon) runHerdrTerminal(t *herdrTerminal) {
	failed := false
	// A failed send means that the link is gone, but the bridge reader
	// can be blocked on a full frame queue. The loop keeps draining the
	// frames, so the reader can finish and end the stream.
	for frame := range t.session.Frames() {
		if failed {
			continue
		}
		body := map[string]any{
			"kind": "terminal_frame", "session": t.id,
			"seq": frame.Seq, "encoding": frame.Encoding, "full": frame.Full,
			"width": frame.Width, "height": frame.Height,
			"bytes": base64.StdEncoding.EncodeToString(frame.Bytes),
		}
		if err := t.link.Send(proto.New(proto.TypeFluxHerdr, body)); err != nil {
			d.stopHerdrTerminal(t, herdrTermStopped)
			failed = true
		}
	}
	reason, err := t.session.Wait()
	d.mu.Lock()
	code, req := herdrTermBridge, t.release
	switch {
	case req != "":
		code = herdrTermReleased
	case t.stop != "":
		code = t.stop
	}
	delete(d.herdrStreams, t.id)
	stopImage := t.imageCancel
	d.mu.Unlock()
	if stopImage != nil {
		stopImage()
	}
	// Close reports a bridge that ended with SIGKILL, with the last
	// stderr line of the bridge. herdr can then keep the terminal at the
	// size of the phone, so the log must not show a clean release.
	killed := t.session.Close()
	t.cancel()
	if err != nil {
		reason = err.Error()
	}
	switch stderr := strings.TrimSpace(t.session.Stderr()); {
	case killed != nil:
		d.logf("The live terminal of %s for %s ended with the code %s: %v", t.target(), d.nameOf(t.dev), code, killed)
	case code == herdrTermBridge && stderr != "":
		// The bridge ended by itself, so its last stderr line tells why.
		d.logf("The live terminal of %s for %s ended with the code %s: %q, and the bridge wrote %q", t.target(), d.nameOf(t.dev), code, reason, lastLine(stderr))
	default:
		d.logf("The live terminal of %s for %s ended with the code %s: %q", t.target(), d.nameOf(t.dev), code, reason)
	}
	_ = t.link.Send(withRequest(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_closed", "session": t.id, "code": code, "reason": reason}), req))
}

// pruneHerdrStreamsLocked ends the streams whose pane or agent is gone.
// It returns them to drop after the lock is released. d.mu must be held,
// with the new state already recorded.
func (d *Daemon) pruneHerdrStreamsLocked(running bool) []*herdrTerminal {
	var gone []*herdrTerminal
	for _, t := range d.herdrStreams {
		known := d.herdrAgentLocked(t.pane) || d.herdrTerminalLocked(t.pane)
		code := ""
		switch {
		case !running:
			code = herdrTermStopped
		case !known:
			code = herdrTermPaneGone
		case t.agent && !d.herdrAgentLocked(t.pane):
			code = herdrTermAgentGone
		}
		if code != "" {
			t.stop = code
			gone = append(gone, t)
		}
	}
	return gone
}

// waitHerdrReads waits until no read of the pane runs, until the read
// timeout passes, or until until. Reads with a request number run in
// reviewJobs, so both queues must be empty before a control stream takes
// the pane.
func (d *Daemon) waitHerdrReads(pane string, until time.Time) {
	deadline := time.Now().Add(herdrReadTimeout + 2*time.Second)
	if until.Before(deadline) {
		deadline = until
	}
	for time.Now().Before(deadline) {
		d.mu.Lock()
		busy := false
		for key := range d.herdrJobs.reads {
			busy = busy || key.pane == pane
		}
		for key := range d.reviewJobs {
			busy = busy || key.pane == pane
		}
		d.mu.Unlock()
		if !busy {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}
