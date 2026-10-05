package core

// Terminal sessions give one phone the live terminal of one herdr pane.
// fluxd runs the herdr terminal-session bridge as its own subprocess and
// forwards its frames over the Flux link; the phone never touches a herdr
// socket and never sees another pane or the herdr UI.
//
// One device streams one pane at a time. One controller per terminal:
// other devices may observe the same pane. A control stream needs
// herdr_control, and a pane without an agent also needs herdr_terminals.
// Control resizes the terminal for the phone, and Herdr restores desktop
// geometry when the controller releases it.
//
// While a stream is open on a pane, fluxd does not read the history of
// that pane from any device: herdr scrolls the terminal to collect the
// history, which would move the live stream and the desktop screen. Such
// reads then return the last cached history.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
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

// herdrTerminal is one open terminal-session bridge for one phone.
type herdrTerminal struct {
	id       string
	dev      *Device
	link     *lan.Link
	pane     string
	terminal string
	agent    bool
	mode     string
	width    int
	height   int
	session  *herdr.Session
	cancel   context.CancelFunc
	release  json.Number
	stop     string
}

// herdrBinName is the herdr CLI that fluxd runs for terminal sessions.
func (d *Daemon) herdrBinName() string {
	if d.herdrBin != "" {
		return d.herdrBin
	}
	return "herdr"
}

// validTermSize reports whether a phone may ask for this terminal size.
// It is in cells, and bounded like the frames of the bridge.
func validTermSize(cols, rows int) bool {
	return cols >= 1 && rows >= 1 && cols <= 1000 && rows <= 1000
}

// herdrTerminalOpen opens one terminal-session bridge for the phone. The
// answer is terminal_opened with the session ID, or with the error. A
// control stream may name the terminal size it wants: herdr then draws
// the pane for the phone and gives the desktop its size back when the
// stream ends. Watching keeps the size of the pane, because its viewport
// would only show part of the desktop screen.
func (d *Daemon) herdrTerminalOpen(dev *Device, l *lan.Link, req json.Number, pane, mode string, cols, rows int) {
	fail := func(err string) {
		_ = l.Send(withRequest(proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_opened", "pane": pane, "mode": mode, "error": err}), req))
	}
	// Reserve the pane while the control stream attaches, so a read that
	// starts during the attach already serves the cache. The wait below
	// then covers only the reads that began before the reservation, and
	// no new read can make herdr scroll the terminal under the stream.
	if mode == "control" {
		defer d.reserveHerdrStream(pane)()
	}
	// A mode change on the same pane replaces the bridge: one CLI stream
	// cannot change its mode, so control opens a new subprocess. The old
	// bridge closes first, so the phone never sees two streams of its
	// pane and the terminal is free again before the new bridge opens.
	d.mu.Lock()
	old := d.herdrSwapLocked(dev, l, pane, mode)
	d.mu.Unlock()
	if old != nil {
		d.stopHerdrTerminal(old, herdrTermReleased)
		// The stop releases the bridge in the background. Wait here
		// until it let go of the terminal, or the new one cannot attach.
		_ = old.session.Close()
	}
	d.mu.Lock()
	why := d.herdrTerminalErrorLocked(dev, pane, mode)
	d.mu.Unlock()
	if why != "" {
		fail(why)
		return
	}
	// herdr scrolls the terminal to collect a history, so a control
	// stream waits until no such read runs.
	if mode == "control" {
		d.waitHerdrReads(pane)
	}
	width, height := 0, 0
	if mode == "control" && (cols > 0 || rows > 0) {
		if !validTermSize(cols, rows) {
			fail("fluxd does not accept that terminal size")
			return
		}
		width, height = cols, rows
	}
	ctx, cancel := context.WithCancel(d.ctx)
	info, perr := herdr.GetPane(ctx, d.herdrPath, pane)
	layout, lerr := herdr.GetLayout(ctx, d.herdrPath, pane)
	if perr != nil || lerr != nil {
		cancel()
		if perr != nil {
			fail("fluxd could not read the identity of the pane")
		} else {
			fail("fluxd could not read the size of the pane")
		}
		return
	}
	if width == 0 {
		width, height = layout.Width, layout.Height
	}
	session, err := herdr.OpenSession(ctx, herdr.SessionConfig{
		Path: d.herdrBinName(), Socket: d.herdrPath, Target: pane,
		Cols: width, Rows: height, Control: mode == "control",
	})
	if err != nil {
		cancel()
		d.logf("%s: terminal session: %v", d.nameOf(dev), err)
		fail("fluxd could not open the terminal of that pane")
		return
	}
	t := &herdrTerminal{dev: dev, link: l, pane: pane, mode: mode,
		terminal: info.TerminalID, width: width, height: height,
		session: session, cancel: cancel}
	d.mu.Lock()
	// The state can change during the herdr calls above, so check again.
	if err := d.herdrTerminalErrorLocked(dev, pane, mode); err != "" {
		d.mu.Unlock()
		_ = session.Close()
		cancel()
		fail(err)
		return
	}
	if d.herdrStreams == nil {
		d.herdrStreams = map[string]*herdrTerminal{}
	}
	d.herdrStreamSeq++
	t.id = fmt.Sprintf("ts%d", d.herdrStreamSeq)
	t.agent = d.herdrAgentLocked(pane)
	d.herdrStreams[t.id] = t
	d.mu.Unlock()

	// The phone gets terminal_opened before the first frame.
	_ = l.Send(withRequest(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_opened", "pane": pane, "mode": mode, "session": t.id,
		"width": t.width, "height": t.height}), req))
	go d.runHerdrTerminal(t)
	d.watchSession(ctx, cancel, dev, l, func() bool { return d.herdrTerminalAllowed(t) })
}

