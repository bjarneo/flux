package core

import (
	"slices"
	"testing"
	"time"
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
		"", "  ", "pixel-8:1716", "100.101.102.103:1716", "https://pixel-8",
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
	dev := &Device{IP: "192.168.1.20", Port: 1716, Addresses: []string{"pixel-8", "192.168.1.20", "100.101.102.103"}}
	if got, want := dev.dialAddrs(now), []string{"192.168.1.20:1716", "pixel-8:1716", "100.101.102.103:1716"}; !slices.Equal(got, want) {
		t.Fatalf("dialAddrs = %v, want %v", got, want)
	}
	if dev.dialPort() != 1716 {
		t.Fatalf("dialPort = %d", dev.dialPort())
	}
	dev = &Device{Addresses: []string{"pixel-8"}}
	if got := dev.dialAddrs(now); !slices.Equal(got, []string{"pixel-8:1716"}) || dev.dialPort() != 1716 {
		t.Fatalf("without a last address: addresses %v, port %d", got, dev.dialPort())
	}
	if got := (&Device{}).dialAddrs(now); len(got) != 0 || (&Device{}).dialPort() != 0 {
		t.Fatalf("a device without addresses has addresses %v", got)
	}
	// An address from discovery comes after the last address, with its own
	// port, and the extra addresses keep the port of the last link.
	dev = &Device{IP: "192.168.1.20", Port: 1716, Addresses: []string{"pixel-8"}, seenIP: "192.168.1.30", seenPort: 1717, seenAt: now}
	if got, want := dev.dialAddrs(now), []string{"192.168.1.20:1716", "192.168.1.30:1717", "pixel-8:1716"}; !slices.Equal(got, want) {
		t.Fatalf("with a discovery address: %v, want %v", got, want)
	}
	if got := dev.dialAddrs(now.Add(forgetAfter)); slices.Contains(got, "192.168.1.30:1717") {
		t.Fatalf("an old discovery address stays: %v", got)
	}
}
