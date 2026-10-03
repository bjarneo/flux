package desktop

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// fakeWtype puts a wtype on PATH that writes its arguments and its stdin
// to files. It returns a function that reads them.
func fakeWtype(t *testing.T) func() ([]string, string) {
	t.Helper()
	dir := t.TempDir()
	args, stdin := filepath.Join(dir, "args"), filepath.Join(dir, "stdin")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + args + "\n/usr/bin/cat > " + stdin + "\n"
	if err := os.WriteFile(filepath.Join(dir, "wtype"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return func() ([]string, string) {
		a, err := os.ReadFile(args)
		if err != nil {
			t.Fatal(err)
		}
		in, err := os.ReadFile(stdin)
		if err != nil {
			t.Fatal(err)
		}
		return strings.Fields(string(a)), string(in)
	}
}

// TestKeyboardReleasesMods checks that Type and Key release each modifier
// after the text or the keys. Hyprland 0.56 keeps a modifier down that
// wtype does not release.
func TestKeyboardReleasesMods(t *testing.T) {
	read := fakeWtype(t)
	var kb Keyboard
	if err := kb.Type(context.Background(), "hi", []string{"ctrl", "shift"}); err != nil {
		t.Fatal(err)
	}
	args, in := read()
	if want := []string{"-M", "ctrl", "-M", "shift", "-", "-m", "shift", "-m", "ctrl"}; !slices.Equal(args, want) || in != "hi" {
		t.Errorf("Type ran wtype %q with %q on stdin, want %q with \"hi\"", args, in, want)
	}
	if err := kb.Key(context.Background(), "Up", []string{"logo"}, 2); err != nil {
		t.Fatal(err)
	}
	args, _ = read()
	if want := []string{"-M", "logo", "-k", "Up", "-k", "Up", "-m", "logo"}; !slices.Equal(args, want) {
		t.Errorf("Key ran wtype %q, want %q", args, want)
	}
	if err := kb.Key(context.Background(), "Return", nil, 1); err != nil {
		t.Fatal(err)
	}
	if args, _ = read(); !slices.Equal(args, []string{"-k", "Return"}) {
		t.Errorf("Key without modifiers ran wtype %q", args)
	}
}
