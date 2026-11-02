package core

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

// motionRig is a daemon with 1 paired phone on a real loopback link. The
// phone side collects the flux.motion bodies, and a motion receiver
// collects the events.
type motionRig struct {
	t      *testing.T
	d      *Daemon
	dev    *Device
	phone  chan motionBody
	mu     sync.Mutex
	events []motionEvent
}

func newMotionRig(t *testing.T) *motionRig {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	r := &motionRig{t: t, phone: make(chan motionBody, 64)}
	go onPhone.Receive(func(p *proto.Packet) {
		if p.Type != proto.TypeFluxMotion {
			return
		}
		var b motionBody
		if err := json.Unmarshal(p.Body, &b); err == nil {
			r.phone <- b
		}
	})
	d := testDaemon()
	d.ctx = ctx
	d.motion = newMotionState()
	d.cfg.MotionCues, d.cfg.MotionAuto = true, true
	r.dev = &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: onDesk,
		Incoming: []string{proto.TypeFluxMotion}, Outgoing: []string{proto.TypeFluxMotion}}
	d.devices[phoneID] = r.dev
	r.d = d
	d.SubscribeMotion(func(data any) {
		r.mu.Lock()
		r.events = append(r.events, data.(motionEvent))
		r.mu.Unlock()
	})
	return r
}

// next returns the next body that the phone got.
func (r *motionRig) next() motionBody {
	r.t.Helper()
	select {
	case b := <-r.phone:
		return b
	case <-time.After(5 * time.Second):
		r.t.Fatal("the phone got no flux.motion packet within 5 seconds")
		return motionBody{}
	}
}

// none checks that the phone gets no packet for a short time.
func (r *motionRig) none() {
	r.t.Helper()
	select {
	case b := <-r.phone:
		r.t.Fatalf("the phone got an unexpected packet %+v", b)
	case <-time.After(150 * time.Millisecond):
	}
}

func (r *motionRig) last() motionEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.events[len(r.events)-1]
}

// send delivers a flux.motion body from the phone.
func (r *motionRig) send(body any) {
	r.d.handleMotion(r.dev, r.dev.link, proto.New(proto.TypeFluxMotion, body))
}

func (r *motionRig) samples(t0 int64, n int, x float64) {
	list := make([]motionSample, n)
	for i := range list {
		list[i] = motionSample{T: t0 + int64(i)*33, X: x, Mount: "flat"}
	}
	r.send(map[string]any{"samples": list})
}

func (r *motionRig) running() bool {
	r.d.motion.mu.Lock()
	defer r.d.motion.mu.Unlock()
	return r.d.motion.running
}

func TestMotionStartSamplesStop(t *testing.T) {
	r := newMotionRig(t)
	if ev := r.last(); ev.Active || ev.Size != "medium" {
		t.Fatalf("first event %+v", ev)
	}
	if err := r.d.StartMotion(""); err != nil {
		t.Fatal(err)
	}
	if b := r.next(); b.Action != "start" || b.Rate != motionRate {
		t.Fatalf("start body %+v", b)
	}
	r.samples(0, 16, 2)
	ev := r.last()
	if !ev.Active || ev.Device != r.dev.ID || ev.OffsetX >= 0 {
		t.Fatalf("event after samples %+v", ev)
	}
	r.d.mu.Lock()
	view := r.d.motionViewLocked()
	r.d.mu.Unlock()
	if !view.Running || !view.Active || view.DeviceName != "Pixel 8" || view.Auto {
		t.Fatalf("view %+v", view)
	}
	r.d.StopMotion()
	if b := r.next(); b.Action != "stop" {
		t.Fatalf("stop body %+v", b)
	}
	if ev := r.last(); ev.Active || ev.OffsetX != 0 {
		t.Fatalf("event after stop %+v", ev)
	}
}

