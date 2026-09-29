package core

import (
	"bytes"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// pairTimeout is how long a pair request stays open. Tests make it
// shorter.
var pairTimeout = 30 * time.Second

// maxClockSkew is the largest difference between the pair timestamp and the
// local clock that Flux accepts.
const maxClockSkew = 30 * time.Minute

// pairCooldown is the shortest time between 2 pair requests of 1 device.
// fluxd ignores a request that comes sooner.
const pairCooldown = 2 * time.Second

// maxIncoming is the number of incoming pair requests that can be open at
// the same time. fluxd refuses more, so that devices on the network cannot
// fill the desktop with pair notifications.
const maxIncoming = 4

// A pairing is bound to the link and the certificate on which it started:
// pairLink and pairCert of the device. The key that the user compares comes
// from pairCert. While the pairing is open, a new link for the device ID
// must show pairCert, or onLink refuses it. Pair packets count only on the
// current link, and fluxd pins pairCert only while pairLink is the current
// link. A pairing ends when its link goes away.

// RequestPair asks a device to pair and returns the verification key.
func (d *Daemon) RequestPair(dev *Device) (string, error) {
	d.mu.Lock()
	l := dev.link
	if l == nil {
		err := offline(dev)
		d.mu.Unlock()
		return "", err
	}
	if dev.Paired {
		name := dev.Name
		d.mu.Unlock()
		return "", apiErr("paired", "%s is already paired", name)
	}
	ts := time.Now().Unix()
	dev.pairState, dev.pairTime = "requested", ts
	dev.pairLink, dev.pairCert, dev.pairAt = l, l.Cert, time.Now()
	dev.pairKey = d.keyLocked(dev, ts)
	d.startPairTimerLocked(dev)
	key := dev.pairKey
	d.mu.Unlock()
	d.markDirty()
	return key, l.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts}))
}

// AcceptPair accepts a pair request from a device. It pins the certificate
// of the request, and only while the link of the request is the current
// link of the device.
func (d *Daemon) AcceptPair(dev *Device) error {
	d.mu.Lock()
	l := dev.link
	if dev.pairState != "incoming" || l == nil || dev.pairLink != l {
		name := dev.Name
		d.mu.Unlock()
		return apiErr("no_request", "%s has no open pair request", name)
	}
	d.mu.Unlock()
	if err := l.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		return err
	}
	if err := d.pairingDone(dev, l); err != nil {
		// The link changed after the answer, so the device must not count
		// on the pairing.
		_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
		return err
	}
	return nil
}

// RejectPair rejects a pair request, or cancels an outgoing request. A
// paired device reads pair false as an unpair, so RejectPair sends it only
// while a request is open.
func (d *Daemon) RejectPair(dev *Device) error {
	d.mu.Lock()
	if dev.pairState == "" {
		name := dev.Name
		d.mu.Unlock()
		return apiErr("no_request", "%s has no open pair request", name)
	}
	l := dev.link
	dev.clearPairingLocked()
	d.mu.Unlock()
	d.markDirty()
	if l == nil {
		return nil
	}
	return l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
}

// Unpair removes the trust, tells the device, and closes the link. No
// session of the device outlives the pairing.
func (d *Daemon) Unpair(dev *Device) error {
	d.mu.Lock()
	if !dev.Paired && !dev.badTrust {
		name := dev.Name
		d.mu.Unlock()
		return apiErr("not_paired", "%s is not paired", name)
	}
	l := dev.link
	dev.clearPairingLocked()
	d.dropTrustLocked(dev)
	if l == nil {
		delete(d.devices, dev.ID)
	}
	name := dev.Name
	d.mu.Unlock()
	d.markDirty()
	if l != nil {
		if err := l.Send(proto.New(proto.TypePair, map[string]any{"pair": false})); err != nil {
			d.logf("%s: send unpair: %v", name, err)
		}
		l.Close()
	}
	return nil
}

// dropTrustLocked removes the trust of a device in memory and in
// devices.json, and the data that the device shared. The trust store
// changes under d.mu, so that a new link sees the same state in memory and
// on disk. The caller holds d.mu.
func (d *Daemon) dropTrustLocked(dev *Device) {
	dev.Paired, dev.PairedAt, dev.badTrust = false, "", false
	dev.Addresses = nil
	dev.seenIP, dev.seenPort = "", 0
	dev.battery, dev.batteryLow = nil, false
	dev.notifications = nil
	dev.notifDesktop = map[string]uint32{}
	dev.conversations = map[int64]*Conversation{}
	if dev.link != nil {
		dev.link.SetPaired(false)
	}
	if err := d.trust.Remove(dev.ID); err != nil {
		d.logf("save trust: %v", err)
	}
}

