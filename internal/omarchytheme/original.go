package omarchytheme

import (
	"encoding/json"
	"errors"
	"flux/internal/wallpaper"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
)

// Original returns the selected bytes, never the preview projection. Read them
// between generation/revision checks; callers fence the live paired link again.
func (r Reader) Original(c Catalog) ([]byte, error) {
	before, ok := r.ReadRevision()
	if !ok || before.Revision != c.Revision || before.Current != c.Current {
		return nil, errors.New("stale")
	}
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	path, e := canonicalOriginalPath(state)
	if e != nil {
		return nil, e
	}
	g, ok := generation(path, false)
	if !ok {
		return nil, errors.New("source")
	}
	data, e := readRegular(path, wallpaper.MaxBytes)
	if e != nil {
		return nil, e
	}
	if _, _, _, e = wallpaper.Inspect(data); e != nil {
		return nil, e
	}
	after, ok := r.ReadRevision()
	g2, valid := generation(path, false)
	if !ok || !valid || after.Revision != c.Revision || g != g2 {
		return nil, errors.New("stale")
	}
	return data, nil
}

// Only Omarchy's locally selected link supplies the original source. This
// permits a manually selected image outside the theme folders without adding
// a remote path parameter or relaxing readRegular's no-symlink/file bounds.
func canonicalOriginalPath(state string) (string, error) {
	fd, err := openSafe(state, unix.O_RDONLY|unix.O_DIRECTORY)
	if err != nil {
		return "", err
	}
	defer unix.Close(fd)
	target, err := backgroundLink(fd)
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(state, target)
	}
	return filepath.Clean(target), nil
}

// CommitOriginal changes only the selected image, under the existing theme
// switch lock. Both previous pixels and link remain recoverable on failure.
// notify invokes the fixed local shell IPC; never a peer-supplied command.
func (r Reader) CommitOriginal(m wallpaper.Meta, data []byte, authorized func() bool, notify func(string) error) (string, error) {
	if e := wallpaper.Validate(m, data); e != nil {
		return "", e
	}
	fd, e := openSafe(filepath.Join(r.runtimePath(), "omarchy-theme-set.lock"), unix.O_RDWR|unix.O_CREAT)
	if e != nil {
		return "", e
	}
	defer unix.Close(fd)
	var st unix.Stat_t
	if unix.Fstat(fd, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Nlink != 1 || st.Uid != uint32(os.Geteuid()) || unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB) != nil {
		return "", errors.New("busy")
	}
	c, ok := r.readRevision()
	if !ok || !authorized() {
		return "", errors.New("stale-session")
	}
	receiptPath := filepath.Join(r.Home, ".local/state/omarchy/flux-wallpaper-receipts.json")
	type receipt struct {
		Meta     wallpaper.Meta `json:"meta"`
		Revision string         `json:"revision"`
	}
	receipts := map[string]receipt{}
	if raw, err := readRegular(receiptPath, 256<<10); err == nil {
		if json.Unmarshal(raw, &receipts) != nil {
			return "", errors.New("receipt-corrupt")
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	key := m.Origin + ":" + m.Operation
	if done, exists := receipts[key]; exists {
		if done.Meta != m {
			return "", errors.New("operation-reuse")
		}
		return done.Revision, nil
	}
	saveReceipt := func(revision string) error {
		// A bounded durable ledger; evicted old operations still face revision CAS.
		if len(receipts) >= 128 {
			for key := range receipts {
				delete(receipts, key)
				break
			}
		}
		receipts[key] = receipt{m, revision}
		raw, err := json.Marshal(receipts)
		if err != nil {
			return err
		}
		f, err := os.CreateTemp(filepath.Dir(receiptPath), ".wallpaper-receipt-")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())
		if _, err = f.Write(raw); err == nil {
			err = f.Sync()
		}
		ce := f.Close()
		if err == nil {
			err = ce
		}
		if err != nil {
			return err
		}
		return os.Rename(f.Name(), receiptPath)
	}
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	link := filepath.Join(state, "background")
	previous, e := os.Readlink(link)
	if e != nil {
		return "", e
	}
	extension := map[string]string{"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}[m.MIME]
	// Received images are selections, not additions to a theme album.
	// Keeping them outside both canonical album roots lets a later theme
	// selection choose that theme's own background.
	dir := filepath.Join(r.Home, ".local/state/omarchy/flux-wallpapers")
	target := filepath.Join(dir, m.SHA256+extension)
	// The shared hash cache is independent of theme IDs. Only a durable
	// historical receipt may acknowledge an operation from an older theme.
	if c.Current != m.Theme {
		return "", errors.New("conflict")
	}
	// Retry after a lost ACK/restart: original already selected, no hook or rewrite.
	if previous == target {
		existing, e := readRegular(target, wallpaper.MaxBytes)
		if e == nil && wallpaper.Validate(m, existing) == nil {
			if e = saveReceipt(c.Revision); e != nil {
				return "", e
			}
			return c.Revision, nil
		}
	}
	if c.Revision != m.Revision || c.Current != m.Theme {
		return "", errors.New("conflict")
	}
	if e = os.MkdirAll(dir, 0700); e != nil {
		return "", e
	}
	safe, e := openSafe(dir, unix.O_RDONLY|unix.O_DIRECTORY)
	if e != nil {
		return "", e
	}
	unix.Close(safe)
	temp, e := os.CreateTemp(dir, ".original-")
	if e != nil {
		return "", e
	}
	defer os.Remove(temp.Name())
	if _, e = temp.Write(data); e == nil {
		e = temp.Sync()
	}
	closeErr := temp.Close()
	if e == nil {
		e = closeErr
	}
	if e != nil {
		return "", e
	}
	if !authorized() {
		return "", errors.New("stale-session")
	}
	if e = os.Rename(temp.Name(), target); e != nil {
		return "", e
	}
	swap := func(value string) error {
		tmp, e := os.CreateTemp(state, ".wallpaper-link-")
		if e != nil {
			return e
		}
		name := tmp.Name()
		tmp.Close()
		os.Remove(name)
		defer os.Remove(name)
		if e = os.Symlink(value, name); e != nil {
			return e
		}
		return os.Rename(name, link)
	}
	// Check native theme state again after staging and immediately before commit.
	current, valid := r.readRevision()
	if !valid || current.Revision != m.Revision || !authorized() {
		return "", errors.New("conflict")
	}
	if e = swap(target); e != nil {
		return "", e
	}
	rollback := func(cause error) (string, error) {
		if err := swap(previous); err != nil {
			return "", errors.Join(cause, err)
		}
		restore := previous
		if !filepath.IsAbs(restore) {
			restore = filepath.Join(state, restore)
		}
		if err := notify(restore); err != nil {
			return "", errors.Join(cause, err)
		}
		return "", cause
	}
	if e = notify(target); e != nil {
		return rollback(e)
	}
	current, valid = r.readRevision()
	if !valid {
		return rollback(errors.New("revision"))
	}
	if e = saveReceipt(current.Revision); e != nil {
		return rollback(e)
	}
	return current.Revision, nil
}