// herdrTerminalErrorLocked reports why the phone may not open the stream.
// d.mu must be held.
func (d *Daemon) herdrTerminalErrorLocked(dev *Device, pane, mode string) string {
	v := d.herdrViewForLocked(dev.ID)
	switch {
	case !v.Enabled:
		return errHerdrDisabled
	case !dev.Paired:
		return "this device is not paired"
	case mode != "observe" && mode != "control":
		return "fluxd does not know that terminal mode"
	case !d.herdrAgentLocked(pane) && !d.herdrTerminalLocked(pane):
		return "fluxd does not know that pane"
	case mode == "control" && !v.Control:
		return "replies are off on this computer"
	case mode == "control" && !d.herdrAgentLocked(pane) && !v.Terminals:
		return "terminals are off on this computer"
	}
	for _, t := range d.herdrStreams {
		switch {
		case t.dev == dev:
			return "fluxd already streams a terminal to this device"
		case t.pane == pane && t.mode == "control" && mode == "control":
			return "another device controls that terminal"
		}
	}
	return ""
}

// herdrTerminalAllowed runs with d.mu held and ends a stream when the
// user turns the feature or its permission off.
func (d *Daemon) herdrTerminalAllowed(t *herdrTerminal) bool {
	v := d.herdrViewForLocked(t.dev.ID)
	switch {
	case !v.Enabled:
	case t.mode == "control" && !v.Control:
	case t.mode == "control" && !t.agent && !v.Terminals:
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
// stream attaches to the pane: a stream that fails releases only its own.
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

// herdrStreamed reports whether a terminal session shows the pane, or one
// is about to attach.
func (d *Daemon) herdrStreamed(pane string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.herdrStreamedLocked(pane)
}

// herdrStreamedLocked reports whether a terminal session shows the pane,
// or a control stream is attaching to it. d.mu must be held.
func (d *Daemon) herdrStreamedLocked(pane string) bool {
	if d.herdrStreamWait[pane] > 0 {
		return true
	}
	for _, t := range d.herdrStreams {
		if t.pane == pane {
			return true
		}
	}
	return false
}

// herdrTerminalScroll sends one wheel step to the terminal. fluxd fixes
// the source and the step size, so a phone cannot turn a gesture into
// another key.
func (d *Daemon) herdrTerminalScroll(dev *Device, l *lan.Link, id, direction string, column, row int) {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	d.mu.Unlock()
	if t == nil {
		d.logf("%s: ignored terminal.scroll for an unknown session", d.nameOf(dev))
		return
	}
	if err := t.session.SendScroll(direction, 1, column, row); err != nil {
		d.logf("%s: terminal.scroll: %v", d.nameOf(dev), err)
	}
}

// herdrTerminalMouse sends one pointer event to the terminal.
func (d *Daemon) herdrTerminalMouse(dev *Device, l *lan.Link, id, action, button string, column, row int) {
	d.mu.Lock()
	t := d.herdrStreamLocked(dev, l, id)
	d.mu.Unlock()
	if t == nil {
		d.logf("%s: ignored terminal.mouse for an unknown session", d.nameOf(dev))
		return
	}
	if err := t.session.SendMouse(action, button, column, row); err != nil {
		d.logf("%s: terminal.mouse: %v", d.nameOf(dev), err)
	}
}

// herdrTerminalResize changes the grid of an active controller without
// replacing its stream. The phone owns only its paired control session.
func (d *Daemon) herdrTerminalResize(dev *Device, l *lan.Link, id string, cols, rows int) {
	if !validTermSize(cols, rows) {
		d.logf("%s: ignored terminal.resize with invalid size %dx%d", d.nameOf(dev), cols, rows)
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
		d.logf("%s: terminal.resize: %v", d.nameOf(dev), err)
	}
}

// herdrTerminalRelease ends the stream of the phone and lets its
// forwarder answer with terminal_closed. A release for an unknown
// session is ignored: it may belong to another device or to a stream
// that already ended.
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
// The forwarder goroutine sends terminal_closed after the last frame, so
// the phone always gets the frames before the end of the stream.
func (d *Daemon) stopHerdrTerminal(t *herdrTerminal, code string) {
	d.mu.Lock()
	if t.stop == "" {
		t.stop = code
	}
	// A new stream may open at once; the forwarder of this one still
	// sends its last frames and the end.
	delete(d.herdrStreams, t.id)
	d.mu.Unlock()
	go func() {
		// Close releases the terminal politely and reaps the subprocess.
		_ = t.session.Close()
		t.cancel()
	}()
}

// runHerdrTerminal forwards the frames of one bridge until its stream
// ends. ANSI frames are incremental, so none may be dropped: the bridge
// waits instead, and a link that cannot take them ends the stream. It is
// the only sender of terminal_closed.
func (d *Daemon) runHerdrTerminal(t *herdrTerminal) {
	failed := false
	// A failed send means the link is gone, but the bridge reader may be
	// blocked on a full frame queue. Keep draining the frames so the
	// reader can finish and close the stream, instead of waiting for a
	// Close that only happens after Wait.
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
			t.cancel()
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
	_ = t.session.Close()
	t.cancel()
	if err != nil {
		reason = err.Error()
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

// waitHerdrReads waits until no read of the pane runs, or until the read
// timeout passes. Reads with a request number run in reviewJobs, so both
// queues must be empty before a control stream takes the pane.
func (d *Daemon) waitHerdrReads(pane string) {
	deadline := time.Now().Add(herdrReadTimeout + 2*time.Second)
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
