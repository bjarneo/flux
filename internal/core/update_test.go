package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/release"
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

// TestAppUpdate checks which devices get the offer of a new Android app.
func TestAppUpdate(t *testing.T) {
	d := releaseDaemon(t, "http://example.com/latest")
	d.release = releaseInfo{Version: "0.7.0", APK: "https://example.com/apk", Sums: "https://example.com/sums", Sig: "https://example.com/sig"}
	cases := []struct {
		app, version, want string
	}{
		{"android", "0.6.0", "0.7.0"},
		{"android", "0.7.0", ""},
		{"android", "0.8.0", ""},
		// A release APK cannot update a debug build with another key.
		{"android-debug", "0.6.0", ""},
		// An earlier app sends no version.
		{"", "", ""},
		{"ios", "0.6.0", ""},
		{"fluxd", "0.6.0", ""},
	}
	for _, c := range cases {
		dev := &Device{Name: "phone", App: c.app, AppVersion: c.version, Paired: true}
		if got := d.appUpdateLocked(dev); got != c.want {
			t.Errorf("%s %s: offer %q, want %q", c.app, c.version, got, c.want)
		}
	}
	// A device that is not paired gets no offer, and no app.
	stranger := &Device{Name: "phone", App: "android", AppVersion: "0.6.0"}
	if got := d.appUpdateLocked(stranger); got != "" {
		t.Errorf("an offer %q for a device that is not paired", got)
	}
	if err := d.sendAppUpdate(stranger); err == nil || err.(*Error).Code != "not_paired" {
		t.Errorf("sendAppUpdate to a device that is not paired: %v", err)
	}
	// Only 1 app update runs at a time.
	d.appSending = "tablet"
	if err := d.sendAppUpdate(&Device{Name: "phone", App: "android", AppVersion: "0.6.0", Paired: true}); err == nil || err.(*Error).Code != "busy" {
		t.Errorf("a second app update: %v", err)
	}
	if what := d.Busy(); what == "" {
		t.Error("Busy does not count the app update")
	}
	d.appSending = ""

	d.release.APK = ""
	if got := d.appUpdateLocked(&Device{App: "android", AppVersion: "0.6.0", Paired: true}); got != "" {
		t.Errorf("an offer %q without an APK in the release", got)
	}
	d.release.APK = "https://example.com/apk"
	// Without SHA256SUMS.sig, only a fluxd without a release key makes an
	// offer. A fluxd with a key cannot pass the check of the send.
	d.release.Sig = ""
	got := d.appUpdateLocked(&Device{App: "android", AppVersion: "0.6.0", Paired: true})
	if want := !release.Signed(); (got != "") != want {
		t.Errorf("without SHA256SUMS.sig: offer %q, and the release key is set: %v", got, release.Signed())
	}
	d.release.Sig = "https://example.com/sig"
	d.cfg.CheckUpdates = false
	if got := d.appUpdateLocked(&Device{App: "android", AppVersion: "0.6.0", Paired: true}); got != "" {
		t.Errorf("an offer %q with the release check off", got)
	}
	if err := d.sendAppUpdate(&Device{Name: "phone", App: "android", AppVersion: "0.6.0", Paired: true}); err == nil {
		t.Error("sendAppUpdate sent an app with no offer")
	}
}

