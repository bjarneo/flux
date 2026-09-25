package approve

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeTestKey writes a key file for ph in a new folder that the test user
// owns, and returns its path.
func writeTestKey(t *testing.T, ph *phone) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "approve")
	path := filepath.Join(dir, "alice.pub")
	content, err := EncodeKey(ph.spki, "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93", "Pixel 8", time.Unix(1790000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteKey(path, os.Getuid(), content); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadKey(t *testing.T) {
	ph := newPhone(t)
	path := writeTestKey(t, ph)
	k, err := ReadKey(path, os.Getuid())
	if err != nil {
		t.Fatal(err)
	}
	if k.DeviceID != "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93" || k.DeviceName != "Pixel 8" || k.Enrolled != "2026-09-21T14:13:20Z" {
		t.Fatalf("headers: %+v", k)
	}
	if !k.Public.Equal(&ph.priv.PublicKey) {
		t.Fatal("the key is not the enrolled key")
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v", st.Mode())
	}
}

func TestReadKeyMissing(t *testing.T) {
	if _, err := ReadKey(filepath.Join(t.TempDir(), "none.pub"), os.Getuid()); !errors.Is(err, ErrNoKey) {
		t.Fatalf("got %v", err)
	}
}

// A key file that the user owns is a key file that the user can change,
// so the production check, which wants root, refuses it.
func TestReadKeyRefusesAUserFile(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("the test needs a user that is not root")
	}
	path := writeTestKey(t, newPhone(t))
	if _, err := ReadKey(path, 0); err == nil {
		t.Fatal("a key file of the user must fail when root must own it")
	}
}

func TestReadKeyRefusesWritableFiles(t *testing.T) {
	path := writeTestKey(t, newPhone(t))
	if err := os.Chmod(path, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKey(path, os.Getuid()); err == nil {
		t.Fatal("a file that others can write must fail")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(path), 0o775); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKey(path, os.Getuid()); err == nil {
		t.Fatal("a folder that a group can write must fail")
	}
}

func TestReadKeyRefusesSymlinks(t *testing.T) {
	path := writeTestKey(t, newPhone(t))
	link := filepath.Join(filepath.Dir(path), "link.pub")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKey(link, os.Getuid()); err == nil {
		t.Fatal("a symbolic link must fail")
	}
}

func TestReadKeyRefusesOtherContent(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"empty.pub": "",
		"text.pub":  "not a key\n",
		"nodev.pub": "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n",
		"rsa.pub":   "-----BEGIN RSA PUBLIC KEY-----\nAA==\n-----END RSA PUBLIC KEY-----\n",
		"large.pub": string(make([]byte, maxKeyFile+10)),
	} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadKey(p, os.Getuid()); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestRemoveKey(t *testing.T) {
	path := writeTestKey(t, newPhone(t))
	if err := RemoveKey(path); err != nil {
		t.Fatal(err)
	}
	if err := RemoveKey(path); err != nil {
		t.Fatalf("a second remove: %v", err)
	}
	if _, err := ReadKey(path, os.Getuid()); !errors.Is(err, ErrNoKey) {
		t.Fatalf("got %v", err)
	}
}
