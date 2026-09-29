package main

import (
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
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
	code, title, body := commandResult([]string{"/usr/bin/make", "-j8"}, false, nil, 72*time.Second)
	if code != 0 || title != "make finished" || body != "make · 1m 12s" {
		t.Fatalf("success: %d %q %q", code, title, body)
	}

	err := exec.Command("sh", "-c", "exit 3").Run()
	code, title, _ = commandResult([]string{"sh", "-c", "exit 3"}, false, err, time.Second)
	if code != 3 || title != "sh failed (exit 3)" {
		t.Fatalf("exit 3: %d %q", code, title)
	}

	err = exec.Command("sh", "-c", "kill -TERM $$").Run()
	code, title, _ = commandResult([]string{"sh"}, false, err, time.Second)
	if code != 143 || !strings.HasPrefix(title, "sh stopped") {
		t.Fatalf("signal: %d %q", code, title)
	}

	_, err = exec.LookPath("flux-no-such-command")
	code, title, _ = commandResult([]string{"flux-no-such-command"}, false, err, 0)
	if code != 127 || title != "flux-no-such-command failed (not found)" {
		t.Fatalf("not found: %d %q", code, title)
	}
}

// The phone can show the body on its lock screen, so the arguments, which
// can hold a secret, go to the phone only with --show-command.
func TestCommandResultHidesArguments(t *testing.T) {
	args := []string{"curl", "-H", "Authorization: Bearer secret", "https://example.com"}
	_, _, body := commandResult(args, false, nil, time.Second)
	if strings.Contains(body, "secret") || body != "curl · 1s" {
		t.Fatalf("body %q", body)
	}
	_, _, body = commandResult(args, true, nil, time.Second)
	if body != strings.Join(args, " ")+" · 1s" {
		t.Fatalf("--show-command: %q", body)
	}
	long := []string{"echo", strings.Repeat("é", 300)}
	_, _, body = commandResult(long, true, nil, time.Second)
	if len(body) > maxShown+len("… · 1s") || !utf8.ValidString(body) {
		t.Fatalf("a long command: %d bytes, valid %v", len(body), utf8.ValidString(body))
	}
}

// Free text after the command keeps -d and --device, so `commands add`
// stores the command that the user typed.
func TestSplitDeviceKeepsFreeText(t *testing.T) {
	cases := []struct {
		in     []string
		args   []string
		device string
	}{
		{[]string{"-d", "Pixel", "ring"}, []string{"ring"}, "Pixel"},
		{[]string{"ring", "--device=Pixel"}, []string{"ring"}, "Pixel"},
		{[]string{"status", "--json", "-d", "Pixel"}, []string{"status", "--json"}, "Pixel"},
		{[]string{"commands", "add", "Sync", "rsync", "-a", "-d", "src", "dst"}, []string{"commands", "add", "Sync", "rsync", "-a", "-d", "src", "dst"}, ""},
		{[]string{"-d", "Pixel", "sms", "+1555", "call -d me"}, []string{"sms", "+1555", "call -d me"}, "Pixel"},
		{[]string{"ping", "hello", "--device", "Pixel"}, []string{"ping", "hello", "--device", "Pixel"}, ""},
	}
	for _, c := range cases {
		args, device := splitDevice(c.in)
		if !slices.Equal(args, c.args) || device != c.device {
			t.Errorf("%q: args %q device %q", c.in, args, device)
		}
	}
}

func TestCommandLine(t *testing.T) {
	for words, want := range map[string]string{
		"rsync -a src dst":        "rsync -a src dst",
		"xdg-open\x00My File.pdf": "xdg-open 'My File.pdf'",
		"echo\x00it's\x00$HOME":   `echo 'it'\''s' '$HOME'`,
		"true\x00":                "true ''",
	} {
		if got := commandLine(strings.Split(words, "\x00")); got != want {
			t.Errorf("%q: got %q, want %q", words, got, want)
		}
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
