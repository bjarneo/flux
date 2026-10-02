package core

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

const approvalID1 = "12345678-1234-4123-8123-123456789abc"
const approvalID2 = "12345678-1234-4123-8123-123456789abd"

type approvalNotifierFake struct {
	notes        chan desktop.Notification
	beforeReturn func(uint32)
}

func (n *approvalNotifierFake) Show(note desktop.Notification) (uint32, error) {
	n.notes <- note
	if n.beforeReturn != nil {
		n.beforeReturn(42)
	}
	return 42, nil // exercise notification-server ID reuse
}
func (n *approvalNotifierFake) Close(uint32) error { return nil }

type approvalInputFake struct {
	fakeInput
	moveEntered    chan struct{}
	releaseEntered chan struct{}
	pressEntered   chan struct{}
	pressOnce      sync.Once
	moveOnce       sync.Once
	releaseOnce    sync.Once
	quarantined    atomic.Bool
}

func (f *approvalInputFake) MoveContext(ctx context.Context, x, y float64) error {
	if f.moveEntered != nil {
		f.moveOnce.Do(func() { close(f.moveEntered) })
		<-ctx.Done()
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Move(x, y)
}
func (f *approvalInputFake) MoveToContext(ctx context.Context, monitor string, x, y float64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.MoveTo(monitor, x, y)
}
func (f *approvalInputFake) ButtonContext(ctx context.Context, button uint32, pressed bool) error {
	if pressed && f.pressEntered != nil {
		_ = f.Button(button, true)
		f.pressOnce.Do(func() { close(f.pressEntered) })
		<-ctx.Done()
		return ctx.Err()
	}
	if !pressed && f.releaseEntered != nil {
		f.releaseOnce.Do(func() { close(f.releaseEntered) })
		<-ctx.Done()
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Button(button, pressed)
}
func (f *approvalInputFake) ScrollContext(ctx context.Context, x, y float64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Scroll(x, y)
}
func (f *approvalInputFake) TypeContext(ctx context.Context, text string, mods []string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Type(ctx, text, mods)
}
func (f *approvalInputFake) KeyContext(ctx context.Context, name string, mods []string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return f.Key(ctx, name, mods)
}
func (f *approvalInputFake) Quarantine() { f.quarantined.Store(true) }

func approvalFixture(t *testing.T) (*Daemon, *Device, *lan.Link, *approvalInputFake, *approvalNotifierFake, chan *proto.Packet) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	trust, err := config.LoadTrust()
	if err != nil {
		t.Fatal(err)
	}
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := trust.Put(config.TrustedDevice{ID: id, CertPEM: proto.CertPEM(cert.Leaf)}); err != nil {
		t.Fatal(err)
	}
	l := &lan.Link{Identity: proto.Identity{DeviceID: id, OutgoingCapabilities: []string{proto.TypeFluxInputRequestV2}}, Cert: cert.Leaf}
	dev := &Device{ID: id, Name: "Ohm", Paired: true, link: l, Cert: cert.Leaf}
	in := &approvalInputFake{}
	n := &approvalNotifierFake{notes: make(chan desktop.Notification, 32)}
	states := make(chan *proto.Packet, 64)
	ctx, cancel := context.WithCancel(context.Background())
	d := &Daemon{cfg: &config.Config{}, ctx: ctx, cert: cert, trust: trust, devices: map[string]*Device{id: dev}, input: in, inputQ: make(chan inputAction, inputQueue),
		inputNotify: n, logger: log.New(io.Discard, "", 0), inputStatusWriter: func(ctx context.Context, _ *lan.Link, p *proto.Packet) error {
			select {
			case states <- p:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}}
	t.Cleanup(func() { d.revokeInputLink(l, true); cancel() })
	return d, dev, l, in, n, states
}

func approvalRequest(id string, request bool) *proto.Packet {
	return proto.New(proto.TypeFluxInputRequestV2, map[string]any{"request": request, "requestId": id})
}

func awaitApprovalCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("input approval condition timed out")
}

func approveFixture(t *testing.T, d *Daemon, dev *Device, l *lan.Link, n *approvalNotifierFake, states chan *proto.Packet, id string) *inputApproval {
	t.Helper()
	d.handleInputApproval(dev, l, approvalRequest(id, true))
	select {
	case note := <-n.notes:
		if len(note.Actions) != 2 || note.Actions[0].Key != "input-approve:"+id || note.Actions[1].Key != "input-deny:"+id {
			t.Fatalf("actions: %+v", note.Actions)
		}
	case <-time.After(time.Second):
		t.Fatal("no approval notification")
	}
	var r *inputApproval
	awaitApprovalCondition(t, func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		r = d.inputRequests[l]
		return r != nil && r.notification == 42
	})
	d.onInputApprovalAction(42, "input-approve:"+id)
	awaitApprovalState(t, states, id, true)
	return r
}