func TestMotionOffOrNoDevice(t *testing.T) {
	r := newMotionRig(t)
	r.d.cfg.MotionCues = false
	if err := r.d.StartMotion(""); err == nil {
		t.Fatal("a start with the setting off worked")
	}
	r.d.cfg.MotionCues = true
	r.d.cfg.Devices = map[string]map[string]bool{r.dev.ID: {"motionCues": false}}
	if err := r.d.StartMotion(""); err == nil {
		t.Fatal("a start for a device without access worked")
	}
	r.d.cfg.Devices = nil
	r.dev.Incoming = nil
	if err := r.d.StartMotion(""); err == nil {
		t.Fatal("a start for a device that does not accept flux.motion worked")
	}
	r.none()
}

func TestMotionStraySamplesGetStop(t *testing.T) {
	r := newMotionRig(t)
	r.samples(0, 4, 1)
	if b := r.next(); b.Action != "stop" {
		t.Fatalf("stray samples got %+v", b)
	}
	// A second batch at once does not send another stop.
	r.samples(200, 4, 1)
	r.none()
	if ev := r.last(); ev.Active {
		t.Fatalf("stray samples showed the cues: %+v", ev)
	}
}

func TestMotionBadSamples(t *testing.T) {
	r := newMotionRig(t)
	if err := r.d.StartMotion(""); err != nil {
		t.Fatal(err)
	}
	r.next()
	r.send(map[string]any{"samples": []map[string]any{{"t": 1, "x": 500, "y": 0, "z": 0}}})
	if ev := r.last(); ev.Active {
		t.Fatalf("an out of range sample showed the cues: %+v", ev)
	}
	// More than 16 samples: the rest is dropped, the first 16 count.
	r.samples(0, 40, 1)
	if ev := r.last(); !ev.Active {
		t.Fatalf("a long list did not count: %+v", ev)
	}
	// A body over the limit is dropped whole.
	big := make([]motionSample, 200)
	r.d.handleMotion(r.dev, r.dev.link, &proto.Packet{Type: proto.TypeFluxMotion, Body: mustJSON(map[string]any{"samples": big})})
}

func TestMotionVehicleAutoStartAndHold(t *testing.T) {
	r := newMotionRig(t)
	r.send(map[string]any{"action": "vehicle", "in": true})
	if b := r.next(); b.Action != "start" {
		t.Fatalf("vehicle enter got %+v", b)
	}
	if !r.running() || !r.d.motion.auto {
		t.Fatal("vehicle detection did not start an automatic run")
	}
	// The user stops the cues during the trip. A repeated enter does not
	// start them again.
	r.send(map[string]any{"action": "stop"})
	if b := r.next(); b.Action != "stop" {
		t.Fatalf("phone stop got %+v", b)
	}
	r.send(map[string]any{"action": "vehicle", "in": true})
	r.none()
	// The trip ends, and the next trip starts the cues again.
	r.send(map[string]any{"action": "vehicle", "in": false})
	r.none()
	r.send(map[string]any{"action": "vehicle", "in": true})
	if b := r.next(); b.Action != "start" {
		t.Fatalf("next trip got %+v", b)
	}
	// Leaving the vehicle ends an automatic run.
	r.send(map[string]any{"action": "vehicle", "in": false})
	if b := r.next(); b.Action != "stop" {
		t.Fatalf("vehicle exit got %+v", b)
	}
}

func TestMotionVehicleRespectsSettings(t *testing.T) {
	r := newMotionRig(t)
	r.d.cfg.MotionAuto = false
	r.send(map[string]any{"action": "vehicle", "in": true})
	r.none()
	r.send(map[string]any{"action": "vehicle", "in": false})
	r.d.cfg.MotionAuto, r.d.cfg.MotionCues = true, false
	r.send(map[string]any{"action": "vehicle", "in": true})
	r.none()
}

func TestMotionHandRunSurvivesVehicleExit(t *testing.T) {
	r := newMotionRig(t)
	r.send(map[string]any{"action": "start"})
	if b := r.next(); b.Action != "start" {
		t.Fatalf("phone start got %+v", b)
	}
	r.send(map[string]any{"action": "vehicle", "in": true})
	r.send(map[string]any{"action": "vehicle", "in": false})
	r.none()
	if !r.running() {
		t.Fatal("a vehicle exit stopped a run by hand")
	}
}

