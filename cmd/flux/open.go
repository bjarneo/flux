package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"flux/internal/config"
)

// The Flux window has 2 front ends with the same views: the flux plugin
// inside omarchy-shell, and the flux-gui app (Qt6 C++). openWindow asks
// omarchy-shell to summon the plugin, and it starts the app when the shell
// does not run or the plugin is not enabled. FLUX_GUI=plugin or
// FLUX_GUI=app, or `gui` in config.toml, forces one of them.

const pluginID = "flux"

func openWindow(page string) error {
	switch guiChoice() {
	case "plugin":
		return summonPlugin(page)
	case "app":
		return launchApp(page)
	}
	if summonPlugin(page) == nil {
		return nil
	}
	return launchApp(page)
}

func guiChoice() string {
	if v := os.Getenv("FLUX_GUI"); v != "" {
		return v
	}
	if cfg, err := config.Load(); err == nil {
		return cfg.GUI
	}
	return ""
}

// pluginInstalled reports whether the running omarchy-shell knows the flux
// plugin.
func pluginInstalled() bool {
	if _, err := exec.LookPath("omarchy-shell"); err != nil {
		return false
	}
	out, err := exec.Command("omarchy-shell", "shell", "listPlugins").Output()
	if err != nil {
		return false
	}
	var plugins []struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(out, &plugins) != nil {
		return false
	}
	for _, p := range plugins {
		if p.ID == pluginID {
			return true
		}
	}
	return false
}

// summonPlugin opens the plugin panel. omarchy-shell answers "ok" only
// when the plugin is installed and enabled.
func summonPlugin(page string) error {
	if _, err := exec.LookPath("omarchy-shell"); err != nil {
		return err
	}
	payload, _ := json.Marshal(map[string]string{"page": page})
	out, err := exec.Command("omarchy-shell", "shell", "summon", pluginID, string(payload)).Output()
	if err != nil {
		return fmt.Errorf("omarchy-shell: %w", err)
	}
	if strings.TrimSpace(string(out)) != "ok" {
		return errors.New("the flux plugin is not enabled. Run: omarchy plugin enable flux")
	}
	return nil
}

// appPath finds flux-gui next to the flux binary, then in PATH.
func appPath() (string, error) {
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for _, p := range []string{filepath.Join(dir, "flux-gui"), filepath.Join(dir, "..", "gui", "app", "build", "flux-gui")} {
			if _, err := os.Stat(p); err == nil {
				return p, nil
			}
		}
	}
	if p, err := exec.LookPath("flux-gui"); err == nil {
		return p, nil
	}
	return "", errors.New("flux-gui is not installed, and the flux plugin is not enabled in omarchy-shell")
}

// launchApp starts flux-gui. A running flux-gui gets the page and raises
// its window, and the new process exits at once.
func launchApp(page string) error {
	bin, err := appPath()
	if err != nil {
		return err
	}
	args := []string{}
	if page != "" {
		args = append(args, page)
	}
	cmd := exec.Command(bin, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if devnull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0); err == nil {
		cmd.Stdin, cmd.Stdout, cmd.Stderr = devnull, devnull, devnull
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start flux-gui: %w", err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	// Wait a moment, so a start error such as a missing Qt library is not
	// lost. A running flux-gui makes the new process exit at once.
	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
	}
	return nil
}
