// Package core holds the device state of fluxd, the pairing logic, the
// plugins, and the API that the IPC server exposes.
package core

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/herdr"
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
	// clipDir holds the images of the clipboard history. clipSend stops
	// the image that fluxd sends to the phones, when a newer copy replaces
	// it.
	clipDir   string
	clipSend  context.CancelFunc
	transfers []*Transfer

	opts Options
	clip clipboard
	// input moves the pointer and types for the phone. It is nil in a
	// headless daemon. inputQ holds the actions in order.
	input    inputBackend
	inputQ   chan inputAction
	notifier *desktop.Notifier
	media    *desktop.Media
	// callPlayers are the players that a call pauses. It is the desktop
	// media when media control works, else nil.
	callPlayers callMedia
	calls       map[string]*callState

	// dnd is the Do Not Disturb of the desktop, or nil when the desktop has
	// no supported notification service. dndWake makes dndLoop check again
	// whether it must read the state.
	dnd      dndBackend
	dndGuard dndGuard
	dndWake  chan struct{}

	// themePath is the colors.toml file of the active Omarchy theme, or ""
	// in a headless daemon, which sends no theme. themeBody is the JSON of
	// the last theme that parsed, or nil when the file is missing or does
	// not parse. themeErr is the last read error, so the log shows each
	// error once. themeSend keeps the theme packets in order, so that a
	// link never gets an old theme after a new one.
	themePath string
	themeBody json.RawMessage
	themeErr  string
	themeSend sync.Mutex

	// mdns resolves the address of a paired device again. It is nil when
	// Avahi is not available.
	mdns *lan.MDNS

	webcam       *webcamSession
	webcamErr    string
	webcamConfig json.RawMessage
	webcamCaps   json.RawMessage
	loopback     *desktop.Loopback
	loopMu       sync.Mutex // held while fluxd creates loopback

	mic       *micSession
	micErr    string
	screen    *screenSession
	screenErr string
	// desktop streams this screen to a phone.
	desktop    *desktopSession
	desktopErr string
	approvals  approvalBook

	// pendingVersion is the version of a new fluxd binary on disk. fluxd
	// restarts into it when no transfer or stream runs.
	pendingVersion string
	// binDir is the folder of the fluxd binary at the start.
	binDir string
	// release is the last answer of the release check. releaseErr is the
	// error of the last check, or "". releaseTried is the time of the last
	// check. releaseWake starts a check when one is due.
	release      releaseInfo
	releaseErr   string
	releaseTried time.Time
	releaseWake  chan struct{}

	// herdrPath is the API socket of herdr. herdrRunning, herdrAgents,
	// herdrTerms, herdrPlaces, and herdrKinds are the last state that the
	// herdr loop read. herdrHistory keeps the last plain history of each
	// agent for the reads while it works. herdrWake makes the loop check
	// the setting and read the session again.
	herdrPath    string
	herdrRunning bool
	herdrAgents  []HerdrAgent
	herdrTerms   []HerdrTerminal
	herdrPlaces  []HerdrWorkspace
	herdrKinds   []string
	herdrHistory map[string]agentHistory
	herdrWake    chan struct{}

	subs   map[int]func(event string, data any)
	nextID int
	dirty  chan struct{}
	ctx    context.Context
	logger *log.Logger

	// herdrJobs keeps the herdr work that runs for the phones.
	herdrJobs herdrJobs

	// content holds the workers and the limits of shares, the clipboard,
	// notifications, media, calls, and Do Not Disturb.
	content contentState

	// appSending is the name of the phone that gets the Android app from
	// sendAppUpdate, or "". Only 1 app update runs at a time, and Busy
	// counts it.
	appSending string

	// sessions is the state of the remote sessions: the input queue, the
	// streams, Browse PC, and the shortcut requests.
	sessions sessionState

	// ready closes when Run has started the network. fluxd serves the
	// socket only after that, because requests use the network.
	ready chan struct{}

	// releaseWoken is true when a wake came after the last release check.
	// After a failed check, the next check then runs releaseRetryGap after
	// the failure and not after releaseRetry.
	releaseWoken bool
	// trustNote tells the user that devices.json did not parse, or is "".
	// The first window that connects shows it, with a desktop
	// notification.
	trustNote string

	// lastClipAt is the time of the newest clipboard that fluxd took from
	// any source: a desktop copy, or a copied text, a shared text, or an
	// image from a device. For a flux.clipboard.connect packet, it is the
	// time of the copy on the device. A flux.clipboard.connect packet that
	// is not newer is stale.
	lastClipAt time.Time
}