// handlePair runs the pairing state machine for a flux.pair packet that
// arrived on the link l.
func (d *Daemon) handlePair(dev *Device, l *lan.Link, p *proto.Packet) {
	var body struct {
		Pair      bool  `json:"pair"`
		Timestamp int64 `json:"timestamp"`
	}
	if p.Decode(&body) != nil {
		return
	}
	d.mu.Lock()
	if l == nil || dev.link != l {
		// Pair packets count only on the current link of the device.
		d.mu.Unlock()
		return
	}
	state, paired, name := dev.pairState, dev.Paired, dev.Name

	if !body.Pair {
		dev.clearPairingLocked()
		if paired {
			d.dropTrustLocked(dev)
		}
		d.mu.Unlock()
		if paired {
			// The device unpaired. The link ends, so no session of the
			// device outlives the pairing.
			l.Close()
			d.toast("%s unpaired", name)
		} else if state == "requested" {
			d.toast("%s rejected the pair request", name)
		}
		d.markDirty()
		return
	}

	if state == "requested" {
		// The answer counts only on the link of the request.
		ours := dev.pairLink == l
		d.mu.Unlock()
		if ours {
			if err := d.pairingDone(dev, l); err != nil {
				d.toast("%v", err)
			}
		}
		return
	}
	now := time.Now()
	if now.Sub(dev.pairAt) < pairCooldown || (state == "incoming" && body.Timestamp == dev.pairTime) {
		// A repeated request keeps the open request and its notification.
		d.mu.Unlock()
		return
	}
	dev.pairAt = now
	if paired {
		// The device lost its trust and asks again. Treat it as a new
		// request, so the user confirms the key again.
		d.dropTrustLocked(dev)
	}
	refuse := ""
	skew := time.Since(time.Unix(body.Timestamp, 0))
	switch {
	case body.Timestamp == 0:
		refuse = "no timestamp"
	case skew > maxClockSkew || skew < -maxClockSkew:
		refuse = "clock"
	case d.incomingLocked(dev) >= maxIncoming:
		refuse = "busy"
	}
	if refuse != "" {
		dev.clearPairingLocked()
		d.mu.Unlock()
		_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
		switch refuse {
		case "clock":
			d.toast("%s has a clock that differs by more than 30 minutes. Fix the time and pair again", name)
		case "busy":
			d.logf("%s: refused a pair request, because %d requests are open", name, maxIncoming)
		}
		d.markDirty()
		return
	}
	dev.pairState, dev.pairTime = "incoming", body.Timestamp
	dev.pairLink, dev.pairCert = l, l.Cert
	dev.pairKey = d.keyLocked(dev, body.Timestamp)
	d.startPairTimerLocked(dev)
	key, replaces := dev.pairKey, dev.pairNote
	d.mu.Unlock()
	// A new request of the device replaces its old notification, so each
	// device has at most 1.
	id := d.notify(desktop.Notification{
		AppName: "Flux", Title: name + " wants to pair",
		Body:    "Check that the device shows " + proto.FormatKey(key) + ". Open Flux to accept.",
		Actions: []desktop.Action{{Key: "pair-accept:" + dev.ID, Label: "Accept"}, {Key: "pair-reject:" + dev.ID, Label: "Reject"}},
		Urgency: 1, Timeout: pairTimeout, ReplacesID: replaces,
	})
	if id != 0 {
		d.mu.Lock()
		dev.pairNote = id
		d.mu.Unlock()
	}
	d.markDirty()
}

// incomingLocked counts the open incoming pair requests of the devices
// other than dev. The caller holds d.mu.
func (d *Daemon) incomingLocked(dev *Device) int {
	n := 0
	for _, o := range d.devices {
		if o != dev && o.pairState == "incoming" {
			n++
		}
	}
	return n
}

// pairingDone pins the certificate of the pairing and marks the device as
// paired. It refuses when the link l is no longer the link of the pairing
// or the current link of the device.
func (d *Daemon) pairingDone(dev *Device, l *lan.Link) error {
	d.mu.Lock()
	cert := dev.pairCert
	if dev.link != l || dev.pairLink != l || cert == nil || l.Cert == nil || !bytes.Equal(cert.Raw, l.Cert.Raw) {
		dev.clearPairingLocked()
		name := dev.Name
		d.mu.Unlock()
		d.markDirty()
		d.logf("%s: the link changed during the pairing, so fluxd pinned nothing", name)
		return apiErr("no_request", "The connection of %s changed during the pairing. Pair again", name)
	}
	dev.clearPairingLocked()
	dev.Paired, dev.badTrust = true, false
	dev.Cert = cert
	dev.PairedAt = time.Now().Format("2006-01-02")
	t := config.TrustedDevice{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, LastIP: dev.IP, LastPort: dev.Port, PairedAt: dev.PairedAt,
		CertPEM: proto.CertPEM(cert),
	}
	err := d.trust.Put(t)
	l.SetPaired(true)
	name := dev.Name
	d.mu.Unlock()
	if err != nil {
		d.logf("save trust: %v", err)
	}
	d.toast("✓ %s paired", name)
	d.markDirty()
	go d.onPairedLink(dev, l)
	return nil
}

// pairCall runs a pairing method of the API. The result names the device
// and the key that the method acted on, so that flux-cli can show them:
// the verification key of the request, and the fingerprint of the
// certificate of the device.
func (d *Daemon) pairCall(method string, dev *Device) (any, error) {
	d.mu.Lock()
	key, fingerprint := dev.pairKey, proto.Fingerprint(dev.Cert)
	d.mu.Unlock()
	var err error
	switch method {
	case "pair.request":
		key, err = d.RequestPair(dev)
	case "pair.accept":
		err = d.AcceptPair(dev)
	case "pair.reject":
		err = d.RejectPair(dev)
	case "pair.unpair":
		err = d.Unpair(dev)
	}
	if err != nil {
		return nil, err
	}
	d.mu.Lock()
	name := dev.Name
	d.mu.Unlock()
	return map[string]any{"device": dev.ID, "name": name, "key": key, "fingerprint": fingerprint}, nil
}

func (d *Daemon) keyLocked(dev *Device, ts int64) string {
	if dev.pairCert == nil || d.cert.Leaf == nil {
		return ""
	}
	return proto.VerificationKey(d.cert.Leaf, dev.pairCert, ts)
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
		name := dev.Name
		d.mu.Unlock()
		if expired {
			d.toast("Pairing with %s timed out", name)
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
	dev.pairLink, dev.pairCert = nil, nil
}
