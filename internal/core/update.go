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

	"flux/internal/desktop"
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
	// releaseRetryGap is the shortest time between a failed check and
	// the check that a network change starts. A network that changes
	// often then does not start a check at each change. A change in the
	// gap starts the check at the end of the gap.
	releaseRetryGap = time.Minute
)

// releaseInfo is the last answer from GitHub.
type releaseInfo struct {
	Version   string `json:"version"`
	Page      string `json:"page"`
	APK       string `json:"apk,omitempty"`
	Sums      string `json:"sums,omitempty"`
	CheckedAt int64  `json:"checkedAt"`

	// APKName and APKSize are the name and the size of the APK. Sig is
	// the address of SHA256SUMS.sig, or "" when the release has no
	// signature. A cache from an earlier fluxd does not have them.
	APKName string `json:"apkName,omitempty"`
	APKSize int64  `json:"apkSize,omitempty"`
	Sig     string `json:"sig,omitempty"`
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
		due := false
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			due = d.releaseWait(time.Now(), 0) == 0
		case <-d.releaseWake:
			d.mu.Lock()
			d.releaseWoken = true
			d.mu.Unlock()
			due = d.releaseWait(time.Now(), 0) == 0
		}
		if due {
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

// releaseWait returns the time until the next check, at least least. While
// check_updates is off, only a wake starts a check. A check time in the
// future comes from a clock that was wrong, so the next check is due.
// After a failed check, a wake makes the retry due releaseRetryGap after
// the failure. A network change often ends the error.
func (d *Daemon) releaseWait(now time.Time, least time.Duration) time.Duration {
	d.mu.Lock()
	defer d.mu.Unlock()
	var wait time.Duration
	checked := time.Unix(d.release.CheckedAt, 0)
	switch {
	case !d.cfg.CheckUpdates:
		wait = releaseInterval
	case d.releaseErr != "" && d.releaseWoken:
		wait = d.releaseTried.Add(releaseRetryGap).Sub(now)
	case d.releaseErr != "":
		wait = d.releaseTried.Add(releaseRetry).Sub(now)
	case d.release.CheckedAt == 0 || checked.After(now):
		wait = 0
	default:
		wait = checked.Add(releaseInterval).Sub(now)
	}
	return max(min(wait, releaseInterval), least, 0)
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
	d.releaseTried, d.releaseWoken = now, false
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
	if apk, ok := r.Find(func(n string) bool { return n == apkName(info.Version) }); ok {
		info.APK, info.APKName, info.APKSize = apk.URL, apk.Name, apk.Size
	}
	if sums, ok := r.Find(func(n string) bool { return n == "SHA256SUMS" }); ok {
		info.Sums = sums.URL
	}
	if sig, ok := r.Find(func(n string) bool { return n == "SHA256SUMS.sig" }); ok {
		info.Sig = sig.URL
	}
	known := d.release.Version
	d.release, d.releaseErr = info, ""
	d.mu.Unlock()
	if err := saveRelease(info); err != nil {
		d.logf("release check: %v", err)
	}
	if len(r.Dropped) > 0 {
		d.logf("release check: GitHub gives %s of Flux %s at an address outside the Flux repository, so fluxd does not use these files", strings.Join(r.Dropped, ", "), info.Version)
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

// apkName is the name of the APK of the release version.
func apkName(version string) string { return "flux-android-" + version + ".apk" }

// appUpdateLocked returns the version of the Android app in the latest
// release when it is newer than the app on dev, else "". An earlier app
// sends no version, and a debug build is "android-debug", so neither gets
// an offer. A device that is not paired gets no offer. When this fluxd has
// a release key, a release without SHA256SUMS.sig gets no offer, because
// the send cannot pass the check.
func (d *Daemon) appUpdateLocked(dev *Device) string {
	r := d.release
	if !d.cfg.CheckUpdates || d.opts.ReleaseURL == "" || r.APK == "" || r.Sums == "" || (release.Signed() && r.Sig == "") || dev.App != "android" || !dev.Paired {
		return ""
	}
	if !release.Newer(r.Version, dev.AppVersion) {
		return ""
	}
	return r.Version
}

// sendAppUpdate downloads the Android app of the latest release, checks
// it against SHA256SUMS and its signature, and sends it to the phone. The
// phone opens the Android installer from its notification. The installer
// accepts only an app with the same signing key. Only 1 app update runs
// at a time.
func (d *Daemon) sendAppUpdate(dev *Device) error {
	d.mu.Lock()
	paired, name := dev.Paired, dev.Name
	version := d.appUpdateLocked(dev)
	r, busy := d.release, d.appSending
	if paired && version != "" && busy == "" {
		d.appSending = name
	}
	d.mu.Unlock()
	switch {
	case !paired:
		return apiErr("not_paired", "%s is not paired", name)
	case version == "":
		return apiErr("no_update", "No newer Flux for Android is available for %s", name)
	case busy != "":
		return apiErr("busy", "Flux for Android goes to %s now. Wait until that transfer ends", busy)
	}
	go func() {
		defer func() {
			d.mu.Lock()
			d.appSending = ""
			d.mu.Unlock()
			d.markDirty()
		}()
		d.sendApp(dev, r, version, name)
	}()
	return nil
}

// sendApp downloads the APK of r, sends it to dev, and waits for the end
// of the transfer. It shows the result as a toast and logs an error.
func (d *Daemon) sendApp(dev *Device, r releaseInfo, version, name string) {
	d.toast("Downloading Flux for Android %s", version)
	if !release.Signed() {
		d.logf("app update: this fluxd has no release key, so it checks the APK only against SHA256SUMS")
	}
	apk := release.Asset{Name: r.APKName, URL: r.APK, Size: r.APKSize}
	if apk.Name == "" {
		apk.Name = apkName(r.Version)
	}
	dir := filepath.Join(cacheDir(), "update")
	path, _, err := release.Fetch(d.ctx, apk, r.Sums, r.Sig, dir, d.opts.Version)
	if err != nil {
		d.logf("app update: %v", err)
		d.toast("Cannot download Flux for Android %s: %v", version, err)
		return
	}
	removeOldApps(dir, apk.Name)
	// The download can take minutes. A phone that was unpaired in that
	// time gets no app.
	d.mu.Lock()
	paired := dev.Paired
	d.mu.Unlock()
	if !paired {
		d.logf("app update: %s is not paired now, so fluxd does not send %s", name, apk.Name)
		return
	}
	transfers, err := d.SendFiles(dev, []string{path})
	if err != nil {
		d.logf("app update: send %s to %s: %v", apk.Name, name, err)
		d.toast("Cannot send Flux for Android %s: %v", version, err)
		return
	}
	d.toast("Sending Flux for Android %s to %s", version, name)
	switch state, msg := d.transferEnd(transfers[0]); state {
	case "done":
		d.toast("Sent Flux for Android %s to %s. Open its notification on the phone to install it", version, name)
	case "canceled":
		d.logf("app update: the transfer of %s to %s stopped", apk.Name, name)
	default:
		// SendFiles shows the error as a toast.
		d.logf("app update: send %s to %s: %s", apk.Name, name, msg)
	}
}

// transferEnd waits until t ends. It returns the last state of t and its
// error.
func (d *Daemon) transferEnd(t *Transfer) (string, string) {
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		d.mu.Lock()
		state, msg := t.State, t.Error
		d.mu.Unlock()
		if state != "queued" && state != "active" {
			return state, msg
		}
		select {
		case <-d.ctx.Done():
			return "canceled", ""
		case <-tick.C:
		}
	}
}

// removeOldApps removes the APKs in dir other than keep, so that the cache
// keeps only the APK of the latest release.
func removeOldApps(dir, keep string) {
	old, _ := filepath.Glob(filepath.Join(dir, "flux-android-*.apk"))
	for _, p := range old {
		if filepath.Base(p) != keep {
			os.Remove(p)
		}
	}
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
		// The terminal must outlive the restart of fluxd after the update.
		cmd = desktop.UserCommand(p, "sh", "-c", line+`; printf '\nPress Enter to close. '; read _`)
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
