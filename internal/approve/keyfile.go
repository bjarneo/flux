package approve

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// KeyDir is the folder of the key files. Only root writes to it.
const KeyDir = "/etc/flux/approve"

// maxKeyFile is the largest key file that ReadKey accepts.
const maxKeyFile = 16 << 10

// ErrNoKey means that no key is enrolled for the user.
var ErrNoKey = errors.New("no key is enrolled")

// Key is an enrolled phone key.
type Key struct {
	Public     *ecdsa.PublicKey
	DER        []byte
	DeviceID   string
	DeviceName string
	Enrolled   string
}

// KeyPath returns the key file of a user in KeyDir.
func KeyPath(user string) string { return filepath.Join(KeyDir, user+".pub") }

// ReadKey reads a key file and checks that only owner can change it: the
// file and each folder above it belong to owner or root, and no group or
// other user can write to them. A folder that root owns can be writable
// by others when it has the sticky bit. The production owner is root.
func ReadKey(path string, owner int) (*Key, error) {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return nil, errors.New("the key path is not absolute")
	}
	st, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrNoKey
	}
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	if err := checkOwner(path, st, owner, false); err != nil {
		return nil, err
	}
	for dir := filepath.Dir(path); ; dir = filepath.Dir(dir) {
		ds, err := os.Lstat(dir)
		if err != nil {
			return nil, err
		}
		if !ds.IsDir() {
			return nil, fmt.Errorf("%s is not a folder", dir)
		}
		if err := checkOwner(dir, ds, owner, true); err != nil {
			return nil, err
		}
		if dir == "/" {
			break
		}
	}

	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	fst, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !os.SameFile(st, fst) {
		return nil, fmt.Errorf("%s changed while Flux checked it", path)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxKeyFile+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxKeyFile {
		return nil, fmt.Errorf("%s is larger than %d bytes", path, maxKeyFile)
	}
	return parseKeyFile(data)
}

func checkOwner(path string, st os.FileInfo, owner int, dir bool) error {
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("cannot read the owner of %s", path)
	}
	uid := int(sys.Uid)
	if uid != owner && uid != 0 {
		return fmt.Errorf("%s belongs to user %d, not to root", path, uid)
	}
	if !dir && uid != owner {
		return fmt.Errorf("%s belongs to user %d, not to user %d", path, uid, owner)
	}
	if st.Mode().Perm()&0o022 != 0 {
		if dir && uid == 0 && st.Mode()&fs.ModeSticky != 0 {
			return nil
		}
		return fmt.Errorf("a group or other users can write to %s", path)
	}
	return nil
}

func parseKeyFile(data []byte) (*Key, error) {
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PUBLIC KEY" {
		return nil, errors.New("the key file has no PUBLIC KEY block")
	}
	pub, err := ParsePublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	k := &Key{
		Public:     pub,
		DER:        block.Bytes,
		DeviceID:   block.Headers["Device-Id"],
		DeviceName: block.Headers["Device-Name"],
		Enrolled:   block.Headers["Enrolled"],
	}
	for name, v := range map[string]string{"Device-Id": k.DeviceID, "Device-Name": k.DeviceName, "Enrolled": k.Enrolled} {
		if err := CheckField(name, v); err != nil {
			return nil, err
		}
	}
	if k.DeviceID == "" {
		return nil, errors.New("the key file has no Device-Id")
	}
	if k.DeviceName == "" {
		k.DeviceName = "the phone"
	}
	return k, nil
}

// EncodeKey returns the key file content for a key.
func EncodeKey(spki []byte, deviceID, deviceName string, enrolled time.Time) ([]byte, error) {
	if _, err := x509.ParsePKIXPublicKey(spki); err != nil {
		return nil, err
	}
	headers := map[string]string{
		"Device-Id":   deviceID,
		"Device-Name": strings.TrimSpace(deviceName),
		"Enrolled":    enrolled.UTC().Format(time.RFC3339),
	}
	for name, v := range headers {
		if err := CheckField(name, v); err != nil {
			return nil, err
		}
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Headers: headers, Bytes: spki}), nil
}

// WriteKey writes a key file atomically: a temporary file in the same
// folder, mode 0644 and owner, a sync, and a rename. It makes the folder
// with mode 0755 when it is missing.
func WriteKey(path string, owner int, content []byte) error {
	dir := filepath.Dir(path)
	// Root gets the root group. Another owner keeps its group, because a
	// user cannot give a file to a group that the user is not in.
	group := -1
	if owner == 0 {
		group = 0
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.Chown(dir, owner, group); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".key-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chown(owner, group); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// RemoveKey deletes a key file. A missing file is not an error.
func RemoveKey(path string) error {
	err := os.Remove(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}
