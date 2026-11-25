package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"flux/internal/approve"
)

func lookupAlice(name string) (approve.User, error) {
	if name == "alice" {
		return approve.User{Name: "alice", UID: 1000}, nil
	}
	return approve.User{}, errors.New("alice is the only user")
}

func TestSudoUserRefusesRoot(t *testing.T) {
	cases := []struct {
		euid int
		name string
		ok   bool
	}{
		{0, "alice", true},
		{1000, "alice", false},
		{0, "", false},
		{0, "root", false},
		{0, "../alice", false},
		{0, "carol", false},
	}
	for _, c := range cases {
		u, err := findSudoUser("setup", c.euid, c.name, lookupAlice)
		if (err == nil) != c.ok {
			t.Errorf("euid %d SUDO_USER %q: %+v %v", c.euid, c.name, u, err)
		}
	}
	root := func(string) (approve.User, error) { return approve.User{Name: "toor", UID: 0}, nil }
	if _, err := findSudoUser("setup", 0, "toor", root); err == nil {
		t.Error("a user with the user ID 0 must fail")
	}
}

func TestCheckHelperRefusesWritableHelper(t *testing.T) {
	dir := t.TempDir()
	if err := checkHelper(filepath.Join(dir, "missing")); err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Errorf("a missing helper: %v", err)
	}
	// The test user owns this file, so it is not a file that only root
	// can change.
	path := filepath.Join(dir, "flux-approve")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if os.Getuid() != 0 {
		if err := checkHelper(path); err == nil || !strings.Contains(err.Error(), "only root") {
			t.Errorf("a helper of the user: %v", err)
		}
	}
	if err := os.Chmod(path, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := checkHelper(path); err == nil || !strings.Contains(err.Error(), "only root") {
		t.Errorf("a helper that others can write: %v", err)
	}
}

func TestPolkitNeedsSetuidHelper(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "polkit-agent-helper-1")
	if err := polkitSetuid([]string{path}); err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Errorf("no helper: %v", err)
	}
	if err := os.WriteFile(path, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := polkitSetuid([]string{path}); err == nil || !strings.Contains(err.Error(), "setuid") {
		t.Errorf("a helper that runs as a service: %v", err)
	}
	if err := os.Chmod(path, 0o755|os.ModeSetuid); err != nil {
		t.Fatal(err)
	}
	if err := polkitSetuid([]string{filepath.Join(dir, "none"), path}); err != nil {
		t.Errorf("a setuid helper: %v", err)
	}
}

// The user types the code of the phone. The terminal does not show the
// code of the key that fluxd sent.
func TestTypedCode(t *testing.T) {
	code := "5EE6 825F 974E D59A"
	if !typedCode(bufio.NewReader(strings.NewReader("5ee6 825f 974e d59a\n")), io.Discard, "Pixel 8", code) {
		t.Error("the code of the phone must match")
	}
	for _, typed := range []string{"y\n", "5EE6 825F\n", "5EE6 825F 974E D59B\n", ""} {
		if typedCode(bufio.NewReader(strings.NewReader(typed)), io.Discard, "Pixel 8", code) {
			t.Errorf("%q must not match", typed)
		}
	}

	// An earlier phone app says to type y. The user gets a hint and
	// types the code on the next try.
	var out strings.Builder
	if !typedCode(bufio.NewReader(strings.NewReader("y\n5EE6-825F-974E-D59A\n")), &out, "Pixel 8", code) {
		t.Error("the code after y must match")
	}
	if !strings.Contains(out.String(), "Do not type y. Type the 16 characters that Pixel 8 shows.") {
		t.Errorf("no hint after y:\n%s", out.String())
	}
	// The user has 3 tries.
	wrong := strings.Repeat("5EE6 825F 974E D59B\n", codeTries)
	if typedCode(bufio.NewReader(strings.NewReader(wrong+"5EE6 825F 974E D59A\n")), io.Discard, "Pixel 8", code) {
		t.Errorf("a code after %d wrong codes must not match", codeTries)
	}
	if !typedCode(bufio.NewReader(strings.NewReader(wrong[20:]+"5EE6 825F 974E D59A\n")), io.Discard, "Pixel 8", code) {
		t.Error("the code on the last try must match")
	}
}

// flux-cli doctor prints the polkit-1 line of flux-cli approve status when
// polkit-1 cannot ask the phone of an enrolled user.
func TestApproveDoctorPrintsThePolkitLine(t *testing.T) {
	unsupported := errors.New("polkit-agent-helper-1 is not installed, so polkit-1 cannot use approvals")
	cases := []struct {
		name           string
		enrolled, uses bool
		unsupported    error
		want           string
		wantProblem    bool
	}{
		{"not enrolled", false, true, unsupported, "", false},
		{"polkit-1 can ask", true, true, nil, "", false},
		{"cannot ask, no helper in the PAM file", true, false, unsupported, "- polkit-1 cannot ask the phone: " + unsupported.Error() + "\n", false},
		{"cannot ask, helper in the PAM file", true, true, unsupported, "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var out strings.Builder
			var fixes []string
			check := func(ok bool, pass, fix string) {
				if !ok {
					fixes = append(fixes, fix)
				}
			}
			approveDoctor(&out, c.enrolled, c.uses, c.unsupported, check)
			if out.String() != c.want {
				t.Errorf("output %q, want %q", out.String(), c.want)
			}
			switch {
			case c.wantProblem:
				want := serviceLine("polkit-1", true, c.unsupported)
				if len(fixes) != 1 || fixes[0] != want {
					t.Errorf("problems %q, want %q", fixes, want)
				}
			case len(fixes) != 0:
				t.Errorf("problems %q", fixes)
			}
		})
	}
}

func TestServiceLine(t *testing.T) {
	bad := errors.New("no")
	for _, c := range []struct {
		uses bool
		err  error
		want string
	}{
		{true, bad, "polkit-1 runs the helper, but it cannot ask the phone: no"},
		{false, bad, "polkit-1 cannot ask the phone: no"},
		{true, nil, "polkit-1 asks the phone first."},
		{false, nil, "polkit-1 does not ask the phone. To turn it on, run: sudo flux-cli approve enable polkit-1"},
	} {
		if got := serviceLine("polkit-1", c.uses, c.err); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}
