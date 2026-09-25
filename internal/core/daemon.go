// Package core holds the device state of fluxd, the pairing logic, the
// plugins, and the API that the IPC server exposes.
package core

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// Daemon is the running fluxd state.
type Daemon struct {
	mu      sync.Mutex
	cfg     *config.Config
	trust   *config.TrustStore
	cert    tls.Certificate
	selfID  string
	lan     *lan.Provider
	devices map[string]*Device

	clipboard     []ClipEntry
	lastLocalClip time.Time
	transfers     []*Transfer
	ringing       bool
	ringFrom      string

	opts     Options
	clip     clipboard
	notifier *desktop.Notifier
	media    *desktop.Media
	ringer   ringer

	webcam       *webcamSession
	webcamErr    string
	webcamConfig json.RawMessage
	webcamCaps   json.RawMessage
	loopback     *desktop.Loopback

	approvals approvalBook

	subs   map[int]func(event string, data any)
	nextID int
	dirty  chan struct{}
	ctx    context.Context
	logger *log.Logger
}

// Options change how the daemon runs. The zero value is the normal mode.
type Options struct {
	// Headless turns off the desktop: clipboard, notifications, media,
	// sound, and mDNS. Discovery uses loopback only. Tests use it.
	Headless bool
	// UDPPort and FirstTCPPort change the protocol ports. Zero means 1716.
	UDPPort      int
	FirstTCPPort int
}

type clipboard interface {
	Watch(ctx context.Context, onChange func(text string))
	Get() (string, error)
	Set(text string) error
}

type ringer interface {
	Start()
	Stop()
}

// memClipboard is the clipboard of a headless daemon.
type memClipboard struct {
	mu   sync.Mutex
	text string
}

func (m *memClipboard) Watch(ctx context.Context, _ func(string)) { <-ctx.Done() }
func (m *memClipboard) Get() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.text, nil
}
func (m *memClipboard) Set(text string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.text = text
	return nil
}

type silentRinger struct{}

func (silentRinger) Start() {}
func (silentRinger) Stop()  {}

// New loads the identity, the configuration, and the trust store. The
// context ends the transfers and sessions that the daemon starts.
func New(ctx context.Context, logger *log.Logger, opts Options) (*Daemon, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	trust, err := config.LoadTrust()
	if err != nil {
		return nil, err
	}
	cert, id, err := proto.LoadOrCreateCert(config.DataDir())
	if err != nil {
		return nil, err
	}
	d := &Daemon{
		cfg: cfg, trust: trust, cert: cert, selfID: id,
		opts:    opts,
		devices: map[string]*Device{},
		clip:    desktop.NewClipboard(),
		ringer:  &desktop.Ringer{},
		subs:    map[int]func(string, any){},
		dirty:   make(chan struct{}, 1),
		ctx:     ctx,
		logger:  logger,
	}
	if opts.Headless {
		d.clip, d.ringer = &memClipboard{}, silentRinger{}
	}
	for _, t := range trust.All() {
		dev := d.deviceLocked(t.ID)
		dev.applyTrust(t)
	}
	return d, nil
}

func (d *Daemon) logf(format string, args ...any) { d.logger.Printf(format, args...) }

// SelfID returns the device ID of this computer.
func (d *Daemon) SelfID() string { return d.selfID }

// Name returns the device name that fluxd announces.
func (d *Daemon) Name() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.nameLocked()
}

func (d *Daemon) nameLocked() string {
	if d.cfg.Name != "" {
		return proto.CleanName(d.cfg.Name)
	}
	return proto.CleanName(hostname())
}

