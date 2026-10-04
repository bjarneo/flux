package core

// Terminal sessions give one phone the live terminal of one herdr pane.
// fluxd runs the herdr terminal-session bridge as its own subprocess and
// forwards its frames over the Flux link; the phone never touches a herdr
// socket and never sees another pane or the herdr UI.
//
// One device streams one pane at a time. One controller per terminal:
// other devices may observe the same pane. A control stream needs
// herdr_control, and a pane without an agent also needs herdr_terminals.
// The phone sees the terminal at the size it has on the desktop, so
// opening a stream does not resize the desktop.
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
	herdrTermReleased  = "released"   // the phone released the terminal
	herdrTermBridge    = "bridge"     // the bridge stream ended
	herdrTermAgentGone = "agent_ended" // the agent left the pane
	herdrTermPaneGone  = "pane_closed" // the pane closed or moved
	herdrTermStopped   = "stopped"    // permissions or the link changed
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

// herdrTerminalOpen opens one terminal-session bridge for the phone. The
// answer is terminal_opened with the session ID, or with the error.
func (d *Daemon) herdrTerminalOpen(dev *Device, l *lan.Link, req json.Number, pane, mode string) {
	fail := func(err string) {
		_ = l.Send(withRequest(proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_opened", "pane": pane, "mode": mode, "error": err}), req))
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
	session, err := herdr.OpenSession(ctx, herdr.SessionConfig{
		Path: d.herdrBinName(), Socket: d.herdrPath, Target: pane,
		Cols: layout.Width, Rows: layout.Height, Control: mode == "control",
	})
	if err != nil {
		cancel()
		d.logf("%s: terminal session: %v", d.nameOf(dev), err)
		fail("fluxd could not open the terminal of that pane")
		return
	}
	t := &herdrTerminal{dev: dev, link: l, pane: pane, mode: mode,
		terminal: info.TerminalID, width: layout.Width, height: layout.Height,
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

// herdrStreamedLocked reports whether a terminal session shows the pane.
// d.mu must be held.
func (d *Daemon) herdrStreamedLocked(pane string) bool {
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
	for frame := range t.session.Frames() {
		body := map[string]any{
			"kind": "terminal_frame", "session": t.id,
			"seq": frame.Seq, "encoding": frame.Encoding, "full": frame.Full,
			"width": frame.Width, "height": frame.Height,
			"bytes": base64.StdEncoding.EncodeToString(frame.Bytes),
		}
		if err := t.link.Send(proto.New(proto.TypeFluxHerdr, body)); err != nil {
			t.cancel()
			break
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
// timeout passes.
func (d *Daemon) waitHerdrReads(pane string) {
	deadline := time.Now().Add(herdrReadTimeout + 2*time.Second)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		busy := false
		for key := range d.herdrJobs.reads {
			busy = busy || key.pane == pane
		}
		d.mu.Unlock()
		if !busy {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}
