package core

import (
	"bytes"
	"fmt"
	"maps"
	"slices"
	"strings"
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

// pairRetry is the time after a pair false, a reject, or a timeout in which
// fluxd refuses a new pair request of the device. An incoming request that
// ends with its link also starts the wait. A device on the network then
// cannot show its request again and again. A request of this computer that
// the device did not accept starts no wait, because the user of this
// computer sent it.
const pairRetry = 30 * time.Second

// maxConfirmQueue is the largest number of packets that fluxd keeps from a
// device while a pairing waits in state "confirm". The link of a device
// that is not paired reads at most 64 KiB per line, so the queue holds at
// most 2 MiB. fluxd drops the packets after the limit.
const maxConfirmQueue = 32

// maxIncoming is the number of incoming pair requests that can be open at
// the same time. fluxd refuses more, so that devices on the network cannot
// fill the desktop with pair notifications. maxIncomingPerIP is the part of
// 1 address, so that 1 host cannot hold every place.
const (
	maxIncoming      = 4
	maxIncomingPerIP = 2
)

// A pairing is bound to the link and the certificate on which it started:
// pairLink and pairCert of the device. The key that the user compares comes
// from pairCert. While the pairing is open, a new link for the device ID
// must show pairCert, or onLink refuses it. Pair packets count only on the
// current link, and fluxd pins pairCert only while pairLink is the current
// link. A pairing ends when its link goes away.
//
// The pair states of a device:
//
//   - "requested": this computer asked the device to pair and waits for
//     the answer.
//   - "confirm": the device accepted the request of this computer and
//     pinned this computer. fluxd pins the device only after the user of
//     this computer confirms the key, so that a device that copies the
//     name of a phone does not pair with 1 click.
//   - "incoming": the device asked to pair and waits for the user of this
//     computer.
//
// An accept or a reject can name the key that the user compared. It then
// counts only for the pairing with that key.

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
	// The new request replaces an open pairing and its notification.
	note := dev.clearPairingLocked()
	ts := time.Now().Unix()
	dev.pairState, dev.pairTime = "requested", ts
	dev.pairLink, dev.pairCert, dev.pairAt = l, l.Cert, time.Now()
	dev.pairKey = d.keyLocked(dev, ts)
	d.startPairTimerLocked(dev)
	key := dev.pairKey
	d.mu.Unlock()
	d.closeNotes(note)
	d.markDirty()
	return key, l.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts}))
}

// AcceptPair accepts the open pairing of a device: a pair request of the
// device, or a pairing in state "confirm". When key is not "", it accepts
// only the pairing with that key.
func (d *Daemon) AcceptPair(dev *Device, key string) error {
	_, err := d.acceptPair(dev, key)
	return err
}

// acceptPair accepts the open pairing of a device and returns its key.
// When want is not "", it accepts only the pairing with that key. It pins
// the certificate of the pairing under d.mu before it sends the answer, so
// only 1 call can accept a pairing. The link then reads the long lines of
// a paired device from the first packet after the answer. The pin needs
// the link of the pairing as the current link. In state "confirm", the
// device sent pair true already, so no answer goes out.
func (d *Daemon) acceptPair(dev *Device, want string) (string, error) {
	d.mu.Lock()
	l := dev.link
	state := dev.pairState
	if (state != "incoming" && state != "confirm") || l == nil || !dev.pairOnLocked(l) {
		name := dev.Name
		d.mu.Unlock()
		return "", apiErr("no_request", "%s has no open pair request", name)
	}
	if want != "" && want != dev.pairKey {
		name := dev.Name
		d.mu.Unlock()
		return "", apiErr("no_request", "%s has no open pair request with the key %s", name, proto.FormatKey(want))
	}
	key, cert := dev.pairKey, dev.pairCert
	queued := dev.confirmQueue
	note, err := d.pinLocked(dev, l)
	name := dev.Name
	d.mu.Unlock()
	d.closeNotes(note)
	if err != nil {
		d.logf("save trust: %v", err)
	}
	if state == "confirm" {
		d.pairedLink(dev, l, name)
		// The device sent these packets after its answer, while this
		// computer waited for the user.
		for _, p := range queued {
			d.handlePacket(dev, l, p)
		}
		return key, nil
	}
	if err := l.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		// The device did not get the answer, so the pin goes away again.
		var notes []uint32
		d.mu.Lock()
		if dev.Paired && dev.Cert.Equal(cert) {
			notes, _ = d.dropTrustLocked(dev)
		}
		d.mu.Unlock()
		d.closeNotes(notes...)
		d.markDirty()
		d.logf("%s: send the pair answer: %v", name, err)
		return "", err
	}
	d.pairedLink(dev, l, name)
	return key, nil
}

