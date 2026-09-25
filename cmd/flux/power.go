package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"flux/internal/config"
)

// power turns fluxd off or on. Off writes the marker of config.OffPath
// and stops the service. The marker keeps fluxd off at the next login,
// also when the package enabled the service for all users. On removes the
// marker, and enables and starts the service.
func power(on bool) error {
	if on {
		if err := os.Remove(config.OffPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err := systemctl("enable", "--now", "fluxd.service"); err != nil {
			return err
		}
		fmt.Println("fluxd is on, and it starts at each login")
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(config.OffPath()), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(config.OffPath(), []byte("flux off\n"), 0o644); err != nil {
		return err
	}
	if err := systemctl("stop", "fluxd.service"); err != nil {
		return err
	}
	// A fluxd that runs outside systemd, for example from a checkout, still
	// holds the socket.
	time.Sleep(300 * time.Millisecond)
	if c, err := dial(); err == nil {
		c.Close()
		fmt.Println("fluxd.service is off, but a fluxd outside systemd still runs. To stop it, run: pkill -x fluxd")
		return nil
	}
	fmt.Println("fluxd is off, also after the next login. Phones cannot connect until you run: flux on")
	return nil
}

func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
	if err == nil {
		return nil
	}
	msg := strings.TrimSpace(string(out))
	if strings.Contains(msg, "not found") || strings.Contains(msg, "does not exist") {
		return errors.New("fluxd.service is not installed. Run: flux setup")
	}
	return fmt.Errorf("systemctl --user %s: %s", strings.Join(args, " "), msg)
}
