package core

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"flux/internal/release"
)

// The release check. While check_updates is on, fluxd asks GitHub once a
// day for the latest release. It keeps the last answer in the cache, so a
// restart does not ask again, and a known update stays visible without a
// network. A failed check changes nothing else in fluxd.

const (
	// releaseInterval is the time between 2 checks.
	releaseInterval = 24 * time.Hour
	// releaseRetry is the wait after a failed check. A network change
	// also starts the next check.
	releaseRetry = time.Hour
)

// releaseInfo is the last answer from GitHub.
type releaseInfo struct {
	Version   string `json:"version"`
	Page      string `json:"page"`
	APK       string `json:"apk,omitempty"`
	CheckedAt int64  `json:"checkedAt"`
}

func releasePath() string { return filepath.Join(cacheDir(), "release.json") }

func loadRelease() releaseInfo {
	var r releaseInfo
	if data, err := os.ReadFile(releasePath()); err == nil {
		_ = json.Unmarshal(data, &r)
	}
	return r
}

func saveRelease(r releaseInfo) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cacheDir(), 0o755); err != nil {
		return err
	}
	tmp := releasePath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, releasePath())
}

// releaseLoop checks for a new release while check_updates is on.
func (d *Daemon) releaseLoop(ctx context.Context) {
	if d.opts.ReleaseURL == "" {
		return
	}
	info := loadRelease()
	d.mu.Lock()
	d.release = info
	d.mu.Unlock()
	d.markDirty()

	timer := time.NewTimer(d.releaseWait(time.Now(), d.opts.ReleaseDelay))
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		case <-d.releaseWake:
		}
		if d.releaseWait(time.Now(), 0) == 0 {
			_ = d.checkRelease(ctx)
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(d.releaseWait(time.Now(), 0))
	}
}

// releaseWait returns the time until the next check, at least min. While
// check_updates is off, only a wake starts a check.
func (d *Daemon) releaseWait(now time.Time, min time.Duration) time.Duration {
	d.mu.Lock()
	defer d.mu.Unlock()
	var wait time.Duration
	switch {
	case !d.cfg.CheckUpdates:
		wait = releaseInterval
	case d.releaseErr != "":
		wait = d.releaseTried.Add(releaseRetry).Sub(now)
	case d.release.CheckedAt == 0:
		wait = 0
	default:
		wait = time.Unix(d.release.CheckedAt, 0).Add(releaseInterval).Sub(now)
	}
	return max(wait, min, 0)
}

// wakeRelease starts a check when one is due: after check_updates turns
// on, or after a network change that follows a failed check.
func (d *Daemon) wakeRelease() {
	select {
	case d.releaseWake <- struct{}{}:
	default:
	}
}

// checkRelease asks GitHub for the latest release. On an error, fluxd
// keeps the last answer and logs the error once.
func (d *Daemon) checkRelease(ctx context.Context) error {
	r, err := release.Latest(ctx, d.opts.ReleaseURL, d.opts.Version)
	now := time.Now()
	d.mu.Lock()
	d.releaseTried = now
	if err != nil {
		changed := d.releaseErr != err.Error()
		d.releaseErr = err.Error()
		d.mu.Unlock()
		if changed {
			d.logf("release check: %v. fluxd tries again in 1 hour or after a network change", err)
		}
		d.markDirty()
		return err
	}
	info := releaseInfo{Version: r.Version(), Page: r.Page, CheckedAt: now.Unix()}
	if apk, ok := r.Find(func(n string) bool { return strings.HasPrefix(n, "flux-android-") && strings.HasSuffix(n, ".apk") }); ok {
		info.APK = apk.URL
	}
	known := d.release.Version
	d.release, d.releaseErr = info, ""
	d.mu.Unlock()
	if err := saveRelease(info); err != nil {
		d.logf("release check: %v", err)
	}
	if info.Version != known && release.Newer(info.Version, d.opts.Version) {
		d.logf("Flux %s is available. This computer runs %s. To update, run: flux-cli update", info.Version, d.opts.Version)
	}
	d.markDirty()
	return nil
}

// updateViewLocked is the update part of the state.
func (d *Daemon) updateViewLocked() map[string]any {
	on := d.cfg.CheckUpdates && d.opts.ReleaseURL != ""
	v := map[string]any{"enabled": on, "latest": "", "available": false, "url": "", "apk": "", "checkedAt": int64(0), "error": ""}
	if !on {
		return v
	}
	r := d.release
	v["latest"], v["url"], v["apk"], v["checkedAt"], v["error"] = r.Version, r.Page, r.APK, r.CheckedAt, d.releaseErr
	v["available"] = release.Newer(r.Version, d.opts.Version)
	return v
}

// installUpdate opens a terminal that runs `flux-cli update`, so that the
// user sees pacman and can answer sudo.
func (d *Daemon) installUpdate() error {
	cli := "flux-cli"
	if p := filepath.Join(d.binDir, "flux-cli"); d.binDir != "" {
		if _, err := os.Stat(p); err == nil {
			cli = p
		}
	}
	line := shellQuote(cli) + " update"
	var cmd *exec.Cmd
	if p, err := exec.LookPath("omarchy-launch-floating-terminal-with-presentation"); err == nil {
		cmd = exec.Command(p, line)
	} else if p, err := exec.LookPath("xdg-terminal-exec"); err == nil {
		cmd = exec.Command(p, "sh", "-c", line+`; printf '\nPress Enter to close. '; read _`)
	} else {
		return apiErr("no_terminal", "No terminal found. Run: flux-cli update")
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return apiErr("no_terminal", "Cannot open a terminal: %v. Run: flux-cli update", err)
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
