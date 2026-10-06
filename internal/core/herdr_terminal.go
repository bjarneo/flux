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
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

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
