package core

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// TestWakeTargets checks which network cards fluxd sends for Wake-on-LAN,
// their order, and their broadcast addresses.
func TestWakeTargets(t *testing.T) {
	dir := t.TempDir()
	old := sysClassNet
	sysClassNet = dir
	t.Cleanup(func() { sysClassNet = old })
	for _, name := range []string{"eno1", "eno2", "wlan0"} {
		if err := os.MkdirAll(filepath.Join(dir, name, "device"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(dir, "wlan0", "wireless"), 0o755); err != nil {
		t.Fatal(err)
	}
	mac := func(s string) net.HardwareAddr {
		m, err := net.ParseMAC(s)
		if err != nil {
			t.Fatal(err)
		}
		return m
	}
	ifaces := []net.Interface{
		{Name: "lo", Flags: net.FlagLoopback},
		{Name: "wlan0", HardwareAddr: mac("aa:aa:aa:aa:aa:03")},
		{Name: "eno2", HardwareAddr: mac("aa:aa:aa:aa:aa:02")},
		{Name: "eno1", HardwareAddr: mac("aa:aa:aa:aa:aa:01")},
		// A virtual interface has no device in sysfs.
		{Name: "docker0", HardwareAddr: mac("aa:aa:aa:aa:aa:04")},
		{Name: "tailscale0"},
	}
	addrs := func(i net.Interface) ([]net.Addr, error) {
		switch i.Name {
		case "eno1":
			_, n, _ := net.ParseCIDR("192.168.1.20/24")
			n.IP = net.ParseIP("192.168.1.20")
			return []net.Addr{n}, nil
		case "wlan0":
			_, n, _ := net.ParseCIDR("10.0.8.7/22")
			n.IP = net.ParseIP("10.0.8.7")
			return []net.Addr{&net.IPNet{IP: net.ParseIP("fe80::1"), Mask: net.CIDRMask(64, 128)}, n}, nil
		}
		return nil, errors.New("no address")
	}
	got := wakeTargets(ifaces, addrs)
	want := []wakeTarget{
		{MAC: "aa:aa:aa:aa:aa:01", Broadcast: "192.168.1.255"},
		{MAC: "aa:aa:aa:aa:aa:02"},
		{MAC: "aa:aa:aa:aa:aa:03", Broadcast: "10.0.11.255", Wireless: true},
	}
	if len(got) != len(want) {
		t.Fatalf("targets %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("target %d is %+v, want %+v", i, got[i], want[i])
		}
	}
}
