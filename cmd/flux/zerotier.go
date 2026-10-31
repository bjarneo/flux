package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
)

// avahiConf is the configuration of avahi-daemon. Its allow-interfaces and
// deny-interfaces lines decide which interfaces carry mDNS.
const avahiConf = "/etc/avahi/avahi-daemon.conf"

// ztIface is a ZeroTier network interface as doctor sees it.
type ztIface struct {
	Name      string
	Up        bool
	Broadcast bool
	Multicast bool
	IPv4      []string
}

// zerotierIfaces returns the ZeroTier interfaces of this computer.
// ZeroTier names each interface zt and an id of the network, for example
// ztrgg3ljah.
func zerotierIfaces() []ztIface {
	all, _ := net.Interfaces()
	var out []ztIface
	for _, ifc := range all {
		if !strings.HasPrefix(ifc.Name, "zt") {
			continue
		}
		z := ztIface{
			Name:      ifc.Name,
			Up:        ifc.Flags&net.FlagUp != 0,
			Broadcast: ifc.Flags&net.FlagBroadcast != 0,
			Multicast: ifc.Flags&net.FlagMulticast != 0,
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
				z.IPv4 = append(z.IPv4, ipn.String())
			}
		}
		out = append(out, z)
	}
	return out
}

// avahiInterfaces returns the allow-interfaces and deny-interfaces lists
// of an avahi-daemon configuration. Empty lists let Avahi use every
// interface with multicast.
func avahiInterfaces(conf string) (allow, deny []string) {
	split := func(v string) []string {
		var out []string
		for _, name := range strings.Split(v, ",") {
			if name = strings.TrimSpace(name); name != "" {
				out = append(out, name)
			}
		}
		return out
	}
	section := ""
	sc := bufio.NewScanner(strings.NewReader(conf))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.Trim(line, "[]")
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok || section != "server" {
			continue
		}
		switch strings.TrimSpace(k) {
		case "allow-interfaces":
			allow = split(v)
		case "deny-interfaces":
			deny = split(v)
		}
	}
	return allow, deny
}

// checkZeroTier checks that each ZeroTier network can carry the discovery
// of Flux. ZeroTier makes a virtual Ethernet network, so the mDNS of Avahi
// and the UDP broadcasts of fluxd reach the devices on it, as on the local
// network. running reports whether zerotier-one runs. conf is the Avahi
// configuration. doctor prints nothing for a computer without ZeroTier.
func checkZeroTier(running bool, ifaces []ztIface, conf string, w io.Writer, check func(ok bool, pass, fix string)) {
	if len(ifaces) == 0 {
		if running {
			fmt.Fprintln(w, "- zerotier-one runs and has joined no network. To find devices through ZeroTier, run: sudo zerotier-cli join NETWORK")
		}
		return
	}
	if !running {
		fmt.Fprintln(w, "- zerotier-one does not run, so its networks carry no traffic. Run: sudo systemctl enable --now zerotier-one")
		return
	}
	allow, deny := avahiInterfaces(conf)
	for _, z := range ifaces {
		switch {
		case !z.Up:
			check(false, "", fmt.Sprintf("%s is down, so fluxd cannot find devices through ZeroTier. Check: zerotier-cli listnetworks", z.Name))
		case len(z.IPv4) == 0:
			check(false, "", fmt.Sprintf("%s has no IPv4 address, and Flux finds devices over IPv4 only. Give the ZeroTier network an IPv4 range", z.Name))
		case !z.Broadcast || !z.Multicast:
			check(false, "", fmt.Sprintf("%s has no broadcast or multicast, so fluxd cannot find devices through it", z.Name))
		case len(allow) > 0 && !slices.Contains(allow, z.Name):
			check(false, "", fmt.Sprintf("Avahi does not use %s, so fluxd cannot find devices through it with mDNS. Add %s to allow-interfaces in %s", z.Name, z.Name, avahiConf))
		case slices.Contains(deny, z.Name):
			check(false, "", fmt.Sprintf("Avahi does not use %s, so fluxd cannot find devices through it with mDNS. Remove %s from deny-interfaces in %s", z.Name, z.Name, avahiConf))
		default:
			check(true, fmt.Sprintf("ZeroTier network %s (%s) carries mDNS and broadcasts, so fluxd can find devices on it", z.Name, strings.Join(z.IPv4, ", ")), "")
		}
	}
}
