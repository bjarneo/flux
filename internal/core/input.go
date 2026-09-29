package core

import (
	"context"
	"math"
	"strings"
	"unicode"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// inputBackend moves the pointer and types on the desktop.
type inputBackend interface {
	Move(dx, dy float64) error
	Button(button uint32, pressed bool) error
	Scroll(dx, dy float64) error
	Type(text string, mods []string) error
	Key(name string, mods []string) error
	// MoveTo moves the pointer to x and y, from 0 to 1, on the monitor.
	MoveTo(monitor string, x, y float64) error
}

// Limits for 1 mousepad packet. A larger value is cut to the limit.
const (
	maxInputDelta = 2000
	maxInputText  = 4096
	// inputQueue is the number of actions that wait for the desktop. The
	// link drops actions when the desktop falls behind, so a slow wtype
	// does not stop the packets of the phone.
	inputQueue = 256
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
// of the remote desktop before the action.
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
	Alt           bool     `json:"alt"`
	Ctrl          bool     `json:"ctrl"`
	Shift         bool     `json:"shift"`
	Super         bool     `json:"super"`
}

// inputAction is 1 step for the input backend.
type inputAction struct {
	kind    string // move, moveTo, button, scroll, type, or key
	dx, dy  float64
	x, y    float64 // the position for moveTo, from 0 to 1
	monitor string  // the monitor for moveTo
	button  uint32
	pressed bool
	text    string // the text for type, the key name for key
	mods    []string
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
		return []inputAction{{kind: "key", text: name, mods: inputMods(b)}}
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
// remote_input is on.
func (d *Daemon) handleMousepad(dev *Device, p *proto.Packet) {
	d.mu.Lock()
	on := d.cfg.RemoteInput && d.input != nil
	warn := !on && !dev.inputRefused
	if !on {
		dev.inputRefused = true
	}
	d.mu.Unlock()
	if !on {
		if warn {
			d.logf("%s: ignored remote input, because remote_input is off", dev.Name)
		}
		return
	}
	var b mousepadBody
	if p.Decode(&b) != nil {
		return
	}
	monitor := d.desktopMonitor(dev.ID)
	for _, a := range inputActions(b) {
		if a.kind == "moveTo" {
			// A position is on the remote desktop that the phone shows.
			if monitor == "" {
				continue
			}
			a.monitor = monitor
		}
		select {
		case d.inputQ <- a:
		default:
			d.logf("%s: dropped remote input, because the desktop is slow", dev.Name)
			return
		}
	}
}

// inputLoop runs the input actions in order until ctx ends.
func (d *Daemon) inputLoop(ctx context.Context) {
	var lastErr string
	for {
		select {
		case <-ctx.Done():
			return
		case a := <-d.inputQ:
			err := d.runInput(a)
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

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (d *Daemon) runInput(a inputAction) error {
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
		return in.Type(a.text, a.mods)
	case "key":
		return in.Key(a.text, a.mods)
	}
	return nil
}

// sendInputState tells a phone whether this computer accepts remote input,
// and whether it shows its screen on the phone.
func (d *Daemon) sendInputState(l *lan.Link) {
	d.mu.Lock()
	on := d.cfg.RemoteInput && d.input != nil
	desktop := d.cfg.RemoteDesktop && !d.opts.Headless
	d.mu.Unlock()
	_ = l.Send(proto.New(proto.TypeFluxInput, map[string]any{"enabled": on, "desktop": desktop}))
}

// inputChanged sends the remote input state to each connected phone that
// accepts flux.input. It stops the remote desktop when its setting is off.
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
	d.mu.Unlock()
	for _, l := range links {
		d.sendInputState(l)
	}
	if !desktop {
		_ = d.StopDesktop()
	}
}
