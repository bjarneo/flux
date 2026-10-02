package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

const inputApprovalWindow = 20 * time.Second
const inputApprovalLease = 5 * time.Minute
const inputOperationTimeout = 2 * time.Second

var inputRequestID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var inputNotificationSlots = make(chan struct{}, 4)
var inputStatusSlots = make(chan struct{}, 8)

type inputApprovalNotifier interface {
	Show(desktop.Notification) (uint32, error)
	Close(uint32) error
}

// Every production v2 native operation must honor revocation of its context.
type contextInputBackend interface {
	MoveContext(context.Context, float64, float64) error
	MoveToContext(context.Context, string, float64, float64) error
	ButtonContext(context.Context, uint32, bool) error
	ScrollContext(context.Context, float64, float64) error
	TypeContext(context.Context, string, []string) error
	KeyContext(context.Context, string, []string) error
}

type inputApproval struct {
	dev          *Device
	link         *lan.Link
	id           string
	name         string
	context      context.Context
	cancel       context.CancelFunc
	dead         atomic.Bool
	heldButtons  map[uint32]bool // guarded by inputEffects; never release another client's button
	status       sync.Mutex
	approved     bool // daemon mutex
	expires      time.Time
	timer        *time.Timer
	generation   uint64
	notification uint32
}

// Capability policy is captured at the authenticated handshake. An in-band
// identity change cannot switch an Ohm link back to the legacy setting path.
func inputApprovalPeer(l *lan.Link) bool {
	return l != nil && slices.Contains(l.Identity.OutgoingCapabilities, proto.TypeFluxInputRequestV2)
}

func parseInputRequest(p *proto.Packet) (request bool, id string, ok bool) {
	if p.Type != proto.TypeFluxInputRequestV2 || len(p.Body) > 256 || p.PayloadSize != 0 || p.PayloadTransferInfo != nil {
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(p.Body))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return
	}
	fields := map[string]json.RawMessage{}
	for decoder.More() {
		token, err = decoder.Token()
		key, valid := token.(string)
		if err != nil || !valid || (key != "request" && key != "requestId") || fields[key] != nil {
			return
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return
		}
		fields[key] = raw
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') || len(fields) != 2 {
		return
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return
	}
	if string(fields["request"]) != "true" && string(fields["request"]) != "false" {
		return
	}
	if json.Unmarshal(fields["request"], &request) != nil || json.Unmarshal(fields["requestId"], &id) != nil || !inputRequestID.MatchString(id) {
		return
	}
	return request, id, true
}

func (d *Daemon) inputNotifier() inputApprovalNotifier {
	if d.inputNotify != nil {
		return d.inputNotify
	}
	if d.notifier != nil {
		return d.notifier
	}
	return nil
}

// Called under d.mu; pin and pairing are checked again at approval, dispatch,
// and status delivery rather than trusting the original request admission.
func (d *Daemon) inputLinkCurrentLocked(dev *Device, l *lan.Link) bool {
	if d.ctx != nil && d.ctx.Err() != nil {
		return false
	}
	if dev == nil || l == nil || !dev.Paired || dev.link != l || d.devices[dev.ID] != dev ||
		l.Cert == nil || d.trust == nil {
		return false
	}
	select {
	case <-l.Done():
		return false
	default:
	}
	trusted, ok := d.trust.Get(dev.ID)
	if !ok {
		return false
	}
	pin, err := proto.ParseCertPEM(trusted.CertPEM)
	return err == nil && bytes.Equal(pin.Raw, l.Cert.Raw)
}

func (d *Daemon) inputApprovalCurrentLocked(r *inputApproval) bool {
	return r != nil && !r.dead.Load() && r.context.Err() == nil && d.inputRequests[r.link] == r &&
		d.inputLinkCurrentLocked(r.dev, r.link) && time.Now().Before(r.expires)
}

func (d *Daemon) armInputExpiryLocked(r *inputApproval, duration time.Duration) {
	if r.timer != nil {
		r.timer.Stop()
	}
	r.generation++
	generation := r.generation
	r.expires = time.Now().Add(duration)
	r.timer = time.AfterFunc(duration, func() {
		d.mu.Lock()
		expired := r.generation == generation && !r.dead.Load() && !time.Now().Before(r.expires)
		d.mu.Unlock()
		if expired {
			d.endInputApproval(r)
		}
	})
}

