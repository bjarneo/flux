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
	"image"
	_ "image/gif"
	_ "image/jpeg"
	"image/png"
	"strings"
	"time"
	"unicode/utf8"

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
// the controller types. Only fluxd encodes a special key, so a client
// cannot smuggle an arbitrary escape sequence into a text event.
var herdrTerminalInputKeys = map[string]string{
	"enter": "\r", "tab": "\t", "esc": "\x1b", "backspace": "\x7f",
	"up": "\x1b[A", "down": "\x1b[B", "left": "\x1b[D", "right": "\x1b[C",
}

// herdrTerminalInputText reports whether text is a valid text event: not
// empty, within the limit, one line, and without control or directional
// characters. A terminal reads a control character as a key, and the
// Unicode bidirectional controls can reorder text on a screen.
func herdrTerminalInputText(text string) bool {
	if text == "" || len(text) > herdrTerminalInputMax || !utf8.ValidString(text) {
		return false
	}
	for _, r := range text {
		switch {
		case r == '\n' || r == '\t':
			return false
		case r < 0x20 || r == 0x7f || r >= 0x80 && r <= 0x9f:
			return false
		case r == 0x061c || r == 0x200e || r == 0x200f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069,
			r == 0x2028 || r == 0x2029:
			return false
		}
	}
	return true
}

// herdrTerminalInputPayload validates one typed event and returns the bytes
// that the controller types. Exactly one of text or key is set. An invalid
// event returns an empty payload and the reason for the phone.
func herdrTerminalInputPayload(text, key string) (string, string) {
	switch {
	case text != "" && key != "":
		return "", "Send text or a key, not both."
	case key != "":
		encoded, ok := herdrTerminalInputKeys[key]
		if !ok {
			return "", "fluxd does not know that key."
		}
		return encoded, ""
	case herdrTerminalInputText(text):
		return text, ""
	}
	return "", "The terminal did not accept this input."
}

// herdrTerminalPasteMax is the largest paste that a phone may send in one
// terminal_paste. A paste is often a code block, so it is larger than one
// typed event; the controller writes the whole line to the program.
const herdrTerminalPasteMax = 64 << 10

// herdrTerminalPasteText prepares the text of a paste. A paste keeps its
// line breaks and tabs, because the program reads them as pasted content
// and not as keys. Every other control character goes, so a paste cannot
// close its own bracketed paste with an escape sequence or type a key. It
// returns an empty text and the reason when the paste is refused.
func herdrTerminalPasteText(text string) (string, string) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	switch {
	case text == "":
		return "", "The clipboard has no text."
	case len(text) > herdrTerminalPasteMax:
		return "", fmt.Sprintf("The paste is longer than %d KB", herdrTerminalPasteMax>>10)
	case !utf8.ValidString(text):
		return "", "The paste is not valid text."
	}
	var b strings.Builder
	b.Grow(len(text))
	for _, r := range text {
		switch {
		case r == '\n' || r == '\t':
			b.WriteRune(r)
		case r < 0x20 || r == 0x7f || r >= 0x80 && r <= 0x9f:
			// Drop, so the paste cannot type a key.
		case r == 0x061c || r == 0x200e || r == 0x200f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069,
			r == 0x2028 || r == 0x2029:
			// Drop the directional controls that can reorder the paste.
		default:
			b.WriteRune(r)
		}
	}
	out := b.String()
	if out == "" {
		return "", "The paste has no text that the terminal can read."
	}
	return out, ""
}

// herdrTerminalPaste types text as one bracketed paste in the controller
// session of the phone. A program that enabled bracketed paste reads the
// text as pasted content and does not submit on its line breaks, so a
// phone paste reaches the program's own paste handling, for example the
// compact placeholder of opencode. The markers are Flux's, because the
// controller writes the bytes as they are.
func (d *Daemon) herdrTerminalPaste(dev *Device, l *lan.Link, id, text string) {
	body, why := herdrTerminalPasteText(text)
	if body == "" {
		herdrTerminalInputError(l, id, "invalid_input", why)
		return
	}
	d.herdrTerminalSend(dev, l, id, "\x1b[200~"+body+"\x1b[201~")
}

// herdrTerminalImageMax is the largest image that a phone may paste into a
// terminal in one terminal_paste_image. It matches the clipboard image
// limit of Flux.
const herdrTerminalImageMax = 16 << 20

// herdrTerminalPasteKey is the paste key of the controlled program. A
// terminal reads 0x16 as Ctrl+V. opencode reads the clipboard then, so an
// image on the clipboard of the computer reaches the prompt as an
// attachment instead of typed text.
const herdrTerminalPasteKey = "\x16"