// Options change how the daemon runs. The zero value is the normal mode.
type Options struct {
	// Headless turns off the desktop: clipboard, notifications, media,
	// sound, and mDNS. Discovery uses loopback only. Tests use it.
	Headless bool
	// UDPPort and FirstTCPPort change the protocol ports. Zero means 1716.
	UDPPort      int
	FirstTCPPort int
	// Version is the build version of fluxd.
	Version string
	// ReleaseURL is the GitHub API address of the latest release. Empty
	// turns the release check off. ReleaseDelay is the wait before the
	// first check after the start.
	ReleaseURL   string
	ReleaseDelay time.Duration
}

type clipboard interface {
	Watch(ctx context.Context, onText func(text string), onImage func(data []byte, mime string))
	Get() (string, error)
	GetImage() ([]byte, error)
	Set(text string) error
	SetImage(data []byte, mime string) error
}

// memClipboard is the clipboard of a headless daemon.
type memClipboard struct {
	mu    sync.Mutex
	text  string
	image []byte
	mime  string
}

func (m *memClipboard) Watch(ctx context.Context, _ func(string), _ func([]byte, string)) {
	<-ctx.Done()
}
func (m *memClipboard) Get() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.text, nil
}
func (m *memClipboard) GetImage() ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.image, nil
}
func (m *memClipboard) Set(text string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.text = text
	return nil
}
func (m *memClipboard) SetImage(data []byte, mime string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.image, m.mime = data, mime
	return nil
}

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
		clipDir: filepath.Join(config.RuntimeDir(), "clipboard"),
		input:   desktop.NewInput(),
		inputQ:  make(chan inputAction, inputQueue),
		subs:    map[int]func(string, any){},
		dirty:   make(chan struct{}, 1),
		ctx:     ctx,
		logger:  logger,

		herdrPath:   herdr.SocketPath(),
		herdrWake:   make(chan struct{}, 1),
		dndWake:     make(chan struct{}, 1),
		releaseWake: make(chan struct{}, 1),
	}
	d.ready = make(chan struct{})
	if exe, err := os.Executable(); err == nil {
		d.binDir = filepath.Dir(exe)
	}
	if opts.Headless {
		d.clip = &memClipboard{}
		// A headless daemon can share the runtime folder with the daemon of
		// the desktop, so it keeps its clipboard images in its own folder.
		d.clipDir = filepath.Join(os.TempDir(), "fluxd-clipboard-"+config.NewID(6))
		d.input = nil
	}
	if trust.Broken != "" {
		d.logf("%v. fluxd moved the file to %s and starts without paired devices", trust.BrokenErr, trust.Broken)
		d.trustNote = fmt.Sprintf("devices.json was damaged, so Flux starts without paired devices. Pair your devices again. The old file is %s", trust.Broken)
	}
	for _, t := range trust.All() {
		dev := d.deviceLocked(t.ID)
		if err := dev.applyTrust(t); err != nil {
			d.logf("devices.json: the certificate of %s (%s) does not parse: %v. fluxd refuses its links. To pair it again, run: flux-cli unpair %s", dev.Name, t.ID, err, t.ID)
		}
	}
	// The link handlers and the API read these fields without the lock, so
	// they are set before any link or request can come.
	if !opts.Headless {
		if n, err := desktop.NewNotifier(); err == nil {
			d.notifier = n
			n.OnAction(d.onNotificationAction)
		} else {
			d.logf("notifications off: %v", err)
		}
		if m, err := desktop.NewMedia(); err == nil {
			d.media = m
			d.callPlayers = m
			m.OnChange(d.onDesktopMediaChange)
		} else {
			d.logf("media control off: %v", err)
		}
		// The first link can come before the theme watch starts, so the
		// theme loads now.
		d.themePath = desktop.ThemePath()
		d.reloadTheme()
	}
	return d, nil
}

