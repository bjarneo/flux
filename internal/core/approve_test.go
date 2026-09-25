package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

func approveDaemon() (*Daemon, *Device) {
	d := &Daemon{cfg: &config.Config{}, devices: map[string]*Device{}, logger: log.New(io.Discard, "", 0)}
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	dev.Incoming = []string{proto.TypeFluxApprove}
	d.devices[dev.ID] = dev
	return d, dev
}

func approveRaw(t *testing.T, fields map[string]any) json.RawMessage {
	t.Helper()
	base := map[string]any{
		"device": "phone1", "host": "omarchy-xps", "user": "alice", "service": "sudo",
		"tty": "/dev/pts/3", "time": time.Now().Unix(), "nonce": strings.Repeat("ab", 32),
	}
	for k, v := range fields {
		base[k] = v
	}
	b, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func errCode(err error) string {
	if e, ok := err.(*Error); ok {
		return e.Code
	}
	return ""
}

func TestApproveRequestChecks(t *testing.T) {
	d, dev := approveDaemon()
	cases := []struct {
		name   string
		fields map[string]any
		code   string
	}{
		{"a newline in a field", map[string]any{"user": "alice\nservice=sshd"}, "bad_params"},
		{"a short nonce", map[string]any{"nonce": "abcd"}, "bad_params"},
		{"an unknown phone", map[string]any{"device": "other"}, "not_found"},
		{"an offline phone", nil, "offline"},
	}
	for _, c := range cases {
		_, err := d.ApproveRequest(approveRaw(t, c.fields))
		if errCode(err) != c.code {
			t.Errorf("%s: got %v, want the code %s", c.name, err, c.code)
		}
	}
	dev.Paired = false
	if _, err := d.ApproveRequest(approveRaw(t, nil)); errCode(err) != "not_paired" {
		t.Errorf("a phone that is not paired: %v", err)
	}
}

func TestApproveTimeoutLimits(t *testing.T) {
	d, _ := approveDaemon()
	for set, want := range map[int]int{0: 20, 1: 5, 30: 30, 900: 120} {
		d.cfg.ApproveTimeout = set
		if got := d.approveTimeout(); got != want {
			t.Errorf("approve_timeout %d: got %d, want %d", set, got, want)
		}
	}
}

func TestApprovalBook(t *testing.T) {
	var b approvalBook
	a := &approval{id: "a1", kind: "request", device: "phone1", deadline: time.Now().Add(time.Minute)}
	if err := b.add(a); err != nil {
		t.Fatal(err)
	}
	if err := b.add(&approval{id: "a2", kind: "request", device: "phone1", deadline: time.Now().Add(time.Minute)}); errCode(err) != "busy" {
		t.Fatalf("a second request for the same phone: %v", err)
	}

	// No answer yet: the wait returns pending after its slice.
	res, _, expired, err := b.wait(context.Background(), "a1", 20*time.Millisecond)
	if err != nil || expired || res.State != "pending" {
		t.Fatalf("pending: %+v %v %v", res, expired, err)
	}

	// Another phone and a wrong kind cannot answer.
	if b.deliver("phone2", "a1", approvalResult{State: "denied"}) {
		t.Fatal("another phone answered the request")
	}
	if b.deliver("phone1", "a1", approvalResult{State: "enrolled"}) {
		t.Fatal("an enrollment answered an approval")
	}
	if !b.deliver("phone1", "a1", approvalResult{State: "approved", Signature: "c2ln"}) {
		t.Fatal("the phone could not answer")
	}
	if b.deliver("phone1", "a1", approvalResult{State: "denied"}) {
		t.Fatal("the phone answered twice")
	}
	res, _, _, err = b.wait(context.Background(), "a1", time.Second)
	if err != nil || res.State != "approved" || res.Signature != "c2ln" {
		t.Fatalf("the answer: %+v %v", res, err)
	}
	if _, _, _, err := b.wait(context.Background(), "a1", time.Second); errCode(err) != "not_found" {
		t.Fatalf("a request after its answer: %v", err)
	}
}

func TestApprovalExpires(t *testing.T) {
	var b approvalBook
	if err := b.add(&approval{id: "a1", kind: "request", device: "phone1", deadline: time.Now().Add(30 * time.Millisecond)}); err != nil {
		t.Fatal(err)
	}
	_, device, expired, err := b.wait(context.Background(), "a1", time.Second)
	if !expired || device != "phone1" || errCode(err) != "timeout" {
		t.Fatalf("expired %v device %q err %v", expired, device, err)
	}
	// The phone is free for a new request.
	if err := b.add(&approval{id: "a2", kind: "request", device: "phone1", deadline: time.Now().Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
}

func TestHandleApprove(t *testing.T) {
	sig := base64.StdEncoding.EncodeToString([]byte("0123456789"))
	key := base64.StdEncoding.EncodeToString([]byte("key"))
	cases := []struct {
		kind  string
		body  map[string]any
		state string
	}{
		{"request", map[string]any{"kind": "response", "denied": true}, "denied"},
		{"request", map[string]any{"kind": "response", "signature": sig}, "approved"},
		{"request", map[string]any{"kind": "response", "error": "No fingerprint is set up"}, "failed"},
		{"enroll", map[string]any{"kind": "enrolled", "signature": sig, "publicKey": key}, "enrolled"},
		{"request", map[string]any{"kind": "response", "signature": "not base64!"}, ""},
		{"request", map[string]any{"kind": "enrolled", "signature": sig, "publicKey": key}, ""},
	}
	for i, c := range cases {
		d, dev := approveDaemon()
		if err := d.approvals.add(&approval{id: "a1", kind: c.kind, device: dev.ID, deadline: time.Now().Add(time.Minute)}); err != nil {
			t.Fatal(err)
		}
		c.body["id"] = "a1"
		d.handleApprove(dev, proto.New(proto.TypeFluxApprove, c.body))
		res, _, _, err := d.approvals.wait(context.Background(), "a1", 10*time.Millisecond)
		if err != nil {
			t.Fatalf("case %d: %v", i, err)
		}
		want := c.state
		if want == "" {
			want = "pending"
		}
		if res.State != want {
			t.Errorf("case %d: state %q, want %q", i, res.State, want)
		}
	}
}
