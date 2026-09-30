package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"flux/internal/release"
)

func newSeed(t *testing.T) (seed, key string) {
	t.Helper()
	b := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	seed = base64.StdEncoding.EncodeToString(b)
	key, err := release.KeyOf(seed)
	if err != nil {
		t.Fatal(err)
	}
	return seed, key
}

// TestSign checks that sign writes no signature with a key that the
// installed copies refuse, and that verify checks with the given key.
func TestSign(t *testing.T) {
	seed, key := newSeed(t)
	_, other := newSeed(t)
	sums := filepath.Join(t.TempDir(), "SHA256SUMS")
	if err := os.WriteFile(sums, []byte("0000  flux-android-0.7.0.apk\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct{ what, seed, want string }{
		{"no secret", "", ""},
		{"no secret with a public key", "", key},
		{"a secret that does not match the public key", seed, other},
		{"a secret that is not a seed", "not a seed", ""},
	} {
		if err := sign(sums, c.seed, c.want); err == nil {
			t.Errorf("%s: no error", c.what)
		}
		if _, err := os.Stat(sums + ".sig"); !os.IsNotExist(err) {
			t.Fatalf("%s: sign wrote SHA256SUMS.sig", c.what)
		}
	}

	// Without a public key in the build, any valid secret signs.
	if err := sign(sums, seed, ""); err != nil {
		t.Fatal(err)
	}
	if err := verify(sums, key); err != nil {
		t.Errorf("verify with the key of the secret: %v", err)
	}
	if err := verify(sums, other); err == nil {
		t.Error("verify with another key: no error")
	}
	if err := verify(sums, ""); err == nil {
		t.Error("verify without a key: no error")
	}

	os.Remove(sums + ".sig")
	if err := sign(sums, seed, key+"\n"); err != nil {
		t.Fatalf("sign with the matching public key: %v", err)
	}
	if err := verify(sums, key); err != nil {
		t.Errorf("verify: %v", err)
	}
}
