package approve

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"strings"
	"testing"
	"time"
)

// The same vectors are in the Android test ApproveMessageTest, so that
// both sides build the same bytes.
const testNonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

var testRequest = Request{
	Host: "omarchy-xps", User: "alice", Service: "sudo", TTY: "/dev/pts/3",
	Time: 1790000000, Nonce: testNonce,
}

func TestMessageBytes(t *testing.T) {
	msg, err := testRequest.Message()
	if err != nil {
		t.Fatal(err)
	}
	want := "flux-approve-v1\nhost=omarchy-xps\nuser=alice\nservice=sudo\ntty=/dev/pts/3\nrhost=\ntime=1790000000\nnonce=" + testNonce + "\n"
	if string(msg) != want {
		t.Fatalf("message:\n%q\nwant:\n%q", msg, want)
	}
}

func TestEnrollmentBytes(t *testing.T) {
	e := Enrollment{Host: "omarchy-xps", User: "alice", Time: 1790000000, Nonce: testNonce}
	msg, err := e.Message([]byte("test-key"))
	if err != nil {
		t.Fatal(err)
	}
	want := "flux-approve-enroll-v1\nhost=omarchy-xps\nuser=alice\n" +
		"key=62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef\n" +
		"time=1790000000\nnonce=" + testNonce + "\n"
	if string(msg) != want {
		t.Fatalf("message:\n%q\nwant:\n%q", msg, want)
	}
}

func TestFingerprint(t *testing.T) {
	if got := Fingerprint([]byte("test-key")); got != "62AF 8704 764F AF8E" {
		t.Fatalf("fingerprint %q", got)
	}
}

func TestFieldRules(t *testing.T) {
	bad := []Request{
		func() Request { r := testRequest; r.Host = ""; return r }(),
		func() Request { r := testRequest; r.User = "alice\nservice=sshd"; return r }(),
		func() Request { r := testRequest; r.TTY = "tty\x00"; return r }(),
		func() Request { r := testRequest; r.RHost = "host\u0085"; return r }(),
		func() Request { r := testRequest; r.Service = strings.Repeat("s", 257); return r }(),
		func() Request { r := testRequest; r.Service = "\xff"; return r }(),
		func() Request { r := testRequest; r.Nonce = testNonce[:62]; return r }(),
		func() Request { r := testRequest; r.Nonce = strings.ToUpper(testNonce); return r }(),
	}
	for i, r := range bad {
		if _, err := r.Message(); err == nil {
			t.Errorf("request %d: want an error", i)
		}
	}
}

// phone is a test phone key.
type phone struct {
	priv *ecdsa.PrivateKey
	spki []byte
}

func newPhone(t *testing.T) *phone {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return &phone{priv: priv, spki: spki}
}

func (p *phone) sign(t *testing.T, msg []byte) []byte {
	t.Helper()
	sum := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, p.priv, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return sig
}

func (p *phone) signRequest(t *testing.T, r Request) []byte {
	t.Helper()
	msg, err := r.Message()
	if err != nil {
		t.Fatal(err)
	}
	return p.sign(t, msg)
}

func TestVerify(t *testing.T) {
	ph := newPhone(t)
	now := time.Unix(testRequest.Time+4, 0)
	sig := ph.signRequest(t, testRequest)

	if err := Verify(testRequest, sig, &ph.priv.PublicKey, now, 30*time.Second); err != nil {
		t.Fatalf("a valid signature: %v", err)
	}

	other := newPhone(t)
	if err := Verify(testRequest, sig, &other.priv.PublicKey, now, 30*time.Second); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a wrong key: %v", err)
	}

	changed := testRequest
	changed.Service = "polkit-1"
	if err := Verify(changed, sig, &ph.priv.PublicKey, now, 30*time.Second); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a changed field: %v", err)
	}

	if err := Verify(testRequest, sig, &ph.priv.PublicKey, time.Unix(testRequest.Time+600, 0), 30*time.Second); !errors.Is(err, ErrStale) {
		t.Fatalf("a stale time: %v", err)
	}
	if err := Verify(testRequest, sig, &ph.priv.PublicKey, time.Unix(testRequest.Time-60, 0), 30*time.Second); !errors.Is(err, ErrStale) {
		t.Fatalf("a time in the future: %v", err)
	}

	// A signature for an earlier request is not valid for a new request
	// with a new nonce.
	replay := testRequest
	replay.Nonce = strings.Repeat("ab", 32)
	if err := Verify(replay, sig, &ph.priv.PublicKey, now, 30*time.Second); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a replayed signature: %v", err)
	}

	if err := Verify(testRequest, nil, &ph.priv.PublicKey, now, 30*time.Second); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("an empty signature: %v", err)
	}
}

func TestEnrollmentProofIsNotAnApproval(t *testing.T) {
	ph := newPhone(t)
	e := Enrollment{Host: testRequest.Host, User: testRequest.User, Time: testRequest.Time, Nonce: testNonce}
	msg, err := e.Message(ph.spki)
	if err != nil {
		t.Fatal(err)
	}
	sig := ph.sign(t, msg)
	now := time.Unix(testRequest.Time+1, 0)
	if _, err := VerifyEnrollment(e, ph.spki, sig, now, time.Minute); err != nil {
		t.Fatalf("a valid proof: %v", err)
	}
	if err := Verify(testRequest, sig, &ph.priv.PublicKey, now, time.Minute); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("an enrollment proof passed as an approval: %v", err)
	}
	if _, err := VerifyEnrollment(e, newPhone(t).spki, sig, now, time.Minute); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a proof for another key: %v", err)
	}
}

func TestParsePublicKeyRefusesOtherCurves(t *testing.T) {
	priv, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, _ := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if _, err := ParsePublicKey(spki); err == nil {
		t.Fatal("a P-384 key must fail")
	}
}
