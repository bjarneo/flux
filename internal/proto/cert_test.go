package proto

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A missing certificate does not replace the private key of the identity,
// because the paired devices pinned the certificate of that key.
func TestLoadOrCreateCertKeepsTheKey(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := LoadOrCreateCert(dir); err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, keyFile)
	key, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, certFile)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadOrCreateCert(dir); err == nil || !strings.Contains(err.Error(), certFile) {
		t.Fatalf("a missing certificate: %v", err)
	}
	if b, _ := os.ReadFile(keyPath); !bytes.Equal(b, key) {
		t.Fatal("the private key changed")
	}

	// A certificate without its key is left from a stop during the first
	// start. It has no use, so a new identity replaces it.
	if err := os.Remove(keyPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, certFile), []byte("left"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, id, err := LoadOrCreateCert(dir); err != nil || !ValidDeviceID(id) {
		t.Fatalf("a certificate without a key: %q %v", id, err)
	}
	if st, err := os.Stat(keyPath); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("the new key: %v", err)
	}
}
