package desktop

import (
	"os"
	"slices"
	"testing"
)

// TestMain keeps the tests from systemd-run, so that no test starts a
// systemd unit.
func TestMain(m *testing.M) {
	userScope = func() bool { return false }
	os.Exit(m.Run())
}

func TestScopeArgs(t *testing.T) {
	got := scopeArgs(true, "xdg-open", []string{"https://omarchy.org"})
	want := []string{"systemd-run", "--user", "--scope", "--collect", "--quiet", "--", "xdg-open", "https://omarchy.org"}
	if !slices.Equal(got, want) {
		t.Errorf("with a scope: %q", got)
	}
	if got := scopeArgs(false, "sh", []string{"-c", "kitty &"}); !slices.Equal(got, []string{"sh", "-c", "kitty &"}) {
		t.Errorf("without a scope: %q", got)
	}
	if cmd := UserCommand("sh", "-c", "true"); !slices.Equal(cmd.Args, []string{"sh", "-c", "true"}) {
		t.Errorf("UserCommand without systemd-run: %q", cmd.Args)
	}
}