// RejectPair rejects the open pairing of a device, or cancels an outgoing
// request. When key is not "", it rejects only the pairing with that key.
// A paired device reads pair false as an unpair, so RejectPair sends it
// only while a pairing is open. A device that pinned this computer in state
// "confirm" then removes the pin.
func (d *Daemon) RejectPair(dev *Device, key string) error {
	d.mu.Lock()
	if dev.pairState == "" || (key != "" && key != dev.pairKey) {
		name := dev.Name
		d.mu.Unlock()
		return apiErr("no_request", "%s has no open pair request", name)
	}
	l, state := dev.link, dev.pairState
	note := dev.clearPairingLocked()
	if state != "requested" {
		dev.pairEnded = time.Now()
	}
	d.mu.Unlock()
	d.closeNotes(note)
	d.markDirty()
	if l == nil {
		return nil
	}
	return l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
}

// Unpair removes the trust, tells the device, and closes the link. No
// session of the device outlives the pairing. It returns the error of
// devices.json, because the device is paired again after a restart when
// the file keeps it.
func (d *Daemon) Unpair(dev *Device) error {
	d.mu.Lock()
	if !dev.Paired && !dev.badTrust {
		name := dev.Name
		d.mu.Unlock()
		return apiErr("not_paired", "%s is not paired", name)
	}
	l := dev.link
	note := dev.clearPairingLocked()
	notes, err := d.dropTrustLocked(dev)
	if l == nil {
		delete(d.devices, dev.ID)
	}
	name := dev.Name
	d.mu.Unlock()
	d.closeNotes(append(notes, note)...)
	d.clearDeviceOutbox(dev.ID)
	d.markDirty()
	if l != nil {
		if err := l.Send(proto.New(proto.TypePair, map[string]any{"pair": false})); err != nil {
			d.logf("%s: send unpair: %v", name, err)
		}
		l.Close()
	}
	if err != nil {
		return apiErr("not_saved", "%s is unpaired until fluxd restarts, because devices.json did not change: %v", name, err)
	}
	return nil
}

// dropTrustLocked removes the trust of a device in memory and in
// devices.json, and the data that the device shared. The trust store
// changes under d.mu, so that a new link sees the same state in memory and
// on disk. It returns the desktop notifications of the phone notifications
// of the device, which the caller closes with closeNotes after it unlocks
// d.mu. Their buttons no longer reach the device. It logs and returns the
// error of devices.json. The caller holds d.mu.
func (d *Daemon) dropTrustLocked(dev *Device) ([]uint32, error) {
	dev.Paired, dev.PairedAt, dev.badTrust = false, "", false
	dev.Addresses = nil
	dev.seenIP, dev.seenPort = "", 0
	dev.battery, dev.batteryLow = nil, false
	dev.notifications = nil
	notes := slices.Collect(maps.Values(dev.notifDesktop))
	dev.notifDesktop = map[string]uint32{}
	dev.conversations = map[int64]*Conversation{}
	dev.outbox = nil
	if dev.link != nil {
		dev.link.SetPaired(false)
	}
	err := d.trust.Remove(dev.ID)
	if err != nil {
		d.logf("save trust: %v", err)
	}
	return notes, err
}

