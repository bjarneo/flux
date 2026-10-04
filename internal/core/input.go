package core

import (
	"context"
	"math"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// inputBackend moves the pointer and types on the desktop.
type inputBackend interface {
	Move(dx, dy float64) error
	Button(button uint32, pressed bool) error
	Scroll(dx, dy float64) error
	// Type and Key stop when ctx ends. Key presses the key times times.
	Type(ctx context.Context, text string, mods []string) error
	Key(ctx context.Context, name string, mods []string, times int) error
	// MoveTo moves the pointer to x and y, from 0 to 1, on the monitor.
	MoveTo(monitor string, x, y float64) error
}

// Limits for 1 mousepad packet. A larger value is cut to the limit.
const (
	maxInputDelta = 2000
	maxInputText  = 4096
	// maxKeyRepeat is the most presses of 1 special key in 1 packet.
	maxKeyRepeat = 4096
	// inputQueue is the number of actions that wait for the desktop. The
	// link drops actions when the desktop falls behind, so a slow wtype
	// does not stop the packets of the phone.
	inputQueue = 256
	// inputReserve is the number of queue places that only a button
	// release can take, so that a full queue does not keep a button down.
	inputReserve = 4
	// maxInputBacklog is the number of characters of text and repeated
	// key presses that the queue holds at most. wtype types about 250
	// characters each second.
	maxInputBacklog = 4 * maxInputText
	// heldCheck is the time between 2 checks that the device that holds a
	// button is still allowed.
	heldCheck = 500 * time.Millisecond
)

// specialKeys maps the specialKey numbers of flux.mousepad.request
// to XKB key names.
var specialKeys = map[int]string{
	1: "BackSpace", 2: "Tab", 4: "Left", 5: "Up", 6: "Right", 7: "Down",
	8: "Page_Up", 9: "Page_Down", 10: "Home", 11: "End", 12: "Return", 13: "Delete",
	14: "Escape",
	21: "F1", 22: "F2", 23: "F3", 24: "F4", 25: "F5", 26: "F6",
	27: "F7", 28: "F8", 29: "F9", 30: "F10", 31: "F11", 32: "F12",
}

// mousepadBody is the body of flux.mousepad.request. A packet holds
// 1 action: a click, a button press or release, a scroll, text or a key,
// or a pointer motion. The fields X and Y put the pointer on a position
// of the remote desktop before the action. Repeat presses a special key
// that many times, for example Backspace for each character of a text
// that the phone clears.
type mousepadBody struct {
	Dx            float64  `json:"dx"`
	Dy            float64  `json:"dy"`
	X             *float64 `json:"x"`
	Y             *float64 `json:"y"`
	Scroll        bool     `json:"scroll"`
	SingleClick   bool     `json:"singleclick"`
	MiddleClick   bool     `json:"middleclick"`
	RightClick    bool     `json:"rightclick"`
	SingleHold    bool     `json:"singlehold"`
	SingleRelease bool     `json:"singlerelease"`
	Key           string   `json:"key"`
	SpecialKey    int      `json:"specialKey"`
	Repeat        int      `json:"repeat"`
	Alt           bool     `json:"alt"`
	Ctrl          bool     `json:"ctrl"`
	Shift         bool     `json:"shift"`
	Super         bool     `json:"super"`
}

// inputAction is 1 step for the input backend.
type inputAction struct {
	device  string
	kind    string // move, moveTo, button, scroll, type, or key
	dx, dy  float64
	x, y    float64 // the position for moveTo, from 0 to 1
	monitor string  // the monitor for moveTo
	button  uint32
	pressed bool
	text    string // the text for type, the key name for key
	mods    []string
	count   int // the presses of a key when more than 1

	// dev is the device that sent the action, link is its link at that
	// time, and gen is the input generation. The action runs only while
	// remote input stays on, the device stays paired, and the link stays.
	dev  *Device
	link *lan.Link
	gen  uint64
}

// inputActions turns a mousepad body into the steps for the backend. A
// position comes first. The action follows this order:
// clicks, then a held button, then a scroll, then keys, then a motion.
func inputActions(b mousepadBody) []inputAction {
	if b.X == nil || b.Y == nil || !finite(*b.X) || !finite(*b.Y) {
		return mousepadAction(b)
	}
	to := inputAction{kind: "moveTo", x: max(0, min(1, *b.X)), y: max(0, min(1, *b.Y))}
	return append([]inputAction{to}, mousepadAction(b)...)
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

// mousepadAction returns the steps of the action of a mousepad body.
func mousepadAction(b mousepadBody) []inputAction {
	click := func(button uint32, times int) []inputAction {
		var out []inputAction
		for range times {
			out = append(out, inputAction{kind: "button", button: button, pressed: true}, inputAction{kind: "button", button: button})
		}
		return out
	}
	dx, dy := clampDelta(b.Dx), clampDelta(b.Dy)
	switch {
	case b.SingleClick:
		return click(desktop.BtnLeft, 1)
	case b.MiddleClick:
		return click(desktop.BtnMiddle, 1)
	case b.RightClick:
		return click(desktop.BtnRight, 1)
	case b.SingleHold:
		return []inputAction{{kind: "button", button: desktop.BtnLeft, pressed: true}}
	case b.SingleRelease:
		return []inputAction{{kind: "button", button: desktop.BtnLeft}}
	case b.Scroll:
		if dx == 0 && dy == 0 {
			return nil
		}
		return []inputAction{{kind: "scroll", dx: dx, dy: dy}}
	case b.SpecialKey != 0:
		name, ok := specialKeys[b.SpecialKey]
		if !ok {
			return nil
		}
		a := inputAction{kind: "key", text: name, mods: inputMods(b)}
		if b.Repeat > 1 {
			a.count = min(b.Repeat, maxKeyRepeat)
		}
		return []inputAction{a}
	case b.Key != "":
		text := cleanInputText(b.Key)
		if text == "" {
			return nil
		}
		return []inputAction{{kind: "type", text: text, mods: inputMods(b)}}
	case dx != 0 || dy != 0:
		return []inputAction{{kind: "move", dx: dx, dy: dy}}
	}
	return nil
}

// backlog returns the characters and the repeated key presses of an
// action, for the limit of the queue.
func (a inputAction) backlog() int {
	switch a.kind {
	case "type":
		return utf8.RuneCountInString(a.text)
	case "key":
		return a.count
	}
	return 0
}

func inputMods(b mousepadBody) []string {
	var mods []string
	if b.Ctrl {
		mods = append(mods, "ctrl")
	}
	if b.Alt {
		mods = append(mods, "alt")
	}
	if b.Shift {
		mods = append(mods, "shift")
	}
	if b.Super {
		mods = append(mods, "logo")
	}
	return mods
}

func clampDelta(v float64) float64 {
	if !finite(v) {
		return 0
	}
	return max(-maxInputDelta, min(maxInputDelta, v))
}

// cleanInputText limits the text and removes control characters. The
// phone sends Enter and Tab as special keys.
func cleanInputText(s string) string {
	var b strings.Builder
	n := 0
	for _, r := range s {
		if unicode.IsControl(r) || r == unicode.ReplacementChar {
			continue
		}
		if n == maxInputText {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// handleMousepad runs the input of a phone on the desktop while
// remote_input is on. The actions of 1 packet go into the queue together,
// or not at all, so that a click is never only a press.
func (d *Daemon) handleMousepad(dev *Device, p *proto.Packet) {
	var b mousepadBody
	if p.Decode(&b) != nil {
		return
	}
	d.mu.Lock()
	on := d.cfg.RemoteInput && d.input != nil && d.permittedLocked(dev.ID, "remoteInput")
	if !on {
		warn := !dev.inputRefused
		dev.inputRefused = true
		d.mu.Unlock()
		if warn {
			d.logf("%s: ignored remote input, because remote_input is off", dev.Name)
		}
		return
	}
	if !dev.Paired || dev.link == nil {
		d.mu.Unlock()
		return
	}
	monitor := ""
	if d.desktop != nil && d.desktop.dev.ID == dev.ID {
		monitor = d.desktop.view.Monitor
	}
	var actions []inputAction
	text, releases := 0, true
	for _, a := range inputActions(b) {
		a.device = dev.ID
		if a.kind == "moveTo" {
			// A position is on the remote desktop that the phone shows.
			if monitor == "" {
				continue
			}
			a.monitor = monitor
		} else if a.kind != "button" || a.pressed {
			releases = false
		}
		text += a.backlog()
		a.dev, a.link, a.gen = dev, dev.link, d.sessions.inputGen
		actions = append(actions, a)
	}
	free := cap(d.inputQ) - len(d.inputQ)
	if !releases {
		free -= inputReserve
	}
	if len(actions) > free || d.sessions.inputText+text > maxInputBacklog {
		// Log once for each burst, not for each packet.
		warn := !d.sessions.inputDropped
		d.sessions.inputDropped = true
		d.mu.Unlock()
		if warn {
			d.logf("%s: dropped remote input, because the desktop is slow", dev.Name)
		}
		return
	}
	// Only this function adds to the queue, and it holds d.mu, so the
	// actions fit.
	for _, a := range actions {
		select {
		case d.inputQ <- a:
		default:
		}
	}
	d.sessions.inputText += text
	d.sessions.inputDropped = false
	d.mu.Unlock()
}

// inputWakeLocked returns the channel that makes inputLoop check the held
// buttons at once. d.mu must be held.
func (d *Daemon) inputWakeLocked() chan struct{} {
	if d.sessions.inputWake == nil {
		d.sessions.inputWake = make(chan struct{}, 1)
	}
	return d.sessions.inputWake
}

// inputAllowedLocked reports whether an action can still run: remote input
// is on, the action is not older than the last time it turned off, and its
// device is paired and has the same link. d.mu must be held.
func (d *Daemon) inputAllowedLocked(a inputAction) bool {
	return d.cfg.RemoteInput && d.input != nil && a.gen == d.sessions.inputGen &&
		a.dev != nil && a.dev.Paired && d.permittedLocked(a.dev.ID, "remoteInput") && a.link != nil && a.dev.link == a.link && !linkClosed(a.link)
}

func linkClosed(l *lan.Link) bool {
	select {
	case <-l.Done():
		return true
	default:
		return false
	}
}

// inputLoop runs the input actions in order until ctx ends. It releases a
// button that it pressed when the device that pressed it is no longer
// allowed, for example when its link drops during a drag.
func (d *Daemon) inputLoop(ctx context.Context) {
	var lastErr string
	d.mu.Lock()
	wake := d.inputWakeLocked()
	d.mu.Unlock()
	// held holds the press action of each button that is down.
	held := map[uint32]inputAction{}
	tick := time.NewTicker(heldCheck)
	defer tick.Stop()
	for {
		// The check runs also while another device sends actions.
		var check <-chan time.Time
		if len(held) > 0 {
			check = tick.C
		}
		select {
		case <-ctx.Done():
			return
		case <-wake:
			d.releaseHeld(held)
		case <-check:
			d.releaseHeld(held)
		case a := <-d.inputQ:
			err := d.runQueued(ctx, a, held)
			// Log a failure once, not for each motion.
			if msg := errString(err); msg != lastErr {
				if err != nil {
					d.logf("remote input: %v", err)
				}
				lastErr = msg
			}
		}
	}
}

// runQueued runs 1 action from the queue when it is still allowed.
func (d *Daemon) runQueued(ctx context.Context, a inputAction, held map[uint32]inputAction) error {
	d.mu.Lock()
	d.sessions.inputText = max(0, d.sessions.inputText-a.backlog())
	ok := d.inputAllowedLocked(a)
	var actx context.Context
	var stop context.CancelFunc
	if ok && (a.kind == "type" || a.kind == "key") {
		// inputChanged stops the wtype that runs when remote input turns off.
		actx, stop = context.WithCancel(ctx)
		d.sessions.inputStop = stop
	}
	d.mu.Unlock()
	if !ok {
		// The button that the device holds must not stay down.
		d.releaseHeld(held)
		return nil
	}
	if stop != nil {
		defer func() {
			stop()
			d.mu.Lock()
			d.sessions.inputStop = nil
			d.mu.Unlock()
		}()
		// A link that drops or an unpair stops the text that wtype still
		// types.
		d.watchSession(actx, stop, a.dev, a.link, func() bool { return d.inputAllowedLocked(a) })
	}
	err := d.runInput(actx, a)
	if a.kind == "button" {
		if a.pressed {
			held[a.button] = a
		} else {
			delete(held, a.button)
		}
	}
	return err
}

// releaseHeld releases each held button whose device is no longer allowed.
func (d *Daemon) releaseHeld(held map[uint32]inputAction) {
	if len(held) == 0 {
		return
	}
	var stale []uint32
	d.mu.Lock()
	in := d.input
	for b, a := range held {
		if !d.inputAllowedLocked(a) {
			stale = append(stale, b)
		}
	}
	d.mu.Unlock()
	for _, b := range stale {
		if in != nil {
			_ = in.Button(b, false)
		}
		delete(held, b)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (d *Daemon) runInput(ctx context.Context, a inputAction) error {
	if a.device != "" {
		d.mu.Lock()
		allowed := d.cfg.RemoteInput && d.permittedLocked(a.device, "remoteInput")
		d.mu.Unlock()
		if !allowed {
			return nil
		}
	}
	in := d.input
	switch a.kind {
	case "move":
		return in.Move(a.dx, a.dy)
	case "moveTo":
		return in.MoveTo(a.monitor, a.x, a.y)
	case "button":
		return in.Button(a.button, a.pressed)
	case "scroll":
		return in.Scroll(a.dx, a.dy)
	case "type":
		return in.Type(ctx, a.text, a.mods)
	case "key":
		return in.Key(ctx, a.text, a.mods, max(1, a.count))
	}
	return nil
}

// sendInputState tells a phone whether this computer accepts remote input,
// and whether it shows its screen on the phone. keyRepeat tells the phone
// that it can send repeat with a special key.
func (d *Daemon) sendInputState(l *lan.Link) {
	d.mu.Lock()
	on := d.cfg.RemoteInput && d.input != nil && d.permittedLocked(l.DeviceID(), "remoteInput")
	desktop := d.cfg.RemoteDesktop && !d.opts.Headless && d.permittedLocked(l.DeviceID(), "remoteDesktop")
	d.mu.Unlock()
	_ = l.Send(proto.New(proto.TypeFluxInput, map[string]any{"enabled": on, "desktop": desktop, "keyRepeat": true}))
}

// inputChanged sends the remote input state to each connected phone that
// accepts flux.input. It stops the remote desktop when its setting is off.
// When remote input is off, it drops the queued actions, stops the wtype
// that runs, and releases the held buttons. It also clears the error of
// the last remote desktop start, because that error can say that the
// setting is off.
func (d *Daemon) inputChanged() {
	d.mu.Lock()
	var links []*lan.Link
	for _, dev := range d.devices {
		dev.inputRefused = false
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxInput) {
			links = append(links, dev.link)
		}
	}
	desktop := d.cfg.RemoteDesktop
	d.desktopErr = ""
	var stop context.CancelFunc
	if !d.cfg.RemoteInput {
		// A new generation drops the actions that a loop already took.
		d.sessions.inputGen++
	drain:
		for {
			select {
			case <-d.inputQ:
			default:
				break drain
			}
		}
		d.sessions.inputText = 0
		stop = d.sessions.inputStop
	}
	wake := d.inputWakeLocked()
	d.mu.Unlock()
	if stop != nil {
		stop()
	}
	select {
	case wake <- struct{}{}:
	default:
	}
	for _, l := range links {
		d.sendInputState(l)
	}
	if !desktop {
		_ = d.StopDesktop()
	}
}
