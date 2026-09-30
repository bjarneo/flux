package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"flux/internal/herdr"
	"flux/internal/ipc"
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
	for _, v := range []string{"resolution=1e300", "resolution=-9.2e18", "resolution=720.5", "zoom=inf", "zoom=NaN", "warmth=-70000"} {
		if _, err := webcamSettings([]string{v}); err == nil {
			t.Errorf("%s: no error", v)
		}
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

// TestFindPairing checks how flux-cli accept and flux-cli reject find the
// key of a pairing.
func TestFindPairing(t *testing.T) {
	var s State
	raw := `{"devices":[
		{"id":"a1b2c3","name":"Pixel 8","pairState":"confirm","pairKey":"5EE6825F974ED59A"},
		{"id":"d4e5f6","name":"Pixel 8","pairState":"paired"},
		{"id":"f0f0f0","name":"Tab S9","pairState":"incoming","pairKey":"9B03E7D16A2FC048"},
		{"id":"e1e1e1","name":"tab s9","pairState":"incoming","pairKey":"1111222233334444"},
		{"id":"c7c7c7","name":"Pixel 7","pairState":"requested","pairKey":"AAAABBBBCCCCDDDD"}]}`
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatal(err)
	}
	if id, key, err := findPairing(&s, "pixel 8", false); err != nil || id != "a1b2c3" || key != "5EE6825F974ED59A" {
		t.Fatalf("a name: %s %s %v", id, key, err)
	}
	if id, key, err := findPairing(&s, "f0f0f0", false); err != nil || id != "f0f0f0" || key != "9B03E7D16A2FC048" {
		t.Fatalf("an ID: %s %s %v", id, key, err)
	}
	if _, _, err := findPairing(&s, "Tab S9", false); err == nil || !strings.Contains(err.Error(), "e1e1e1, f0f0f0") {
		t.Fatalf("2 requests with 1 name: %v", err)
	}
	if _, _, err := findPairing(&s, "d4e5f6", true); err == nil {
		t.Fatal("a paired device has no open pairing")
	}
	if _, _, err := findPairing(&s, "Nothing", true); err == nil {
		t.Fatal("an unknown name found a pairing")
	}
	// Only a reject finds a request of this computer, and only by its ID.
	if _, _, err := findPairing(&s, "c7c7c7", false); err == nil {
		t.Fatal("an accept found a request of this computer")
	}
	if id, key, err := findPairing(&s, "c7c7c7", true); err != nil || id != "c7c7c7" || key != "AAAABBBBCCCCDDDD" {
		t.Fatalf("a reject of a request of this computer: %s %s %v", id, key, err)
	}
	if _, _, err := findPairing(&s, "Pixel 7", true); err == nil {
		t.Fatal("a name found a request of this computer")
	}
}