// Run starts the network and the desktop watchers and blocks until the
// context of New ends.
func (d *Daemon) Run() error {
	ctx := d.ctx
	d.lan = lan.New(lan.Config{
		Cert: d.cert,
		Identity: func() proto.Identity {
			return proto.NewIdentity(d.selfID, d.Name(), 0)
		},
		Trusted: func(id string) (*x509.Certificate, bool) {
			t, ok := d.trust.Get(id)
			if !ok {
				return nil, false
			}
			c, err := proto.ParseCertPEM(t.CertPEM)
			return c, err == nil
		},
		HasLink: func(id string) bool {
			d.mu.Lock()
			defer d.mu.Unlock()
			dev, ok := d.devices[id]
			return ok && dev.link != nil
		},
		OnLink:       d.onLink,
		OnIdentity:   d.onIdentity,
		Logf:         d.logf,
		UDPPort:      d.opts.UDPPort,
		FirstTCPPort: d.opts.FirstTCPPort,
		LoopbackOnly: d.opts.Headless,
	})
	if err := d.lan.Start(ctx); err != nil {
		return err
	}
	d.logf("fluxd %s listening on TCP %d as %q", d.selfID, d.lan.TCPPort(), d.Name())
	if d.opts.Headless {
		go d.publishLoop(ctx)
		go d.discoveryLoop(ctx)
		<-ctx.Done()
		d.closeLinks()
		return nil
	}
	mdns := lan.MDNSInfo{DeviceID: d.selfID, Name: d.Name(), Type: proto.DeviceType(), Protocol: proto.ProtocolVersion, Port: d.lan.TCPPort()}
	if err := lan.StartMDNS(ctx, mdns, d.onMDNS); err != nil {
		d.logf("mDNS off, UDP discovery only: %v", err)
	}

	if n, err := desktop.NewNotifier(); err == nil {
		d.notifier = n
		n.OnAction(d.onNotificationAction)
	} else {
		d.logf("notifications off: %v", err)
	}
	if m, err := desktop.NewMedia(); err == nil {
		d.media = m
		m.OnChange(d.onDesktopMediaChange)
	} else {
		d.logf("media control off: %v", err)
	}

	go d.clip.Watch(ctx, d.onLocalClipboard)
	go d.publishLoop(ctx)
	go d.discoveryLoop(ctx)
	go d.batteryLoop(ctx)

	<-ctx.Done()
	d.closeLinks()
	d.ringer.Stop()
	d.mu.Lock()
	loop := d.loopback
	d.mu.Unlock()
	if loop != nil {
		if err := loop.Close(); err != nil {
			d.logf("remove %s: %v", loop.Path, err)
		}
	}
	if d.notifier != nil {
		d.notifier.Shutdown()
	}
	if d.media != nil {
		d.media.Shutdown()
	}
	return nil
}

func (d *Daemon) closeLinks() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, dev := range d.devices {
		if dev.link != nil {
			dev.link.Close()
		}
	}
}

// discoveryLoop broadcasts at start, when the network addresses change,
// and every 60 seconds while a paired device is offline.
func (d *Daemon) discoveryLoop(ctx context.Context) {
	d.announce()
	d.dialKnown()
	last := addrKey()
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	n := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		n++
		if k := addrKey(); k != last {
			last = k
			d.logf("network changed, broadcasting")
			d.announce()
			continue
		}
		if n%3 == 0 {
			d.dialKnown()
		}
		if n%6 == 0 && d.anyPairedOffline() {
			d.announce()
		}
	}
}

// announce broadcasts the identity and sends it to the last address of
// each paired device that is offline.
func (d *Daemon) announce() {
	d.lan.Broadcast()
	d.mu.Lock()
	var ips []string
	for _, dev := range d.devices {
		if dev.Paired && dev.link == nil && dev.IP != "" {
			ips = append(ips, dev.IP)
		}
	}
	d.mu.Unlock()
	for _, ip := range ips {
		d.lan.Announce(ip)
	}
}

func (d *Daemon) anyPairedOffline() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, dev := range d.devices {
		if dev.Paired && dev.link == nil {
			return true
		}
	}
	return false
}

