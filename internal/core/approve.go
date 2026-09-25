package core

// fluxd carries approval and enrollment requests between the flux-approve
// helper, the flux CLI, and the phone. It checks the format of each field,
// but it does not check signatures and it cannot make them: the helper
// checks each signature with the key file that only root can change.
// docs/approve.md is the security design.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"sync"
	"time"

	"flux/internal/approve"
	"flux/internal/proto"
)

// The wait for the phone, in seconds. config.toml sets approve_timeout.
const (
	approveMinTimeout     = 5
	approveDefaultTimeout = 20
	approveMaxTimeout     = 120
	enrollTimeout         = 120
)

// waitSlice is the longest time 1 approve.wait call blocks. A longer wait
// returns the state "pending", and the client calls again. The flux CLI
// gives up on a call after 60 seconds.
var waitSlice = 50 * time.Second

// approvalResult is the answer of the phone, as approve.wait returns it.
type approvalResult struct {
	State     string `json:"state"`
	Signature string `json:"signature,omitempty"`
	PublicKey string `json:"publicKey,omitempty"`
	Message   string `json:"message,omitempty"`
}

type approval struct {
	id       string
	kind     string // "request" or "enroll"
	device   string
	deadline time.Time
	done     chan struct{}
	result   *approvalResult
}

// approvalBook holds the requests that wait for a phone.
type approvalBook struct {
	mu   sync.Mutex
	byID map[string]*approval
}

// add stores a new request. A phone has at most 1 request at a time.
func (b *approvalBook) add(a *approval) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.byID == nil {
		b.byID = map[string]*approval{}
	}
	// A request whose helper stopped before approve.wait stays until here.
	for id, other := range b.byID {
		if time.Since(other.deadline) > time.Minute {
			delete(b.byID, id)
		}
	}
	for _, other := range b.byID {
		if other.device == a.device && other.result == nil && time.Now().Before(other.deadline) {
			return apiErr("busy", "Another request waits for this phone")
		}
	}
	a.done = make(chan struct{})
	b.byID[a.id] = a
	return nil
}

// deliver stores the answer of a phone. It accepts only an answer from the
// phone that got the request, of the kind that the request expects, and
// only once.
func (b *approvalBook) deliver(device, id string, r approvalResult) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	a := b.byID[id]
	if a == nil || a.device != device || a.result != nil {
		return false
	}
	switch r.State {
	case "approved":
		if a.kind != "request" {
			return false
		}
	case "enrolled":
		if a.kind != "enroll" {
			return false
		}
	}
	a.result = &r
	close(a.done)
	return true
}

// wait blocks until the phone answers, the request expires, or slice ends.
// An expired request returns expired true, and the caller cancels it on
// the phone.
func (b *approvalBook) wait(ctx context.Context, id string, slice time.Duration) (res approvalResult, device string, expired bool, err error) {
	b.mu.Lock()
	a := b.byID[id]
	b.mu.Unlock()
	if a == nil {
		return res, "", false, apiErr("not_found", "No request with ID %s", id)
	}
	limit := time.Until(a.deadline)
	pending := limit > slice
	if pending {
		limit = slice
	}
	t := time.NewTimer(max(limit, 0))
	defer t.Stop()
	select {
	case <-a.done:
		b.remove(id)
		return *a.result, a.device, false, nil
	case <-t.C:
		if pending {
			return approvalResult{State: "pending"}, a.device, false, nil
		}
		b.remove(id)
		return res, a.device, true, apiErr("timeout", "The phone did not answer in time")
	case <-ctx.Done():
		return res, a.device, false, ctx.Err()
	}
}

func (b *approvalBook) remove(id string) (device string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if a := b.byID[id]; a != nil {
		device = a.device
		delete(b.byID, id)
	}
	return device
}

type approveParams struct {
	ID      string `json:"id"`
	Device  string `json:"device"`
	Host    string `json:"host"`
	User    string `json:"user"`
	Service string `json:"service"`
	TTY     string `json:"tty"`
	RHost   string `json:"rhost"`
	Time    int64  `json:"time"`
	Nonce   string `json:"nonce"`
}

func newApprovalID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// approveTimeout returns approve_timeout in seconds, from 5 to 120.
func (d *Daemon) approveTimeout() int {
	d.mu.Lock()
	t := d.cfg.ApproveTimeout
	d.mu.Unlock()
	if t == 0 {
		t = approveDefaultTimeout
	}
	return min(max(t, approveMinTimeout), approveMaxTimeout)
}

// approveDevice returns a paired and connected phone that takes flux.approve.
func (d *Daemon) approveDevice(dev *Device) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !dev.Paired {
		return apiErr("not_paired", "%s is not paired", dev.Name)
	}
	if dev.link == nil {
		return offline(dev)
	}
	if !dev.accepts(proto.TypeFluxApprove) {
		return apiErr("unsupported", "Update Flux for Android on %s to approve with a fingerprint", dev.Name)
	}
	return nil
}

