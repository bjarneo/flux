package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"flux/internal/herdr"
)

func TestWebcamSettings(t *testing.T) {
	cfg, err := webcamSettings([]string{"aspect=1:1", "resolution=1080", "mirror=true", "brightness=-0.2", "whiteBalance=daylight"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg["aspect"] != "1:1" || cfg["resolution"] != 1080.0 || cfg["mirror"] != true || cfg["brightness"] != -0.2 || cfg["whiteBalance"] != "daylight" {
		t.Fatalf("settings: %#v", cfg)
	}
	if _, err := webcamSettings([]string{"aspect"}); err == nil {
		t.Fatal("a setting without = must fail")
	}
	if _, err := webcamSettings([]string{"white_balance=daylight"}); err == nil {
		t.Fatal("an unknown setting must fail")
	}
}

// The status shows the ID and the fingerprint of each device, so that the
// user can give the ID when 2 devices have 1 name.
func TestPrintStatus(t *testing.T) {
	var s State
	raw := `{"self":{"name":"desk","type":"desktop","tcpPort":1716},"devices":[
		{"id":"a1b2c3","name":"Pixel 8","type":"phone","online":true,"paired":true,"pairState":"paired","fingerprint":"71C0E5A93B2D8F46"},
		{"id":"d4e5f6","name":"Pixel 8","type":"phone","pairState":"none","fingerprint":""}]}`
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	printStatus(&b, &s)
	out := b.String()
	if !strings.Contains(out, "ID a1b2c3 · certificate 71C0 E5A9 3B2D 8F46\n") {
		t.Errorf("no ID and fingerprint of the first device:\n%s", out)
	}
	if !strings.Contains(out, "ID d4e5f6\n") || strings.Count(out, "certificate") != 1 {
		t.Errorf("the second device has no fingerprint:\n%s", out)
	}
}

// doctor says that herdr does not run only for a plain connection
// failure. Another error, such as a socket of another user, shows as it is.
func TestHerdrDown(t *testing.T) {
	dir := t.TempDir()
	_, err := herdr.Ping(context.Background(), filepath.Join(dir, "none.sock"))
	if !herdrDown(err) {
		t.Errorf("a missing socket: %v", err)
	}
	path := filepath.Join(dir, "herdr.sock")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	// The socket file stays, and nothing listens on it.
	ln.SetUnlinkOnClose(false)
	ln.Close()
	if _, err := herdr.Ping(context.Background(), path); !herdrDown(err) {
		t.Errorf("a socket without a server: %v", err)
	}
	if herdrDown(errors.New("herdr: the socket belongs to user 1001, not to user 1000")) {
		t.Error("the owner check is not a plain connection failure")
	}
}