func awaitApprovalState(t *testing.T, states chan *proto.Packet, id string, enabled bool) {
	t.Helper()
	select {
	case state := <-states:
		fields := state.Fields()
		if state.Type != proto.TypeFluxInput || len(fields) != 2 || fields["requestId"] != id || fields["enabled"] != enabled {
			t.Fatalf("state: %s %s", state.Type, state.Body)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("no correlated input state")
	}
}

func TestInputApprovalRejectsMalformedExactSchema(t *testing.T) {
	d, dev, l, _, n, _ := approvalFixture(t)
	for _, body := range []string{
		`{"request":true}`, `{"request":null,"requestId":"` + approvalID1 + `"}`,
		`{"request":1,"requestId":"` + approvalID1 + `"}`, `{"request":true,"requestId":"` + strings.ToUpper(approvalID1) + `"}`,
		`{"request":true,"requestId":"12345678-1234-3123-8123-123456789abc"}`,
		`{"request":true,"requestId":"` + approvalID1 + `","extra":0}`,
		`{"request":false,"request":true,"requestId":"` + approvalID1 + `"}`,
	} {
		d.handleInputApproval(dev, l, &proto.Packet{Type: proto.TypeFluxInputRequestV2, Body: json.RawMessage(body)})
	}
	p := approvalRequest(approvalID1, true)
	p.PayloadSize = 1
	d.handleInputApproval(dev, l, p)
	d.mu.Lock()
	pending := len(d.inputRequests)
	d.mu.Unlock()
	if pending != 0 || len(n.notes) != 0 {
		t.Fatal("malformed request admitted")
	}
}

func TestInputApprovalControlsOnlyCurrentLeaseAndDoesNotChangeSettings(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	if d.cfg.RemoteInput {
		t.Fatal("approval changed persistent setting")
	}
	d.handleMousepadLink(dev, l, mousepad(`{"key":"hello"}`))
	a := <-d.inputQ
	if a.approval != r || d.runApprovedInput(a) != nil {
		t.Fatal("approved action rejected")
	}
	d.handleMousepadLink(dev, l, mousepad(`{"key":"stale"}`))
	stale := <-d.inputQ
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, false))
	awaitApprovalState(t, states, approvalID1, false)
	if d.runApprovedInput(stale) == nil {
		t.Fatal("queued action survived cancellation")
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	for _, call := range in.calls {
		if strings.Contains(call, "stale") {
			t.Fatal("stale text typed")
		}
	}
}

func TestInputApprovalCapabilityCannotFallBackToPersistentInput(t *testing.T) {
	d, dev, l, _, _, _ := approvalFixture(t)
	d.cfg.RemoteInput = true
	dev.Outgoing = nil // simulate an in-band identity dropping v2
	d.handleMousepadLink(dev, l, mousepad(`{"singleclick":true}`))
	if len(d.inputQ) != 0 {
		t.Fatal("v2 peer bypassed approval with persistent setting")
	}
	legacy := &lan.Link{Identity: proto.Identity{DeviceID: dev.ID}, Cert: l.Cert}
	dev.link = legacy
	d.handleMousepadLink(dev, legacy, mousepad(`{"singleclick":true}`))
	if len(d.inputQ) != 2 || (<-d.inputQ).approval != nil {
		t.Fatal("legacy input compatibility changed")
	}
}