// closeNotes closes desktop notifications of fluxd on the notification
// worker. An ID of 0 is no notification. The caller does not hold d.mu.
func (d *Daemon) closeNotes(ids ...uint32) {
	ids = slices.DeleteFunc(ids, func(id uint32) bool { return id == 0 })
	if d.notifier == nil || len(ids) == 0 {
		return
	}
	d.runNotify(func() {
		for _, id := range ids {
			_ = d.notifier.Close(id)
		}
	})
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
		note := dev.clearPairingLocked()
		var notes []uint32
		if paired {
			notes, _ = d.dropTrustLocked(dev)
		} else if state == "incoming" || state == "confirm" {
			// A device that ends a pairing waits before a new request
			// counts, so that it cannot withdraw and send its request in a
			// loop.
			dev.pairEnded = time.Now()
		}
		d.mu.Unlock()
		d.closeNotes(append(notes, note)...)
		switch {
		case paired:
			d.clearDeviceOutbox(dev.ID)
			// The device unpaired. The link ends, so no session of the
			// device outlives the pairing.
			l.Close()
			d.logf("%s unpaired this computer", name)
			d.toast("%s unpaired", name)
		case state == "requested":
			d.toast("%s rejected the pair request", name)
		case state == "confirm":
			d.toast("%s ended the pairing", name)
		}
		d.markDirty()
		return
	}

	switch state {
	case "requested":
		d.mu.Unlock()
		d.peerAccepted(dev, l)
		return
	case "confirm":
		// A repeated answer keeps the pairing.
		d.mu.Unlock()
		return
	}
	now := time.Now()
	if now.Sub(dev.pairAt) < pairCooldown || (state == "incoming" && body.Timestamp == dev.pairTime) {
		// A repeated request keeps the open request and its notification.
		d.mu.Unlock()
		return
	}
	// last is the time of the request before this one.
	last := dev.pairAt
	dev.pairAt = now
	var notes []uint32
	if paired {
		// The device lost its trust and asks again. Treat it as a new
		// request, so the user confirms the key again.
		notes, _ = d.dropTrustLocked(dev)
		defer d.clearDeviceOutbox(dev.ID)
	}
	ip := l.IP()
	refuse := ""
	skew := time.Since(time.Unix(body.Timestamp, 0))
	switch {
	case body.Timestamp == 0:
		refuse = "no timestamp"
	case skew > maxClockSkew || skew < -maxClockSkew:
		refuse = "clock"
	case now.Sub(dev.pairEnded) < pairRetry:
		refuse = "retry"
	case d.incomingLocked(dev, ip) >= maxIncomingPerIP:
		refuse = "address"
	case d.incomingLocked(dev, "") >= maxIncoming:
		refuse = "busy"
	}
	if refuse != "" {
		notes = append(notes, dev.clearPairingLocked())
		d.mu.Unlock()
		d.closeNotes(notes...)
		_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
		switch refuse {
		case "clock":
			d.toast("%s has a clock that differs by more than 30 minutes. Fix the time and pair again", name)
		case "retry":
			d.logf("%s: refused a pair request, because its last pairing ended less than %v ago", name, pairRetry)
		case "address", "busy":
			why := fmt.Sprintf("%d requests are open", maxIncoming)
			if refuse == "address" {
				why = fmt.Sprintf("%d requests from this address are open", maxIncomingPerIP)
			}
			d.logf("%s (%s): refused a pair request, because %s", name, ip, why)
			// A device that asks again and again gets 1 toast.
			if now.Sub(last) >= pairRetry {
				d.toast("Flux refused the pair request of %s (%s), because too many pair requests are open. Reject the other requests, or pair from this computer", name, ip)
			}
		}
		d.markDirty()
		return
	}
	dev.pairState, dev.pairTime = "incoming", body.Timestamp
	dev.pairLink, dev.pairCert = l, l.Cert
	dev.pairKey = d.keyLocked(dev, body.Timestamp)
	d.startPairTimerLocked(dev)
	// Tests change pairTimeout, so it is read under d.mu.
	key, replaces, timeout := dev.pairKey, dev.pairNote, pairTimeout
	d.mu.Unlock()
	d.closeNotes(notes...)
	// A new request of the device replaces its old notification, so each
	// device has at most 1.
	d.notifyPairing(dev, "incoming", key, desktop.Notification{
		AppName: "Flux", Title: name + " wants to pair",
		Body:    "Check that the device shows " + proto.FormatKey(key) + ". Open Flux to accept.",
		Actions: pairActions(dev.ID, key, "Accept"),
		Urgency: 1, Timeout: timeout, ReplacesID: replaces,
	})
	d.markDirty()
}

