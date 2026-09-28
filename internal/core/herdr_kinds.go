package core

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"flux/internal/herdr"
)

// herdrKindsTTL is how long fluxd keeps the list of available agents.
const herdrKindsTTL = time.Minute

// miseTimeout limits one `mise which` call.
const miseTimeout = 3 * time.Second

// herdrAvailableKinds returns the agent kinds of herdr that can run on
// this computer. An older herdr can lack the manifest list. The phone
// then cannot start agents, and the rest works.
func (d *Daemon) herdrAvailableKinds(ctx context.Context) []string {
	kinds, err := herdr.AgentKinds(ctx, d.herdrPath)
	if err != nil {
		d.logf("herdr: cannot list the agent kinds: %v", err)
		return nil
	}
	home, _ := os.UserHomeDir()
	var out []string
	for _, k := range kinds {
		if agentAvailable(ctx, k, home) {
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
// home folder. The shell of a pane uses the same tools.
func agentAvailable(ctx context.Context, kind, home string) bool {
	path, err := exec.LookPath(kind)
	if err != nil {
		return false
	}
	if !miseLauncher(path) {
		return true
	}
	ctx, cancel := context.WithTimeout(ctx, miseTimeout)
	defer cancel()
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