func addrKey() string {
	var parts []string
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			parts = append(parts, a.String())
		}
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

// deviceLocked returns the device with the ID and creates it when needed.
func (d *Daemon) deviceLocked(id string) *Device {
	dev, ok := d.devices[id]
	if !ok {
		dev = newDevice(id)
		d.devices[id] = dev
	}
	return dev
}

// onMDNS records a device that mDNS found and connects to it. fluxd opens
// the connection, so it works with a firewall that blocks incoming
// traffic.
func (d *Daemon) onMDNS(peer lan.MDNSPeer) {
	if !proto.ValidDeviceID(peer.DeviceID) || peer.DeviceID == d.selfID {
		return
	}
	d.mu.Lock()
	dev := d.deviceLocked(peer.DeviceID)
	if !dev.Paired {
		dev.Name, dev.Type = proto.CleanName(peer.Name), peer.Type
	}
	dev.IP, dev.Port, dev.LastSeen = peer.IP, peer.Port, time.Now()
	dev.mdnsSeen = time.Now()
	d.mu.Unlock()
	d.lan.Dial(d.ctx, peer.IP, peer.Port, proto.Identity{DeviceID: peer.DeviceID, DeviceName: peer.Name, ProtocolVersion: peer.Protocol})
}

// dialKnown connects to each device that is offline and has a known
// address: paired devices, and devices that mDNS found in the last 10
// minutes. It also sends a unicast UDP identity from port 1716. A device
// that answers from its port 1716 passes the firewall as a reply.
func (d *Daemon) dialKnown() {
	type target struct {
		ip   string
		port int
		id   proto.Identity
	}
	var targets []target
	d.mu.Lock()
	for _, dev := range d.devices {
		if dev.link != nil || dev.IP == "" {
			continue
		}
		if !dev.Paired && time.Since(dev.mdnsSeen) > 10*time.Minute {
			continue
		}
		targets = append(targets, target{dev.IP, dev.Port, proto.Identity{DeviceID: dev.ID, DeviceName: dev.Name, ProtocolVersion: dev.Version}})
	}
	d.mu.Unlock()
	for _, t := range targets {
		d.lan.Announce(t.ip)
		if t.port > 0 {
			d.lan.Dial(d.ctx, t.ip, t.port, t.id)
		}
	}
}

// onIdentity records a device seen by UDP.
func (d *Daemon) onIdentity(id proto.Identity, ip string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	dev := d.deviceLocked(id.DeviceID)
	if dev.Name == "" || !dev.Paired {
		dev.Name = proto.CleanName(id.DeviceName)
		dev.Type = id.DeviceType
	}
	dev.IP = ip
	if id.TCPPort > 0 {
		dev.Port = id.TCPPort
	}
	dev.LastSeen = time.Now()
}

// onLink takes over a new authenticated link.
func (d *Daemon) onLink(l *lan.Link) {
	d.mu.Lock()
	dev := d.deviceLocked(l.DeviceID())
	old := dev.link
	if old != nil && lan.Preferred(old, l, d.selfID) == old {
		d.mu.Unlock()
		l.Close()
		return
	}
	dev.link = l
	dev.setIdentity(l.Identity)
	dev.IP = l.IP()
	if l.PeerPort > 0 {
		dev.Port = l.PeerPort
	}
	dev.LastSeen = time.Now()
	dev.Cert = l.Cert
	_, trusted := d.trust.Get(dev.ID)
	dev.Paired = trusted
	d.mu.Unlock()
	if old != nil {
		old.Close()
	}
	d.logf("link up: %s (%s) paired=%v", dev.Name, dev.IP, trusted)
	if trusted {
		d.mu.Lock()
		port := dev.Port
		d.mu.Unlock()
		_ = d.trust.Update(dev.ID, func(t *config.TrustedDevice) {
			t.Name, t.Type, t.LastIP = dev.Name, dev.Type, dev.IP
			if port > 0 {
				t.LastPort = port
			}
		})
		d.onPairedLink(dev, l)
	}
	d.markDirty()

	go func() {
		err := l.Receive(func(p *proto.Packet) { d.handlePacket(dev, l, p) })
		d.mu.Lock()
		if dev.link == l {
			dev.link = nil
			dev.LastSeen = time.Now()
			dev.clearPairingLocked()
			dev.closeSftp()
		}
		d.mu.Unlock()
		d.logf("link down: %s: %v", dev.Name, err)
		d.markDirty()
	}()
}

