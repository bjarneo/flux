package core

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// Motion cues: a paired phone sends its acceleration, fluxd turns it into
// cue targets with the motion model, and the omarchy-shell plugin draws the
// dots. docs/motion-cues.md describes the feature and the packets.

const (
	// motionRate is the sample rate that fluxd asks the phone for, in Hz.
	motionRate = 30
	// motionStale is the time without a sample after which the overlay
	// hides. The run goes on, so the cues come back with the next sample.
	motionStale = time.Second
	// motionPublishGap is the shortest time between 2 motion events.
	motionPublishGap = time.Second / 30
	// motionMaxSamples is the most samples in 1 packet. fluxd drops the
	// rest of a longer list.
	motionMaxSamples = 16
	// motionMaxBody is the largest flux.motion body that fluxd reads.
	motionMaxBody = 4096
	// motionTick is the time between 2 checks for a stale feed and the
	// idle stop while the cues run.
	motionTick = 250 * time.Millisecond
	// motionStrayStop is the shortest time between 2 stops that fluxd sends
	// to a device that sends samples without a run.
	motionStrayStop = 2 * time.Second
)

// motionState is the state of the motion cues. Its mutex comes after d.mu:
// code that holds motionState.mu never takes d.mu.
type motionState struct {
	mu sync.Mutex
	// running is true from the start that fluxd sent until the stop.
	running bool
	// device is the device that feeds the run.
	device string
	// auto is true when vehicle detection started the run.
	auto      bool
	startedAt time.Time
	// phoneRunning is the sensor state that the phone reported last.
	phoneRunning bool
	// lastErr is the last sensor error that the phone reported.
	lastErr    string
	model      *motionModel
	lastSample time.Time
	lastMove   time.Time
	lastPub    time.Time
	// active is true while the overlay shows, that is while the run gets
	// fresh samples.
	active  bool
	targets motionTargets
	// inVehicle holds the devices that report that they are in a vehicle.
	inVehicle map[string]bool
	// held holds the devices whose run the user stopped during a vehicle
	// trip. Vehicle detection does not start them again until the trip
	// ends.
	held map[string]bool
	// strayStop is the time of the last stop to each device that sent
	// samples without a run.
	strayStop map[string]time.Time
	subs      map[int]func(any)
	nextSub   int
	wake      chan struct{}
}

func newMotionState() *motionState {
	return &motionState{
		inVehicle: map[string]bool{},
		held:      map[string]bool{},
		strayStop: map[string]time.Time{},
		subs:      map[int]func(any){},
		wake:      make(chan struct{}, 1),
	}
}

// mot returns the motion state. A daemon that a test builds without New
// gets it on first use.
func (d *Daemon) mot() *motionState {
	d.motionOnce.Do(func() {
		if d.motion == nil {
			d.motion = newMotionState()
		}
	})
	return d.motion
}

// motionEvent is the data of the motion event on the IPC socket.
type motionEvent struct {
	Active bool   `json:"active"`
	Device string `json:"device,omitempty"`
	Size   string `json:"size"`
	motionTargets
}

// MotionView is the motion part of the state.
type MotionView struct {
	Running    bool   `json:"running"`
	Device     string `json:"device,omitempty"`
	DeviceName string `json:"deviceName,omitempty"`
	Auto       bool   `json:"auto"`
	Active     bool   `json:"active"`
	Error      string `json:"error,omitempty"`
}

// motionBody is the union of the flux.motion bodies.
type motionBody struct {
	Action  string         `json:"action,omitempty"`
	Rate    int            `json:"rate,omitempty"`
	Enabled *bool          `json:"enabled,omitempty"`
	Auto    *bool          `json:"auto,omitempty"`
	Running *bool          `json:"running,omitempty"`
	Error   string         `json:"error,omitempty"`
	In      *bool          `json:"in,omitempty"`
	Samples []motionSample `json:"samples,omitempty"`
}

// motionViewLocked returns the motion part of the state. The caller holds
// d.mu.
func (d *Daemon) motionViewLocked() MotionView {
	m := d.mot()
	m.mu.Lock()
	defer m.mu.Unlock()
	v := MotionView{Running: m.running, Device: m.device, Auto: m.auto, Active: m.active, Error: m.lastErr}
	if dev := d.devices[m.device]; dev != nil {
		v.DeviceName = dev.Name
	}
	return v
}

// SubscribeMotion registers a receiver for motion events. It sends the
// current event at once. The returned function removes the receiver.
func (d *Daemon) SubscribeMotion(send func(data any)) func() {
	d.mu.Lock()
	size := d.cfg.MotionDotSize()
	d.mu.Unlock()
	m := d.mot()
	m.mu.Lock()
	m.nextSub++
	id := m.nextSub
	m.subs[id] = send
	ev := m.eventLocked(size)
	m.mu.Unlock()
	send(ev)
	return func() {
		m.mu.Lock()
		delete(m.subs, id)
		m.mu.Unlock()
	}
}

