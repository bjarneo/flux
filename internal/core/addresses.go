package core

import (
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
)

// maxAddresses limits the extra addresses of one device. fluxd tries them
// one after another, so a long list delays the last address.
const maxAddresses = 5

// Extra addresses let fluxd reach a paired device outside the local
// network, for example through Tailscale. mDNS and UDP broadcasts do not
// cross a VPN, so fluxd dials each address directly. The device listens on
// all interfaces, and fluxd opens every connection, so the payloads,
// tunnels, and streams also use the address of the link.

// normalizeAddress checks an address that the user gives and returns its
// canonical form: an IP address, or a host name in lower case.
func normalizeAddress(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", apiErr("bad_params", "Give a host name or an IP address")
	}
	if strings.Contains(s, "://") || strings.Contains(s, "/") {
		return "", apiErr("bad_address", "%q is not a host name or an IP address. Give the host only, for example pixel-8 or 100.101.102.103", raw)
	}
	if ip, err := netip.ParseAddr(strings.TrimSuffix(strings.TrimPrefix(s, "["), "]")); err == nil {
		if ip.IsUnspecified() || ip.IsMulticast() {
			return "", apiErr("bad_address", "%s cannot be the address of a device", ip)
		}
		return ip.String(), nil
	}
	if strings.Contains(s, ":") {
		return "", apiErr("bad_address", "Give %q without a port. fluxd uses the TCP port of the device", raw)
	}
	name := strings.ToLower(strings.TrimSuffix(s, "."))
	if !validHostName(name) {
		return "", apiErr("bad_address", "%q is not a valid host name", raw)
	}
	return name, nil
}

// validHostName checks a DNS name: labels of 1 to 63 letters, digits, and
// hyphens, 253 characters or fewer in total.
func validHostName(name string) bool {
	if name == "" || len(name) > 253 {
		return false
	}
	for label := range strings.SplitSeq(name, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
				return false
			}
		}
	}
	return true
}

// AddAddress adds an extra address to a paired device and saves it in the
// trust store. fluxd then dials the device at once when it is offline. It
// returns the address in its canonical form and the new list.
func (d *Daemon) AddAddress(dev *Device, raw string) (string, []string, error) {
	addr, err := normalizeAddress(raw)
	if err != nil {
		return "", nil, err
	}
	full := false
	err = d.trust.Update(dev.ID, func(t *config.TrustedDevice) {
		switch {
		case slices.Contains(t.Addresses, addr):
		case len(t.Addresses) >= maxAddresses:
			full = true
		default:
			// Clone the list. Other copies of the entry share its array.
			t.Addresses = append(slices.Clone(t.Addresses), addr)
		}
	})
	if err != nil {
		return "", nil, err
	}
	if full {
		return "", nil, apiErr("too_many", "%s has %d addresses. Remove 1 first", dev.Name, maxAddresses)
	}
	addrs := d.syncAddresses(dev)
	go d.dialKnown()
	return addr, addrs, nil
}

// RemoveAddress removes an extra address from a paired device. It returns
// the address in its canonical form and the new list.
func (d *Daemon) RemoveAddress(dev *Device, raw string) (string, []string, error) {
	addr, err := normalizeAddress(raw)
	if err != nil {
		return "", nil, err
	}
	found := false
	err = d.trust.Update(dev.ID, func(t *config.TrustedDevice) {
		if slices.Contains(t.Addresses, addr) {
			found = true
			t.Addresses = slices.DeleteFunc(slices.Clone(t.Addresses), func(a string) bool { return a == addr })
		}
	})
	if err != nil {
		return "", nil, err
	}
	if !found {
		return "", nil, apiErr("not_found", "%s has no address %s", dev.Name, addr)
	}
	return addr, d.syncAddresses(dev), nil
}

// syncAddresses copies the addresses from the trust store to the device
// and publishes the state.
func (d *Daemon) syncAddresses(dev *Device) []string {
	t, _ := d.trust.Get(dev.ID)
	d.mu.Lock()
	dev.Addresses = t.Addresses
	d.mu.Unlock()
	d.markDirty()
	if t.Addresses == nil {
		return []string{}
	}
	return t.Addresses
}

// dialPort returns the TCP port that fluxd dials. A device with extra
// addresses and no known port gets the default port. The caller holds
// d.mu.
func (dev *Device) dialPort() int {
	if dev.Port == 0 && len(dev.Addresses) > 0 {
		return lan.MinTCPPort
	}
	return dev.Port
}

// dialAddrs returns the addresses that fluxd dials for an offline device,
// as host and port: the last address, then the address that discovery
// reported in the last forgetAfter, then the extra addresses. The extra
// addresses use the port of the last link, because discovery does not
// change the port of a paired device. The caller holds d.mu.
func (dev *Device) dialAddrs(now time.Time) []string {
	var out []string
	add := func(host string, port int) {
		if host == "" || port <= 0 {
			return
		}
		if a := net.JoinHostPort(host, strconv.Itoa(port)); !slices.Contains(out, a) {
			out = append(out, a)
		}
	}
	port := dev.dialPort()
	add(dev.IP, port)
	if dev.seenIP != "" && now.Sub(dev.seenAt) < forgetAfter {
		seen := dev.seenPort
		if seen == 0 {
			seen = port
		}
		add(dev.seenIP, seen)
	}
	for _, a := range dev.Addresses {
		add(a, port)
	}
	return out
}
