package core

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"flux/internal/herdr"
)

// herdrKindsTTL is how long fluxd keeps the list of available agents.
const herdrKindsTTL = time.Minute

// miseTimeout limits the `mise which` calls of one lookup.
const miseTimeout = 3 * time.Second

// herdrKindsNow returns the agent kinds of the last lookup. When
// herdr_control is on and the lookup is older than herdrKindsTTL, it
// starts a new lookup. The lookup runs mise and can take seconds, so the
// herdr loop does not wait for it. The lookup wakes the loop when it ends.
// An agent that the user installs or removes then shows within a minute.
// Only herdr_control uses the list, so fluxd forgets it and skips the
// lookup while herdr_control is off.
func (d *Daemon) herdrKindsNow(ctx context.Context) []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := &d.herdrJobs
	if !d.herdrControlLocked() {
		j.kinds, j.kindsAt = nil, time.Time{}
		return nil
	}
	if !j.kindsBusy && time.Since(j.kindsAt) > herdrKindsTTL {
		j.kindsBusy = true
		go func() {
			kinds := d.herdrAvailableKinds(ctx)
			d.mu.Lock()
			j.kinds, j.kindsAt, j.kindsBusy = kinds, time.Now(), false
			if !d.herdrControlLocked() {
				// The user turned herdr_control off during the lookup.
				j.kinds, j.kindsAt = nil, time.Time{}
			}
			d.mu.Unlock()
			d.wakeHerdr()
		}()
	}
	return j.kinds
}

// herdrKindsDue makes the next call of herdrKindsNow start a lookup.
func (d *Daemon) herdrKindsDue() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.herdrJobs.kindsAt = time.Time{}
}

// herdrAvailableKinds returns the agent kinds of herdr that can run on
// this computer. It checks the kinds at the same time, and miseTimeout
// limits all checks together. An older herdr can lack the manifest list.
// The phone then cannot start agents, and the rest works.
func (d *Daemon) herdrAvailableKinds(ctx context.Context) []string {
	kinds, err := herdr.AgentKinds(ctx, d.herdrPath)
	if err != nil {
		d.logf("herdr: cannot list the agent kinds: %v", err)
		return nil
	}
	home, _ := os.UserHomeDir()
	ctx, cancel := context.WithTimeout(ctx, miseTimeout)
	defer cancel()
	ok := make([]bool, len(kinds))
	var wg sync.WaitGroup
	for i, k := range kinds {
		wg.Go(func() { ok[i] = agentAvailable(ctx, k, home) })
	}
	wg.Wait()
	var out []string
	for i, k := range kinds {
		if ok[i] {
			out = append(out, k)
		}
	}
	return out
}

// agentAvailable reports whether the command of an agent kind runs on
// this computer. herdr starts an agent with a command that has the name
// of its kind. The check never runs that command: a launcher of Omarchy
// installs its tool when it runs. A mise shim or a launcher that starts
// its tool with mise counts only when mise has the tool active for the
// home folder. The shell of a pane uses the same tools. ctx limits the
// mise call.
func agentAvailable(ctx context.Context, kind, home string) bool {
	path, err := exec.LookPath(kind)
	if err != nil {
		return false
	}
	if !miseLauncher(path) {
		return true
	}
	cmd := exec.CommandContext(ctx, "mise", "which", kind)
	cmd.Dir = home
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	fi, err := os.Stat(strings.TrimSpace(string(out)))
	return err == nil && !fi.IsDir()
}

// miseLauncher reports whether the command at path starts its tool
// through mise: a mise shim, which is a link to the mise program, or a
// short script that calls mise, such as the install-on-first-use
// launchers of Omarchy in ~/.local/bin.
func miseLauncher(path string) bool {
	if real, err := filepath.EvalSymlinks(path); err == nil && filepath.Base(real) == "mise" {
		return true
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 4096)
	n, _ := io.ReadFull(f, head)
	head = head[:n]
	if !bytes.HasPrefix(head, []byte("#!")) {
		return false
	}
	for _, call := range []string{"mise x ", "mise exec ", "mise use "} {
		if bytes.Contains(head, []byte(call)) {
			return true
		}
	}
	return false
}
