package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"flux/internal/nativemsg"
)

// The browser extension asks fluxd for a share through flux-native, which
// every browser starts as a native messaging host. This file writes the
// manifest that tells a browser where that host is, and that the Flux
// extension is the one that may start it.

// hostBinary is the file that a browser starts.
const hostBinary = "flux-native"

// extensionID is the fixed ID of the Chromium build of the extension, from
// the key in browser/extension/manifest.json. A host manifest names the
// extensions that may start it, so a fixed ID keeps another extension from
// sending to the phone. TestExtensionMatchesID keeps it in step with the
// manifest.
const extensionID = "jgfibbdalckcbmdcngbalobbhcbepamm"

// geckoID is the add-on ID of the Firefox and Zen build, from
// browser/extension/manifest.firefox.json.
const geckoID = "flux@omarchy.org"

// installedExtension is where `make install` puts the unpacked extension.
const installedExtension = "/usr/share/flux/browser-extension"

// userExtension is where `make install-user` puts it, and it must match
// USER_PREFIX in the Makefile.
var userExtension = filepath.Join(".local", "share", "flux", "browser-extension")

// hostManifest is the file that a browser reads to find a native messaging
// host. The two browsers disagree on the key that names the callers: a
// Chromium browser reads allowed_origins, which holds the origin of the
// extension, and Firefox and Zen read allowed_extensions, which holds the
// add-on ID. A browser ignores the key it does not know, so each manifest
// carries only the one its browser reads.
type hostManifest struct {
	Name              string   `json:"name"`
	Description       string   `json:"description"`
	Path              string   `json:"path"`
	Type              string   `json:"type"`
	AllowedOrigins    []string `json:"allowed_origins,omitempty"`
	AllowedExtensions []string `json:"allowed_extensions,omitempty"`
}

// chromiumBrowsers are the profile roots of the Chromium browsers that
// Flux supports, below the config directory. Each of them reads its own
// NativeMessagingHosts directory.
var chromiumBrowsers = []string{
	"chromium",
	"chromium-browser",
	"google-chrome",
	"google-chrome-beta",
	"google-chrome-unstable",
	"BraveSoftware/Brave-Browser",
	"BraveSoftware/Brave-Browser-Beta",
	"BraveSoftware/Brave-Browser-Nightly",
	"BraveSoftware/Brave-Origin-Beta",
	"microsoft-edge",
	"microsoft-edge-beta",
	"microsoft-edge-dev",
	"vivaldi",
	"opera",
}

// geckoBrowsers are Firefox and Zen, below the home directory. Each keeps
// its profiles in one folder and reads the host manifests from another.
var geckoBrowsers = []struct {
	Home  string // the folder the browser keeps
	Hosts string // the directory with the host manifests
}{
	{".mozilla/firefox", ".mozilla/native-messaging-hosts"},
	{".zen", ".zen/native-messaging-hosts"},
}

// target is one host manifest to write.
type target struct {
	path       string
	host       string
	origins    []string
	extensions []string
}

func browser(args []string) error {
	switch first(args) {
	case "install":
		return browserInstall(args[1:])
	case "remove", "uninstall":
		return browserRemove()
	}
	return errors.New("unknown browser action. Use install or remove")
}

func browserInstall(args []string) error {
	id, dry := extensionID, false
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--dry-run" || a == "-n":
			dry = true
		case a == "--id" && i+1 < len(args):
			id, i = args[i+1], i+1
		case strings.HasPrefix(a, "--id="):
			id = strings.TrimPrefix(a, "--id=")
		default:
			return fmt.Errorf("unknown option %q. Use --id EXTENSION_ID or --dry-run", a)
		}
	}
	if id == "" {
		return errors.New("the extension ID is empty")
	}
	path, err := hostPath()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	var targets []target
	var chromium, gecko bool
	for _, config := range configHomes(home) {
		for _, rel := range chromiumBrowsers {
			dir := filepath.Join(config, rel)
			if !isDir(dir) {
				continue
			}
			chromium = true
			targets = append(targets, target{
				path:    filepath.Join(dir, "NativeMessagingHosts", nativemsg.Host+".json"),
				host:    path,
				origins: []string{"chrome-extension://" + id + "/"},
			})
		}
	}
	for _, b := range geckoBrowsers {
		if !isDir(filepath.Join(home, b.Home)) {
			continue
		}
		gecko = true
		// Firefox and Zen name the caller by its add-on ID, which
		// manifest.firefox.json fixes. The UUID a profile hands the
		// add-on is not in the host manifest and is not needed: the ID
		// is the same in every profile, so the manifest is written the
		// first time, whether or not the add-on has been loaded.
		targets = append(targets, target{
			path:       filepath.Join(home, b.Hosts, nativemsg.Host+".json"),
			host:       path,
			extensions: []string{geckoID},
		})
	}
	if len(targets) == 0 {
		fmt.Println("No browser found in your home directory. Flux writes the host manifest when a browser is there.")
	}
	for _, t := range targets {
		if dry {
			fmt.Println("  would write:", t.path)
			continue
		}
		if err := writeHost(t); err != nil {
			return err
		}
		fmt.Println("  ✓", t.path)
	}
	printExtensionHelp(chromium, gecko)
	return nil
}

