package lan

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// mDNS through the Avahi daemon on the system bus. Omarchy installs and
// starts avahi-daemon. The iOS app finds desktops only through mDNS, and
// the Android app uses it next to UDP broadcasts.
const (
	avahiBus      = "org.freedesktop.Avahi"
	avahiServer   = "org.freedesktop.Avahi.Server"
	avahiGroup    = "org.freedesktop.Avahi.EntryGroup"
	avahiBrowser  = "org.freedesktop.Avahi.ServiceBrowser"
	busName       = "org.freedesktop.DBus"
	serviceType   = "_flux._udp"
	ifaceUnspec   = int32(-1)
	protoInet     = int32(0)
	lookupNoFlags = uint32(0)
)

// The wait before the next attempt to connect to the system bus or to
// publish through Avahi again. It starts at mdnsRetryMin and doubles after
// each failure, up to mdnsRetryMax.
const (
	mdnsRetryMin = time.Second
	mdnsRetryMax = time.Minute
)

// MDNSInfo is what the mDNS record announces.
type MDNSInfo struct {
	DeviceID string
	Name     string
	Type     string
	Protocol int
	Port     int
	// Logf receives a line when the system bus closes, when Avahi stops,
	// and when mDNS runs again. It can be nil.
	Logf func(format string, args ...any)
}

// MDNSPeer is a device that mDNS found.
type MDNSPeer struct {
	DeviceID string
	Name     string
	Type     string
	Protocol int
	IP       string
	Port     int
}

// MDNS is a running mDNS publisher and browser.
type MDNS struct {
	self  string
	found func(MDNSPeer)

	mu     sync.Mutex
	server dbus.BusObject
}

// avahi is 1 connection to the system bus. While Avahi runs, it also has
// the published service and the browser. group is nil when Avahi does not
// publish the service.
type avahi struct {
	conn    *dbus.Conn
	server  dbus.BusObject
	group   dbus.BusObject
	browser dbus.ObjectPath
	signals chan *dbus.Signal
}

// Refresh resolves the service of deviceID again, and calls found with its
// address now. The browser reports a service only when its name is new. A
// phone keeps its name when it gets a new address, so fluxd must resolve
// it again to find the phone. A nil MDNS does nothing.
func (m *MDNS) Refresh(deviceID string) {
	if m == nil || deviceID == "" || deviceID == m.self {
		return
	}
	m.mu.Lock()
	server := m.server
	m.mu.Unlock()
	if server == nil {
		return
	}
	go resolve(server, ifaceUnspec, protoInet, deviceID, serviceType, "local", m.found)
}

// setServer sets the Avahi server for Refresh. A nil server stops Refresh
// while Avahi does not run.
func (m *MDNS) setServer(server dbus.BusObject) {
	m.mu.Lock()
	m.server = server
	m.mu.Unlock()
}

// StartMDNS publishes this device and browses for other devices, and calls
// found for each device that it resolves. The default ufw rules of Omarchy
// let mDNS in, so this path works with a firewall that blocks all other
// incoming traffic. When Avahi is not available, StartMDNS returns the
// error, and the returned MDNS publishes the device when Avahi starts. When
// the system bus closes or Avahi starts again later, the MDNS publishes the
// device again.
func StartMDNS(ctx context.Context, info MDNSInfo, found func(MDNSPeer)) (*MDNS, error) {
	m := &MDNS{self: info.DeviceID, found: found}
	a, err := dialBus()
	if err == nil {
		if err = a.publish(info, 0); err == nil {
			m.server = a.server
		}
	}
	go m.run(ctx, info, a)
	return m, err
}

