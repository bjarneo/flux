package core

// fluxd serves the ssh-agent protocol for the SSH keys of the phones. The
// private key stays in the Android Keystore of the phone. fluxd sends each
// sign request to the phone, and the phone signs only after its user
// approves with a fingerprint or the screen lock. fluxd checks each
// signature with the key of the phone before the client gets it.
// docs/ssh.md is the design.

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
	"flux/internal/sshagent"
)

// sshSignTimeout is the longest wait for a phone, from the start of the
// sign request. The phone closes its prompt at the same time.
var sshSignTimeout = 30 * time.Second

// sshLinkPoll is the time between 2 checks of the link during a sign
// request. A link that closes ends the request before its time limit.
var sshLinkPoll = 500 * time.Millisecond

// The longest public key and signature that fluxd takes from a phone, in
// bytes. An EC P-256 key in DER has 91 bytes, and its signature at most 72.
const (
	sshMaxKey       = 256
	sshMaxSignature = 128
)

// sshNoteGap is the shortest time between 2 desktop notifications of a
// failed signature.
const sshNoteGap = 10 * time.Second

// sshAnswer is the answer of a phone to a sign request.
type sshAnswer struct {
	signature []byte
	denied    bool
	err       string
}

type sshSign struct {
	id     string
	device string
	done   chan struct{}
	answer *sshAnswer
}

// sshBook holds the sign requests that wait for a phone. A phone gets 1
// request at a time. The next request waits for its turn within its own
// time limit.
type sshBook struct {
	mu     sync.Mutex
	byID   map[string]*sshSign
	turns  map[string]chan struct{}
	noteAt time.Time
}

// turn returns the channel that gives 1 request at a time to device.
func (b *sshBook) turn(device string) chan struct{} {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.turns == nil {
		b.turns = map[string]chan struct{}{}
	}
	t := b.turns[device]
	if t == nil {
		t = make(chan struct{}, 1)
		b.turns[device] = t
	}
	return t
}

func (b *sshBook) add(device string) *sshSign {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.byID == nil {
		b.byID = map[string]*sshSign{}
	}
	s := &sshSign{id: newApprovalID(), device: device, done: make(chan struct{})}
	b.byID[s.id] = s
	return s
}

func (b *sshBook) remove(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.byID, id)
}

// pending returns the number of sign requests that wait for a phone.
func (b *sshBook) pending() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.byID)
}

// deliver stores the answer of a phone. It accepts only an answer from the
// phone that got the request, and only once.
func (b *sshBook) deliver(device, id string, a sshAnswer) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := b.byID[id]
	if s == nil || s.device != device || s.answer != nil {
		return false
	}
	s.answer = &a
	close(s.done)
	return true
}

// noteDue reports whether a desktop notification of a failure can show
// now, and keeps the time when it can.
func (b *sshBook) noteDue(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.noteAt.IsZero() && now.Sub(b.noteAt) < sshNoteGap {
		return false
	}
	b.noteAt = now
	return true
}

// SetSSHAgent tells the daemon the path of its agent socket, or the error
// that stopped the socket.
func (d *Daemon) SetSSHAgent(path string, err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.sshSocket, d.sshSocketErr = path, ""
	if err != nil {
		d.sshSocket, d.sshSocketErr = "", err.Error()
	}
}

// sshPhonesLocked returns the paired, connected phones that offer an SSH
// key, sorted by name. The caller holds d.mu.
func (d *Daemon) sshPhonesLocked() []*Device {
	var out []*Device
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.sshKey != nil && dev.accepts(proto.TypeFluxSSH) {
			out = append(out, dev)
		}
	}
	slices.SortFunc(out, func(a, b *Device) int { return strings.Compare(a.Name+a.ID, b.Name+b.ID) })
	return out
}

// sshComment is the comment of the key of a phone in the agent list and
// in authorized_keys.
func sshComment(name string) string { return "Flux on " + name }

// SSHKeys returns the key of each connected phone that has one. The agent
// lists them.
func (d *Daemon) SSHKeys() []sshagent.Key {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []sshagent.Key
	for _, dev := range d.sshPhonesLocked() {
		out = append(out, sshagent.Key{Blob: dev.sshKey.Marshal(), Comment: sshComment(dev.Name)})
	}
	return out
}

