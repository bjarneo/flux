package proto

import (
	"crypto/x509"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode"
)

func TestPacketIDAcceptsNumberAndString(t *testing.T) {
	for _, line := range []string{
		`{"id":1727260000000,"type":"flux.ping","body":{}}`,
		`{"id":"1727260000000","type":"flux.ping","body":{}}`,
		`{"id":1727260000000.0,"type":"flux.ping"}`,
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
		"...":                           "omarchy",
		"Pixel\x1bc 8\r\npaired=true":   "Pixelc 8paired=true",
		"Pixel \u202egnp.exe\u2066 8":   "Pixel gnpexe 8",
		"\u200fPixel\u0085 8\x7f\u009b": "Pixel 8",
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

func TestCleanType(t *testing.T) {
	for _, typ := range []string{"phone", "tablet", "desktop", "laptop", "tv"} {
		if CleanType(typ) != typ {
			t.Errorf("CleanType(%q) = %q", typ, CleanType(typ))
		}
	}
	for _, typ := range []string{"", "smartphone", "Phone", "\x1b]52;c;aGk=\x07", strings.Repeat("x", 60000)} {
		if got := CleanType(typ); got != "" {
			t.Errorf("CleanType(%.20q) = %q, want an empty type", typ, got)
		}
	}
}

func TestCleanText(t *testing.T) {
	if got := CleanText(" 0.7.0\x1b[2J\u202e ", 32); got != "0.7.0[2J" {
		t.Errorf("CleanText = %q", got)
	}
	if got := CleanText(strings.Repeat("é", 40), 32); got != strings.Repeat("é", 32) {
		t.Errorf("CleanText keeps %d characters", len([]rune(got)))
	}
}

// TestVerificationKeyVector checks the key against the test vector that
// Flux for Android, Flux for iOS, and Flux for macOS share.
func TestVerificationKeyVector(t *testing.T) {
	a := []byte{0x30, 0x82, 0x01, 0x22, 0x80}
	b := []byte{0x30, 0x82, 0x01, 0x22, 0x7f}
	ca, cb := &x509.Certificate{RawSubjectPublicKeyInfo: a}, &x509.Certificate{RawSubjectPublicKeyInfo: b}
	for _, c := range []struct {
		ts   int64
		want string
	}{{1790000000, "5EE6825F974ED59A"}, {0, "5BB22DB11047F34B"}} {
		if got := VerificationKey(ca, cb, c.ts); got != c.want {
			t.Errorf("VerificationKey(a, b, %d) = %s, want %s", c.ts, got, c.want)
		}
		if got := VerificationKey(cb, ca, c.ts); got != c.want {
			t.Errorf("VerificationKey(b, a, %d) = %s, want %s", c.ts, got, c.want)
		}
	}
	if got := FormatKey("5EE6825F974ED59A"); got != "5EE6 825F 974E D59A" {
		t.Errorf("FormatKey = %q", got)
	}
}

func TestFingerprint(t *testing.T) {
	a := testCert(t)
	fp := Fingerprint(a)
	if len(fp) != 16 || strings.ToUpper(fp) != fp || strings.ContainsFunc(fp, func(r rune) bool { return !unicode.Is(unicode.ASCII_Hex_Digit, r) }) {
		t.Fatalf("fingerprint %q is not 16 uppercase hex digits", fp)
	}
	if Fingerprint(a) != fp || Fingerprint(testCert(t)) == fp {
		t.Fatal("the fingerprint does not identify the certificate")
	}
	if Fingerprint(nil) != "" {
		t.Fatal("a missing certificate must have no fingerprint")
	}
}

// TestKeyPermissions checks that the private key and the data directory
// lose the access of other users when the certificate loads.
func TestKeyPermissions(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "flux")
	if _, _, err := LoadOrCreateCert(dir); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(dir, keyFile)
	if err := os.Chmod(key, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadOrCreateCert(dir); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]os.FileMode{key: 0o600, dir: 0o700} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != want {
			t.Errorf("%s has mode %o, want %o", path, got, want)
		}
	}
}

func TestUnmarshalLongType(t *testing.T) {
	if _, err := Unmarshal([]byte(`{"type":"` + strings.Repeat("x", maxTypeSize+1) + `"}`)); err == nil {
		t.Fatal("a packet type longer than the limit must fail")
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
	if len(ka) != 16 {
		t.Fatalf("key %q does not have 16 characters", ka)
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

func TestMediaGoesOneWay(t *testing.T) {
	// The phone controls the players on the computer. The computer does
	// not take the players of the phone and does not control them.
	if !slices.Contains(Incoming, TypeMprisRequest) || !slices.Contains(Outgoing, TypeMpris) {
		t.Error("the computer must take player requests and send player state")
	}
	if slices.Contains(Incoming, TypeMpris) || slices.Contains(Outgoing, TypeMprisRequest) {
		t.Error("the computer must not take player state or send player requests")
	}
}

func TestThemeGoesOneWay(t *testing.T) {
	// The computer sends its Omarchy theme to the phone. It does not take
	// a theme from the phone.
	if !slices.Contains(Outgoing, TypeFluxTheme) {
		t.Error("the computer must send the theme")
	}
	if slices.Contains(Incoming, TypeFluxTheme) {
		t.Error("the computer must not take a theme")
	}
}

func TestStreamRequestGoesOneWay(t *testing.T) {
	// The computer asks a device to start its camera or its microphone.
	// It does not take such a request from a device.
	if !slices.Contains(Outgoing, TypeFluxStreamRequest) {
		t.Error("the computer must send the stream request")
	}
	if slices.Contains(Incoming, TypeFluxStreamRequest) {
		t.Error("the computer must not take a stream request")
	}
}

// TestIdentityApp checks the optional app fields. An earlier app sends
// neither, and the JSON of an identity without them has no such keys.
func TestIdentityApp(t *testing.T) {
	var id Identity
	if err := json.Unmarshal([]byte(`{"deviceId":"x","app":"android","appVersion":"0.7.0"}`), &id); err != nil {
		t.Fatal(err)
	}
	if id.App != "android" || id.AppVersion != "0.7.0" {
		t.Fatalf("identity %+v", id)
	}
	b, err := json.Marshal(NewIdentity("0123456789abcdef0123456789abcdef", "pc", 0))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), `"app`) {
		t.Fatalf("an identity without app fields: %s", b)
	}
}
