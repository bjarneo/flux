package core

import (
	"context"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// dndPoll is how often fluxd reads the Do Not Disturb state of the desktop.
// The Omarchy shell has no change event, and a read of its state file is
// cheap.
const dndPoll = 2 * time.Second

// dndSettle is how long fluxd waits for the desktop to report a state that
// a phone set. The Omarchy shell writes its state file 200 ms after a
// change.
const dndSettle = 3 * time.Second

// dndBackend is the Do Not Disturb of the desktop. desktop.DND implements it.
type dndBackend interface {
	Get() (on, ok bool)
	Set(on bool) error
}

// dndGuard keeps Do Not Disturb sync from sending a change back to the
// side that made it. known is the last state of this computer. A state from
// a phone sets known before fluxd applies it, so the poll that sees the
// state does not count it as a local change.
type dndGuard struct {
	known   bool
	valid   bool
	pending bool      // a state from a phone that the desktop does not report yet
	until   time.Time // the end of the wait for the pending state
}

// local takes a state that the desktop reports. It returns true when the
// state is a local change that the phones must get. The first state only
// sets the start value, because the start of fluxd is not a change.
func (g *dndGuard) local(on bool, now time.Time) bool {
	if g.pending {
		if on == g.known {
			g.pending = false
			return false
		}
		if now.Before(g.until) {
			// The desktop still reports the state from before the change.
			return false
		}
		// The change from the phone did not apply. The desktop state wins.
		g.pending = false
	}
	if !g.valid {
		g.known, g.valid = on, true
		return false
	}
	if on == g.known {
		return false
	}
	g.known = on
	return true
}

// remote takes a state from a phone. It returns true when fluxd must apply
// the state to the desktop.
func (g *dndGuard) remote(on bool, now time.Time) bool {
	if g.valid && on == g.known {
		return false
	}
	g.known, g.valid = on, true
	g.pending, g.until = true, now.Add(dndSettle)
	return true
}

// dndLoop reads the desktop state and sends each local change to the
// phones.
func (d *Daemon) dndLoop(ctx context.Context) {
	t := time.NewTicker(dndPoll)
	defer t.Stop()
	for {
		on, ok := d.dnd.Get()
		if ok {
			d.mu.Lock()
			send := d.dndGuard.local(on, time.Now()) && d.cfg.SyncDnd
			d.mu.Unlock()
			if send {
				d.logf("Do Not Disturb is %s on this computer", onOff(on))
				d.sendDnd(on, "")
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// handleDnd applies the Do Not Disturb state of a phone to this computer,
// and gives it to the other phones.
func (d *Daemon) handleDnd(dev *Device, p *proto.Packet) {
	var body struct {
		On *bool `json:"on"`
	}
	if p.Decode(&body) != nil || body.On == nil {
		return
	}
	on := *body.On
	d.mu.Lock()
	apply := d.dnd != nil && d.cfg.SyncDnd && d.dndGuard.remote(on, time.Now())
	d.mu.Unlock()
	if !apply {
		return
	}
	d.logf("%s turned Do Not Disturb %s", dev.Name, onOff(on))
	d.sendDnd(on, dev.ID)
	go func() {
		if err := d.dnd.Set(on); err != nil {
			d.logf("set Do Not Disturb: %v", err)
		}
	}()
}

// sendDnd sends the state to each paired phone that is connected and
// accepts flux.dnd, except the phone with the ID except.
func (d *Daemon) sendDnd(on bool, except string) {
	d.mu.Lock()
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.ID != except && dev.accepts(proto.TypeFluxDnd) {
			links = append(links, dev.link)
		}
	}
	d.mu.Unlock()
	for _, l := range links {
		_ = l.Send(proto.New(proto.TypeFluxDnd, map[string]any{"on": on}))
	}
}

func onOff(on bool) string {
	if on {
		return "on"
	}
	return "off"
}
