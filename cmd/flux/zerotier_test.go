package main

import (
	"slices"
	"strings"
	"testing"
)

// avahiInterfaces reads the interface lists of the server section only and
// skips comments.
func TestAvahiInterfaces(t *testing.T) {
	conf := `[server]
use-ipv4=yes
#allow-interfaces=eth0
allow-interfaces= wlan0 , ztabc,
deny-interfaces=docker0
[reflector]
deny-interfaces=ztabc
`
	allow, deny := avahiInterfaces(conf)
	if !slices.Equal(allow, []string{"wlan0", "ztabc"}) {
		t.Errorf("allow = %q, want wlan0 and ztabc", allow)
	}
	if !slices.Equal(deny, []string{"docker0"}) {
		t.Errorf("deny = %q, want docker0", deny)
	}
}

// doctor checks each ZeroTier interface. A computer without ZeroTier gets
// no line, and a stopped zerotier-one gets a note and no problem.
func TestCheckZeroTier(t *testing.T) {
	good := ztIface{Name: "ztabc", Up: true, Broadcast: true, Multicast: true, IPv4: []string{"10.1.2.3/24"}}
	with := func(f func(*ztIface)) []ztIface {
		z := good
		f(&z)
		return []ztIface{z}
	}
	cases := []struct {
		name     string
		running  bool
		ifaces   []ztIface
		conf     string
		out      string
		pass     string
		problems []string
	}{
		{name: "no zerotier"},
		{name: "no network", running: true, out: "- zerotier-one runs and has joined no network. To find devices through ZeroTier, run: sudo zerotier-cli join NETWORK\n"},
		{name: "stopped", ifaces: []ztIface{good}, out: "- zerotier-one does not run, so its networks carry no traffic. Run: sudo systemctl enable --now zerotier-one\n"},
		{name: "good", running: true, ifaces: []ztIface{good}, pass: "ZeroTier network ztabc (10.1.2.3/24) carries mDNS and broadcasts, so fluxd can find devices on it"},
		{name: "allowed", running: true, ifaces: []ztIface{good}, conf: "[server]\nallow-interfaces=wlan0,ztabc\n", pass: "ZeroTier network ztabc (10.1.2.3/24) carries mDNS and broadcasts, so fluxd can find devices on it"},
		{
			name: "down", running: true, ifaces: with(func(z *ztIface) { z.Up = false }),
			problems: []string{"ztabc is down, so fluxd cannot find devices through ZeroTier. Check: zerotier-cli listnetworks"},
		},
		{
			name: "ipv6 only", running: true, ifaces: with(func(z *ztIface) { z.IPv4 = nil }),
			problems: []string{"ztabc has no IPv4 address, and Flux finds devices over IPv4 only. Give the ZeroTier network an IPv4 range"},
		},
		{
			name: "no multicast", running: true, ifaces: with(func(z *ztIface) { z.Multicast = false }),
			problems: []string{"ztabc has no broadcast or multicast, so fluxd cannot find devices through it"},
		},
		{
			name: "not allowed", running: true, ifaces: []ztIface{good}, conf: "[server]\nallow-interfaces=wlan0\n",
			problems: []string{"Avahi does not use ztabc, so fluxd cannot find devices through it with mDNS. Add ztabc to allow-interfaces in /etc/avahi/avahi-daemon.conf"},
		},
		{
			name: "denied", running: true, ifaces: []ztIface{good}, conf: "[server]\ndeny-interfaces=ztabc\n",
			problems: []string{"Avahi does not use ztabc, so fluxd cannot find devices through it with mDNS. Remove ztabc from deny-interfaces in /etc/avahi/avahi-daemon.conf"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var out strings.Builder
			var passes, problems []string
			check := func(ok bool, pass, fix string) {
				if ok {
					passes = append(passes, pass)
				} else {
					problems = append(problems, fix)
				}
			}
			checkZeroTier(c.running, c.ifaces, c.conf, &out, check)
			if out.String() != c.out {
				t.Errorf("output %q, want %q", out.String(), c.out)
			}
			var wantPasses []string
			if c.pass != "" {
				wantPasses = []string{c.pass}
			}
			if !slices.Equal(passes, wantPasses) {
				t.Errorf("passes %q, want %q", passes, wantPasses)
			}
			if !slices.Equal(problems, c.problems) {
				t.Errorf("problems %q, want %q", problems, c.problems)
			}
		})
	}
}