// SSHKeyView is 1 key in the answer of ssh.keys.
type SSHKeyView struct {
	Device string `json:"device"`
	Name   string `json:"name"`
	// Key is the line for authorized_keys.
	Key string `json:"key"`
	// Fingerprint is the SHA-256 fingerprint, as ssh-add -l shows it.
	Fingerprint string `json:"fingerprint"`
}

// SSHView is the answer of ssh.keys: the agent socket and the keys of the
// connected phones.
type SSHView struct {
	Socket string       `json:"socket"`
	Error  string       `json:"error,omitempty"`
	Keys   []SSHKeyView `json:"keys"`
}

func (d *Daemon) sshView() SSHView {
	d.mu.Lock()
	defer d.mu.Unlock()
	v := SSHView{Socket: d.sshSocket, Error: d.sshSocketErr, Keys: []SSHKeyView{}}
	for _, dev := range d.sshPhonesLocked() {
		v.Keys = append(v.Keys, SSHKeyView{
			Device:      dev.ID,
			Name:        dev.Name,
			Key:         sshagent.AuthorizedKey(dev.sshKey, sshComment(dev.Name)),
			Fingerprint: ssh.FingerprintSHA256(dev.sshKey),
		})
	}
	return v
}

// requestSSHKey asks a phone for its SSH key at the start of a link.
func (d *Daemon) requestSSHKey(dev *Device, l *lan.Link) {
	d.mu.Lock()
	ok := dev.accepts(proto.TypeFluxSSH)
	d.mu.Unlock()
	if ok {
		_ = l.Send(proto.New(proto.TypeFluxSSH, map[string]any{"kind": "key"}))
	}
}

// SSHSign sends a sign request to the phone of keyBlob and waits for the
// signature. It fails at once when no connected phone has the key.
func (d *Daemon) SSHSign(ctx context.Context, keyBlob, data []byte, peer sshagent.Peer) (*ssh.Signature, error) {
	program := peer.Program
	if program == "" {
		program = "an unknown program"
	}
	what, err := sshagent.ParseData(data, keyBlob)
	if err != nil {
		d.logf("ssh agent: refused a sign request of %s: %v", program, err)
		return nil, err
	}
	d.mu.Lock()
	var dev *Device
	for _, p := range d.sshPhonesLocked() {
		if bytes.Equal(p.sshKey.Marshal(), keyBlob) {
			dev = p
			break
		}
	}
	var key ssh.PublicKey
	var spki, name string
	if dev != nil {
		key, spki, name = dev.sshKey, dev.sshSPKI, dev.Name
	}
	d.mu.Unlock()
	if dev == nil {
		return nil, d.sshFailed("No connected phone has this SSH key. Open Flux on the phone, and check that SSH key is on.")
	}

	ctx, cancel := context.WithTimeout(ctx, sshSignTimeout)
	defer cancel()
	turn := d.sshSigns.turn(dev.ID)
	select {
	case turn <- struct{}{}:
	case <-ctx.Done():
		return nil, d.sshEnded(ctx, name, program)
	}
	defer func() { <-turn }()

	s := d.sshSigns.add(dev.ID)
	defer d.sshSigns.remove(s.id)
	deadline, _ := ctx.Deadline()
	d.mu.Lock()
	l := dev.link
	d.mu.Unlock()
	body := map[string]any{
		"kind": "sign", "id": s.id, "key": spki, "data": base64.StdEncoding.EncodeToString(data),
		"program": peer.Program, "timeout": max(1, int(math.Ceil(time.Until(deadline).Seconds()))),
	}
	if err := d.send(dev, proto.New(proto.TypeFluxSSH, body)); err != nil {
		return nil, d.sshFailed("Flux could not reach %s: %v", name, err)
	}
	d.logf("ssh agent: %s asks %s for %s", program, name, what)

	tick := time.NewTicker(sshLinkPoll)
	defer tick.Stop()
	for {
		select {
		case <-s.done:
			return d.sshResult(key, data, name, *s.answer)
		case <-ctx.Done():
			d.sshCancel(dev, s.id)
			return nil, d.sshEnded(ctx, name, program)
		case <-tick.C:
			d.mu.Lock()
			same := dev.link == l && dev.Paired
			d.mu.Unlock()
			if !same {
				return nil, d.sshFailed("The link to %s closed before it signed", name)
			}
		}
	}
}

