package proto

import (
	"crypto/x509"
	"testing"
)

func TestPacketIDAcceptsNumberAndString(t *testing.T) {
	for _, line := range []string{
		`{"id":1727260000000,"type":"kdeconnect.ping","body":{}}`,
		`{"id":"1727260000000","type":"kdeconnect.ping","body":{}}`,
		`{"id":1727260000000.0,"type":"kdeconnect.ping"}`,
	} {
		p, err := Unmarshal([]byte(line))
		if err != nil {
			t.Fatalf("%s: %v", line, err)
		}
		if p.ID != 1727260000000 {
			t.Errorf("%s: id = %d", line, p.ID)
		}
		if string(p.Body) == "" {
			t.Errorf("%s: body is empty", line)
		}
	}
}

func TestMarshalOmitsPayloadFieldsWithoutPayload(t *testing.T) {
	b, err := New(TypePing, map[string]any{"message": "hi"}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if s[len(s)-1] != '\n' {
		t.Fatal("packet does not end with a newline")
	}
	for _, key := range []string{"payloadSize", "payloadTransferInfo"} {
		if contains(s, key) {
			t.Errorf("packet without payload has %s: %s", key, s)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestCleanName(t *testing.T) {
	cases := map[string]string{
		`Bob's "Pixel" (8)!`:                            "Bobs Pixel 8",
		"omarchy-framework":                             "omarchy-framework",
		"a name that is much longer than 32 characters": "a name that is much longer than",
		"...": "omarchy",
	}
	for in, want := range cases {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestValidDeviceID(t *testing.T) {
	if !ValidDeviceID("9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b") {
		t.Error("32 hex characters must be valid")
	}
	if ValidDeviceID("short") || ValidDeviceID("9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b!") {
		t.Error("invalid IDs passed")
	}
}

func TestTargetVersion(t *testing.T) {
	for _, v := range []any{float64(8), "8"} {
		if got := (Identity{TargetProtocolVersion: v}).TargetVersion(); got != 8 {
			t.Errorf("TargetVersion(%v) = %d", v, got)
		}
	}
}

func TestVerificationKeyIsSymmetric(t *testing.T) {
	a := testCert(t)
	b := testCert(t)
	ka := VerificationKey(a, b, 1727260000)
	kb := VerificationKey(b, a, 1727260000)
	if ka != kb {
		t.Fatalf("keys differ: %s and %s", ka, kb)
	}
	if len(ka) != 8 {
		t.Fatalf("key %q does not have 8 characters", ka)
	}
	if VerificationKey(a, b, 1727260001) == ka {
		t.Error("the timestamp does not change the key")
	}
}

func testCert(t *testing.T) *x509.Certificate {
	t.Helper()
	cert, id, err := LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !ValidDeviceID(id) || cert.Leaf.Subject.CommonName != id {
		t.Fatalf("bad device ID %q", id)
	}
	return cert.Leaf
}