func (d *Daemon) handleInputApproval(dev *Device, l *lan.Link, p *proto.Packet) {
	request, id, valid := parseInputRequest(p)
	if !valid || !inputApprovalPeer(l) {
		return
	}
	d.mu.Lock()
	if !d.inputLinkCurrentLocked(dev, l) {
		d.mu.Unlock()
		return
	}
	if !request {
		r := d.inputRequests[l]
		d.mu.Unlock()
		if r != nil && r.id == id {
			d.endInputApproval(r)
		}
		return
	}
	if d.inputUsed == nil {
		d.inputUsed = map[*lan.Link]map[string]bool{}
	}
	if d.inputRequests == nil {
		d.inputRequests = map[*lan.Link]*inputApproval{}
	}
	used := d.inputUsed[l]
	if used == nil {
		used = map[string]bool{}
		d.inputUsed[l] = used
	}
	if used[id] {
		d.mu.Unlock()
		return
	}
	if len(used) >= 64 || len(d.inputRequests) >= 16 {
		d.mu.Unlock()
		l.Abort()
		return
	}
	used[id] = true
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithCancel(ctx)
	r := &inputApproval{dev: dev, link: l, id: id, name: dev.Name, context: ctx, cancel: cancel}
	prior := d.inputRequests[l]
	_, contextCapable := d.input.(contextInputBackend)
	available := prior == nil && contextCapable && d.inputNotifier() != nil && !d.inputQuarantined && d.inputCleanup == nil
	if available {
		d.inputRequests[l] = r
		d.armInputExpiryLocked(r, inputApprovalWindow)
	}
	d.mu.Unlock()
	if !available {
		r.dead.Store(true)
		cancel()
		d.postInputStatus(r)
		return
	}
	select {
	case inputNotificationSlots <- struct{}{}:
		go func() {
			defer func() { <-inputNotificationSlots }()
			notifier := d.inputNotifier()
			note, err := notifier.Show(desktop.Notification{AppName: "Flux", Title: "Allow desktop control from " + r.name + "?",
				Body:    "Allow this paired device to use the pointer and keyboard for five minutes. The approval ends when this connection closes.",
				Actions: []desktop.Action{{Key: "input-approve:" + id, Label: "Approve"}, {Key: "input-deny:" + id, Label: "Deny"}},
				Urgency: 2, Timeout: inputApprovalWindow})
			d.mu.Lock()
			r.notification = note
			closedAt := d.inputEarlyClosed[note]
			closedEarly := !closedAt.IsZero() && time.Since(closedAt) <= inputApprovalWindow
			delete(d.inputEarlyClosed, note)
			current := d.inputApprovalCurrentLocked(r)
			d.mu.Unlock()
			if err != nil || note == 0 || closedEarly || !current {
				d.endInputApproval(r)
				if note != 0 {
					_ = notifier.Close(note)
				}
			}
		}()
	default:
		d.endInputApproval(r)
	}
}

func (d *Daemon) onInputApprovalAction(notification uint32, key string) {
	d.mu.Lock()
	var found *inputApproval
	for _, r := range d.inputRequests {
		if notification == r.notification && notification != 0 &&
			(key == "input-approve:"+r.id || key == "input-deny:"+r.id) {
			found = r
			break
		}
	}
	if found == nil {
		d.mu.Unlock()
		return
	}
	r := found
	allow := key == "input-approve:"+r.id && d.inputApprovalCurrentLocked(r) && !r.approved &&
		d.inputOwner == nil && d.inputCleanup == nil && !d.inputQuarantined
	if allow {
		r.approved = true
		d.inputOwner = r
		d.armInputExpiryLocked(r, inputApprovalLease)
	}
	d.mu.Unlock()
	if allow {
		d.postInputStatus(r)
		d.closeInputNotification(r)
	} else {
		d.endInputApproval(r)
	}
}

