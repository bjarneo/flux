package core

import (
	"io"
	"log"
	"slices"
	"testing"

	"flux/internal/config"
	"flux/internal/proto"
)

// TestRunCommandRunsOnlyConfiguredIDs checks that a device runs only a
// command whose ID is in config.toml, and that the command text comes from
// config.toml and not from the packet.
func TestRunCommandRunsOnlyConfiguredIDs(t *testing.T) {
	var ran []string
	old := runDesktopCommand
	runDesktopCommand = func(command string, _ func(error, []byte)) error {
		ran = append(ran, command)
		return nil
	}
	defer func() { runDesktopCommand = old }()
	d := &Daemon{
		cfg:    &config.Config{Commands: []config.Command{{ID: "lock", Name: "Lock", Command: "loginctl lock-session"}}},
		logger: log.New(io.Discard, "", 0),
	}
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	run := func(key string) {
		d.handleRunCommand(dev, nil, proto.New(proto.TypeRunCommandRequest, map[string]any{"key": key, "command": "rm -rf ~"}))
	}
	for _, key := range []string{"unknown", "loginctl lock-session", "LOCK", "lock ", ""} {
		run(key)
	}
	if len(ran) != 0 {
		t.Fatalf("keys that are not in config.toml ran %q", ran)
	}
	run("lock")
	if !slices.Equal(ran, []string{"loginctl lock-session"}) {
		t.Fatalf("ran %q, want the command of config.toml", ran)
	}
}
