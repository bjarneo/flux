package main

import (
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestSplitDeviceStopsAtDoubleDash(t *testing.T) {
	args, device := splitDevice([]string{"notify", "--device", "Pixel 8", "--run", "--", "ssh", "-d", "host"})
	if device != "Pixel 8" {
		t.Fatalf("device %q", device)
	}
	if !slices.Equal(args, []string{"notify", "--run", "--", "ssh", "-d", "host"}) {
		t.Fatalf("args %q", args)
	}
}

func TestCommandResult(t *testing.T) {
	code, title, body := commandResult([]string{"/usr/bin/make", "-j8"}, nil, 72*time.Second)
	if code != 0 || title != "make finished" || body != "/usr/bin/make -j8 · 1m 12s" {
		t.Fatalf("success: %d %q %q", code, title, body)
	}

	err := exec.Command("sh", "-c", "exit 3").Run()
	code, title, _ = commandResult([]string{"sh", "-c", "exit 3"}, err, time.Second)
	if code != 3 || title != "sh failed (exit 3)" {
		t.Fatalf("exit 3: %d %q", code, title)
	}

	err = exec.Command("sh", "-c", "kill -TERM $$").Run()
	code, title, _ = commandResult([]string{"sh"}, err, time.Second)
	if code != 143 || !strings.HasPrefix(title, "sh stopped") {
		t.Fatalf("signal: %d %q", code, title)
	}

	_, err = exec.LookPath("flux-no-such-command")
	code, title, _ = commandResult([]string{"flux-no-such-command"}, err, 0)
	if code != 127 || title != "flux-no-such-command failed (not found)" {
		t.Fatalf("not found: %d %q", code, title)
	}
}

func TestDuration(t *testing.T) {
	for d, want := range map[time.Duration]string{
		0:                                     "0s",
		42 * time.Second:                      "42s",
		72 * time.Second:                      "1m 12s",
		2*time.Hour + 3*time.Minute:           "2h 3m",
		59*time.Second + 600*time.Millisecond: "1m 0s",
	} {
		if got := duration(d); got != want {
			t.Errorf("%v: got %q, want %q", d, got, want)
		}
	}
}
