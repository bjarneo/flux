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
