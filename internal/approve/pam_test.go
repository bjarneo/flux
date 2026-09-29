package approve

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// archSudo is /etc/pam.d/sudo on Arch Linux.
const archSudo = `#%PAM-1.0
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session		optional	pam_systemd.so class=none
`

func TestAddPAMLine(t *testing.T) {
	out, changed, err := AddPAMLine(archSudo)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	lines := strings.Split(out, "\n")
	if lines[0] != "#%PAM-1.0" || lines[1] != pamComment || lines[2] != PAMLine || !strings.HasPrefix(lines[3], "auth\t\tinclude") {
		t.Fatalf("the line must come before the first auth rule:\n%s", out)
	}
	// A second run changes nothing.
	again, changed, err := AddPAMLine(out)
	if err != nil || changed || again != out {
		t.Fatalf("second run: changed=%v err=%v", changed, err)
	}
}

func TestAddPAMLineNeedsAuth(t *testing.T) {
	if _, _, err := AddPAMLine("#%PAM-1.0\naccount include system-auth\n"); !errors.Is(err, ErrNoAuth) {
		t.Fatalf("err = %v, want ErrNoAuth", err)
	}
}

func TestAddPAMLineKeepsACommentedHelper(t *testing.T) {
	// A commented line does not run the helper, so Flux adds its rule.
	in := "#auth sufficient pam_exec.so " + HelperPath + "\nauth include system-auth\n"
	out, changed, err := AddPAMLine(in)
	if err != nil || !changed || strings.Count(out, PAMLine) != 1 {
		t.Fatalf("changed=%v err=%v\n%s", changed, err, out)
	}
}

func TestRemovePAMLine(t *testing.T) {
	with, _, _ := AddPAMLine(archSudo)
	out, changed := RemovePAMLine(with)
	if !changed || out != archSudo {
		t.Fatalf("remove must give the original file back:\n%s", out)
	}
	if _, changed := RemovePAMLine(archSudo); changed {
		t.Fatal("a file with no helper must stay the same")
	}
}

func TestRemovePAMLineOldComment(t *testing.T) {
	with, _, _ := AddPAMLine(archSudo)
	with = strings.Replace(with, pamComment, oldPAMComment, 1)
	if out, changed := RemovePAMLine(with); !changed || out != archSudo {
		t.Fatalf("remove must also delete the comment of earlier versions:\n%s", out)
	}
}

func testPAM(t *testing.T) PAMFiles {
	root := t.TempDir()
	p := PAMFiles{Dir: filepath.Join(root, "etc"), Vendor: filepath.Join(root, "vendor"), Backup: filepath.Join(root, "backup")}
	for _, d := range []string{p.Dir, p.Vendor} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return p
}

func TestEnableDisable(t *testing.T) {
	p := testPAM(t)
	path := filepath.Join(p.Dir, "sudo")
	if err := os.WriteFile(path, []byte(archSudo), 0o644); err != nil {
		t.Fatal(err)
	}
	changed, err := p.Enable("sudo")
	if err != nil || !changed || !p.Uses("sudo") {
		t.Fatalf("enable: changed=%v err=%v", changed, err)
	}
	if b, _ := os.ReadFile(filepath.Join(p.Backup, "sudo")); string(b) != archSudo {
		t.Fatalf("the backup must hold the original file:\n%s", b)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode = %v, want 0644", st.Mode().Perm())
	}
	if changed, err := p.Enable("sudo"); err != nil || changed {
		t.Fatalf("second enable: changed=%v err=%v", changed, err)
	}
	changed, err = p.Disable("sudo")
	if err != nil || !changed || p.Uses("sudo") {
		t.Fatalf("disable: changed=%v err=%v", changed, err)
	}
	if b, _ := os.ReadFile(path); string(b) != archSudo {
		t.Fatalf("disable must give the original file back:\n%s", b)
	}
	// No temporary file stays in the PAM folder.
	entries, _ := os.ReadDir(p.Dir)
	if len(entries) != 1 {
		t.Fatalf("the PAM folder has %d files, want 1", len(entries))
	}
}

func TestEnableCopiesTheVendorFile(t *testing.T) {
	p := testPAM(t)
	vendor := "#%PAM-1.0\nauth include system-auth\naccount include system-auth\n"
	if err := os.WriteFile(filepath.Join(p.Vendor, "polkit-1"), []byte(vendor), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed, err := p.Enable("polkit-1"); err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	if !p.Uses("polkit-1") {
		t.Fatal("the copy in the PAM folder must run the helper")
	}
	if b, _ := os.ReadFile(filepath.Join(p.Vendor, "polkit-1")); string(b) != vendor {
		t.Fatal("the vendor file must stay the same")
	}
}

func TestEnableRefusesOtherServices(t *testing.T) {
	p := testPAM(t)
	for _, s := range []string{"sshd", "login", "../sudo", "system-auth"} {
		if _, err := p.Enable(s); err == nil {
			t.Errorf("%s: want an error", s)
		}
	}
	if _, err := p.Enable("hyprlock"); err == nil {
		t.Error("a service with no file must give an error")
	}
}

// Disable removes a copy of the vendor file that Enable made, so that
// later changes of the vendor file work again.
func TestDisableRemovesTheVendorCopy(t *testing.T) {
	p := testPAM(t)
	vendorPath := filepath.Join(p.Vendor, "polkit-1")
	vendor := "#%PAM-1.0\nauth include system-auth\naccount include system-auth\n"
	if err := os.WriteFile(vendorPath, []byte(vendor), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Enable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if changed, err := p.Disable("polkit-1"); err != nil || !changed {
		t.Fatalf("disable: changed=%v err=%v", changed, err)
	}
	if _, err := os.Stat(filepath.Join(p.Dir, "polkit-1")); !os.IsNotExist(err) {
		t.Fatalf("the copy stays: %v", err)
	}

	// An update of the vendor file between enable and disable.
	if _, err := p.Enable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(vendorPath, []byte(vendor+"session include system-auth\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Disable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(p.Dir, "polkit-1")); !os.IsNotExist(err) {
		t.Fatalf("the copy stays after a vendor update: %v", err)
	}

	// A copy that the administrator changed stays, without the Flux lines.
	if _, err := p.Enable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(p.Dir, "polkit-1")
	b, _ := os.ReadFile(path)
	if err := os.WriteFile(path, append(b, "# own rule\n"...), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Disable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(path); err != nil || p.Uses("polkit-1") || !strings.Contains(string(b), "# own rule") {
		t.Fatalf("the changed copy: %q %v", b, err)
	}
}

// A file that existed before Flux stays, also when it equals the vendor
// file.
func TestDisableKeepsAnOwnFile(t *testing.T) {
	p := testPAM(t)
	text := "#%PAM-1.0\nauth include system-auth\n"
	for _, dir := range []string{p.Dir, p.Vendor} {
		if err := os.WriteFile(filepath.Join(dir, "polkit-1"), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := p.Enable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Disable("polkit-1"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(p.Dir, "polkit-1")); err != nil || string(b) != text {
		t.Fatalf("the own file: %q %v", b, err)
	}
}
