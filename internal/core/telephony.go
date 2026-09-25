package core

import (
	"slices"
	"strconv"
	"strings"
	"time"

	"flux/internal/desktop"
	"flux/internal/proto"
)

// callMedia is the part of the desktop players that call awareness uses.
// *desktop.Media implements it. Tests use a fake.
type callMedia interface {
	Players() []desktop.Player
	Action(name, action string) error
}

// callPause remembers the desktop players that fluxd paused for a call.
type callPause struct {
	paused []string
}

// pause pauses every player that plays and remembers it. A player that
// fluxd already paused for this call stays in the list once.
func (c *callPause) pause(m callMedia) {
	for _, pl := range m.Players() {
		if !pl.Playing || slices.Contains(c.paused, pl.Name) {
			continue
		}
		if m.Action(pl.Name, "Pause") == nil {
			c.paused = append(c.paused, pl.Name)
		}
	}
}

// resume plays the players that pause paused. A player that plays again,
// or that closed, stays as it is. The list is empty after the call.
func (c *callPause) resume(m callMedia) {
	names := c.paused
	c.paused = nil
	playing := map[string]bool{}
	for _, pl := range m.Players() {
		playing[pl.Name] = pl.Playing
	}
	for _, name := range names {
		if on, open := playing[name]; open && !on {
			_ = m.Action(name, "Play")
		}
	}
}

// callState is the call on 1 phone: the players that fluxd paused and the
// desktop notification that shows the call.
type callState struct {
	pause  callPause
	notice uint32
}

// callBody is the body of a kdeconnect.telephony packet.
type callBody struct {
	Event       string     `json:"event"`
	PhoneNumber string     `json:"phoneNumber"`
	ContactName string     `json:"contactName"`
	IsCancel    flexString `json:"isCancel"`
}

// caller returns the name to show for a call: the contact name, the
// number, or "Unknown caller".
func (b callBody) caller() string {
	if s := strings.TrimSpace(b.ContactName); s != "" {
		return s
	}
	if s := strings.TrimSpace(b.PhoneNumber); s != "" {
		return s
	}
	return "Unknown caller"
}

// handleTelephony follows the calls on a phone. While the phone rings or
// has a call, fluxd pauses the desktop players that play. When the call
// ends, it plays only those players again. A missed call gives a desktop
// notification.
func (d *Daemon) handleTelephony(dev *Device, p *proto.Packet) {
	var b callBody
	if p.Decode(&b) != nil {
		return
	}
	d.mu.Lock()
	if d.calls == nil {
		d.calls = map[string]*callState{}
	}
	c := d.calls[dev.ID]
	if c == nil {
		c = &callState{}
		d.calls[dev.ID] = c
	}
	pauseMedia := d.cfg.PauseMediaOnCall
	d.mu.Unlock()

	// Only the read loop of this device uses c, so the media calls, which
	// go over D-Bus, run without the daemon lock.
	m := d.callPlayers
	switch {
	case b.IsCancel.bool():
		// The call ended, or the phone stopped ringing.
		if m != nil {
			c.pause.resume(m)
		}
		if c.notice != 0 && d.notifier != nil {
			_ = d.notifier.Close(c.notice)
		}
		c.notice = 0
	case b.Event == "ringing" || b.Event == "talking":
		if pauseMedia && m != nil {
			c.pause.pause(m)
		}
		if b.Event == "talking" && c.notice != 0 && d.notifier != nil {
			// The user answered, so the ringing notification closes.
			_ = d.notifier.Close(c.notice)
			c.notice = 0
		}
		if b.Event == "ringing" {
			// A second ringing packet, with the number or the name, replaces
			// the first notification.
			c.notice = d.notify(desktop.Notification{
				AppName: dev.Name, Title: "Call from " + b.caller(), Body: callDetail(b, dev.Name),
				Category: "call.incoming", Urgency: 2, Timeout: -1, ReplacesID: c.notice,
			})
		}
	case b.Event == "missedCall":
		d.notify(desktop.Notification{
			AppName: dev.Name, Title: "Missed call from " + b.caller(), Body: callDetail(b, dev.Name),
			Category: "call.unanswered", Timeout: -1,
		})
	}
	d.logf("%s: call %s cancel=%v", dev.Name, b.Event, b.IsCancel.bool())
}

// callDetail is the body of a call notification: the number when the
// title shows the name, and the phone.
func callDetail(b callBody, phone string) string {
	if strings.TrimSpace(b.ContactName) != "" && strings.TrimSpace(b.PhoneNumber) != "" {
		return b.PhoneNumber + " · " + phone
	}
	return phone
}

// SendNotification shows a notification on a device. The device shows the
// name of this computer as the app name.
func (d *Daemon) SendNotification(dev *Device, title, body string) error {
	title = strings.TrimSpace(title)
	body = strings.TrimSpace(body)
	if title == "" {
		return apiErr("bad_params", "title is empty")
	}
	d.mu.Lock()
	accepts := dev.accepts(proto.TypeNotification)
	d.mu.Unlock()
	if !accepts {
		return apiErr("not_supported", "%s does not show notifications from this computer. Update Flux for Android", dev.Name)
	}
	now := time.Now()
	ticker := title
	if body != "" {
		ticker = title + ": " + body
	}
	return d.send(dev, proto.New(proto.TypeNotification, map[string]any{
		"id":          "flux-" + strconv.FormatInt(now.UnixNano(), 36),
		"appName":     d.Name(),
		"title":       title,
		"text":        body,
		"ticker":      ticker,
		"isClearable": true,
		"time":        strconv.FormatInt(now.UnixMilli(), 10),
	}))
}