func TestSameKey(t *testing.T) {
	for answer, want := range map[string]bool{"y\n": true, " YES \n": true, "n\n": false, "\n": false, "": false, "5EE6 825F 974E D59A\n": false} {
		if got := sameKey(bufio.NewReader(strings.NewReader(answer))); got != want {
			t.Errorf("answer %q: %v, want %v", answer, got, want)
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

// TestKeyArg checks the forms of the KEY argument of flux-cli accept.
func TestKeyArg(t *testing.T) {
	for _, args := range [][]string{
		{"5EE6825F974ED59A"},
		{"5EE6 825F 974E D59A"},
		{"5ee6", "825f", "974e", "d59a"},
		{" 5EE6 825F", "974E\tD59A "},
	} {
		if got := keyArg(args); got != "5EE6825F974ED59A" || !validKey(got) {
			t.Errorf("keyArg(%q) = %q", args, got)
		}
	}
	if got := keyArg(nil); got != "" {
		t.Errorf("keyArg(nil) = %q", got)
	}
}

// fakeFluxd plays fluxd for waitPair and askAccept. It sends the events,
// answers the method state, and records the other calls.
type fakeFluxd struct {
	events chan ipc.Message
	calls  chan string

	// state is the answer to the method state.
	state string
}

func (f *fakeFluxd) Call(method string, params, result any) error {
	if method == "state" {
		return json.Unmarshal([]byte(f.state), result)
	}
	b, _ := json.Marshal(params)
	f.calls <- method + " " + string(b)
	return nil
}

func (f *fakeFluxd) Events() <-chan ipc.Message { return f.events }

// pairStates returns a fake fluxd that sends a state event for each pair
// state of the device a1b2c3. The state "paired" marks the device as
// paired.
func pairStates(states ...string) *fakeFluxd {
	f := &fakeFluxd{events: make(chan ipc.Message, len(states)), calls: make(chan string, 4)}
	for _, st := range states {
		data := fmt.Sprintf(`{"devices":[{"id":"a1b2c3","name":"Pixel 8","paired":%v,"pairState":%q,"pairKey":"5EE6825F974ED59A"}]}`, st == "paired", st)
		f.events <- ipc.Message{Event: "state", Data: json.RawMessage(data)}
	}
	return f
}

// TestWaitPair checks the key question of flux-cli pair. The answer y
// accepts the pairing with the key, and another answer rejects it. The
// question ends when the pairing ends in another way.
func TestWaitPair(t *testing.T) {
	res := pairResult{Device: "a1b2c3", Name: "Pixel 8", Key: "5EE6825F974ED59A"}
	const question = "Does Pixel 8 show 5EE6 825F 974E D59A? [y/N] "
	// silent is stdin of a user who does not answer.
	silent := func() io.Reader {
		r, w := io.Pipe()
		t.Cleanup(func() { w.Close() })
		return r
	}
	for _, tc := range []struct {
		name   string
		in     io.Reader
		f      *fakeFluxd
		call   string
		out    string
		errMsg string
	}{
		{"y", strings.NewReader("y\n"), pairStates("requested", "confirm"),
			`pair.accept {"device":"a1b2c3","key":"5EE6825F974ED59A"}`, question + "✓ Pixel 8 (a1b2c3) paired with the key 5EE6 825F 974E D59A\n", ""},
		{"n", strings.NewReader("n\n"), pairStates("requested", "confirm"),
			`pair.reject {"device":"a1b2c3","key":"5EE6825F974ED59A"}`, question, "you rejected the pairing with Pixel 8"},
		{"a confirm in the window", silent(), pairStates("requested", "confirm", "paired"),
			"", question + "\n✓ Pixel 8 (a1b2c3) paired with the key 5EE6 825F 974E D59A\n", ""},
		{"a timeout", silent(), pairStates("requested", "confirm", "none"),
			"", question + "\n", "the pairing with Pixel 8 ended before you answered"},
		{"a reject on the device", nil, pairStates("requested", "none"),
			"", "", "Pixel 8 did not pair"},
		{"no terminal", nil, pairStates("requested", "confirm"),
			"", "Pixel 8 accepted. Compare the key. When Pixel 8 shows 5EE6 825F 974E D59A, run:\n  flux-cli accept a1b2c3 5EE6 825F 974E D59A\n", ""},
	} {
		var out strings.Builder
		err := waitPair(tc.f, tc.in, &out, res)
		if got := fmt.Sprint(err); (tc.errMsg == "" && err != nil) || (tc.errMsg != "" && got != tc.errMsg) {
			t.Errorf("%s: error %v, want %q", tc.name, err, tc.errMsg)
		}
		if out.String() != tc.out {
			t.Errorf("%s: output %q, want %q", tc.name, out.String(), tc.out)
		}
		call := ""
		select {
		case call = <-tc.f.calls:
		default:
		}
		if call != tc.call {
			t.Errorf("%s: call %q, want %q", tc.name, call, tc.call)
		}
	}
}

// TestAskAccept checks flux-cli accept without a key. It shows the key of
// the open pairing and sends that key with the answer. Without a
// terminal, it accepts nothing and names the command with the key.
func TestAskAccept(t *testing.T) {
	const state = `{"devices":[
		{"id":"a1b2c3","name":"Pixel 8","pairState":"confirm","pairKey":"5EE6825F974ED59A"},
		{"id":"f0f0f0","name":"Tab S9","pairState":"incoming","pairKey":"9B03E7D16A2FC048"}]}`
	const question = "Does Pixel 8 show 5EE6 825F 974E D59A? [y/N] "
	for _, tc := range []struct {
		name   string
		device string
		in     io.Reader
		call   string
		out    string
		errMsg string
	}{
		{"y", "pixel 8", strings.NewReader("y\n"),
			`pair.accept {"device":"a1b2c3","key":"5EE6825F974ED59A"}`, question + "✓ Pixel 8 (a1b2c3) paired with the key 5EE6 825F 974E D59A\n", ""},
		{"a request of the device", "f0f0f0", strings.NewReader("y\n"),
			`pair.accept {"device":"f0f0f0","key":"9B03E7D16A2FC048"}`, "Does Tab S9 show 9B03 E7D1 6A2F C048? [y/N] ✓ Tab S9 (f0f0f0) paired with the key 9B03 E7D1 6A2F C048\n", ""},
		{"n", "Pixel 8", strings.NewReader("\n"),
			`pair.reject {"device":"a1b2c3","key":"5EE6825F974ED59A"}`, question, "you rejected the pairing with Pixel 8"},
		{"no terminal", "Pixel 8", nil,
			"", "", "compare the key first. When Pixel 8 shows 5EE6 825F 974E D59A, run:\n  flux-cli accept a1b2c3 5EE6 825F 974E D59A"},
		{"no pairing", "Nothing", strings.NewReader("y\n"),
			"", "", `no device named "Nothing" has an open pair request`},
	} {
		f := &fakeFluxd{calls: make(chan string, 4), state: state}
		var out strings.Builder
		err := askAccept(f, tc.in, &out, tc.device)
		if got := fmt.Sprint(err); (tc.errMsg == "" && err != nil) || (tc.errMsg != "" && got != tc.errMsg) {
			t.Errorf("%s: error %v, want %q", tc.name, err, tc.errMsg)
		}
		if out.String() != tc.out {
			t.Errorf("%s: output %q, want %q", tc.name, out.String(), tc.out)
		}
		call := ""
		select {
		case call = <-f.calls:
		default:
		}
		if call != tc.call {
			t.Errorf("%s: call %q, want %q", tc.name, call, tc.call)
		}
	}
}
