package main

import (
	"errors"
	"strings"
	"testing"

	"flux/internal/lan"
)

// The CLI keeps its own copy of the discovery port, because it does not
// import the lan package.
func TestDiscoveryPortMatchesFluxd(t *testing.T) {
	if discoveryPort != lan.UDPPort {
		t.Fatalf("doctor checks UDP port %d, and fluxd listens on %d", discoveryPort, lan.UDPPort)
	}
}

// doctor checks that no other program listens on the UDP port of
// discovery. Each other program is a problem with a fix. A failed ss is no
// problem.
func TestCheckDiscoveryPort(t *testing.T) {
	cases := []struct {
		name     string
		holders  []string
		err      error
		out      []string
		problems []string
	}{
		{name: "free", out: []string{"✓ no other program uses UDP port 12100"}},
		{name: "no ss", err: errors.New("exec: ss: not found"), out: []string{"? Cannot run ss, so Flux cannot check UDP port 12100"}},
		{
			name:    "taken",
			holders: []string{"socat", ""},
			problems: []string{
				"socat also uses UDP port 12100, so devices cannot always reach fluxd. Stop it: pkill -x socat",
				"a program of another user also uses UDP port 12100, so devices cannot always reach fluxd. Find it: sudo ss -ulnp 'sport = :12100'",
			},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var asked []int
			holders := func(port int) ([]string, error) {
				asked = append(asked, port)
				return c.holders, c.err
			}
			var out strings.Builder
			var problems []string
			check := func(ok bool, pass, fix string) {
				if !ok {
					problems = append(problems, fix)
				}
			}
			checkDiscoveryPort(holders, &out, check)
			if len(asked) != 1 || asked[0] != 12100 {
				t.Errorf("doctor asked for the ports %v, want 12100", asked)
			}
			for _, line := range c.out {
				if !strings.Contains(out.String(), line+"\n") {
					t.Errorf("no line %q in:\n%s", line, out.String())
				}
			}
			if strings.Join(problems, "\n") != strings.Join(c.problems, "\n") {
				t.Errorf("problems:\n%s\nwant:\n%s", strings.Join(problems, "\n"), strings.Join(c.problems, "\n"))
			}
		})
	}
}

// doctor reports whether the phone can show the live terminal. The herdr
// server and the herdr CLI that fluxd runs both need herdr 0.9.3, and
// the live terminal needs herdr_control. A setting that turns the live
// terminal off gives a note and not a problem.
func TestCheckLiveTerminal(t *testing.T) {
	state := func(running bool, bridge []string, path, version, err string) *State {
		s := &State{}
		s.Herdr.Running, s.Herdr.Bridge = running, bridge
		s.Herdr.CLI.Path, s.Herdr.CLI.Version, s.Herdr.CLI.Error = path, version, err
		s.Herdr.Enabled, s.Herdr.Control = true, true
		return s
	}
	controlOff := func(s *State) *State {
		s.Herdr.Control = false
		return s
	}
	herdrOff := func(s *State) *State {
		s.Herdr.Enabled, s.Herdr.Control = false, false
		return s
	}
	caps := []string{"observe", "control", "scroll", "mouse"}
	cases := []struct {
		name    string
		server  string
		fluxd   *State
		pass    string
		out     string
		problem string
	}{
		{name: "both new", server: "0.9.3", fluxd: state(true, caps, "/usr/bin/herdr", "0.9.3", ""),
			pass: "herdr 0.9.3 runs, and fluxd runs /usr/bin/herdr 0.9.3, so the phone can show the live terminal"},
		{name: "old server", server: "0.9.1", fluxd: state(true, nil, "", "", ""),
			problem: "The live terminal on the phone needs herdr 0.9.3 or newer, and herdr 0.9.1 runs. Run: herdr update"},
		{name: "old CLI", server: "0.9.3", fluxd: state(true, nil, "/usr/bin/herdr", "0.9.1", ""),
			problem: "The live terminal on the phone needs herdr 0.9.3 or newer, and fluxd runs /usr/bin/herdr 0.9.1. Update that herdr, or put a newer herdr first in the PATH of fluxd.service. Then run: systemctl --user restart fluxd"},
		{name: "no CLI", server: "0.9.3", fluxd: state(true, nil, "herdr", "", "exec: not found"),
			problem: "The live terminal on the phone needs the herdr CLI in the PATH of fluxd.service, and fluxd cannot run it: exec: not found. After the fix, run: systemctl --user restart fluxd"},
		{name: "no fluxd", server: "0.9.3",
			out: "- The live terminal on the phone needs herdr 0.9.3 or newer for the herdr server and for the herdr CLI that fluxd runs. fluxd does not answer, so doctor cannot check that CLI"},
		{name: "no fluxd and an old server", server: "0.9.1",
			problem: "The live terminal on the phone needs herdr 0.9.3 or newer, and herdr 0.9.1 runs. Run: herdr update"},
		{name: "not checked yet", server: "0.9.3", fluxd: state(false, nil, "", "", ""),
			out: "- The live terminal on the phone needs herdr 0.9.3 or newer for the herdr server and for the herdr CLI that fluxd runs. fluxd did not check its herdr CLI yet"},
		// The bridge works, but the phone shows no Live key without
		// herdr_control.
		{name: "control off", server: "0.9.3", fluxd: controlOff(state(true, caps, "/usr/bin/herdr", "0.9.3", "")),
			out: "- The live terminal on the phone needs herdr_control = true in config.toml"},
		// With control off, an old herdr is no problem of the doctor.
		{name: "control off and an old server", server: "0.9.1", fluxd: controlOff(state(true, nil, "", "", "")),
			out: "- The live terminal on the phone needs herdr_control = true in config.toml"},
		{name: "herdr off", server: "0.9.3", fluxd: herdrOff(state(false, nil, "", "", "")),
			out: "- The live terminal on the phone needs herdr = true and herdr_control = true in config.toml"},
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
			checkLiveTerminal(c.server, c.fluxd, &out, check)
			if strings.Join(passes, "\n") != c.pass || strings.Join(problems, "\n") != c.problem {
				t.Errorf("passes %q, problems %q", passes, problems)
			}
			if strings.TrimSpace(out.String()) != c.out {
				t.Errorf("out %q, want %q", out.String(), c.out)
			}
		})
	}
}
