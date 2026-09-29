// Package plugin copies the flux plugin of omarchy-shell into the plugin
// folder of the user. `flux-cli setup` adds the plugin, and fluxd keeps
// an added plugin at the version of its own install.
package plugin

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"flux/internal/config"
)

// SystemDir is the plugin of the package or of `sudo make install`.
const SystemDir = "/usr/share/flux/omarchy-plugin"

// UserDir returns the plugin folder that omarchy-shell loads.
func UserDir() string {
	return filepath.Join(config.ConfigDir(), "..", "omarchy", "plugins", "flux")
}

// Installed returns the plugin that was installed with the binary exe:
// PREFIX/share/flux/omarchy-plugin for PREFIX/bin/exe. It returns ""
// when that folder has no plugin.
func Installed(exe string) string {
	dir := filepath.Join(filepath.Dir(exe), "..", "share", "flux", "omarchy-plugin")
	if _, err := os.Stat(filepath.Join(dir, "manifest.json")); err != nil {
		return ""
	}
	return filepath.Clean(dir)
}

// Source returns the plugin for the binary exe: the plugin installed with
// it, the system plugin, or the checkout of exe. From a checkout, views
// is the folder of the shared views, else it is "".
func Source(exe string) (plugin, views string, err error) {
	if dir := Installed(exe); dir != "" {
		return dir, "", nil
	}
	if _, err := os.Stat(filepath.Join(SystemDir, "manifest.json")); err == nil {
		return SystemDir, "", nil
	}
	root := filepath.Join(filepath.Dir(exe), "..")
	if _, err := os.Stat(filepath.Join(root, "gui", "omarchy", "manifest.json")); err != nil {
		return "", "", errors.New("the plugin files are missing. Install Flux, or run flux from its checkout")
	}
	return filepath.Join(root, "gui", "omarchy"), filepath.Join(root, "gui", "qml"), nil
}

// Files lists the plugin files as `omarchy plugin validate` wants them:
// real files, no symlinks, and no tools folder. The map goes from the path
// in the plugin to the source file. From a checkout, the shared views in
// views go into Flux/. An installed plugin already has Flux/ as real
// files.
func Files(src, views string) (map[string]string, error) {
	files := map[string]string{}
	tools := func(rel string) bool { return rel == "tools" || strings.HasPrefix(rel, "tools/") }
	err := walk(src, func(rel string) bool {
		// From a checkout, Flux is a symlink to ../qml. The views below
		// replace it.
		return tools(rel) || (views != "" && (rel == "Flux" || strings.HasPrefix(rel, "Flux/")))
	}, func(rel, path string) { files[rel] = path })
	if err != nil || views == "" {
		return files, err
	}
	err = walk(views, func(rel string) bool {
		return tools(rel) || strings.HasSuffix(rel, ".md") || strings.HasPrefix(filepath.Base(rel), ".")
	}, func(rel, path string) { files[filepath.Join("Flux", rel)] = path })
	return files, err
}

func walk(root string, skip func(rel string) bool, add func(rel, path string)) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if rel == "." {
			return nil
		}
		if skip(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() {
			add(rel, path)
		}
		return nil
	})
}

// Sync makes dest hold the files and nothing else. It writes only the
// files that differ, and it removes the files of an earlier version. The
// folder stays in place, so omarchy-shell reloads the plugin and keeps it
// enabled. Sync reports whether it changed a file.
func Sync(files map[string]string, dest string) (bool, error) {
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return false, err
	}
	rels := make([]string, 0, len(files))
	for rel := range files {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	changed := false
	for _, rel := range rels {
		data, err := os.ReadFile(files[rel])
		if err != nil {
			return changed, err
		}
		target := filepath.Join(dest, rel)
		if old, err := os.ReadFile(target); err == nil && bytes.Equal(old, data) {
			continue
		}
		if err := writeFile(target, data); err != nil {
			return changed, err
		}
		changed = true
	}

	var stale, dirs []string
	err := filepath.WalkDir(dest, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dest, path)
		switch {
		case rel == ".":
		case d.IsDir():
			dirs = append(dirs, path)
		default:
			if _, ok := files[rel]; !ok {
				stale = append(stale, path)
			}
		}
		return nil
	})
	if err != nil {
		return changed, err
	}
	for _, path := range stale {
		if err := os.Remove(path); err != nil {
			return changed, err
		}
		changed = true
	}
	// Remove the folders that are empty now, the deepest first.
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, dir := range dirs {
		_ = os.Remove(dir)
	}
	return changed, nil
}

// writeFile replaces path in 1 step, so that omarchy-shell never reads a
// part of a file.
func writeFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(dir, "."+filepath.Base(path)+".tmp")
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