// TestReleaseAssets checks which files of a release fluxd keeps: only the
// APK of the release version, SHA256SUMS, and SHA256SUMS.sig.
func TestReleaseAssets(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"tag_name":"v0.8.0","html_url":"https://example.com/v0.8.0","assets":[
			{"name":"flux-android-0.5.0.apk","browser_download_url":"https://example.com/old","size":5},
			{"name":"flux-android-0.8.0.apk","browser_download_url":"https://example.com/apk","size":8},
			{"name":"SHA256SUMS","browser_download_url":"https://example.com/sums","size":1},
			{"name":"SHA256SUMS.sig","browser_download_url":"https://example.com/sig","size":1}]}`))
	}))
	defer srv.Close()
	d := releaseDaemon(t, srv.URL)
	if err := d.checkRelease(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := releaseInfo{Version: "0.8.0", Page: "https://example.com/v0.8.0", APK: "https://example.com/apk", Sums: "https://example.com/sums",
		CheckedAt: d.release.CheckedAt, APKName: "flux-android-0.8.0.apk", APKSize: 8, Sig: "https://example.com/sig"}
	if d.release != want {
		t.Fatalf("release %+v, want %+v", d.release, want)
	}
}

// TestReleaseClock checks the wait after a clock change. A check time in
// the future makes the check due, and no wait is longer than 1 interval.
func TestReleaseClock(t *testing.T) {
	d := releaseDaemon(t, "http://example.com/latest")
	now := time.Now()
	d.release = releaseInfo{Version: "0.7.0", CheckedAt: now.Add(365 * 24 * time.Hour).Unix()}
	if w := d.releaseWait(now, 0); w != 0 {
		t.Errorf("a check time in the future: wait %v, want 0", w)
	}
	d.release.CheckedAt = now.Add(-time.Hour).Unix()
	if w := d.releaseWait(now, 0); w > releaseInterval || w < releaseInterval-2*time.Hour {
		t.Errorf("a check 1 hour ago: wait %v, want about 23 hours", w)
	}
	d.releaseErr, d.releaseTried = "offline", now.Add(24*time.Hour)
	if w := d.releaseWait(now, 0); w > releaseInterval {
		t.Errorf("a wait of %v, longer than 1 interval", w)
	}
}

// TestReleaseRetryOnWake checks that a network change after a failed check
// starts a check at once, but not within 1 minute of the failure. A change
// in that minute starts the check at the end of the minute.
func TestReleaseRetryOnWake(t *testing.T) {
	d := releaseDaemon(t, closedURL(t))
	if err := d.checkRelease(context.Background()); err == nil {
		t.Fatal("no error without a network")
	}
	now := time.Now()
	if wait := d.releaseWait(now, 0); wait < releaseRetry-time.Minute {
		t.Errorf("the retry without a wake is due in %v", wait)
	}
	// A wake 20 seconds after the failure makes the retry due 1 minute
	// after the failure.
	d.mu.Lock()
	d.releaseTried, d.releaseWoken = now.Add(-20*time.Second), true
	d.mu.Unlock()
	if wait := d.releaseWait(now, 0); wait != releaseRetryGap-20*time.Second {
		t.Errorf("the retry after a wake in the gap is due in %v", wait)
	}
	if wait := d.releaseWait(now.Add(releaseRetryGap), 0); wait != 0 {
		t.Errorf("the retry after a wake is not due at the end of the gap: %v", wait)
	}

	// A wake in the gap starts the check at the end of the gap.
	d.mu.Lock()
	d.releaseTried, d.releaseWoken = time.Now().Add(-releaseRetryGap+300*time.Millisecond), false
	d.mu.Unlock()
	d.opts.ReleaseURL = releaseServer(t, "v0.7.0").URL
	d.opts.ReleaseDelay = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.releaseLoop(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		<-done
	}()
	d.wakeRelease()
	waitRelease(t, d, "0.7.0")

	// A wake after the gap starts the check at once.
	d.mu.Lock()
	d.releaseErr, d.releaseTried = "offline", time.Now().Add(-2*releaseRetryGap)
	d.release.Version = ""
	d.mu.Unlock()
	d.wakeRelease()
	waitRelease(t, d, "0.7.0")
}

// waitRelease waits up to 5 seconds for a check that finds the version.
func waitRelease(t *testing.T, d *Daemon, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		d.mu.Lock()
		version, failed := d.release.Version, d.releaseErr
		d.mu.Unlock()
		if version == want && failed == "" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("no check after the wake: release %q, error %q", version, failed)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestSendAppUnpaired checks that a phone that was unpaired during the
// download gets no app. The download also removes the APK of an earlier
// release from the cache.
func TestSendAppUnpaired(t *testing.T) {
	body := []byte("apk")
	sum := sha256.Sum256(body)
	mux := http.NewServeMux()
	mux.HandleFunc("/flux-android-0.7.0.apk", func(w http.ResponseWriter, r *http.Request) { w.Write(body) })
	mux.HandleFunc("/SHA256SUMS", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(hex.EncodeToString(sum[:]) + "  flux-android-0.7.0.apk\n"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	d := releaseDaemon(t, srv.URL)
	var logs bytes.Buffer
	d.logger = log.New(&logs, "", 0)
	d.ctx = context.Background()
	dir := filepath.Join(cacheDir(), "update")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(dir, "flux-android-0.6.0.apk")
	if err := os.WriteFile(old, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := releaseInfo{Version: "0.7.0", APK: srv.URL + "/flux-android-0.7.0.apk", Sums: srv.URL + "/SHA256SUMS",
		APKName: "flux-android-0.7.0.apk", APKSize: int64(len(body))}
	d.sendApp(&Device{Name: "phone", App: "android", AppVersion: "0.6.0"}, r, "0.7.0", "phone")

	if !strings.Contains(logs.String(), "is not paired now") {
		t.Errorf("the log does not say that the phone is not paired: %q", logs.String())
	}
	if len(d.transfers) != 0 {
		t.Errorf("%d transfers to a phone that is not paired", len(d.transfers))
	}
	if _, err := os.Stat(filepath.Join(dir, "flux-android-0.7.0.apk")); err != nil {
		t.Errorf("the checked APK: %v", err)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Errorf("the APK of the earlier release stays: %v", err)
	}
}