// dialBus connects to the system bus and receives the signals for mDNS:
// a new owner of the Avahi name, and the devices that the browser finds.
func dialBus() (*avahi, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, err
	}
	// Add the match rules before the browser exists, so no ItemNew signal
	// is lost.
	rules := [][]dbus.MatchOption{
		{dbus.WithMatchSender(busName), dbus.WithMatchInterface(busName), dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, avahiBus)},
		{dbus.WithMatchInterface(avahiBrowser), dbus.WithMatchMember("ItemNew")},
	}
	for _, rule := range rules {
		if err := conn.AddMatchSignal(rule...); err != nil {
			conn.Close()
			return nil, err
		}
	}
	signals := make(chan *dbus.Signal, 32)
	conn.Signal(signals)
	return &avahi{conn: conn, server: conn.Object(avahiBus, "/"), signals: signals}, nil
}

// publish publishes the service through Avahi and starts the browser.
// With dbus.FlagNoAutoStart in flags, the bus does not start Avahi for
// the calls.
func (a *avahi) publish(info MDNSInfo, flags dbus.Flags) error {
	var groupPath dbus.ObjectPath
	if err := a.server.Call(avahiServer+".EntryGroupNew", flags).Store(&groupPath); err != nil {
		return fmt.Errorf("avahi: %w", err)
	}
	a.group = a.conn.Object(avahiBus, groupPath)
	txt := [][]byte{
		[]byte("id=" + info.DeviceID),
		[]byte("name=" + info.Name),
		[]byte("type=" + info.Type),
		[]byte(fmt.Sprintf("protocol=%d", info.Protocol)),
	}
	err := a.group.Call(avahiGroup+".AddService", flags, ifaceUnspec, protoInet, uint32(0),
		info.DeviceID, serviceType, "", "", uint16(info.Port), txt).Err
	if err != nil {
		err = fmt.Errorf("avahi add service: %w", err)
	} else if err = a.group.Call(avahiGroup+".Commit", flags).Err; err != nil {
		err = fmt.Errorf("avahi commit: %w", err)
	} else if err = a.server.Call(avahiServer+".ServiceBrowserNew", flags, ifaceUnspec, protoInet, serviceType, "", lookupNoFlags).Store(&a.browser); err != nil {
		err = fmt.Errorf("avahi browse: %w", err)
	}
	if err != nil {
		// The connection stays open, so Avahi keeps the group until a
		// call frees it.
		a.unpublish()
	}
	return err
}

// unpublish frees the service and the browser of a, when Avahi still has
// them. The bus does not start Avahi for the calls.
func (a *avahi) unpublish() {
	if a.group != nil {
		_ = a.group.Call(avahiGroup+".Free", dbus.FlagNoAutoStart).Err
	}
	if a.browser != "" {
		_ = a.conn.Object(avahiBus, a.browser).Call(avahiBrowser+".Free", dbus.FlagNoAutoStart).Err
	}
	a.group, a.browser = nil, ""
}

// run resolves the devices that the browser of a finds until ctx ends. a
// is nil when the system bus is not connected. When the bus closes, run
// connects again. When Avahi stops, run waits for it. When Avahi starts,
// run publishes the service again at once. It waits before each other
// attempt, and the wait doubles after each failure. A retry does not ask
// the bus to start Avahi.
func (m *MDNS) run(ctx context.Context, info MDNSInfo, a *avahi) {
	logf := info.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	wait := mdnsRetryMin
	for {
		if a == nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
			wait = nextRetry(wait)
			var err error
			if a, err = dialBus(); err != nil {
				continue
			}
		}
		var retry <-chan time.Time
		if a.group == nil {
			if a.publish(info, dbus.FlagNoAutoStart) == nil {
				wait = mdnsRetryMin
				m.setServer(a.server)
				logf("mDNS: connected to Avahi")
			} else {
				retry = time.After(wait)
			}
		}
		switch watch(ctx, a.conn.Context().Done(), a.signals, retry, func(sig *dbus.Signal) { m.itemNew(a, sig) }) {
		case ctxDone:
			a.unpublish()
			a.conn.Close()
			return
		case busClosed:
			a.conn.Close()
			a = nil
			m.setServer(nil)
			logf("mDNS: the system bus closed, connecting again")
		case avahiStopped:
			a.unpublish()
			m.setServer(nil)
			logf("mDNS: Avahi stopped, waiting for it to start again")
		case avahiStarted:
			// A publish after the stop can already use the new Avahi, so
			// free that service before the next publish.
			a.unpublish()
			m.setServer(nil)
			wait = mdnsRetryMin
		case retryNow:
			wait = nextRetry(wait)
		}
	}
}

