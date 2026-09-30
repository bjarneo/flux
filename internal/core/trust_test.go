package core

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"flux/internal/config"
)

// A damaged devices.json does not stop fluxd. fluxd moves the file aside,
// logs it, and tells the first window that connects.
func TestBrokenTrustStoreStarts(t *testing.T) {
	home := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, "config"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(home, "data"))
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(home, "run"))
	if err := os.MkdirAll(config.DataDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config.DataDir(), "devices.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	d, err := New(context.Background(), log.New(&logs, "", 0), Options{Headless: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "devices.json.broken-") {
		t.Fatalf("log %q", logs.String())
	}
	toasts := func() []string {
		var out []string
		stop := d.Subscribe(func(event string, data any) {
			if event == "toast" {
				out = append(out, data.(map[string]string)["text"])
			}
		})
		stop()
		return out
	}
	if got := toasts(); len(got) != 1 || !strings.Contains(got[0], "Pair your devices again") {
		t.Fatalf("toasts of the first window: %q", got)
	}
	if got := toasts(); len(got) != 0 {
		t.Fatalf("toasts of the second window: %q", got)
	}
}