func (d *Daemon) onInputApprovalClosed(notification uint32) {
	d.mu.Lock()
	var found *inputApproval
	matched := false
	showPending := false
	for _, r := range d.inputRequests {
		if r.notification == 0 && !r.approved {
			showPending = true
		}
		if r.notification == notification {
			matched = true
			if !r.approved {
				found = r
			}
			break
		}
	}
	if found == nil && !matched && showPending {
		if d.inputEarlyClosed == nil {
			d.inputEarlyClosed = map[uint32]time.Time{}
		}
		for id, closed := range d.inputEarlyClosed {
			if time.Since(closed) > inputApprovalWindow {
				delete(d.inputEarlyClosed, id)
			}
		}
		if len(d.inputEarlyClosed) < 128 {
			d.inputEarlyClosed[notification] = time.Now()
		}
	}
	d.mu.Unlock()
	if found != nil {
		d.endInputApproval(found)
	}
}

func (d *Daemon) closeInputNotification(r *inputApproval) {
	d.mu.Lock()
	note := r.notification
	notifier := d.inputNotifier()
	d.mu.Unlock()
	if note == 0 || notifier == nil {
		return
	}
	select {
	case inputNotificationSlots <- struct{}{}:
		go func() { defer func() { <-inputNotificationSlots }(); _ = notifier.Close(note) }()
	default:
	}
}

// Invalidate first, then join entered native effects without holding daemon
// state. A failed/blocked cleanup quarantines input and blocks later grants.
func (d *Daemon) endInputApproval(r *inputApproval) {
	if r == nil || !r.dead.CompareAndSwap(false, true) {
		return
	}
	r.cancel()
	d.finishRevokedInput(r)
}

func (d *Daemon) finishRevokedInput(r *inputApproval) {
	d.mu.Lock()
	if r.timer != nil {
		r.timer.Stop()
	}
	if d.inputRequests[r.link] == r {
		delete(d.inputRequests, r.link)
	}
	active := d.inputOwner == r
	if active {
		d.inputOwner = nil
	}
	var barrier chan struct{}
	if active {
		barrier = make(chan struct{})
		d.inputCleanup = barrier
	}
	d.mu.Unlock()
	d.closeInputNotification(r)
	if !active {
		d.postInputStatus(r)
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), inputOperationTimeout)
		defer cancel()
		drained := false
		for !d.inputEffects.TryLock() {
			select {
			case <-ctx.Done():
				goto finished
			case <-time.After(5 * time.Millisecond):
			}
		}
		drained = true
		if len(r.heldButtons) > 0 {
			if backend, ok := d.input.(contextInputBackend); ok {
				for _, button := range []uint32{desktop.BtnLeft, desktop.BtnRight, desktop.BtnMiddle} {
					if !r.heldButtons[button] {
						continue
					}
					if backend.ButtonContext(ctx, button, false) != nil {
						drained = false
						break
					}
					delete(r.heldButtons, button)
				}
			} else {
				drained = false
			}
		}
		d.inputEffects.Unlock()
	finished:
		if !drained {
			if backend, ok := d.input.(interface{ Quarantine() }); ok {
				backend.Quarantine()
			}
		}
		d.mu.Lock()
		if !drained {
			d.inputQuarantined = true
		}
		if d.inputCleanup == barrier {
			d.inputCleanup = nil
		}
		close(barrier)
		d.mu.Unlock()
		d.postInputStatus(r)
	}()
}

func (d *Daemon) revokeInputLink(l *lan.Link, forgetLedger bool) {
	d.mu.Lock()
	r := d.inputRequests[l]
	if forgetLedger {
		delete(d.inputUsed, l)
	}
	d.mu.Unlock()
	d.endInputApproval(r)
}

