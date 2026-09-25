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
		cmd := args[1:]
		if len(cmd) > 0 && cmd[0] == "--" {
			cmd = cmd[1:]
		}
		if len(cmd) == 0 {
			fail("Usage: flux notify --run -- CMD [ARGS...]")
		}
		start := time.Now()
		runErr := runForeground(cmd)
		code, title, body := commandResult(cmd, runErr, time.Since(start))
		if err := call("notify.send", map[string]any{"device": device, "title": title, "body": body}); err != nil {
			fmt.Fprintln(os.Stderr, "flux:", err)
		}
		os.Exit(code)
	}
	if len(args) == 0 {
		fail("Usage: flux notify [--device NAME] TITLE [BODY]")
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

// commandResult returns the exit code, the title, and the body of the
// notification for a command that ran for took.
func commandResult(args []string, err error, took time.Duration) (code int, title, body string) {
	name := filepath.Base(args[0])
	body = strings.Join(args, " ") + " · " + duration(took)
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
		return 127, name + " failed (not found)", strings.Join(args, " ")
	default:
		return 126, name + " failed (" + err.Error() + ")", strings.Join(args, " ")
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