// sshEnded returns the error of a sign request whose context ended: the
// time limit, or a client that closed its connection.
func (d *Daemon) sshEnded(ctx context.Context, name, program string) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return d.sshFailed("%s did not answer in %d seconds", name, int(sshSignTimeout.Seconds()))
	}
	d.logf("ssh agent: %s stopped before %s signed", program, name)
	return errors.New("the client closed the connection")
}

// sshResult turns the answer of the phone into a signature, and checks it
// with the key of the phone.
func (d *Daemon) sshResult(key ssh.PublicKey, data []byte, name string, a sshAnswer) (*ssh.Signature, error) {
	switch {
	case a.denied:
		d.logf("ssh agent: %s denied the signature", name)
		return nil, fmt.Errorf("%s denied the signature", name)
	case a.err != "":
		return nil, d.sshFailed("%s: %s", name, a.err)
	}
	sig, err := sshagent.Signature(key, data, a.signature)
	if err != nil {
		return nil, d.sshFailed("%s: %v", name, err)
	}
	d.logf("ssh agent: %s signed", name)
	return sig, nil
}

// sshFailed logs a failed signature and shows it in a desktop
// notification, because the agent protocol has no error text. ssh and
// ssh-keygen only print "agent refused operation".
func (d *Daemon) sshFailed(format string, args ...any) error {
	text := fmt.Sprintf(format, args...)
	d.logf("ssh agent: %s", text)
	if d.sshSigns.noteDue(time.Now()) {
		d.notifyAsync(desktop.Notification{AppName: "Flux", Title: "SSH signature failed", Body: text})
	}
	return errors.New(text)
}

// sshCancel closes the sign request id on the phone.
func (d *Daemon) sshCancel(dev *Device, id string) {
	_ = d.send(dev, proto.New(proto.TypeFluxSSH, map[string]any{"kind": "cancel", "id": id}))
}

// handleSSH takes the key and the answers of a phone.
func (d *Daemon) handleSSH(dev *Device, p *proto.Packet) {
	var b struct {
		Kind      string `json:"kind"`
		ID        string `json:"id"`
		PublicKey string `json:"publicKey"`
		Signature string `json:"signature"`
		Denied    bool   `json:"denied"`
		Error     string `json:"error"`
	}
	if p.Decode(&b) != nil {
		return
	}
	switch b.Kind {
	case "key":
		d.setSSHKey(dev, b.PublicKey)
	case "signed":
		var a sshAnswer
		switch {
		case b.Denied:
			a.denied = true
		case b.Error != "":
			a.err = cleanSSHError(b.Error)
		default:
			der, err := base64.StdEncoding.DecodeString(b.Signature)
			if err != nil || len(der) == 0 || len(der) > sshMaxSignature {
				d.logf("ssh agent: %s sent a signature that fluxd does not take", d.nameOf(dev))
				a.err = "The phone sent a signature that does not parse"
			} else {
				a.signature = der
			}
		}
		if !d.sshSigns.deliver(dev.ID, b.ID, a) {
			d.logf("ssh agent: %s answered a request that does not wait", d.nameOf(dev))
		}
	}
}

// setSSHKey keeps the SSH key that a phone offers. An empty key means that
// the phone has no key.
func (d *Daemon) setSSHKey(dev *Device, spki string) {
	var key ssh.PublicKey
	var problem error
	if spki != "" {
		der, err := base64.StdEncoding.DecodeString(spki)
		switch {
		case err != nil:
			problem = err
		case len(der) > sshMaxKey:
			problem = fmt.Errorf("the key has %d bytes", len(der))
		default:
			key, problem = sshagent.KeyFromSPKI(der)
		}
		if problem != nil {
			key, spki = nil, ""
		}
	}
	d.mu.Lock()
	changed := (key == nil) != (dev.sshKey == nil) || key != nil && !bytes.Equal(key.Marshal(), dev.sshKey.Marshal())
	dev.sshKey, dev.sshSPKI = key, spki
	name := dev.Name
	d.mu.Unlock()
	switch {
	case problem != nil:
		d.logf("ssh agent: %s sent a key that fluxd does not take: %v", name, problem)
	case changed && key != nil:
		d.logf("ssh agent: %s offers the key %s", name, ssh.FingerprintSHA256(key))
	case changed:
		d.logf("ssh agent: %s offers no key", name)
	}
}

// cleanSSHError keeps an error text of the phone short and on 1 line.
func cleanSSHError(s string) string {
	if len(s) > 256 || !sshagent.ValidText(s) {
		return "The phone could not sign"
	}
	return s
}