// onPairedLink sends the packets that a paired device expects after it
// connects.
func (d *Daemon) onPairedLink(dev *Device, l *lan.Link) {
	d.sendBattery(l)
	d.sendCommandList(l)
	d.mu.Lock()
	auto := d.cfg.AutoClipboard
	d.mu.Unlock()
	if auto {
		if text, err := d.clip.Get(); err == nil && text != "" {
			d.mu.Lock()
			ts := d.lastLocalClip.UnixMilli()
			d.mu.Unlock()
			if ts > 0 {
				_ = l.Send(proto.New(proto.TypeClipboardConnect, map[string]any{"content": text, "timestamp": ts}))
			}
		}
	}
	if dev.supports(proto.TypeNotification) {
		_ = l.Send(proto.New(proto.TypeNotificationRequest, map[string]any{"request": true}))
	}
	if dev.supports(proto.TypeMpris) {
		_ = l.Send(proto.New(proto.TypeMprisRequest, map[string]any{"requestPlayerList": true}))
	}
}

// markDirty schedules a state event for all subscribers.
func (d *Daemon) markDirty() {
	select {
	case d.dirty <- struct{}{}:
	default:
	}
}

// publishLoop sends at most 1 state event every 100 ms.
func (d *Daemon) publishLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.dirty:
		}
		time.Sleep(100 * time.Millisecond)
		snap := d.Snapshot()
		d.mu.Lock()
		subs := make([]func(string, any), 0, len(d.subs))
		for _, s := range d.subs {
			subs = append(subs, s)
		}
		d.mu.Unlock()
		for _, s := range subs {
			s("state", snap)
		}
	}
}

// Subscribe registers a receiver for events. It sends the current state at
// once. The returned function removes the receiver.
func (d *Daemon) Subscribe(send func(event string, data any)) func() {
	d.mu.Lock()
	d.nextID++
	id := d.nextID
	d.subs[id] = send
	d.mu.Unlock()
	send("state", d.Snapshot())
	return func() {
		d.mu.Lock()
		delete(d.subs, id)
		d.mu.Unlock()
	}
}

// toast sends a short message to every open Flux window.
func (d *Daemon) toast(format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	d.mu.Lock()
	subs := make([]func(string, any), 0, len(d.subs))
	for _, s := range d.subs {
		subs = append(subs, s)
	}
	d.mu.Unlock()
	for _, s := range subs {
		s("toast", map[string]string{"text": text})
	}
}

// notify shows a desktop notification when the notifier is available.
// Without a phone icon, the notification shows the Flux icon.
func (d *Daemon) notify(n desktop.Notification) uint32 {
	if d.notifier == nil {
		return 0
	}
	if n.IconPath == "" {
		n.IconPath = "flux"
	}
	id, err := d.notifier.Show(n)
	if err != nil {
		d.logf("notification: %v", err)
	}
	return id
}

// send sends a packet to a device and returns an API error when the device
// is offline.
func (d *Daemon) send(dev *Device, p *proto.Packet) error {
	d.mu.Lock()
	l := dev.link
	d.mu.Unlock()
	if l == nil {
		return offline(dev)
	}
	return l.Send(p)
}

// pairedLinks returns the links of every connected paired device.
func (d *Daemon) pairedLinks() []*lan.Link {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil {
			out = append(out, dev.link)
		}
	}
	return out
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
