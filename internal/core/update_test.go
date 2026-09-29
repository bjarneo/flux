package core

import (
	"context"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"flux/internal/config"
)

func releaseDaemon(t *testing.T, url string) *Daemon {
	t.Helper()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	return &Daemon{
		cfg:         &config.Config{CheckUpdates: true},
		opts:        Options{Version: "0.6.0", ReleaseURL: url},
		dirty:       make(chan struct{}, 1),
		releaseWake: make(chan struct{}, 1),
		logger:      log.New(io.Discard, "", 0),
	}
}

func releaseServer(t *testing.T, tag string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"tag_name":"` + tag + `","html_url":"https://example.com/` + tag + `","assets":[
			{"name":"flux-android-0.7.0.apk","browser_download_url":"https://example.com/apk"}]}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func closedURL(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return "http://" + addr + "/latest"
}

func TestReleaseAvailable(t *testing.T) {
	d := releaseDaemon(t, releaseServer(t, "v0.7.0").URL)
	if err := d.checkRelease(context.Background()); err != nil {
		t.Fatal(err)
	}
	v := d.updateViewLocked()
	if v["available"] != true || v["latest"] != "0.7.0" || v["apk"] != "https://example.com/apk" {
		t.Fatalf("update view %v", v)
	}
	if got := loadRelease(); got.Version != "0.7.0" {
		t.Fatalf("the cache has %+v", got)
	}
	if w := d.releaseWait(time.Now(), 0); w < releaseInterval-time.Minute {
		t.Fatalf("the next check comes after %v, want about 1 day", w)
	}
}

// TestReleaseOffline checks a release check without a network. fluxd keeps
// the last known release, reports the error, and tries again in 1 hour.
func TestReleaseOffline(t *testing.T) {
	d := releaseDaemon(t, releaseServer(t, "v0.7.0").URL)
	if err := d.checkRelease(context.Background()); err != nil {
		t.Fatal(err)
	}
	d.opts.ReleaseURL = closedURL(t)
	if err := d.checkRelease(context.Background()); err == nil {
		t.Fatal("no error without a network")
	}
	v := d.updateViewLocked()
	if v["available"] != true || v["latest"] != "0.7.0" || v["error"] == "" {
		t.Fatalf("update view %v", v)
	}
	if w := d.releaseWait(time.Now(), 0); w > releaseRetry || w < releaseRetry-time.Minute {
		t.Fatalf("the retry comes after %v, want 1 hour", w)
	}

	// A new start reads the cache, so the update shows without a network.
	next := &Daemon{cfg: d.cfg, opts: d.opts, release: loadRelease()}
	if v := next.updateViewLocked(); v["available"] != true || v["latest"] != "0.7.0" {
		t.Fatalf("update view after a start %v", v)
	}
}

func TestReleaseOff(t *testing.T) {
	d := releaseDaemon(t, releaseServer(t, "v0.7.0").URL)
	d.cfg.CheckUpdates = false
	v := d.updateViewLocked()
	if v["enabled"] != false || v["available"] != false || v["latest"] != "" {
		t.Fatalf("update view %v", v)
	}
	if w := d.releaseWait(time.Now(), 0); w != releaseInterval {
		t.Fatalf("wait %v while the check is off", w)
	}
}

func TestReleaseNotNewer(t *testing.T) {
	for _, tag := range []string{"v0.6.0", "v0.5.0"} {
		d := releaseDaemon(t, releaseServer(t, tag).URL)
		if err := d.checkRelease(context.Background()); err != nil {
			t.Fatal(err)
		}
		if v := d.updateViewLocked(); v["available"] != false {
			t.Errorf("%s: update view %v", tag, v)
		}
	}
}

// TestInstallUpdate checks the command that the Update button starts,
// with a fake terminal launcher.
func TestInstallUpdate(t *testing.T) {
	bin := t.TempDir()
	out := filepath.Join(t.TempDir(), "args")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + out + "\n"
	if err := os.WriteFile(filepath.Join(bin, "omarchy-launch-floating-terminal-with-presentation"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "flux-cli"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	d := &Daemon{binDir: bin}
	if err := d.installUpdate(); err != nil {
		t.Fatal(err)
	}
	want := "'" + filepath.Join(bin, "flux-cli") + "' update\n"
	deadline := time.Now().Add(5 * time.Second)
	for {
		got, _ := os.ReadFile(out)
		if string(got) == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the launcher got %q, want %q", got, want)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestInstallUpdateNoTerminal(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	d := &Daemon{}
	if err := d.installUpdate(); err == nil {
		t.Fatal("no error without a terminal")
	}
}
