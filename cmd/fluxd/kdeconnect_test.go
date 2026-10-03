package main

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"
	"time"
)

type procs map[int]string

func (p procs) Info(pid int) (int, string, []string, bool) {
	comm, ok := p[pid]
	return 1, comm, nil, ok
}

func (p procs) PIDs() []int {
	var out []int
	for pid := range p {
		out = append(out, pid)
	}
	return out
}

func TestWarnKDEConnect(t *testing.T) {
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)
	warnKDEConnect(context.Background(), logger, procs{7: "kdeconnectd", 8: "fluxd"}, 0)
	if !strings.Contains(buf.String(), "kdeconnectd (PID 7) also uses UDP port 1716") ||
		!strings.Contains(buf.String(), "flux-cli setup") {
		t.Fatalf("log: %q", buf.String())
	}

	buf.Reset()
	warnKDEConnect(context.Background(), logger, procs{8: "fluxd"}, 0)
	if buf.Len() != 0 {
		t.Fatalf("log without kdeconnectd: %q", buf.String())
	}

	// A fluxd that stops before the check logs nothing.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	warnKDEConnect(ctx, logger, procs{7: "kdeconnectd"}, time.Hour)
	if buf.Len() != 0 {
		t.Fatalf("log after the stop: %q", buf.String())
	}
}
