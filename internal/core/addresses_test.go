package core

import (
	"slices"
	"testing"
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

func TestDialHosts(t *testing.T) {
	dev := &Device{IP: "192.168.1.20", Port: 1716, Addresses: []string{"pixel-8", "192.168.1.20", "100.101.102.103"}}
	if got, want := dev.dialHosts(), []string{"192.168.1.20", "pixel-8", "100.101.102.103"}; !slices.Equal(got, want) {
		t.Fatalf("dialHosts = %v, want %v", got, want)
	}
	if dev.dialPort() != 1716 {
		t.Fatalf("dialPort = %d", dev.dialPort())
	}
	dev = &Device{Addresses: []string{"pixel-8"}}
	if got := dev.dialHosts(); !slices.Equal(got, []string{"pixel-8"}) || dev.dialPort() != 1716 {
		t.Fatalf("without a last address: hosts %v, port %d", got, dev.dialPort())
	}
	if got := (&Device{}).dialHosts(); len(got) != 0 || (&Device{}).dialPort() != 0 {
		t.Fatalf("a device without addresses has hosts %v", got)
	}
}