// watchEnd tells why watch returned.
type watchEnd int

const (
	ctxDone      watchEnd = iota // the context ended
	busClosed                    // the bus connection closed
	avahiStopped                 // Avahi left the bus
	avahiStarted                 // Avahi joined the bus
	retryNow                     // the retry time came
)

// watch passes each signal to item until ctx ends, the bus connection
// closes, Avahi stops or starts, or the time comes on retry. godbus closes
// signals and closed when the connection closes. retry can be nil.
func watch(ctx context.Context, closed <-chan struct{}, signals <-chan *dbus.Signal, retry <-chan time.Time, item func(*dbus.Signal)) watchEnd {
	for {
		select {
		case <-ctx.Done():
			return ctxDone
		case <-closed:
			return busClosed
		case <-retry:
			return retryNow
		case sig, ok := <-signals:
			if !ok {
				return busClosed
			}
			if sig == nil {
				continue
			}
			if owner, ok := avahiOwner(sig); ok {
				if owner == "" {
					return avahiStopped
				}
				return avahiStarted
			}
			item(sig)
		}
	}
}

// avahiOwner returns the new owner of the Avahi name when sig is a
// NameOwnerChanged signal of the bus for that name. An empty owner means
// that Avahi stopped. Only the bus can send a signal as busName.
func avahiOwner(sig *dbus.Signal) (string, bool) {
	if sig.Sender != busName || sig.Name != busName+".NameOwnerChanged" || len(sig.Body) != 3 {
		return "", false
	}
	name, _ := sig.Body[0].(string)
	owner, ok := sig.Body[2].(string)
	return owner, ok && name == avahiBus
}

// nextRetry returns the wait after wait: 2 times wait, up to mdnsRetryMax.
func nextRetry(wait time.Duration) time.Duration {
	return min(2*wait, mdnsRetryMax)
}

// itemNew resolves the service of an ItemNew signal from the browser of a.
func (m *MDNS) itemNew(a *avahi, sig *dbus.Signal) {
	if sig.Path != a.browser || len(sig.Body) < 5 {
		return
	}
	iface, _ := sig.Body[0].(int32)
	proto, _ := sig.Body[1].(int32)
	name, _ := sig.Body[2].(string)
	typ, _ := sig.Body[3].(string)
	domain, _ := sig.Body[4].(string)
	if name == m.self {
		return
	}
	go resolve(a.server, iface, proto, name, typ, domain, m.found)
}

func resolve(server dbus.BusObject, iface, proto int32, name, typ, domain string, found func(MDNSPeer)) {
	var (
		rIface, rProto, aProto int32
		rName, rType, rDomain  string
		host, address          string
		port                   uint16
		txt                    [][]byte
		flags                  uint32
	)
	err := server.Call(avahiServer+".ResolveService", 0, iface, proto, name, typ, domain, protoInet, lookupNoFlags).
		Store(&rIface, &rProto, &rName, &rType, &rDomain, &host, &aProto, &address, &port, &txt, &flags)
	ip := net.ParseIP(address)
	if err != nil || ip == nil || ip.To4() == nil || ip.IsLoopback() {
		return
	}
	peer := MDNSPeer{DeviceID: name, IP: address, Port: int(port), Protocol: 8}
	for _, entry := range txt {
		k, v, _ := strings.Cut(string(entry), "=")
		switch k {
		case "id":
			peer.DeviceID = v
		case "name":
			peer.Name = v
		case "type":
			peer.Type = v
		case "protocol":
			if n, err := strconv.Atoi(v); err == nil {
				peer.Protocol = n
			}
		}
	}
	found(peer)
}