func (d *Daemon) postInputStatus(r *inputApproval) {
	select {
	case inputStatusSlots <- struct{}{}:
		go func() {
			defer func() { <-inputStatusSlots }()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			for !r.status.TryLock() {
				select {
				case <-ctx.Done():
					r.link.Abort()
					d.endInputApproval(r)
					return
				case <-time.After(5 * time.Millisecond):
				}
			}
			defer r.status.Unlock()
			d.mu.Lock()
			current := d.inputLinkCurrentLocked(r.dev, r.link)
			enabled := r.approved && d.inputApprovalCurrentLocked(r) && d.inputOwner == r && !d.inputQuarantined
			writer := d.inputStatusWriter
			d.mu.Unlock()
			if !current {
				return
			}
			if writer == nil {
				writer = func(ctx context.Context, l *lan.Link, p *proto.Packet) error {
					return l.SendWithinCurrent(ctx, p, func() bool {
						d.mu.Lock()
						defer d.mu.Unlock()
						return d.inputLinkCurrentLocked(r.dev, r.link) &&
							(!enabled || (r.approved && d.inputApprovalCurrentLocked(r) && d.inputOwner == r && !d.inputQuarantined))
					})
				}
			}
			if writer(ctx, r.link, proto.New(proto.TypeFluxInput, map[string]any{"enabled": enabled, "requestId": r.id})) != nil {
				r.link.Abort()
				d.endInputApproval(r)
			}
		}()
	default:
		r.link.Abort()
		d.endInputApproval(r)
	}
}

func (d *Daemon) handleApprovedMousepad(dev *Device, l *lan.Link, p *proto.Packet) {
	d.mu.Lock()
	r := d.inputRequests[l]
	on := r != nil && r.approved && d.inputOwner == r && d.inputApprovalCurrentLocked(r) && !d.inputQuarantined
	wasApproved := r != nil && r.approved
	d.mu.Unlock()
	if !on {
		if wasApproved {
			d.endInputApproval(r)
		}
		return
	}
	var b mousepadBody
	if p.Decode(&b) != nil {
		return
	}
	d.mu.Lock()
	monitor := ""
	if d.desktop != nil && d.desktop.dev.ID == dev.ID {
		monitor = d.desktop.view.Monitor
	}
	d.mu.Unlock()
	d.mu.Lock()
	if !d.inputApprovalCurrentLocked(r) || d.inputOwner != r {
		d.mu.Unlock()
		return
	}
	var actions []inputAction
	releases := true
	for _, a := range inputActions(b) {
		if a.kind == "moveTo" {
			if monitor == "" {
				continue
			}
			a.monitor = monitor
		}
		if a.kind != "button" || a.pressed {
			releases = false
		}
		a.approval = r
		actions = append(actions, a)
	}
	free := cap(d.inputQ) - len(d.inputQ)
	if !releases {
		free -= inputReserve
	}
	if len(actions) > free {
		d.mu.Unlock()
		d.endInputApproval(r)
		return
	}
	for _, a := range actions {
		d.inputQ <- a
	}
	d.mu.Unlock()
}

func (d *Daemon) runApprovedInput(a inputAction) error {
	r := a.approval
	ctx, cancel := context.WithTimeout(r.context, inputOperationTimeout)
	defer cancel()
	for !d.inputEffects.TryLock() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	defer d.inputEffects.Unlock()
	d.mu.Lock()
	on := r.approved && d.inputOwner == r && d.inputApprovalCurrentLocked(r) && !d.inputQuarantined
	d.mu.Unlock()
	if !on || ctx.Err() != nil {
		return context.Canceled
	}
	in, ok := d.input.(contextInputBackend)
	if !ok {
		return errors.New("native input cancellation unavailable")
	}
	switch a.kind {
	case "move":
		return in.MoveContext(ctx, a.dx, a.dy)
	case "moveTo":
		return in.MoveToContext(ctx, a.monitor, a.x, a.y)
	case "button":
		if a.pressed {
			if r.heldButtons == nil {
				r.heldButtons = map[uint32]bool{}
			}
			// Record the attempt before entering native IO: cancellation can return
			// an error after the compositor has already applied the press.
			r.heldButtons[a.button] = true
		} else if !r.heldButtons[a.button] {
			return nil
		}
		err := in.ButtonContext(ctx, a.button, a.pressed)
		if err == nil && !a.pressed {
			delete(r.heldButtons, a.button)
		}
		return err
	case "scroll":
		return in.ScrollContext(ctx, a.dx, a.dy)
	case "type":
		return in.TypeContext(ctx, a.text, a.mods)
	case "key":
		return in.KeyContext(ctx, a.text, a.mods)
	}
	return nil
}