// peerAccepted moves a pairing that this computer asked for to state
// "confirm", after the device answered pair true on the link l. The device
// pinned this computer, but fluxd pins the device only after the user of
// this computer confirms the key.
func (d *Daemon) peerAccepted(dev *Device, l *lan.Link) {
	d.mu.Lock()
	name := dev.Name
	if dev.pairState != "requested" || dev.pairLink != l {
		// The answer counts only for an open request, and only on the link
		// of the request.
		d.mu.Unlock()
		return
	}
	if !dev.pairOnLocked(l) {
		note := dev.clearPairingLocked()
		d.mu.Unlock()
		d.closeNotes(note)
		_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
		d.markDirty()
		d.logf("%s: the link changed during the pairing, so fluxd pinned nothing", name)
		d.toast("The connection of %s changed during the pairing. Pair again", name)
		return
	}
	dev.pairState = "confirm"
	d.startPairTimerLocked(dev)
	key, timeout := dev.pairKey, pairTimeout
	d.mu.Unlock()
	d.notifyPairing(dev, "confirm", key, desktop.Notification{
		AppName: "Flux", Title: "Confirm the pairing with " + name,
		Body:    name + " accepted. Check that it shows " + proto.FormatKey(key) + ".",
		Actions: pairActions(dev.ID, key, "Confirm"),
		Urgency: 1, Timeout: timeout,
	})
	d.markDirty()
}

// pairActions returns the buttons of a pair notification. Each action key
// names the device and the key of the pairing, so that a click counts only
// for the pairing that the notification showed.
func pairActions(id, key, accept string) []desktop.Action {
	return []desktop.Action{
		{Key: "pair-accept:" + id + ":" + key, Label: accept},
		{Key: "pair-reject:" + id + ":" + key, Label: "Reject"},
	}
}

// notifyPairing shows the desktop notification of the pairing with state
// and key, and keeps its ID in pairNote. When the pairing ended during the
// call, the notification closes again.
func (d *Daemon) notifyPairing(dev *Device, state, key string, n desktop.Notification) {
	id := d.notify(n)
	if id == 0 {
		return
	}
	d.mu.Lock()
	current := dev.pairState == state && dev.pairKey == key
	if current {
		dev.pairNote = id
	}
	d.mu.Unlock()
	if !current {
		d.closeNotes(id)
	}
}

// incomingLocked counts the open incoming pair requests of the devices
// other than dev. When ip is not "", it counts only the requests from that
// address. The caller holds d.mu.
func (d *Daemon) incomingLocked(dev *Device, ip string) int {
	n := 0
	for _, o := range d.devices {
		if o == dev || o.pairState != "incoming" {
			continue
		}
		if ip == "" || (o.pairLink != nil && o.pairLink.IP() == ip) {
			n++
		}
	}
	return n
}

// pairOnLocked reports whether l is the link of the open pairing, the
// current link of the device, and the link that shows the certificate of
// the pairing. The caller holds d.mu.
func (dev *Device) pairOnLocked(l *lan.Link) bool {
	cert := dev.pairCert
	return dev.link == l && dev.pairLink == l && cert != nil && l.Cert != nil && bytes.Equal(cert.Raw, l.Cert.Raw)
}

// pinLocked pins the certificate of the pairing and marks the device as
// paired. The link reads long lines before the trust changes. The caller
// holds d.mu and checked pairOnLocked(l). It returns the notification of
// the pairing, which the caller closes, and the error of the trust store
// on disk. The device is paired in memory also when the save fails.
func (d *Daemon) pinLocked(dev *Device, l *lan.Link) (uint32, error) {
	cert := dev.pairCert
	note := dev.clearPairingLocked()
	l.SetPaired(true)
	dev.Paired, dev.badTrust = true, false
	dev.Cert = cert
	dev.PairedAt = time.Now().Format("2006-01-02")
	dev.pairEnded, dev.unpairPeer, dev.unpairCert = time.Time{}, false, nil
	return note, d.trust.Put(config.TrustedDevice{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, LastIP: dev.IP, LastPort: dev.Port, PairedAt: dev.PairedAt,
		CertPEM: proto.CertPEM(cert),
	})
}