func browserRemove() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	var dirs []string
	for _, config := range configHomes(home) {
		for _, rel := range chromiumBrowsers {
			dirs = append(dirs, filepath.Join(config, rel, "NativeMessagingHosts"))
		}
	}
	for _, b := range geckoBrowsers {
		dirs = append(dirs, filepath.Join(home, b.Hosts))
	}
	removed := 0
	for _, dir := range dirs {
		path := filepath.Join(dir, nativemsg.Host+".json")
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		// Leave a file of another program alone, even with the same name.
		var m hostManifest
		if json.Unmarshal(body, &m) != nil || m.Name != nativemsg.Host {
			continue
		}
		if err := os.Remove(path); err != nil {
			return err
		}
		fmt.Println("  ✓ removed", path)
		removed++
	}
	if removed == 0 {
		fmt.Println("No Flux host manifest found.")
	}
	return nil
}

// writeHost writes one host manifest for a browser to read.
func writeHost(t target) error {
	body, err := json.MarshalIndent(hostManifest{
		Name:              nativemsg.Host,
		Description:       "Flux host for the Flux browser extension",
		Path:              t.host,
		Type:              "stdio",
		AllowedOrigins:    t.origins,
		AllowedExtensions: t.extensions,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(t.path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(t.path, append(body, '\n'), 0o644)
}

// printExtensionHelp prints how to load the extension, which no browser
// does on its own.
func printExtensionHelp(chromium, gecko bool) {
	fmt.Println()
	if dir, ok := extensionDir(); ok {
		fmt.Println("Load the Flux extension from", dir)
	} else {
		fmt.Println("The Flux extension is missing. Run make install, or make browser")
	}
	if chromium {
		fmt.Println("  Chromium and friends: the extensions page, then Developer mode, then Load unpacked")
	}
	if gecko {
		fmt.Println("  Firefox and Zen: about:debugging, then Load temporary add-on, then manifest.firefox.json")
	}
}

// extensionDir returns the folder to load the extension from: the copy
// `make install` wrote, then the one `make install-user` wrote, then the
// one in the checkout next to this flux.
func extensionDir() (string, bool) {
	if isFile(filepath.Join(installedExtension, "manifest.json")) {
		return installedExtension, true
	}
	if home, err := os.UserHomeDir(); err == nil {
		dir := filepath.Join(home, userExtension)
		if isFile(filepath.Join(dir, "manifest.json")) {
			return dir, true
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "", false
	}
	dir := filepath.Join(filepath.Dir(exe), "..", "browser", "extension")
	if isFile(filepath.Join(dir, "manifest.json")) {
		return filepath.Clean(dir), true
	}
	return "", false
}

// configHomes returns the directories where the browsers keep their
// profiles. A Chromium browser follows XDG_CONFIG_HOME, so Flux writes
// there as well as in the default place.
func configHomes(home string) []string {
	dirs := []string{filepath.Join(home, ".config")}
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" && xdg != dirs[0] {
		dirs = append(dirs, xdg)
	}
	return dirs
}

// hostPath returns the flux-native that the browser must start. A browser
// does not read the PATH of the session that installed Flux, so the
// manifest needs the whole path.
func hostPath() (string, error) {
	if exe, err := os.Executable(); err == nil {
		next := filepath.Join(filepath.Dir(exe), hostBinary)
		if isFile(next) {
			return next, nil
		}
	}
	home, _ := os.UserHomeDir()
	for _, dir := range []string{"/usr/bin", "/usr/lib/flux/bin", filepath.Join(home, ".local", "bin")} {
		if isFile(filepath.Join(dir, hostBinary)) {
			return filepath.Join(dir, hostBinary), nil
		}
	}
	return "", fmt.Errorf("%s is not installed. Run make build, or install Flux", hostBinary)
}

func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
