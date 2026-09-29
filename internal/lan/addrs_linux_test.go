//go:build linux

package lan

import (
	"net"
	"slices"
	"testing"
)

// TestIPv4NetsMatchesAddrs checks that the 1 netlink request finds the same
// IPv4 networks as Interface.Addrs for each interface.
func TestIPv4NetsMatchesAddrs(t *testing.T) {
	ifaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	strs := func(nets []*net.IPNet) []string {
		out := make([]string, 0, len(nets))
		for _, n := range nets {
			out = append(out, n.String())
		}
		slices.Sort(out)
		return out
	}
	got, want := ipv4Nets(ifaces), interfaceNets(ifaces)
	if len(want) == 0 {
		t.Skip("no interface has an IPv4 address")
	}
	for _, ifc := range ifaces {
		if g, w := strs(got[ifc.Index]), strs(want[ifc.Index]); !slices.Equal(g, w) {
			t.Errorf("%s: netlink found %v, Addrs found %v", ifc.Name, g, w)
		}
	}
}
