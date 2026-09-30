package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// notify sends a notification to the phone. With --run, it runs a command
// first, sends how the command ended, and exits with its exit code.
func notify(device string, args []string) error {
	if len(args) > 0 && args[0] == "--run" {
		cmd, show := args[1:], false
		if len(cmd) > 0 && cmd[0] == "--show-command" {
			cmd, show = cmd[1:], true
		}
		if len(cmd) > 0 && cmd[0] == "--" {
			cmd = cmd[1:]
		}
		if len(cmd) == 0 {
			fail("Usage: flux-cli notify --run [--show-command] -- CMD [ARGS...]")
		}
		start := time.Now()
		runErr := runForeground(cmd)
		code, title, body := commandResult(cmd, show, runErr, time.Since(start))
		if err := call("notify.send", map[string]any{"device": device, "title": title, "body": body}); err != nil {
			fmt.Fprintln(os.Stderr, "flux-cli:", err)
		}
		os.Exit(code)
	}
	if len(args) == 0 {
		fail("Usage: flux-cli notify [--device NAME] TITLE [BODY]")
	}
	return call("notify.send", map[string]any{"device": device, "title": args[0], "body": strings.Join(args[1:], " ")})
}

// runForeground runs a command with the terminal of flux. Ctrl+C stops the
// command, and flux stays to send the result.
func runForeground(args []string) error {
	c := exec.Command(args[0], args[1:]...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)
	if err := c.Start(); err != nil {
		return err
	}
	go func() {
		// The terminal sends Ctrl+C to the command too. SIGTERM goes on to it.
		for s := range sig {
			if s == syscall.SIGTERM && c.Process != nil {
				_ = c.Process.Signal(s)
			}
		}
	}()
	return c.Wait()
}

// maxShown is the longest command line that --show-command sends.
const maxShown = 200

// commandResult returns the exit code, the title, and the body of the
// notification for a command that ran for took. The phone can show the
// body on its lock screen, so the body has only the program name. The
// arguments can hold a password or a token. With show, the body has the
// command line, at most maxShown bytes of it.
func commandResult(args []string, show bool, err error, took time.Duration) (code int, title, body string) {
	name := filepath.Base(args[0])
	what := name
	if show {
		what = strings.Join(args, " ")
		if len(what) > maxShown {
			what = strings.ToValidUTF8(what[:maxShown], "") + "…"
		}
	}
	body = what + " · " + duration(took)
	var exit *exec.ExitError
	switch {
	case err == nil:
		return 0, name + " finished", body
	case errors.As(err, &exit):
		if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal()), fmt.Sprintf("%s stopped (%s)", name, ws.Signal()), body
		}
		code = exit.ExitCode()
		return code, fmt.Sprintf("%s failed (exit %d)", name, code), body
	case errors.Is(err, exec.ErrNotFound):
		return 127, name + " failed (not found)", what
	default:
		return 126, name + " failed (" + err.Error() + ")", what
	}
}

// duration formats a run time, for example 42s, 1m 12s, or 2h 3m.
func duration(d time.Duration) string {
	s := int(d.Round(time.Second).Seconds())
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm %ds", s/60, s%60)
	default:
		return fmt.Sprintf("%dh %dm", s/3600, (s%3600)/60)
	}
}