func (m *motionState) eventLocked(size string) motionEvent {
	ev := motionEvent{Active: m.active, Size: size}
	if m.active {
		ev.Device = m.device
		ev.motionTargets = m.targets
	}
	return ev
}

// publishLocked sends the current motion event to each receiver. The
// caller holds m.mu. The receivers only queue the event.
func (m *motionState) publishLocked(size string, now time.Time) {
	m.lastPub = now
	ev := m.eventLocked(size)
	for _, s := range m.subs {
		s(ev)
	}
}

// motionConfig is the part of the configuration that the motion code reads.
type motionConfig struct {
	enabled bool
	auto    bool
	scale   float64
	size    string
	idle    time.Duration
}

func (d *Daemon) motionConfig() motionConfig {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.motionConfigLocked()
}

func (d *Daemon) motionConfigLocked() motionConfig {
	return motionConfig{
		enabled: d.cfg.MotionCues,
		auto:    d.cfg.MotionAuto,
		scale:   d.cfg.MotionScale(),
		size:    d.cfg.MotionDotSize(),
		idle:    time.Duration(d.cfg.MotionIdleSeconds()) * time.Second,
	}
}

// motionLink returns the link of a paired, connected device that accepts
// flux.motion and may use motion cues, and its name.
func (d *Daemon) motionLinkLocked(id string) (*lan.Link, string, bool) {
	dev := d.devices[id]
	if dev == nil || !dev.Paired || dev.link == nil || !dev.accepts(proto.TypeFluxMotion) {
		return nil, "", false
	}
	if !d.cfg.MotionCues || !d.permittedLocked(id, "motionCues") {
		return nil, "", false
	}
	return dev.link, dev.Name, true
}

// motionDevicesLocked returns the IDs of the devices that can feed motion
// cues, in a stable order.
func (d *Daemon) motionDevicesLocked() []string {
	var ids []string
	for _, id := range d.featureDevicesLocked("motionCues") {
		if _, _, ok := d.motionLinkLocked(id); ok {
			ids = append(ids, id)
		}
	}
	return ids
}

// sendMotionConfig tells the phone whether motion cues are on and whether
// it watches for a vehicle.
func (d *Daemon) sendMotionConfig(dev *Device, l *lan.Link) {
	d.mu.Lock()
	accepts := dev.accepts(proto.TypeFluxMotion)
	enabled := d.cfg.MotionCues && d.permittedLocked(dev.ID, "motionCues")
	auto := d.cfg.MotionAuto
	d.mu.Unlock()
	if !accepts {
		return
	}
	_ = l.Send(proto.New(proto.TypeFluxMotion, motionBody{Action: "config", Enabled: &enabled, Auto: &auto}))
}

// motionChanged runs after a motion setting or a device rule changed. It
// sends the setting to each phone, and stops a run that is no longer
// allowed.
func (d *Daemon) motionChanged() {
	d.mu.Lock()
	type target struct {
		dev *Device
		l   *lan.Link
	}
	var targets []target
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxMotion) {
			targets = append(targets, target{dev, dev.link})
		}
	}
	m := d.mot()
	m.mu.Lock()
	running, device := m.running, m.device
	m.mu.Unlock()
	allowed := false
	if running {
		_, _, allowed = d.motionLinkLocked(device)
	}
	cfg := d.motionConfigLocked()
	d.mu.Unlock()
	for _, t := range targets {
		d.sendMotionConfig(t.dev, t.l)
	}
	if running && !allowed {
		d.stopMotion("", false)
	}
	m.mu.Lock()
	if m.model != nil {
		m.model.scale = cfg.scale
	}
	if m.running {
		m.publishLocked(cfg.size, time.Now())
	}
	m.mu.Unlock()
	d.markDirty()
}

// StartMotion starts the motion cues by hand. device is a device ID, or
// empty for the first device that can feed them. A run that already goes
// on stays, and an automatic run becomes a run by hand.
func (d *Daemon) StartMotion(device string) error {
	d.mu.Lock()
	if !d.cfg.MotionCues {
		d.mu.Unlock()
		return apiErr("motion_off", "Motion cues are off. Turn them on with: flux-cli motion on")
	}
	if device == "" {
		ids := d.motionDevicesLocked()
		if len(ids) == 0 {
			d.mu.Unlock()
			return apiErr("no_device", "No connected device can send motion. Update Flux on the phone and check its access to motion cues.")
		}
		device = ids[0]
	}
	_, name, ok := d.motionLinkLocked(device)
	d.mu.Unlock()
	if !ok {
		return apiErr("no_device", "The device is not connected, does not send motion, or has no access to motion cues")
	}
	m := d.mot()
	m.mu.Lock()
	m.held[device] = false
	if m.running && m.device == device {
		m.auto = false
		m.mu.Unlock()
		d.markDirty()
		return nil
	}
	m.mu.Unlock()
	if !d.startMotion(device, false) {
		return apiErr("busy", "Motion cues run from another device. Stop them first with: flux-cli motion stop")
	}
	d.logf("motion cues: started by hand from %s", name)
	return nil
}