func TestInputApprovalNotificationReuseAndReplayCannotGrantLaterRequest(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, true))
	<-n.notes
	awaitApprovalCondition(t, func() bool { d.mu.Lock(); defer d.mu.Unlock(); return d.inputRequests[l].notification == 42 })
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, false))
	awaitApprovalState(t, states, approvalID1, false)
	d.handleInputApproval(dev, l, approvalRequest(approvalID2, true))
	<-n.notes
	awaitApprovalCondition(t, func() bool { d.mu.Lock(); defer d.mu.Unlock(); return d.inputRequests[l].notification == 42 })
	d.onInputApprovalAction(42, "input-approve:"+approvalID1)
	d.handleMousepadLink(dev, l, mousepad(`{"key":"stale approval"}`))
	if len(d.inputQ) != 0 {
		t.Fatal("old notification approved new request")
	}
	d.onInputApprovalAction(42, "input-approve:"+approvalID2)
	awaitApprovalState(t, states, approvalID2, true)
	d.handleInputApproval(dev, l, approvalRequest(approvalID2, false))
	awaitApprovalState(t, states, approvalID2, false)
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, true))
	if len(n.notes) != 0 {
		t.Fatal("request replay opened another notification")
	}
}

func TestInputApprovalRevokedPairingOrReplacementRejectsQueuedNativeAction(t *testing.T) {
	for _, change := range []string{"unpaired", "replacement", "pin removed"} {
		t.Run(change, func(t *testing.T) {
			d, dev, l, _, n, states := approvalFixture(t)
			approveFixture(t, d, dev, l, n, states, approvalID1)
			d.handleMousepadLink(dev, l, mousepad(`{"key":"late"}`))
			a := <-d.inputQ
			d.mu.Lock()
			switch change {
			case "unpaired":
				dev.Paired = false
			case "replacement":
				dev.link = &lan.Link{Cert: l.Cert}
			case "pin removed":
				_ = d.trust.Remove(dev.ID)
			}
			d.mu.Unlock()
			if d.runApprovedInput(a) == nil {
				t.Fatal("stale authority reached native input")
			}
		})
	}
}

func TestInputApprovalDeadlineStartsBeforeBlockedNotificationReturns(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	release := make(chan struct{})
	n.beforeReturn = func(uint32) { <-release }
	defer close(release)
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, true))
	<-n.notes
	d.mu.Lock()
	r := d.inputRequests[l]
	d.armInputExpiryLocked(r, 20*time.Millisecond)
	d.mu.Unlock()
	awaitApprovalState(t, states, approvalID1, false)
	if !r.dead.Load() {
		t.Fatal("blocked Notify postponed expiry")
	}
}

func TestInputApprovalEarlyNotificationCloseDeniesRequest(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	n.beforeReturn = d.onInputApprovalClosed
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, true))
	<-n.notes
	awaitApprovalState(t, states, approvalID1, false)
	d.onInputApprovalAction(42, "input-approve:"+approvalID1)
	if len(d.inputQ) != 0 {
		t.Fatal("closed notification granted control")
	}
}

func TestInputApprovalApprovedNotificationCloseDoesNotPoisonReusedID(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	approveFixture(t, d, dev, l, n, states, approvalID1)
	d.onInputApprovalClosed(42)
	d.mu.Lock()
	poisoned := !d.inputEarlyClosed[42].IsZero()
	d.mu.Unlock()
	if poisoned {
		t.Fatal("normal approved-notification closure was stored as early denial")
	}
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, false))
	awaitApprovalState(t, states, approvalID1, false)
	d.mu.Lock()
	d.inputEarlyClosed = map[uint32]time.Time{42: time.Now().Add(-2 * inputApprovalWindow)}
	d.mu.Unlock()
	approveFixture(t, d, dev, l, n, states, approvalID2)
}

func TestInputApprovalCancellationInterruptsEnteredNativeCallAndDrains(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	in.moveEntered = make(chan struct{})
	approveFixture(t, d, dev, l, n, states, approvalID1)
	go d.inputLoop(d.ctx)
	d.handleMousepadLink(dev, l, mousepad(`{"dx":1,"dy":1}`))
	select {
	case <-in.moveEntered:
	case <-time.After(time.Second):
		t.Fatal("native input did not start")
	}
	d.handleMousepadLink(dev, l, mousepad(`{"key":"queued"}`))
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, false))
	awaitApprovalState(t, states, approvalID1, false)
	d.mu.Lock()
	quarantined, draining := d.inputQuarantined, d.inputCleanup != nil
	d.mu.Unlock()
	if quarantined || draining {
		t.Fatal("cooperating native cancellation failed to drain")
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	for _, call := range in.calls {
		if strings.Contains(call, "queued") {
			t.Fatal("queued input ran after revocation")
		}
	}
}