// pairedLink tells the user about a new pairing and sends the packets
// that a paired device expects on the link l. The caller does not hold
// d.mu.
func (d *Daemon) pairedLink(dev *Device, l *lan.Link, name string) {
	d.toast("✓ %s paired", name)
	d.markDirty()
	go d.onPairedLink(dev, l)
}

// pairCall runs a pairing method of the API. want is the key that the user
// compared, or "". The result names the device and the key that the method
// acted on, so that flux-cli can show them: the verification key of the
// pairing, and the fingerprint of the certificate of the device.
func (d *Daemon) pairCall(method string, dev *Device, want string) (any, error) {
	// The key can come in groups and in lower case.
	want = strings.ToUpper(strings.ReplaceAll(want, " ", ""))
	d.mu.Lock()
	key, fingerprint := dev.pairKey, proto.Fingerprint(dev.Cert)
	d.mu.Unlock()
	var err error
	switch method {
	case "pair.request":
		key, err = d.RequestPair(dev)
	case "pair.accept":
		// The key comes from the pairing that this call accepted, and not
		// from a pairing that replaced it after the read above.
		key, err = d.acceptPair(dev, want)
	case "pair.reject":
		err = d.RejectPair(dev, want)
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

// startPairTimerLocked ends the open pairing after pairTimeout. A new call
// restarts the time. The caller holds d.mu.
func (d *Daemon) startPairTimerLocked(dev *Device) {
	if dev.pairTimer != nil {
		dev.pairTimer.Stop()
	}
	var t *time.Timer
	t = time.AfterFunc(pairTimeout, func() {
		d.mu.Lock()
		// A timer that fired while a new pairing took its place does
		// nothing. t is read under d.mu, as it was written.
		if dev.pairTimer != t {
			d.mu.Unlock()
			return
		}
		state, l := dev.pairState, dev.pairLink
		if dev.link != l {
			l = nil
		}
		note := dev.clearPairingLocked()
		if state != "requested" {
			dev.pairEnded = time.Now()
		}
		name := dev.Name
		d.mu.Unlock()
		d.closeNotes(note)
		// The device of a pairing that this computer asked for waits for an
		// answer, or pinned this computer in state "confirm".
		if l != nil && state != "incoming" {
			_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
		}
		d.toast("Pairing with %s timed out", name)
		d.markDirty()
	})
	dev.pairTimer = t
}

// pairLinkEndedLocked ends the open pairing of the device, because the
// link of the pairing went away. A device that ends its incoming request
// in this way waits pairRetry, as after a pair false. A device that pinned
// this computer in state "confirm" gets pair false on its next link with
// the certificate of the pairing. It returns the desktop notification of
// the pairing, as clearPairingLocked does. The caller holds d.mu.
func (dev *Device) pairLinkEndedLocked() uint32 {
	switch dev.pairState {
	case "incoming":
		dev.pairEnded = time.Now()
	case "confirm":
		dev.unpairPeer, dev.unpairCert = true, dev.pairCert
	}
	return dev.clearPairingLocked()
}

// clearPairingLocked ends the open pairing of the device. It returns the
// desktop notification of the pairing, or 0. The caller closes it with
// closeNotes after it unlocks d.mu.
func (dev *Device) clearPairingLocked() uint32 {
	if dev.pairTimer != nil {
		dev.pairTimer.Stop()
		dev.pairTimer = nil
	}
	note := dev.pairNote
	dev.pairState, dev.pairKey, dev.pairTime = "", "", 0
	dev.pairLink, dev.pairCert, dev.pairNote = nil, nil, 0
	dev.confirmQueue = nil
	return note
}
