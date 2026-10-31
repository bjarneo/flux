package main

import (
	"fmt"
	"strconv"
	"strings"
)

// Flux ports that a paired computer dials on the phone: the link range and
// the payload, tunnel, and stream range. The app picks these ports itself,
// so the node forwards all of them.
var fluxPorts = append(rangePorts(12070, 12099), rangePorts(12100, 12108)...)

func rangePorts(first, last int) []int {
	out := make([]int, 0, last-first+1)
	for p := first; p <= last; p++ {
		out = append(out, p)
	}
	return out
}

// parsePorts returns the Flux ports for an empty list, or the listed ports.
func parsePorts(s string) ([]int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return append([]int(nil), fluxPorts...), nil
	}
	var out []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		p, err := strconv.Atoi(part)
		if err != nil || p < 1 || p > 65535 {
			return nil, fmt.Errorf("invalid port %q", part)
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no ports")
	}
	return out, nil
}