func TestInputApprovalFailedHeldButtonCleanupQuarantinesLaterGrants(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	in.releaseEntered = make(chan struct{})
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	if err := d.runApprovedInput(inputAction{approval: r, kind: "button", button: desktop.BtnLeft, pressed: true}); err != nil {
		t.Fatal(err)
	}
	d.handleInputApproval(dev, l, approvalRequest(approvalID1, false))
	select {
	case <-in.releaseEntered:
	case <-time.After(time.Second):
		t.Fatal("button cleanup did not start")
	}
	d.handleInputApproval(dev, l, approvalRequest(approvalID2, true))
	awaitApprovalState(t, states, approvalID2, false)
	awaitApprovalState(t, states, approvalID1, false)
	d.mu.Lock()
	quarantined := d.inputQuarantined
	d.mu.Unlock()
	if !quarantined || !in.quarantined.Load() {
		t.Fatal("failed cleanup did not quarantine native input")
	}
	if len(n.notes) != 0 {
		t.Fatal("new grant offered while native cleanup was blocked")
	}
}

func TestInputOffRevokesTemporaryLeaseAndQueuedActions(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	d.handleMousepadLink(dev, l, mousepad(`{"key":"queued before off"}`))
	queued := <-d.inputQ
	d.inputChanged()
	if !r.dead.Load() {
		t.Fatal("input off retained temporary lease")
	}
	if d.runApprovedInput(queued) == nil {
		t.Fatal("input off revived queued native action")
	}
}

func TestApprovedClickAdmissionIsAtomicAtQueueCapacity(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	for len(d.inputQ) < cap(d.inputQ)-inputReserve-1 {
		d.inputQ <- inputAction{}
	}
	before := len(d.inputQ)
	d.handleMousepadLink(dev, l, mousepad(`{"singleclick":true}`))
	if len(d.inputQ) != before {
		t.Fatal("partial click entered near-full queue")
	}
	if !r.dead.Load() {
		t.Fatal("queue overflow did not revoke lease")
	}
}

func TestKeyboardOnlyLeaseDoesNotReleaseNativeButtonsOrOpenPointer(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	_ = in.Button(desktop.BtnLeft, true) // a drag held by the existing native path
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	if err := d.runApprovedInput(inputAction{approval: r, kind: "type", text: "only keyboard"}); err != nil {
		t.Fatal(err)
	}
	d.endInputApproval(r)
	awaitApprovalState(t, states, approvalID1, false)
	got := in.got()
	if len(got) != 2 || got[0] != "button 0x110 true" || !strings.HasPrefix(got[1], "type ") {
		t.Fatalf("foreign button touched: %v", got)
	}
	d.mu.Lock()
	quarantined := d.inputQuarantined
	d.mu.Unlock()
	if quarantined || in.quarantined.Load() {
		t.Fatal("unused pointer caused quarantine")
	}
}

func TestLeaseRevocationReleasesOnlyItsHeldButton(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	_ = in.Button(desktop.BtnRight, true) // a different client holds this button
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	if err := d.runApprovedInput(inputAction{approval: r, kind: "button", button: desktop.BtnLeft, pressed: true}); err != nil {
		t.Fatal(err)
	}
	d.endInputApproval(r)
	awaitApprovalState(t, states, approvalID1, false)
	got := in.got()
	if len(got) != 3 || got[0] != "button 0x111 true" || got[1] != "button 0x110 true" || got[2] != "button 0x110 false" {
		t.Fatalf("button ownership changed: %v", got)
	}
}

func TestCancellationDuringEnteredPressCompensatesPartialNativeEffect(t *testing.T) {
	d, dev, l, in, n, states := approvalFixture(t)
	in.pressEntered = make(chan struct{})
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	done := make(chan error, 1)
	go func() {
		done <- d.runApprovedInput(inputAction{approval: r, kind: "button", button: desktop.BtnLeft, pressed: true})
	}()
	select {
	case <-in.pressEntered:
	case <-time.After(time.Second):
		t.Fatal("native press did not enter")
	}
	d.endInputApproval(r)
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled press succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("native press did not cancel")
	}
	awaitApprovalState(t, states, approvalID1, false)
	got := in.got()
	if len(got) != 2 || got[0] != "button 0x110 true" || got[1] != "button 0x110 false" {
		t.Fatalf("partial press not released: %v", got)
	}
}