func (d *Daemon) logf(format string, args ...any) { d.logger.Printf(format, args...) }

// Ready returns a channel that closes when Run has started the network.
func (d *Daemon) Ready() <-chan struct{} { return d.ready }

// SetPendingVersion records the version of a new fluxd binary on disk.
func (d *Daemon) SetPendingVersion(v string) {
	d.mu.Lock()
	d.pendingVersion = v
	d.mu.Unlock()
	d.markDirty()
}

// Busy names the transfer, stream, or approval that a restart would stop.
// It returns "" when fluxd can restart.
func (d *Daemon) Busy() string {
	d.mu.Lock()
	for _, t := range d.transfers {
		if t.State == "queued" || t.State == "active" {
			d.mu.Unlock()
			return "a file transfer"
		}
	}
	what := ""
	switch {
	case d.webcam != nil:
		what = "the webcam"
	case d.mic != nil:
		what = "the microphone"
	case d.screen != nil:
		what = "the screen mirror"
	case d.desktop != nil:
		what = "the remote desktop"
	case len(d.sessions.browse) > 0:
		what = "Browse PC"
	case d.appSending != "":
		what = "the app update for " + d.appSending
	}
	d.mu.Unlock()
	if what == "" && d.approvals.pending() > 0 {
		what = "a fingerprint approval"
	}
	return what
}

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
	p := lan.New(lan.Config{
		Cert: d.cert,
		Identity: func() proto.Identity {
			id := proto.NewIdentity(d.selfID, d.Name(), 0)
			id.App, id.AppVersion = "fluxd", d.opts.Version
			return id
		},
		Trusted: d.pinFor,
		HasLink: func(id string) bool {
			d.mu.Lock()
			defer d.mu.Unlock()
			dev, ok := d.devices[id]
			return ok && dev.link != nil
		},
		OnLink:       d.onLink,
		OnIdentity:   d.onIdentity,
		OnOldApp:     d.onOldApp,
		Logf:         d.logf,
		UDPPort:      d.opts.UDPPort,
		FirstTCPPort: d.opts.FirstTCPPort,
		LoopbackOnly: d.opts.Headless,
	})
	if err := p.Start(ctx); err != nil {
		return err
	}
	d.mu.Lock()
	d.lan = p
	d.mu.Unlock()
	close(d.ready)
	d.logf("fluxd %s listening on TCP %d as %q", d.selfID, p.TCPPort(), d.Name())
	go d.releaseLoop(ctx)
	if d.opts.Headless {
		go d.publishLoop(ctx)
		go d.discoveryLoop(ctx)
		<-ctx.Done()
		d.closeLinks()
		return nil
	}
	mdns := lan.MDNSInfo{DeviceID: d.selfID, Name: d.Name(), Type: proto.DeviceType(), Protocol: proto.ProtocolVersion, Port: p.TCPPort(), Logf: d.logf}
	// StartMDNS returns an MDNS also with an error. The MDNS publishes this
	// computer when Avahi starts later.
	m, err := lan.StartMDNS(ctx, mdns, d.onMDNS)
	if err != nil {
		d.logf("mDNS off until Avahi starts, UDP discovery only: %v", err)
	}
	d.mu.Lock()
	d.mdns = m
	var paired []string
	for _, dev := range d.devices {
		if dev.Paired && dev.link == nil {
			paired = append(paired, dev.ID)
		}
	}
	d.mu.Unlock()
	// The first dial round can come before mDNS runs, so resolve the
	// paired devices now. A phone with a new address connects at once.
	// Refresh does nothing while Avahi does not run.
	for _, id := range paired {
		m.Refresh(id)
	}

	if dnd := desktop.NewDND(); dnd.Kind() != "" {
		d.mu.Lock()
		d.dnd = dnd
		d.mu.Unlock()
		d.logf("Do Not Disturb sync uses %s", dnd.Kind())
		go d.dndLoop(ctx)
	} else {
		d.logf("Do Not Disturb sync off: no supported notification service")
	}

	removeClipImages(d.clipDir)
	go d.clip.Watch(ctx, d.onLocalClipboard, d.onLocalImage)
	go d.inputLoop(ctx)
	go d.publishLoop(ctx)
	go d.discoveryLoop(ctx)
	go d.batteryLoop(ctx)
	go d.herdrLoop(ctx)
	go d.themeLoop(ctx)

	<-ctx.Done()
	d.closeLinks()
	removeClipImages(d.clipDir)
	_ = os.Remove(d.clipDir)
	if in, ok := d.input.(*desktop.Input); ok {
		in.Close()
	}
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
			d.resetDials()
			d.announce()
			d.wakeRelease()
			continue
		}
		d.closeIdleLinks(time.Now())
		if n%3 == 0 {
			d.dialKnown()
		}
		if n%6 == 0 && d.anyPairedOffline() {
			d.announce()
		}
	}
}