// herdrTerminalPasteImage puts an image from the phone on the clipboard
// of the computer and pastes it into the controller session of the phone.
// The image travels as the payload of the packet, so the paste does not
// depend on clipboard sync or on the clipboard of the phone. The program
// reads its own clipboard, so the image reaches the prompt as an
// attachment. fluxd detects the image type from the bytes and drops a
// payload that is not an image, so a phone cannot put arbitrary data on
// the clipboard.
func (d *Daemon) herdrTerminalPasteImage(dev *Device, l *lan.Link, p *proto.Packet, id string) {
	// The ownership check runs first, so a foreign, unknown, or released
	// session gets no answer and learns nothing about somebody else's
	// terminal.
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	d.mu.Unlock()
	if t == nil || t.mode != "control" {
		d.logf("%s: ignored an image paste for an unknown session", d.nameOf(dev))
		return
	}
	switch {
	case !p.HasPayload() || p.PayloadSize <= 0:
		herdrTerminalInputError(l, id, "invalid_input", "The image is empty.")
		return
	case p.PayloadSize > herdrTerminalImageMax:
		herdrTerminalInputError(l, id, "invalid_input", fmt.Sprintf("The image is larger than %d MiB", herdrTerminalImageMax>>20))
		return
	}
	if !d.startHerdrImage(dev) {
		herdrTerminalInputError(l, id, "input_failed", "An image of this device is still on its way.")
		return
	}
	go func() {
		defer d.endHerdrImage(dev)
		ctx, cancel := context.WithTimeout(d.ctx, clipImageTimeout)
		defer cancel()
		data, err := fetchAll(ctx, l, p)
		if err != nil {
			d.logf("%s: terminal paste image: %v", d.nameOf(dev), err)
			herdrTerminalInputError(l, id, "input_failed", "fluxd could not receive the image.")
			return
		}
		mime := clipImageType(data)
		if mime == "" {
			herdrTerminalInputError(l, id, "invalid_input", "The paste is not a PNG, JPEG, GIF, or WebP image.")
			return
		}
		pngData, why := herdrTerminalPNG(data, mime)
		if pngData == nil {
			herdrTerminalInputError(l, id, "invalid_input", why)
			return
		}
		if err := d.clip.SetImage(pngData, "image/png"); err != nil {
			d.logf("%s: terminal paste image: %v", d.nameOf(dev), err)
			herdrTerminalInputError(l, id, "input_failed", "fluxd could not put the image on the clipboard.")
			return
		}
		d.herdrTerminalSend(dev, l, id, herdrTerminalPasteKey)
	}()
}

// herdrTerminalPNG returns the image as PNG, the type that the paste path
// of opencode reads. A PNG stays as it is, so it is not encoded again; a
// JPEG or a GIF is decoded and encoded as PNG. A WebP image needs a
// decoder that Flux does not carry. It returns the reason when the image
// cannot become a PNG.
func herdrTerminalPNG(data []byte, mime string) ([]byte, string) {
	switch mime {
	case "image/png":
		return data, ""
	case "image/webp":
		return nil, "opencode reads PNG, and Flux cannot turn WebP into PNG on the computer. Copy it as a PNG or a JPEG."
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, "fluxd could not read that image."
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, "fluxd could not turn the image into a PNG."
	}
	return b.Bytes(), ""
}

// startHerdrImage reserves the one image paste of the device. It returns
// false while another image of the device is still on its way, because the
// clipboard of the computer holds one image at a time. Call endHerdrImage
// when the paste ends.
func (d *Daemon) startHerdrImage(dev *Device) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.herdrJobs.pasting[dev.ID] {
		return false
	}
	if d.herdrJobs.pasting == nil {
		d.herdrJobs.pasting = map[string]bool{}
	}
	d.herdrJobs.pasting[dev.ID] = true
	return true
}

// endHerdrImage ends an image paste that startHerdrImage reserved.
func (d *Daemon) endHerdrImage(dev *Device) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.herdrJobs.pasting, dev.ID)
}

// herdrTerminalInput types one event in the controller session of the
// phone. Exactly one of text or key is set.
func (d *Daemon) herdrTerminalInput(dev *Device, l *lan.Link, id, text, key string) {
	payload, why := herdrTerminalInputPayload(text, key)
	if payload == "" {
		herdrTerminalInputError(l, id, "invalid_input", why)
		return
	}
	d.herdrTerminalSend(dev, l, id, payload)
}

// herdrTerminalInputError answers a refused event. It carries no typed or
// pasted text, so a failure never leaks what the phone sent.
func herdrTerminalInputError(l *lan.Link, id, code, msg string) {
	_ = l.Send(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input_error", "session": id, "code": code, "error": msg,
	}))
}

// herdrTerminalSend enqueues one already validated event in the controller
// stream of the phone. The event goes to the bridge of the stream in
// order, so a character, a Tab, and an Enter stay in order and no legacy
// reply job can reorder them. The daemon lock guards the stream while the
// event is enqueued, so no input can follow a recorded release.
//
// A foreign, unknown, or released session gets no input and no answer, so
// it learns nothing about somebody else's terminal. A valid owned stream
// gets a failure-only terminal_input_error, and a bridge failure also ends
// the stream: the phone must not keep typing into a dead controller.
func (d *Daemon) herdrTerminalSend(dev *Device, l *lan.Link, id, payload string) {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	if t == nil || t.mode != "control" || t.stop != "" {
		d.mu.Unlock()
		d.logf("%s: ignored terminal input for an unknown session", d.nameOf(dev))
		return
	}
	// The stream opened for the agent or the shell that it found, so the
	// input may not follow that identity into another pane. This mirrors
	// pruneHerdrStreamsLocked, which ends the stream on the same state.
	allowed := d.herdrTerminalAllowed(t)
	agent := d.herdrAgentLocked(t.pane)
	known := agent || d.herdrTerminalLocked(t.pane)
	gone := !known || t.agent && !agent
	var err error
	if allowed && !gone {
		// The enqueue is bounded and nonblocking, so it is safe under the
		// lock and it cannot follow a release that this lock serializes.
		err = t.session.SendInput(payload)
	}
	d.mu.Unlock()
	switch {
	case !allowed:
		d.stopHerdrTerminal(t, herdrTermStopped)
	case !known:
		d.stopHerdrTerminal(t, herdrTermPaneGone)
	case t.agent && !agent:
		d.stopHerdrTerminal(t, herdrTermAgentGone)
	case err != nil:
		d.logf("%s: terminal input: %v", d.nameOf(dev), err)
		herdrTerminalInputError(l, id, "input_failed", "The terminal did not accept this input.")
		d.stopHerdrTerminal(t, herdrTermBridge)
	}
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
	d.mu.Unlock()
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
	d.mu.Unlock()
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
