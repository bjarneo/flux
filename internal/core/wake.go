package core

import (
	"net"
	"os"
	"path/filepath"
	"slices"

	"flux/internal/lan"
	"flux/internal/proto"
)

// wakeTarget is 1 network card of this computer for Wake-on-LAN: its MAC
// address, and the IPv4 broadcast address of its network when it has one.
type wakeTarget struct {
	MAC       string `json:"mac"`
	Broadcast string `json:"broadcast,omitempty"`
	// Wireless is true for a Wi-Fi card. Few Wi-Fi cards wake a computer.
	Wireless bool `json:"wireless,omitempty"`
}

// maxWakeTargets is the most cards that fluxd sends.
const maxWakeTargets = 8

// sysClassNet is the folder of the network interfaces in sysfs. Tests
// change it.
var sysClassNet = "/sys/class/net"

// wakeTargets returns the physical network cards of this computer. A
// card counts when sysfs has a device for it, so loopback, Tailscale,
// Docker, and other virtual interfaces do not. The wired cards come
// first, because Wake-on-LAN works mostly on them.
func wakeTargets(ifaces []net.Interface, addrs func(net.Interface) ([]net.Addr, error)) []wakeTarget {
	var wired, wireless []wakeTarget
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagLoopback != 0 || len(ifc.HardwareAddr) != 6 {
			continue
		}
		if _, err := os.Stat(filepath.Join(sysClassNet, ifc.Name, "device")); err != nil {
			continue
		}
		t := wakeTarget{MAC: ifc.HardwareAddr.String()}
		if as, err := addrs(ifc); err == nil {
			for _, a := range as {
				n, ok := a.(*net.IPNet)
				if !ok || n.IP.To4() == nil {
					continue
				}
				ip, mask := n.IP.To4(), net.IP(n.Mask).To4()
				if mask == nil {
					continue
				}
				b := make(net.IP, 4)
				for i := range b {
					b[i] = ip[i] | ^mask[i]
				}
				t.Broadcast = b.String()
				break
			}
		}
		if _, err := os.Stat(filepath.Join(sysClassNet, ifc.Name, "wireless")); err == nil {
			t.Wireless = true
			wireless = append(wireless, t)
		} else {
			wired = append(wired, t)
		}
	}
	// In each group, a card with an address comes first, because it is
	// the card that the computer uses now.
	withAddress := func(a, b wakeTarget) int {
		switch {
		case a.Broadcast != "" && b.Broadcast == "":
			return -1
		case a.Broadcast == "" && b.Broadcast != "":
			return 1
		}
		return 0
	}
	slices.SortStableFunc(wired, withAddress)
	slices.SortStableFunc(wireless, withAddress)
	all := append(wired, wireless...)
	if len(all) > maxWakeTargets {
		all = all[:maxWakeTargets]
	}
	return all
}

// sendWakeTargets sends the network cards of this computer to the phone
// of the link l, so that the phone can wake the computer later.
func (d *Daemon) sendWakeTargets(l *lan.Link) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return
	}
	targets := wakeTargets(ifaces, func(i net.Interface) ([]net.Addr, error) { return i.Addrs() })
	if len(targets) == 0 {
		return
	}
	_ = l.Send(proto.New(proto.TypeFluxWake, map[string]any{"targets": targets}))
}