// provider returns the LAN provider, or nil before Run starts it.
func (d *Daemon) provider() *lan.Provider {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.lan
}

// announce broadcasts the identity and sends it to the last address of
// each paired device that is offline.
func (d *Daemon) announce() {
	p := d.provider()
	if p == nil {
		return
	}
	p.Broadcast()
	d.mu.Lock()
	var ips []string
	for _, dev := range d.devices {
		if dev.Paired && dev.link == nil && dev.IP != "" {
			ips = append(ips, dev.IP)
		}
	}
	d.mu.Unlock()
	for _, ip := range ips {
		p.Announce(ip)
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

// maxDiscovered is the number of devices from discovery that fluxd keeps
// while they are not paired, not connected, and have no pairing.
const maxDiscovered = 64

// discoveredLocked returns the device with the ID for a discovery packet.
// A new device replaces the oldest discovered device when fluxd keeps
// maxDiscovered of them, so that packets with new IDs cannot fill the
// memory. The caller holds d.mu.
func (d *Daemon) discoveredLocked(id string) *Device {
	if dev, ok := d.devices[id]; ok {
		return dev
	}
	var oldest *Device
	n := 0
	for _, dev := range d.devices {
		if !dev.forgettable() {
			continue
		}
		n++
		if oldest == nil || dev.lastHeard().Before(oldest.lastHeard()) {
			oldest = dev
		}
	}
	if n >= maxDiscovered && oldest != nil {
		delete(d.devices, oldest.ID)
	}
	return d.deviceLocked(id)
}

// forgettable reports whether fluxd can remove the device from its list:
// it is not paired, not connected, has no pairing, and gets no pair false
// on its next link.
func (dev *Device) forgettable() bool {
	return !dev.Paired && !dev.badTrust && dev.link == nil && dev.pairState == "" && !dev.unpairPeer
}

// lastHeard returns the last time that UDP or mDNS reported the device.
func (dev *Device) lastHeard() time.Time {
	if dev.mdnsSeen.After(dev.LastSeen) {
		return dev.mdnsSeen
	}
	return dev.LastSeen
}

// seenLocked records an address that UDP or mDNS reported. It changes the
// address of a device that is not paired. For a paired device, the address
// is only a dial candidate, because anyone on the network can send it. A
// connected device keeps the address of its link. The caller holds d.mu.
func (dev *Device) seenLocked(name, typ, ip string, port int, now time.Time) {
	dev.dialTries = 0
	switch {
	case dev.link != nil:
	case dev.Paired || dev.badTrust:
		dev.seenIP, dev.seenPort, dev.seenAt = ip, port, now
	default:
		dev.Name, dev.Type = proto.CleanName(name), proto.CleanType(typ)
		dev.IP = ip
		if port > 0 {
			dev.Port = port
		}
	}
}

// onMDNS records a device that mDNS found and connects to it. fluxd opens
// the connection, so it works with a firewall that blocks incoming
// traffic.
func (d *Daemon) onMDNS(peer lan.MDNSPeer) {
	if !proto.ValidDeviceID(peer.DeviceID) || peer.DeviceID == d.selfID {
		return
	}
	now := time.Now()
	d.mu.Lock()
	dev := d.discoveredLocked(peer.DeviceID)
	dev.LastSeen, dev.mdnsSeen = now, now
	dev.seenLocked(peer.Name, peer.Type, peer.IP, peer.Port, now)
	// Avahi can answer from its cache with an address that the device left.
	// Dial the extra addresses too, because this dial blocks other dials to
	// the device for 1 second.
	var addrs []string
	if dev.link == nil && !dev.badTrust {
		addrs = dev.dialAddrs(now)
	}
	target := proto.Identity{DeviceID: dev.ID, DeviceName: dev.Name, ProtocolVersion: peer.Protocol}
	p := d.lan
	d.mu.Unlock()
	if p != nil && len(addrs) > 0 {
		p.DialAddrs(d.ctx, addrs, target)
	}
}

// redialDelay is how long fluxd waits after a link drops before it dials
// the device again. The phone needs a moment to move to another network.
const redialDelay = 2 * time.Second

// fastDials is the number of dials to a paired device that is offline at
// the normal interval of 30 seconds. After them, fluxd dials the device
// every slowDial until it shows again or the network changes.
const fastDials = 20

// slowDial is the interval of the dials to a paired device that stays
// offline.
const slowDial = 2 * time.Minute

// forgetAfter is the time after which fluxd removes a device that is not
// paired, not connected, and not seen.
const forgetAfter = 10 * time.Minute

// unpairedIdle is how long a device that is not paired can keep its link
// without a pair request.
const unpairedIdle = 2 * time.Minute

// Limits for the links of devices that are not paired. When a new link
// passes a limit, fluxd closes the oldest link that has no pairing.
const (
	maxUnpairedLinks      = 8
	maxUnpairedLinksPerIP = 2
)

// resetDials gives each device the normal dial interval again.
func (d *Daemon) resetDials() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, dev := range d.devices {
		dev.dialTries = 0
	}
}

// dialKnown connects to each device that is offline and has a known
// address: paired devices, and devices that mDNS found in the last 10
// minutes. A paired device can also have extra addresses, for example a
// Tailscale name. dialKnown tries the last address first, then the address
// that discovery reported, then the extra addresses. It also sends a
// unicast UDP identity from port 1716 to the last address of each paired
// device. A device that answers from its port 1716 passes the firewall as
// a reply. It also removes the devices that it no longer needs.
func (d *Daemon) dialKnown() {
	type target struct {
		ip    string
		addrs []string
		id    proto.Identity
	}
	var targets []target
	var refresh []string
	d.mu.Lock()
	m := d.mdns
	p := d.lan
	now := time.Now()
	for id, dev := range d.devices {
		if dev.link != nil || dev.badTrust {
			continue
		}
		if dev.forgettable() && now.Sub(dev.LastSeen) > forgetAfter && now.Sub(dev.mdnsSeen) > forgetAfter {
			delete(d.devices, id)
			continue
		}
		if dev.Paired {
			// A device that stays away gets fewer dials.
			if dev.dialTries >= fastDials && now.Sub(dev.dialAt) < slowDial {
				continue
			}
			dev.dialTries++
			dev.dialAt = now
			// A paired device that is offline can have a new address. mDNS
			// gives it, and onMDNS then dials it.
			refresh = append(refresh, dev.ID)
		}
		addrs := dev.dialAddrs(now)
		if len(addrs) == 0 {
			continue
		}
		if !dev.Paired && now.Sub(dev.mdnsSeen) > 10*time.Minute {
			continue
		}
		// The unicast identity goes only to paired devices. It opens a way
		// through the firewall for the answer of the device.
		ip := ""
		if dev.Paired {
			ip = dev.IP
		}
		targets = append(targets, target{ip, addrs, proto.Identity{DeviceID: dev.ID, DeviceName: dev.Name, ProtocolVersion: dev.Version}})
	}
	d.mu.Unlock()
	for _, id := range refresh {
		m.Refresh(id)
	}
	if p == nil {
		return
	}
	for _, t := range targets {
		if t.ip != "" {
			p.Announce(t.ip)
		}
		p.DialAddrs(d.ctx, t.addrs, t.id)
	}
}

// onIdentity records a device seen by UDP.
func (d *Daemon) onIdentity(id proto.Identity, ip string) {
	now := time.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	dev := d.discoveredLocked(id.DeviceID)
	dev.LastSeen = now
	dev.seenLocked(id.DeviceName, id.DeviceType, ip, id.TCPPort, now)
}

// pinFor returns the certificate that a new link of the device must
// present. The lan provider checks it before the identity exchange, and
// onLink checks it again under d.mu.
func (d *Daemon) pinFor(id string) (*x509.Certificate, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if dev, ok := d.devices[id]; ok {
		return dev.pinLocked()
	}
	return nil, false
}

// onLink takes over a new authenticated link.
func (d *Daemon) onLink(l *lan.Link) {
	d.mu.Lock()
	// A link of a new device counts as a discovery, so that links with new
	// IDs cannot fill the device list.
	dev := d.discoveredLocked(l.DeviceID())
	// A pairing can finish between the check of the provider and this
	// point, so the pin is checked again under the lock.
	if why := dev.refuseLocked(l); why != "" {
		name := dev.Name
		d.mu.Unlock()
		d.logf("%s (%s): %s, link refused", name, l.IP(), why)
		l.Close()
		return
	}
	old := dev.link
	if old != nil && lan.Preferred(old, l, d.selfID) == old {
		d.mu.Unlock()
		l.Close()
		return
	}
	// A pairing ends with its link. The device can pair again on the new
	// link, after pairRetry when it had an incoming request.
	stopped := dev.pairState != "" && dev.pairLink != l
	var note uint32
	if stopped {
		note = dev.pairLinkEndedLocked()
	}
	dev.link = l
	dev.ignored = 0
	dev.setIdentity(l.Identity)
	dev.IP = l.IP()
	if l.PeerPort > 0 {
		dev.Port = l.PeerPort
	}
	dev.seenIP, dev.seenPort = "", 0
	dev.LastSeen = time.Now()
	dev.dialTries = 0
	dev.Cert = l.Cert
	paired := dev.Paired
	l.SetPaired(paired)
	if paired && dev.supports(proto.TypeNotification) {
		// onPairedLink asks for every active notification again. The list
		// then drops the notifications that the device removed while it was
		// away. The clear comes before the first packet of the link.
		dev.notifications = nil
	}
	var evict []*lan.Link
	if !paired {
		evict = d.unpairedOverflowLocked(l)
	}
	// The device pinned this computer in a pairing that ended before the
	// user of this computer confirmed it. Only a link with the certificate
	// of that pairing clears the flag, so that another host with the device
	// ID cannot take the pair false of the device.
	unpair := dev.unpairPeer && !paired && l.Cert != nil && dev.unpairCert.Equal(l.Cert)
	if unpair {
		dev.unpairPeer, dev.unpairCert = false, nil
	}
	name, typ, ip, port := dev.Name, dev.Type, dev.IP, dev.Port
	d.mu.Unlock()
	d.closeNotes(note)
	for _, e := range evict {
		d.logf("%s: too many links of devices that are not paired, closing the oldest", e.Identity.DeviceName)
		e.Close()
	}
	if old != nil && old != l {
		old.Close()
	}
	d.logf("link up: %s (%s) paired=%v", name, ip, paired)
	if unpair {
		_ = l.Send(proto.New(proto.TypePair, map[string]any{"pair": false}))
	}
	if stopped {
		d.toast("Pairing with %s stopped, because the connection changed. Pair again", name)
	}
	if paired {
		_ = d.trust.Update(dev.ID, func(t *config.TrustedDevice) {
			t.Name, t.Type, t.LastIP = name, typ, ip
			if port > 0 {
				t.LastPort = port
			}
		})
	}
	d.markDirty()
	go d.receive(dev, l)
	// The desktop calls of onPairedLink can be slow, so they do not delay
	// the packets of the device.
	if paired {
		go d.onPairedLink(dev, l)
	}
}

// unpairedOverflowLocked returns the links to close after l joined: the
// oldest links of devices that are not paired, when there are more than
// maxUnpairedLinks, or more than maxUnpairedLinksPerIP from the address of
// l. A link with an open pairing stays. The caller holds d.mu.
func (d *Daemon) unpairedOverflowLocked(l *lan.Link) []*lan.Link {
	var all, sameIP []*lan.Link
	candidates := map[*lan.Link]bool{}
	for _, dev := range d.devices {
		o := dev.link
		if o == nil || dev.Paired {
			continue
		}
		all = append(all, o)
		if o.IP() == l.IP() {
			sameIP = append(sameIP, o)
		}
		if o != l && dev.pairState == "" {
			candidates[o] = true
		}
	}
	var out []*lan.Link
	trim := func(links []*lan.Link, limit int) {
		sort.Slice(links, func(i, j int) bool { return links[i].Started.Before(links[j].Started) })
		extra := len(links) - limit
		for _, o := range links {
			if extra <= 0 {
				return
			}
			if candidates[o] {
				delete(candidates, o)
				out = append(out, o)
				extra--
			}
		}
	}
	trim(sameIP, maxUnpairedLinksPerIP)
	var rest []*lan.Link
	for _, o := range all {
		if !slices.Contains(out, o) {
			rest = append(rest, o)
		}
	}
	trim(rest, maxUnpairedLinks)
	return out
}

// closeIdleLinks closes the links of devices that are not paired and sent
// no pair request for unpairedIdle. fluxd then does not dial the device
// again until the device shows again.
func (d *Daemon) closeIdleLinks(now time.Time) {
	var idle []*lan.Link
	d.mu.Lock()
	for _, dev := range d.devices {
		l := dev.link
		if l == nil || dev.Paired || dev.pairState != "" {
			continue
		}
		if now.Sub(l.Started) > unpairedIdle && now.Sub(dev.pairAt) > unpairedIdle {
			idle = append(idle, l)
			dev.mdnsSeen = time.Time{}
		}
	}
	d.mu.Unlock()
	for _, l := range idle {
		d.logf("%s: not paired and no pair request for %v, closing the link", l.Identity.DeviceName, unpairedIdle)
		l.Close()
	}
}

// receive reads the packets of a link until it closes.
func (d *Daemon) receive(dev *Device, l *lan.Link) {
	err := l.Receive(func(p *proto.Packet) { d.dispatch(dev, l, p) })
	d.mu.Lock()
	current := dev.link == l
	if current {
		dev.link = nil
		dev.LastSeen = time.Now()
	}
	var note uint32
	stopped := false
	if current || dev.pairLink == l {
		state := dev.pairState
		stopped = state == "requested" || state == "confirm"
		note = dev.pairLinkEndedLocked()
	}
	name := dev.Name
	d.mu.Unlock()
	d.closeNotes(note)
	d.logf("link down: %s: %v", name, err)
	if stopped {
		d.toast("Pairing with %s stopped, because the connection closed", name)
	}
	d.markDirty()
	// The device can be back at once on another address, for example
	// through Tailscale after it left the Wi-Fi. Do not wait for the next
	// round of dialKnown.
	if current && d.ctx.Err() == nil {
		time.AfterFunc(redialDelay, d.dialKnown)
	}
}

// dispatch handles 1 packet of a link. A panic in a handler drops the
// packet, logs the stack, and keeps the link and fluxd running. When the
// handler left d.mu locked, fluxd stops instead.
func (d *Daemon) dispatch(dev *Device, l *lan.Link, p *proto.Packet) {
	defer d.recoverPacket(l, p)
	d.handlePacket(dev, l, p)
}

// muWait is how long recoverPacket waits for d.mu after a panic. Tests
// make it shorter.
var muWait = 2 * time.Second

// exitProcess stops fluxd. Tests replace it.
var exitProcess = os.Exit

// recoverPacket stops a panic of a packet handler and logs it with the
// stack. Only a deferred call can stop the panic.
func (d *Daemon) recoverPacket(l *lan.Link, p *proto.Packet) {
	r := recover()
	if r == nil {
		return
	}
	// The handler can hold d.mu, so the name comes from the link.
	name := ""
	if l != nil {
		name = l.Identity.DeviceName
	}
	d.logf("%s: the %s packet failed: %v\n%s", name, logType(p.Type), r, debug.Stack())
	// A handler that panics between d.mu.Lock and d.mu.Unlock leaves d.mu
	// locked, and then each link and each API call waits for ever. fluxd
	// then stops with an error, and systemd starts it again.
	if !d.muFree(muWait) {
		d.logf("%s: the %s packet left the daemon locked, so fluxd stops", name, logType(p.Type))
		exitProcess(1)
	}
}

// muFree reports whether d.mu becomes free within wait. Another goroutine
// can hold d.mu for a short time, so muFree tries again until wait ends.
func (d *Daemon) muFree(wait time.Duration) bool {
	end := time.Now().Add(wait)
	for {
		if d.mu.TryLock() {
			d.mu.Unlock()
			return true
		}
		if time.Now().After(end) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// logType returns a packet type for a log line: quoted, and cut to 64
// bytes, because the device chooses it.
func logType(t string) string {
	if len(t) > 64 {
		t = t[:64] + "…"
	}
	return fmt.Sprintf("%q", t)
}

// onPairedLink sends the packets that a paired device expects after it
// connects.
func (d *Daemon) onPairedLink(dev *Device, l *lan.Link) {
	d.mu.Lock()
	notifications := dev.supports(proto.TypeNotification)
	dnd, input := dev.accepts(proto.TypeFluxDnd), dev.accepts(proto.TypeFluxInput)
	players, herdr := dev.supports(proto.TypeMprisRequest), dev.accepts(proto.TypeFluxHerdr)
	d.mu.Unlock()
	d.sendBattery(l)
	d.sendCommandList(l)
	d.sendConnectClipboard(l)
	if notifications {
		d.requestNotifications(dev, l)
	}
	if dnd {
		d.wakeDnd()
	}
	if input {
		d.sendInputState(l)
	}
	if d.media != nil && players {
		// A player that does not answer must not delay the link.
		d.runMedia(func() { d.sendPlayers(l) })
	}
	if herdr {
		d.mu.Lock()
		state := herdrStatePacket(d.herdrViewLocked())
		d.mu.Unlock()
		_ = l.Send(state)
	}
	d.sendThemeTo(dev, l)
}

// markDirty schedules a state event for all subscribers.
func (d *Daemon) markDirty() {
	select {
	case d.dirty <- struct{}{}:
	default:
	}
}

// publishLoop sends at most 1 state event every 100 ms. It sends no event
// when no client listens or when the state did not change.
func (d *Daemon) publishLoop(ctx context.Context) {
	var last json.RawMessage
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.dirty:
		}
		time.Sleep(100 * time.Millisecond)
		d.mu.Lock()
		subs := make([]func(string, any), 0, len(d.subs))
		for _, s := range d.subs {
			subs = append(subs, s)
		}
		d.mu.Unlock()
		if len(subs) == 0 {
			last = nil
			continue
		}
		snap := d.Snapshot()
		if bytes.Equal(snap, last) {
			continue
		}
		last = snap
		for _, s := range subs {
			s("state", snap)
		}
	}
}

// Subscribe registers a receiver for events. It sends the current state at
// once. The first receiver also gets the note about a damaged
// devices.json. The returned function removes the receiver.
func (d *Daemon) Subscribe(send func(event string, data any)) func() {
	d.mu.Lock()
	d.nextID++
	id := d.nextID
	d.subs[id] = send
	note := d.trustNote
	d.trustNote = ""
	d.mu.Unlock()
	send("state", d.Snapshot())
	if note != "" {
		send("toast", map[string]string{"text": note})
		d.notify(desktop.Notification{Title: "Flux lost the paired devices", Body: note, Timeout: -1})
	}
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

// send sends a feature packet to a device. It returns an API error when
// the device is not paired or offline, so that no feature reaches a device
// after an unpair. A button of an old desktop notification then also does
// not reach an unpaired device. The pairing code sends pair packets on the
// link directly.
func (d *Daemon) send(dev *Device, p *proto.Packet) error {
	d.mu.Lock()
	l, paired := dev.link, dev.Paired
	err := offline(dev)
	if l != nil && !paired {
		err = apiErr("not_paired", "%s is not paired", dev.Name)
	}
	d.mu.Unlock()
	if l == nil || !paired {
		return err
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
