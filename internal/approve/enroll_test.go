package approve

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func enrollFrom(p map[string]any) Enrollment {
	s := func(k string) string { v, _ := p[k].(string); return v }
	tm, _ := p["time"].(float64)
	return Enrollment{Host: s("host"), User: s("user"), Time: int64(tm), Nonce: s("nonce")}
}

// phoneEnrolls answers approve.wait like a phone that made the key of ph.
// signer signs the proof, so that a test can use another key.
func phoneEnrolls(t *testing.T, ph, signer *phone) func(map[string]any) (map[string]any, map[string]any) {
	return func(p map[string]any) (map[string]any, map[string]any) {
		msg, err := enrollFrom(p).Message(ph.spki)
		if err != nil {
			t.Error(err)
			return nil, map[string]any{"code": "bad", "message": err.Error()}
		}
		return map[string]any{
			"state":     "enrolled",
			"publicKey": base64.StdEncoding.EncodeToString(ph.spki),
			"signature": base64.StdEncoding.EncodeToString(signer.sign(t, msg)),
		}, nil
	}
}

func enrollOptions(f *fakeFluxd, keyPath string, confirm bool, code *string) EnrollOptions {
	return EnrollOptions{
		User: "alice", Host: "omarchy-xps",
		Socket: f.path, PeerUID: os.Getuid(),
		KeyPath: keyPath, KeyOwner: os.Getuid(),
		Confirm: func(phone, c string) bool {
			if code != nil {
				*code = c
			}
			return confirm
		},
	}
}

func TestEnroll(t *testing.T) {
	ph := newPhone(t)
	f := newFakeFluxd(t)
	f.answer = phoneEnrolls(t, ph, ph)
	path := filepath.Join(t.TempDir(), "approve", "alice.pub")
	var code string
	k, err := Enroll(context.Background(), enrollOptions(f, path, true, &code))
	if err != nil {
		t.Fatal(err)
	}
	if code != Fingerprint(ph.spki) {
		t.Fatalf("the user saw %q, want %q", code, Fingerprint(ph.spki))
	}
	read, err := ReadKey(path, os.Getuid())
	if err != nil {
		t.Fatal(err)
	}
	if !read.Public.Equal(&ph.priv.PublicKey) || read.DeviceID != k.DeviceID || read.DeviceName != "Pixel 8" {
		t.Fatalf("key file %+v", read)
	}
}

func TestEnrollRefusesAProofByAnotherKey(t *testing.T) {
	ph := newPhone(t)
	f := newFakeFluxd(t)
	f.answer = phoneEnrolls(t, ph, newPhone(t))
	path := filepath.Join(t.TempDir(), "alice.pub")
	if _, err := Enroll(context.Background(), enrollOptions(f, path, true, nil)); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("Flux wrote a key file")
	}
}

func TestEnrollNeedsConfirmation(t *testing.T) {
	ph := newPhone(t)
	f := newFakeFluxd(t)
	f.answer = phoneEnrolls(t, ph, ph)
	path := filepath.Join(t.TempDir(), "alice.pub")
	if _, err := Enroll(context.Background(), enrollOptions(f, path, false, nil)); !errors.Is(err, ErrNotConfirmed) {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("Flux wrote a key file")
	}
}

func TestEnrollDenied(t *testing.T) {
	f := newFakeFluxd(t)
	f.answer = func(map[string]any) (map[string]any, map[string]any) { return map[string]any{"state": "denied"}, nil }
	path := filepath.Join(t.TempDir(), "alice.pub")
	if _, err := Enroll(context.Background(), enrollOptions(f, path, true, nil)); !errors.Is(err, ErrDenied) {
		t.Fatalf("got %v", err)
	}
}