// ApproveRequest sends an approval request to the phone in the key file.
func (d *Daemon) ApproveRequest(raw json.RawMessage) (any, error) {
	var p approveParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, apiErr("bad_params", "params: %v", err)
	}
	req := approve.Request{Host: p.Host, User: p.User, Service: p.Service, TTY: p.TTY, RHost: p.RHost, Time: p.Time, Nonce: p.Nonce}
	if _, err := req.Message(); err != nil {
		return nil, apiErr("bad_params", "%v", err)
	}
	d.mu.Lock()
	dev := d.devices[p.Device]
	d.mu.Unlock()
	if dev == nil {
		return nil, apiErr("not_found", "The phone of the key is not known to fluxd")
	}
	if err := d.approveDevice(dev); err != nil {
		return nil, err
	}
	timeout := d.approveTimeout()
	a := &approval{id: newApprovalID(), kind: "request", device: dev.ID, deadline: time.Now().Add(time.Duration(timeout) * time.Second)}
	if err := d.approvals.add(a); err != nil {
		return nil, err
	}
	body := map[string]any{
		"kind": "request", "id": a.id, "host": req.Host, "user": req.User, "service": req.Service,
		"tty": req.TTY, "rhost": req.RHost, "time": req.Time, "nonce": req.Nonce, "timeout": timeout,
	}
	if err := d.send(dev, proto.New(proto.TypeFluxApprove, body)); err != nil {
		d.approvals.remove(a.id)
		return nil, err
	}
	d.logf("approval: %s for %s asks %s", req.Service, req.User, dev.Name)
	return map[string]any{"id": a.id, "timeout": timeout, "name": dev.Name}, nil
}

// ApproveEnroll asks a phone to make a key for approvals.
func (d *Daemon) ApproveEnroll(raw json.RawMessage) (any, error) {
	var p approveParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, apiErr("bad_params", "params: %v", err)
	}
	e := approve.Enrollment{Host: p.Host, User: p.User, Time: p.Time, Nonce: p.Nonce}
	if _, err := e.Message(nil); err != nil {
		return nil, apiErr("bad_params", "%v", err)
	}
	dev, err := d.pick(p.Device)
	if err != nil {
		return nil, err
	}
	if err := d.approveDevice(dev); err != nil {
		return nil, err
	}
	a := &approval{id: newApprovalID(), kind: "enroll", device: dev.ID, deadline: time.Now().Add(enrollTimeout * time.Second)}
	if err := d.approvals.add(a); err != nil {
		return nil, err
	}
	body := map[string]any{
		"kind": "enroll", "id": a.id, "host": e.Host, "user": e.User, "time": e.Time, "nonce": e.Nonce, "timeout": enrollTimeout,
	}
	if err := d.send(dev, proto.New(proto.TypeFluxApprove, body)); err != nil {
		d.approvals.remove(a.id)
		return nil, err
	}
	d.logf("approval: enrollment for %s asks %s", e.User, dev.Name)
	return map[string]any{"id": a.id, "device": dev.ID, "name": dev.Name, "timeout": enrollTimeout}, nil
}

// ApproveWait waits for the answer of the phone. An expired request is
// cancelled on the phone.
func (d *Daemon) ApproveWait(ctx context.Context, id string) (any, error) {
	res, device, expired, err := d.approvals.wait(ctx, id, waitSlice)
	if expired {
		d.cancelApproval(device, id)
	}
	if err != nil {
		return nil, err
	}
	return res, nil
}

// ApproveCancel ends a request and closes it on the phone.
func (d *Daemon) ApproveCancel(id string) error {
	device := d.approvals.remove(id)
	if device == "" {
		return apiErr("not_found", "No request with ID %s", id)
	}
	d.cancelApproval(device, id)
	return nil
}

func (d *Daemon) cancelApproval(device, id string) {
	d.mu.Lock()
	dev := d.devices[device]
	d.mu.Unlock()
	if dev != nil {
		_ = d.send(dev, proto.New(proto.TypeFluxApprove, map[string]any{"kind": "cancel", "id": id}))
	}
}

// handleApprove takes the answer of a phone.
func (d *Daemon) handleApprove(dev *Device, p *proto.Packet) {
	var b struct {
		Kind      string `json:"kind"`
		ID        string `json:"id"`
		Denied    bool   `json:"denied"`
		Signature string `json:"signature"`
		PublicKey string `json:"publicKey"`
		Error     string `json:"error"`
	}
	if p.Decode(&b) != nil || b.ID == "" {
		return
	}
	var r approvalResult
	switch {
	case b.Kind == "response" && b.Denied:
		r = approvalResult{State: "denied"}
	case b.Kind == "response" && b.Error != "":
		r = approvalResult{State: "failed", Message: cleanMessage(b.Error)}
	case b.Kind == "response" && validBase64(b.Signature, 128):
		r = approvalResult{State: "approved", Signature: b.Signature}
	case b.Kind == "enrolled" && validBase64(b.Signature, 128) && validBase64(b.PublicKey, 256):
		r = approvalResult{State: "enrolled", Signature: b.Signature, PublicKey: b.PublicKey}
	default:
		d.logf("approval: %s sent an answer that fluxd does not know", dev.Name)
		return
	}
	if !d.approvals.deliver(dev.ID, b.ID, r) {
		d.logf("approval: %s answered a request that does not wait", dev.Name)
	}
}

// validBase64 reports whether s is standard base64 of at most n bytes.
func validBase64(s string, n int) bool {
	if s == "" {
		return false
	}
	b, err := base64.StdEncoding.DecodeString(s)
	return err == nil && len(b) > 0 && len(b) <= n
}

// cleanMessage keeps an error text of the phone short and on 1 line.
func cleanMessage(s string) string {
	if approve.CheckField("error", s) != nil {
		return "The phone could not approve the request"
	}
	return s
}
