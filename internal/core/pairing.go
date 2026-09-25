package core

import (
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/proto"
)

// pairTimeout is how long a pair request stays open.
const pairTimeout = 30 * time.Second

// maxClockSkew is the largest difference between the pair timestamp and the
// local clock that Flux accepts.
const maxClockSkew = 30 * time.Minute

// RequestPair asks a device to pair.
func (d *Daemon) RequestPair(dev *Device) error {
	d.mu.Lock()
	if dev.link == nil {
		d.mu.Unlock()
		return offline(dev)
	}
	if dev.Paired {
		d.mu.Unlock()
		return apiErr("paired", "%s is already paired", dev.Name)
	}
	ts := time.Now().Unix()
	dev.pairState, dev.pairTime = "requested", ts
	dev.pairKey = d.keyLocked(dev, ts)
	d.startPairTimerLocked(dev)
	l := dev.link
	d.mu.Unlock()
	d.markDirty()
	return l.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts}))
}

// AcceptPair accepts a pair request from a device.
func (d *Daemon) AcceptPair(dev *Device) error {
	d.mu.Lock()
	if dev.pairState != "incoming" || dev.link == nil {
		d.mu.Unlock()
		return apiErr("no_request", "%s has no open pair request", dev.Name)
	}
	l := dev.link
	d.mu.Unlock()
	if err := l.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		return err
	}
	d.pairingDone(dev)
	return nil
}

// RejectPair rejects a pair request, or cancels an outgoing request.
func (d *Daemon) RejectPair(dev *Device) error {
	d.mu.Lock()
	l := dev.link
	dev.clearPairingLocked()
	d.mu.Unlock()
	d.markDirty()
	if l == nil {
		return nil
	}
	return l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
}

// Unpair removes the trust and tells the device.
func (d *Daemon) Unpair(dev *Device) error {
	d.mu.Lock()
	l := dev.link
	dev.Paired, dev.PairedAt = false, ""
	dev.clearPairingLocked()
	if l == nil {
		delete(d.devices, dev.ID)
	}
	d.mu.Unlock()
	_ = d.trust.Remove(dev.ID)
	d.markDirty()
	if l != nil {
		return l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
	}
	return nil
}

// handlePair runs the pairing state machine for a kdeconnect.pair packet.
func (d *Daemon) handlePair(dev *Device, p *proto.Packet) {
	var body struct {
		Pair      bool  `json:"pair"`
		Timestamp int64 `json:"timestamp"`
	}
	if p.Decode(&body) != nil {
		return
	}
	d.mu.Lock()
	state, paired, l := dev.pairState, dev.Paired, dev.link
	d.mu.Unlock()
	if l == nil {
		return
	}

	if !body.Pair {
		d.mu.Lock()
		dev.clearPairingLocked()
		wasPaired := dev.Paired
		dev.Paired, dev.PairedAt = false, ""
		d.mu.Unlock()
		if wasPaired {
			_ = d.trust.Remove(dev.ID)
			d.toast("%s unpaired", dev.Name)
		} else if state == "requested" {
			d.toast("%s rejected the pair request", dev.Name)
		}
		d.markDirty()
		return
	}

	if state == "requested" {
		d.pairingDone(dev)
		return
	}
	if paired {
		// The device lost its trust and asks again. Treat it as a new
		// request, so the user confirms the key again.
		d.mu.Lock()
		dev.Paired, dev.PairedAt = false, ""
		d.mu.Unlock()
		_ = d.trust.Remove(dev.ID)
	}
	if dev.Version >= 8 {
		if body.Timestamp == 0 {
			_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
			return
		}
		skew := time.Since(time.Unix(body.Timestamp, 0))
		if skew > maxClockSkew || skew < -maxClockSkew {
			_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
			d.toast("%s has a clock that differs by more than 30 minutes. Fix the time and pair again", dev.Name)
			return
		}
	}
	d.mu.Lock()
	dev.pairState, dev.pairTime = "incoming", body.Timestamp
	dev.pairKey = d.keyLocked(dev, body.Timestamp)
	d.startPairTimerLocked(dev)
	key := dev.pairKey
	d.mu.Unlock()
	d.notify(desktop.Notification{
		AppName: "Flux", Title: dev.Name + " wants to pair",
		Body:    "Check that the phone shows " + key + ". Open Flux to accept.",
		Actions: []desktop.Action{{Key: "pair-accept:" + dev.ID, Label: "Accept"}, {Key: "pair-reject:" + dev.ID, Label: "Reject"}},
		Urgency: 1, Timeout: pairTimeout,
	})
	d.markDirty()
}

func (d *Daemon) pairingDone(dev *Device) {
	d.mu.Lock()
	dev.clearPairingLocked()
	dev.Paired = true
	dev.PairedAt = time.Now().Format("2006-01-02")
	t := config.TrustedDevice{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, LastIP: dev.IP, LastPort: dev.Port, PairedAt: dev.PairedAt,
	}
	if dev.Cert != nil {
		t.CertPEM = proto.CertPEM(dev.Cert)
	}
	l := dev.link
	d.mu.Unlock()
	if err := d.trust.Put(t); err != nil {
		d.logf("save trust: %v", err)
	}
	d.toast("✓ %s paired", dev.Name)
	d.markDirty()
	if l != nil {
		d.onPairedLink(dev, l)
	}
}

func (d *Daemon) keyLocked(dev *Device, ts int64) string {
	if dev.Cert == nil {
		return ""
	}
	if dev.Version < 8 {
		ts = 0
	}
	return proto.VerificationKey(d.cert.Leaf, dev.Cert, ts)
}

func (d *Daemon) startPairTimerLocked(dev *Device) {
	if dev.pairTimer != nil {
		dev.pairTimer.Stop()
	}
	started := dev.pairTime
	dev.pairTimer = time.AfterFunc(pairTimeout, func() {
		d.mu.Lock()
		expired := dev.pairState != "" && dev.pairTime == started
		if expired {
			dev.clearPairingLocked()
		}
		d.mu.Unlock()
		if expired {
			d.toast("Pairing with %s timed out", dev.Name)
			d.markDirty()
		}
	})
}

func (dev *Device) clearPairingLocked() {
	if dev.pairTimer != nil {
		dev.pairTimer.Stop()
		dev.pairTimer = nil
	}
	dev.pairState, dev.pairKey, dev.pairTime = "", "", 0
}
