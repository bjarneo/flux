package approve

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// HelperPath is the PAM helper that the package installs.
const HelperPath = "/usr/lib/flux/flux-approve"

// PAMLine is the line that turns approvals on in a PAM file. sufficient
// means that an approval ends the auth stack, and that any other result
// goes on to the next rule, so the password still works.
const PAMLine = "auth sufficient pam_exec.so quiet stdout " + HelperPath

// pamComment goes above PAMLine, so that a reader knows where the line
// comes from and how to remove it.
const pamComment = "# Flux: approve with the phone fingerprint. `sudo flux approve disable` removes it."

// PAMServices are the PAM services that Flux can turn approvals on for.
// Flux never changes sshd or login, and the helper refuses sshd.
var PAMServices = []string{"sudo", "polkit-1", "hyprlock"}

// ErrNoAuth is the error for a PAM file with no auth rule.
var ErrNoAuth = errors.New("the PAM file has no auth rule")

// AddPAMLine inserts PAMLine before the first auth rule of a PAM file. It
// returns the text unchanged and false when the file already runs the
// helper.
func AddPAMLine(text string) (string, bool, error) {
	lines := strings.Split(text, "\n")
	for _, l := range lines {
		if runsHelper(l) {
			return text, false, nil
		}
	}
	for i, l := range lines {
		f := strings.Fields(l)
		if len(f) > 0 && (f[0] == "auth" || f[0] == "-auth") {
			out := append([]string{}, lines[:i]...)
			out = append(out, pamComment, PAMLine)
			out = append(out, lines[i:]...)
			return strings.Join(out, "\n"), true, nil
		}
	}
	return text, false, ErrNoAuth
}

// RemovePAMLine removes each rule that runs the helper, and the comment
// that AddPAMLine wrote. It returns false when the file does not run the
// helper.
func RemovePAMLine(text string) (string, bool) {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	changed := false
	for _, l := range lines {
		if runsHelper(l) || strings.TrimSpace(l) == pamComment {
			changed = true
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n"), changed
}

// runsHelper reports whether a PAM line is a rule that runs the helper.
func runsHelper(line string) bool {
	t := strings.TrimSpace(line)
	return !strings.HasPrefix(t, "#") && strings.Contains(t, HelperPath)
}

// PAMFiles are the folders of the PAM files. Tests set them to temporary
// folders.
type PAMFiles struct {
	// Dir is /etc/pam.d, which Flux changes.
	Dir string
	// Vendor is /usr/lib/pam.d. A service with no file in Dir, such as
	// polkit-1, starts from its vendor file.
	Vendor string
	// Backup gets a copy of each file before its first change.
	Backup string
}

// SystemPAM returns the PAM folders of the system.
func SystemPAM() PAMFiles {
	return PAMFiles{Dir: "/etc/pam.d", Vendor: "/usr/lib/pam.d", Backup: filepath.Join(KeyDir, "pam-backup")}
}

// Enable adds PAMLine to the file of service. It returns false when the
// file already runs the helper.
func (p PAMFiles) Enable(service string) (bool, error) {
	if err := checkService(service); err != nil {
		return false, err
	}
	path := filepath.Join(p.Dir, service)
	text, mode, err := p.read(service)
	if err != nil {
		return false, err
	}
	next, changed, err := AddPAMLine(text)
	if err != nil {
		return false, fmt.Errorf("%s: %w", path, err)
	}
	if !changed {
		return false, nil
	}
	if err := p.backup(service, text); err != nil {
		return false, err
	}
	return true, writeAtomic(path, next, mode)
}

// Disable removes the helper from the file of service. It returns false
// when the file does not run the helper, or when there is no file.
func (p PAMFiles) Disable(service string) (bool, error) {
	if err := checkService(service); err != nil {
		return false, err
	}
	path := filepath.Join(p.Dir, service)
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	next, changed := RemovePAMLine(string(b))
	if !changed {
		return false, nil
	}
	st, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	return true, writeAtomic(path, next, st.Mode().Perm())
}

// Uses reports whether the file of service runs the helper.
func (p PAMFiles) Uses(service string) bool {
	b, err := os.ReadFile(filepath.Join(p.Dir, service))
	if err != nil {
		return false
	}
	for _, l := range strings.Split(string(b), "\n") {
		if runsHelper(l) {
			return true
		}
	}
	return false
}

// read returns the text and the mode of the file of service. A service
// with no file in Dir starts from its vendor file.
func (p PAMFiles) read(service string) (string, os.FileMode, error) {
	path := filepath.Join(p.Dir, service)
	b, err := os.ReadFile(path)
	if err == nil {
		st, err := os.Stat(path)
		if err != nil {
			return "", 0, err
		}
		return string(b), st.Mode().Perm(), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", 0, err
	}
	b, verr := os.ReadFile(filepath.Join(p.Vendor, service))
	if verr != nil {
		return "", 0, fmt.Errorf("%s does not exist, so %s is not installed", path, service)
	}
	return string(b), 0o644, nil
}

// backup writes a copy of the file before its first change. A later
// change keeps the first copy, which has the file as it was before Flux.
func (p PAMFiles) backup(service, text string) error {
	if err := os.MkdirAll(p.Backup, 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(p.Backup, service), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if errors.Is(err, os.ErrExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func checkService(service string) error {
	for _, s := range PAMServices {
		if s == service {
			return nil
		}
	}
	return fmt.Errorf("flux does not change the PAM file of %q. Use one of: %s", service, strings.Join(PAMServices, ", "))
}

// writeAtomic replaces path with text, so that PAM never reads a file
// that is half written. The file keeps mode, and root owns it when root
// writes it.
func writeAtomic(path, text string, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".flux-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.WriteString(text); err != nil {
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
	if err := os.Chmod(name, mode); err != nil {
		return err
	}
	if os.Geteuid() == 0 {
		if err := os.Chown(name, 0, 0); err != nil {
			return err
		}
	}
	return os.Rename(name, path)
}