// StopMotion stops the motion cues by hand. During a vehicle trip, vehicle
// detection does not start them again until the trip ends.
func (d *Daemon) StopMotion() {
	d.stopMotion("", true)
}

// startMotion asks device to start its sensor. It returns false when
// another device feeds a run.
func (d *Daemon) startMotion(device string, auto bool) bool {
	d.mu.Lock()
	l, _, ok := d.motionLinkLocked(device)
	cfg := d.motionConfigLocked()
	d.mu.Unlock()
	if !ok {
		return false
	}
	m := d.mot()
	m.mu.Lock()
	if m.running {
		same := m.device == device
		m.mu.Unlock()
		return same
	}
	now := time.Now()
	m.running, m.device, m.auto = true, device, auto
	m.startedAt, m.lastMove, m.lastSample = now, now, time.Time{}
	m.lastErr, m.active = "", false
	m.model = newMotionModel(cfg.scale)
	m.mu.Unlock()
	select {
	case m.wake <- struct{}{}:
	default:
	}
	_ = l.Send(proto.New(proto.TypeFluxMotion, motionBody{Action: "start", Rate: motionRate}))
	d.markDirty()
	return true
}

// stopMotion ends the run. device limits the stop to a run of that device;
// empty stops any run. byHand marks a stop of the user, which holds the
// run off during a vehicle trip.
func (d *Daemon) stopMotion(device string, byHand bool) {
	m := d.mot()
	d.mu.Lock()
	size := d.cfg.MotionDotSize()
	m.mu.Lock()
	if !m.running || (device != "" && m.device != device) {
		if byHand && device != "" && m.inVehicle[device] {
			m.held[device] = true
		}
		m.mu.Unlock()
		d.mu.Unlock()
		return
	}
	feeder := m.device
	if byHand && m.inVehicle[feeder] {
		m.held[feeder] = true
	}
	m.running, m.auto, m.device = false, false, ""
	m.model = nil
	wasActive := m.active
	m.active = false
	if wasActive || len(m.subs) > 0 {
		m.publishLocked(size, time.Now())
	}
	m.mu.Unlock()
	var l *lan.Link
	if dev := d.devices[feeder]; dev != nil && dev.link != nil && dev.accepts(proto.TypeFluxMotion) {
		l = dev.link
	}
	d.mu.Unlock()
	if l != nil {
		_ = l.Send(proto.New(proto.TypeFluxMotion, motionBody{Action: "stop"}))
	}
	d.markDirty()
}

// motionLinkDown ends the run of a device whose link closed. The phone
// stops its sensor itself when the link ends.
func (d *Daemon) motionLinkDown(device string) {
	m := d.mot()
	d.mu.Lock()
	size := d.cfg.MotionDotSize()
	d.mu.Unlock()
	m.mu.Lock()
	delete(m.inVehicle, device)
	if !m.running || m.device != device {
		m.mu.Unlock()
		return
	}
	m.running, m.auto, m.device, m.model = false, false, "", nil
	m.active = false
	m.publishLocked(size, time.Now())
	m.mu.Unlock()
	d.markDirty()
}

// handleMotion handles a flux.motion packet of a paired phone.
func (d *Daemon) handleMotion(dev *Device, l *lan.Link, p *proto.Packet) {
	if len(p.Body) > motionMaxBody {
		return
	}
	var b motionBody
	if json.Unmarshal(p.Body, &b) != nil {
		return
	}
	// A body with samples is a sample body, whatever its action says.
	if len(b.Samples) > 0 {
		d.motionSamples(dev, l, b.Samples)
		return
	}
	switch b.Action {
	case "state":
		d.motionPhoneState(dev, b)
	case "vehicle":
		if b.In != nil {
			d.motionVehicle(dev, *b.In)
		}
	case "start":
		if err := d.StartMotion(dev.ID); err != nil {
			d.toast("%s could not start motion cues: %v", dev.Name, err)
		}
	case "stop":
		d.stopMotion(dev.ID, true)
	}
}

