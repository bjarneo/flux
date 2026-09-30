package main

import (
	"bufio"
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
// user can give the ID when 2 devices have 1 name. The app update hint
// also names the device by its ID.
func TestPrintStatus(t *testing.T) {
	var s State
	raw := `{"self":{"name":"desk","type":"desktop","tcpPort":1716},"devices":[
		{"id":"a1b2c3","name":"Pixel 8","type":"phone","online":true,"paired":true,"pairState":"paired","fingerprint":"71C0E5A93B2D8F46","appUpdate":"1.2.0"},
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
	if !strings.Contains(out, "run: flux-cli --device a1b2c3 update --phone\n") {
		t.Errorf("the app update hint does not name the device ID:\n%s", out)
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

// TestFindPairing checks how flux-cli accept finds the key of a pairing.
func TestFindPairing(t *testing.T) {
	var s State
	raw := `{"devices":[
		{"id":"a1b2c3","name":"Pixel 8","pairState":"confirm","pairKey":"5EE6825F974ED59A"},
		{"id":"d4e5f6","name":"Pixel 8","pairState":"paired"},
		{"id":"f0f0f0","name":"Tab S9","pairState":"incoming","pairKey":"9B03E7D16A2FC048"},
		{"id":"e1e1e1","name":"tab s9","pairState":"incoming","pairKey":"1111222233334444"}]}`
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatal(err)
	}
	if id, key, err := findPairing(&s, "pixel 8"); err != nil || id != "a1b2c3" || key != "5EE6825F974ED59A" {
		t.Fatalf("a name: %s %s %v", id, key, err)
	}
	if id, key, err := findPairing(&s, "f0f0f0"); err != nil || id != "f0f0f0" || key != "9B03E7D16A2FC048" {
		t.Fatalf("an ID: %s %s %v", id, key, err)
	}
	if _, _, err := findPairing(&s, "Tab S9"); err == nil || !strings.Contains(err.Error(), "e1e1e1, f0f0f0") {
		t.Fatalf("2 requests with 1 name: %v", err)
	}
	if _, _, err := findPairing(&s, "d4e5f6"); err == nil {
		t.Fatal("a paired device has no open pairing")
	}
	if _, _, err := findPairing(&s, "Nothing"); err == nil {
		t.Fatal("an unknown name found a pairing")
	}
}

func TestSameKey(t *testing.T) {
	for answer, want := range map[string]bool{"y\n": true, " YES \n": true, "n\n": false, "\n": false, "": false, "5EE6 825F 974E D59A\n": false} {
		var out strings.Builder
		if got := sameKey(bufio.NewReader(strings.NewReader(answer)), &out, "Pixel 8", "5EE6 825F 974E D59A"); got != want {
			t.Errorf("answer %q: %v, want %v", answer, got, want)
		}
		if out.String() != "Does Pixel 8 show 5EE6 825F 974E D59A? [y/N] " {
			t.Errorf("prompt %q", out.String())
		}
	}
}

func TestValidKey(t *testing.T) {
	for key, want := range map[string]bool{"5EE6825F974ED59A": true, "5ee6825f974ed59a": false, "5EE6825F974ED59": false, "5EE6825F974ED59G": false, "": false} {
		if got := validKey(key); got != want {
			t.Errorf("validKey(%q) = %v, want %v", key, got, want)
		}
	}
}
