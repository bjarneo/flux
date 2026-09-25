package lan

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"

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
	serviceType   = "_kdeconnect._udp"
	ifaceUnspec   = int32(-1)
	protoInet     = int32(0)
	lookupNoFlags = uint32(0)
)

// MDNSInfo is what the mDNS record announces.
type MDNSInfo struct {
	DeviceID string
	Name     string
	Type     string
	Protocol int
	Port     int
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
	server dbus.BusObject
	self   string
	found  func(MDNSPeer)
}

// Refresh resolves the service of deviceID again, and calls found with its
// address now. The browser reports a service only when its name is new. A
// phone keeps its name when it gets a new address, so fluxd must resolve
// it again to find the phone. A nil MDNS does nothing.
func (m *MDNS) Refresh(deviceID string) {
	if m == nil || deviceID == "" || deviceID == m.self {
		return
	}
	go resolve(m.server, ifaceUnspec, protoInet, deviceID, serviceType, "local", m.found)
}

// StartMDNS publishes this device and browses for other devices, and calls
// found for each device that it resolves. The default ufw rules of Omarchy
// let mDNS in, so this path works with a firewall that blocks all other
// incoming traffic. It returns an error when Avahi is not available.
func StartMDNS(ctx context.Context, info MDNSInfo, found func(MDNSPeer)) (*MDNS, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, err
	}
	server := conn.Object(avahiBus, "/")

	var groupPath dbus.ObjectPath
	if err := server.Call(avahiServer+".EntryGroupNew", 0).Store(&groupPath); err != nil {
		conn.Close()
		return nil, fmt.Errorf("avahi: %w", err)
	}
	group := conn.Object(avahiBus, groupPath)
	txt := [][]byte{
		[]byte("id=" + info.DeviceID),
		[]byte("name=" + info.Name),
		[]byte("type=" + info.Type),
		[]byte(fmt.Sprintf("protocol=%d", info.Protocol)),
	}
	if err := group.Call(avahiGroup+".AddService", 0, ifaceUnspec, protoInet, uint32(0),
		info.DeviceID, serviceType, "", "", uint16(info.Port), txt).Err; err != nil {
		conn.Close()
		return nil, fmt.Errorf("avahi add service: %w", err)
	}
	if err := group.Call(avahiGroup+".Commit", 0).Err; err != nil {
		conn.Close()
		return nil, fmt.Errorf("avahi commit: %w", err)
	}

	// Add the match rule before the browser exists, so no ItemNew signal is
	// lost.
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(avahiBrowser), dbus.WithMatchMember("ItemNew")); err != nil {
		conn.Close()
		return nil, err
	}
	signals := make(chan *dbus.Signal, 32)
	conn.Signal(signals)
	var browserPath dbus.ObjectPath
	if err := server.Call(avahiServer+".ServiceBrowserNew", 0, ifaceUnspec, protoInet, serviceType, "", lookupNoFlags).Store(&browserPath); err != nil {
		conn.Close()
		return nil, fmt.Errorf("avahi browse: %w", err)
	}

	go func() {
		defer conn.Close()
		for {
			select {
			case <-ctx.Done():
				_ = group.Call(avahiGroup+".Free", 0).Err
				return
			case sig := <-signals:
				if sig == nil || sig.Path != browserPath || len(sig.Body) < 5 {
					continue
				}
				iface, _ := sig.Body[0].(int32)
				proto, _ := sig.Body[1].(int32)
				name, _ := sig.Body[2].(string)
				typ, _ := sig.Body[3].(string)
				domain, _ := sig.Body[4].(string)
				if name == info.DeviceID {
					continue
				}
				go resolve(server, iface, proto, name, typ, domain, found)
			}
		}
	}()
	return &MDNS{server: server, self: info.DeviceID, found: found}, nil
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