func (d *Daemon) motionSamples(dev *Device, l *lan.Link, samples []motionSample) {
	if len(samples) == 0 {
		return
	}
	if len(samples) > motionMaxSamples {
		samples = samples[:motionMaxSamples]
	}
	d.mu.Lock()
	_, _, allowed := d.motionLinkLocked(dev.ID)
	size := d.cfg.MotionDotSize()
	d.mu.Unlock()
	m := d.mot()
	now := time.Now()
	m.mu.Lock()
	if !allowed || !m.running || m.device != dev.ID || m.model == nil {
		// A phone that missed the stop keeps its sensor on. Send the stop
		// again, at most every 2 seconds.
		stray := now.Sub(m.strayStop[dev.ID]) >= motionStrayStop
		if stray {
			m.strayStop[dev.ID] = now
		}
		m.mu.Unlock()
		if stray {
			_ = l.Send(proto.New(proto.TypeFluxMotion, motionBody{Action: "stop"}))
		}
		return
	}
	used := false
	for _, s := range samples {
		if !validSample(s) {
			continue
		}
		used = true
		m.targets = m.model.step(s)
		if s.moving() {
			m.lastMove = now
		}
	}
	if !used {
		m.mu.Unlock()
		return
	}
	m.lastSample = now
	m.phoneRunning = true
	becameActive := !m.active
	m.active = true
	if becameActive || now.Sub(m.lastPub) >= motionPublishGap {
		m.publishLocked(size, now)
	}
	m.mu.Unlock()
	if becameActive {
		d.markDirty()
	}
}

func (d *Daemon) motionPhoneState(dev *Device, b motionBody) {
	m := d.mot()
	m.mu.Lock()
	if m.device != dev.ID {
		m.mu.Unlock()
		return
	}
	running := b.Running != nil && *b.Running
	m.phoneRunning = running
	m.lastErr = b.Error
	stop := m.running && !running
	m.mu.Unlock()
	if stop {
		d.stopMotion(dev.ID, false)
		if b.Error != "" {
			d.toast("%s could not start motion cues: %s", dev.Name, b.Error)
		}
		m.mu.Lock()
		m.lastErr = b.Error
		m.mu.Unlock()
	}
	d.markDirty()
}

func (d *Daemon) motionVehicle(dev *Device, in bool) {
	cfg := d.motionConfig()
	m := d.mot()
	m.mu.Lock()
	was := m.inVehicle[dev.ID]
	m.inVehicle[dev.ID] = in
	if !in {
		delete(m.inVehicle, dev.ID)
		delete(m.held, dev.ID)
	}
	held := m.held[dev.ID]
	autoRun := m.running && m.auto && m.device == dev.ID
	m.mu.Unlock()
	switch {
	case in && !was && cfg.enabled && cfg.auto && !held:
		if d.startMotion(dev.ID, true) {
			d.logf("motion cues: %s is in a vehicle, started", dev.Name)
			d.toast("Motion cues on: %s is in a vehicle", dev.Name)
		}
	case !in && autoRun:
		d.logf("motion cues: %s left the vehicle, stopped", dev.Name)
		d.stopMotion(dev.ID, false)
	}
}

// motionLoop hides the overlay when the feed goes stale and stops a run
// after the idle time without motion. It sleeps while no run goes on.
func (d *Daemon) motionLoop(ctx context.Context) {
	m := d.mot()
	t := time.NewTicker(motionTick)
	defer t.Stop()
	for {
		m.mu.Lock()
		running := m.running
		m.mu.Unlock()
		if !running {
			select {
			case <-ctx.Done():
				return
			case <-m.wake:
			}
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-m.wake:
		case <-t.C:
		}
		d.motionCheck(time.Now())
	}
}

// motionCheck runs 1 check of motionLoop at the time now.
func (d *Daemon) motionCheck(now time.Time) {
	cfg := d.motionConfig()
	m := d.mot()
	m.mu.Lock()
	if !m.running {
		m.mu.Unlock()
		return
	}
	dirty := false
	if m.active && now.Sub(m.lastSample) >= motionStale {
		// The model starts again from rest, so old motion does not jump
		// back with the next sample.
		m.active = false
		m.model.reset()
		m.targets = motionTargets{}
		m.publishLocked(cfg.size, now)
		dirty = true
	}
	idle := now.Sub(m.lastMove) >= cfg.idle
	name := m.device
	m.mu.Unlock()
	if idle {
		d.mu.Lock()
		if dev := d.devices[name]; dev != nil {
			name = dev.Name
		}
		d.mu.Unlock()
		d.stopMotion("", false)
		d.logf("motion cues: no motion for %v, stopped", cfg.idle)
		d.toast("Motion cues stopped after %v without motion from %s", cfg.idle, name)
		return
	}
	if dirty {
		d.markDirty()
	}
}

// numberValue reads a number of a JSON request.
func numberValue(value any) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case json.Number:
		f, err := v.Float64()
		return f, err == nil
	}
	return 0, false
}
