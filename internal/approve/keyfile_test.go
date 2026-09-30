package approve

import (
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
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
	ph := newPhone(t)
	withHeaders := func(h map[string]string) string {
		return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Headers: h, Bytes: ph.spki}))
	}
	const devID = "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93"
	for name, c := range map[string]struct{ content, err string }{
		"empty.pub": {"", "no PUBLIC KEY block"},
		"text.pub":  {"not a key\n", "no PUBLIC KEY block"},
		"short.pub": {"-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n", "the public key"},
		"nodev.pub": {withHeaders(nil), "no Device-Id"},
		"name.pub":  {strings.Replace(withHeaders(map[string]string{"Device-Id": devID, "Device-Name": "Pixel"}), "Device-Name: Pixel", "Device-Name: Pixel\tEvil", 1), "control character"},
		"long.pub":  {withHeaders(map[string]string{"Device-Id": devID, "Enrolled": strings.Repeat("9", 300)}), "longer than"},
		"rsa.pub":   {"-----BEGIN RSA PUBLIC KEY-----\nAA==\n-----END RSA PUBLIC KEY-----\n", "no PUBLIC KEY block"},
		"large.pub": {string(make([]byte, maxKeyFile+10)), "larger than"},
	} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(c.content), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadKey(p, os.Getuid()); err == nil || !strings.Contains(err.Error(), c.err) {
			t.Errorf("%s: got %v, want an error with %q", name, err, c.err)
		}
	}
	// The same key with a Device-Id is valid, so the cases above test only
	// their own rule.
	p := filepath.Join(dir, "valid.pub")
	if err := os.WriteFile(p, []byte(withHeaders(map[string]string{"Device-Id": devID})), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKey(p, os.Getuid()); err != nil {
		t.Fatalf("a valid key: %v", err)
	}
}

// A strict umask of root, as sudo can give it, must not make the key
// folders closed to the helper of a lock screen, which runs as the user.
func TestWriteKeyIgnoresTheUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	root := t.TempDir()
	path := filepath.Join(root, "flux", "approve", "alice.pub")
	content, err := EncodeKey(newPhone(t).spki, "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93", "Pixel 8", time.Unix(1790000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteKey(path, os.Getuid(), content); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{filepath.Join(root, "flux"), filepath.Join(root, "flux", "approve")} {
		if st, err := os.Stat(dir); err != nil || st.Mode().Perm() != 0o755 {
			t.Errorf("%s: mode %v, err %v", dir, st.Mode(), err)
		}
	}
	if st, err := os.Stat(path); err != nil || st.Mode().Perm() != 0o644 {
		t.Errorf("the key file: mode %v, err %v", st.Mode(), err)
	}
}

// An earlier setup under a strict umask left /etc/flux with mode 0700.
// A new setup opens it, but only when it belongs to the owner of the key.
func TestOpenFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "flux")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := openFolder(dir, os.Getuid()+1); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Fatalf("a folder of another owner changed to %v", st.Mode())
	}
	if err := openFolder(dir, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o755 {
		t.Fatalf("mode %v", st.Mode())
	}
	// A folder that others can pass through keeps its mode.
	if err := os.Chmod(dir, 0o711); err != nil {
		t.Fatal(err)
	}
	if err := openFolder(dir, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o711 {
		t.Fatalf("mode %v", st.Mode())
	}
	link := filepath.Join(filepath.Dir(dir), "link")
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := openFolder(link, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Fatalf("openFolder followed a symlink: %v", st.Mode())
	}
}

func TestOtherKeys(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"alice.pub", "bob.pub", "notes.txt", "Bad.pub"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "pam-backup"), 0o755); err != nil {
		t.Fatal(err)
	}
	users, err := OtherKeys(dir, "alice")
	if err != nil || len(users) != 1 || users[0] != "bob" {
		t.Fatalf("users %v, err %v", users, err)
	}
	if users, err := OtherKeys(filepath.Join(dir, "none"), "alice"); err != nil || len(users) != 0 {
		t.Fatalf("no folder: %v %v", users, err)
	}
}

func TestLookupUser(t *testing.T) {
	passwd := filepath.Join(t.TempDir(), "passwd")
	content := "root:x:0:0::/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\nbad:x:nope:1::/:/bin/sh\n"
	if err := os.WriteFile(passwd, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if u, err := lookupUser(passwd, "alice"); err != nil || u.UID != 1000 {
		t.Fatalf("alice: %+v %v", u, err)
	}
	// A user of systemd-homed or LDAP is not in /etc/passwd, and the
	// helper cannot find it.
	if _, err := lookupUser(passwd, "carol"); err == nil || !strings.Contains(err.Error(), "only local users") {
		t.Fatalf("carol: %v", err)
	}
	for _, name := range []string{"bad", "../root", ""} {
		if _, err := lookupUser(passwd, name); err == nil {
			t.Errorf("%q: want an error", name)
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