func TestMotionStaleAndIdle(t *testing.T) {
	r := newMotionRig(t)
	r.d.cfg.MotionIdle = 30
	if err := r.d.StartMotion(""); err != nil {
		t.Fatal(err)
	}
	r.next()
	r.samples(0, 8, 2)
	now := time.Now()
	r.d.motionCheck(now.Add(500 * time.Millisecond))
	if !r.last().Active {
		t.Fatal("the cues hid before the feed went stale")
	}
	r.d.motionCheck(now.Add(1100 * time.Millisecond))
	if ev := r.last(); ev.Active {
		t.Fatalf("a stale feed still shows the cues: %+v", ev)
	}
	if !r.running() {
		t.Fatal("a stale feed ended the run")
	}
	// Samples come back: the cues show again.
	r.samples(10_000, 4, 2)
	if !r.last().Active {
		t.Fatal("the cues did not come back")
	}
	// Samples without motion do not count as motion: after the idle time,
	// the run stops.
	r.samples(20_000, 4, 0)
	r.d.motionCheck(time.Now().Add(31 * time.Second))
	if r.running() {
		t.Fatal("the run did not stop after the idle time")
	}
	if b := r.next(); b.Action != "stop" {
		t.Fatalf("idle stop got %+v", b)
	}
}

func TestMotionPhoneError(t *testing.T) {
	r := newMotionRig(t)
	if err := r.d.StartMotion(""); err != nil {
		t.Fatal(err)
	}
	r.next()
	r.send(map[string]any{"action": "state", "running": false, "error": "no accelerometer"})
	if r.running() {
		t.Fatal("a sensor error did not end the run")
	}
	r.d.mu.Lock()
	view := r.d.motionViewLocked()
	r.d.mu.Unlock()
	if view.Error != "no accelerometer" {
		t.Fatalf("view %+v", view)
	}
}

func TestMotionAccessChangeStops(t *testing.T) {
	r := newMotionRig(t)
	if err := r.d.StartMotion(""); err != nil {
		t.Fatal(err)
	}
	r.next()
	r.d.cfg.Devices = map[string]map[string]bool{r.dev.ID: {"motionCues": false}}
	r.d.motionChanged()
	// The phone gets the new setting and the stop.
	got := map[string]motionBody{}
	for range 2 {
		b := r.next()
		got[b.Action] = b
	}
	if c, ok := got["config"]; !ok || c.Enabled == nil || *c.Enabled {
		t.Fatalf("config body %+v", got)
	}
	if _, ok := got["stop"]; !ok || r.running() {
		t.Fatalf("no stop after the access change: %+v", got)
	}
}

func TestMotionLinkDown(t *testing.T) {
	r := newMotionRig(t)
	r.send(map[string]any{"action": "vehicle", "in": true})
	r.next()
	r.samples(0, 4, 2)
	r.d.motionLinkDown(r.dev.ID)
	if r.running() || r.last().Active {
		t.Fatal("a closed link left the run on")
	}
	r.d.motion.mu.Lock()
	in := r.d.motion.inVehicle[r.dev.ID]
	r.d.motion.mu.Unlock()
	if in {
		t.Fatal("a closed link kept the vehicle state")
	}
}

func TestMotionSettings(t *testing.T) {
	d := testDaemon()
	d.motion = newMotionState()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	for _, c := range []struct {
		key string
		val any
		ok  bool
	}{
		{"motionCues", true, true},
		{"motionAuto", false, true},
		{"motionSize", "large", true},
		{"motionSize", "huge", false},
		{"motionSensitivity", 1.6, true},
		{"motionSensitivity", 2.0, false},
		{"motionIdle", 60.0, true},
		{"motionIdle", 10.0, false},
		{"motionIdle", 60.5, false},
	} {
		err := d.setSetting(c.key, c.val)
		if (err == nil) != c.ok {
			t.Errorf("%s=%v: err %v", c.key, c.val, err)
		}
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.MotionCues || cfg.MotionAuto || cfg.MotionDotSize() != "large" || cfg.MotionScale() != 1.6 || cfg.MotionIdleSeconds() != 60 {
		t.Fatalf("saved config %+v", cfg)
	}
}
