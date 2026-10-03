package core

import (
	"slices"
	"testing"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

func TestNormalizeAddress(t *testing.T) {
	good := map[string]string{
		"pixel-8":                       "pixel-8",
		" Pixel-8.tailnet-name.ts.net.": "pixel-8.tailnet-name.ts.net",
		"100.101.102.103":               "100.101.102.103",
		"fd7a:115c:a1e0::1234":          "fd7a:115c:a1e0::1234",
		"[FD7A:115C:A1E0::1234]":        "fd7a:115c:a1e0::1234",
		"localhost":                     "localhost",
	}
	for in, want := range good {
		got, err := normalizeAddress(in)
		if err != nil || got != want {
			t.Errorf("normalizeAddress(%q) = %q, %v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{
		"", "  ", "pixel-8:12100", "100.101.102.103:12100", "https://pixel-8",
		"pixel 8", "-phone", "phone-", "a..b", "0.0.0.0", "::", "224.0.0.251",
		"phone_1",
	} {
		if got, err := normalizeAddress(in); err == nil {
			t.Errorf("normalizeAddress(%q) = %q, want an error", in, got)
		}
	}
}

func TestDialAddrs(t *testing.T) {
	now := time.Now()
	dev := &Device{IP: "192.168.1.20", Port: 12100, Addresses: []string{"pixel-8", "192.168.1.20", "100.101.102.103"}}
	if got, want := dev.dialAddrs(now), []string{"192.168.1.20:12100", "pixel-8:12100", "100.101.102.103:12100"}; !slices.Equal(got, want) {
		t.Fatalf("dialAddrs = %v, want %v", got, want)
	}
	if dev.dialPort() != 12100 {
		t.Fatalf("dialPort = %d", dev.dialPort())
	}
	dev = &Device{Addresses: []string{"pixel-8"}}
	if got := dev.dialAddrs(now); !slices.Equal(got, []string{"pixel-8:12100"}) || dev.dialPort() != 12100 {
		t.Fatalf("without a last address: addresses %v, port %d", got, dev.dialPort())
	}
	if got := (&Device{}).dialAddrs(now); len(got) != 0 || (&Device{}).dialPort() != 0 {
		t.Fatalf("a device without addresses has addresses %v", got)
	}
	// An address from discovery comes after the last address, with its own
	// port, and the extra addresses keep the port of the last link.
	dev = &Device{IP: "192.168.1.20", Port: 12100, Addresses: []string{"pixel-8"}, seenIP: "192.168.1.30", seenPort: 12101, seenAt: now}
	if got, want := dev.dialAddrs(now), []string{"192.168.1.20:12100", "192.168.1.30:12101", "pixel-8:12100"}; !slices.Equal(got, want) {
		t.Fatalf("with a discovery address: %v, want %v", got, want)
	}
	if got := dev.dialAddrs(now.Add(forgetAfter)); slices.Contains(got, "192.168.1.30:12101") {
		t.Fatalf("an old discovery address stays: %v", got)
	}
}

// A paired device from before the port change has a port that the
// provider refuses. fluxd dials the first port of Flux instead, so that an
// extra address works before the next link. A provider with other ports
// for tests keeps every port.
func TestFixPorts(t *testing.T) {
	id := func() proto.Identity { return proto.Identity{} }
	d := &Daemon{devices: map[string]*Device{
		"old":     {Port: 1716, Addresses: []string{"pixel-8"}},
		"current": {Port: lan.MaxTCPPort},
		"none":    {},
	}}
	d.fixPortsLocked(lan.New(lan.Config{Identity: id}))
	for name, want := range map[string]int{"old": lan.MinTCPPort, "current": lan.MaxTCPPort, "none": 0} {
		if got := d.devices[name].Port; got != want {
			t.Errorf("%s: port %d, want %d", name, got, want)
		}
	}
	if got := d.devices["old"].dialAddrs(time.Now()); !slices.Equal(got, []string{"pixel-8:12100"}) {
		t.Errorf("dialAddrs = %v", got)
	}

	d.devices["test"] = &Device{Port: 28720}
	d.fixPortsLocked(lan.New(lan.Config{Identity: id, FirstTCPPort: 28720}))
	if got := d.devices["test"].Port; got != 28720 {
		t.Errorf("a test daemon changed the port to %d", got)
	}
}
