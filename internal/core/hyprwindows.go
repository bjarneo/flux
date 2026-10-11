package core

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// The Omarchy panel lists the windows of the active workspace. fluxd reads
// them from hyprctl clients and names each app from its desktop entry, so
// that the phone shows "Ghostty" for the class com.mitchellh.ghostty.

// Window is 1 window of a normal workspace.
type Window struct {
	// Address is the Hyprland address of the window, such as 0x5f6b3fd55b00.
	Address   string `json:"address"`
	Workspace int    `json:"workspace"`
	// App is the name of the app, from its desktop entry or its class.
	App     string `json:"app"`
	Class   string `json:"class"`
	Title   string `json:"title"`
	Focused bool   `json:"focused"`
}

// windowAddress matches a Hyprland window address.
var windowAddress = regexp.MustCompile(`^0x[0-9a-f]{1,16}$`)

// maxWindowTitle is the most bytes of a window title that the phone gets.
const maxWindowTitle = 200

// parseWindows returns the mapped windows of the normal workspaces, in
// the order of the workspaces, then from the top left. name gives the app
// name of a class.
func parseWindows(data []byte, name func(string) string) ([]Window, error) {
	var all []struct {
		Address        string `json:"address"`
		Mapped         bool   `json:"mapped"`
		Hidden         bool   `json:"hidden"`
		At             [2]int `json:"at"`
		Class          string `json:"class"`
		Title          string `json:"title"`
		FocusHistoryID int    `json:"focusHistoryID"`
		Workspace      struct {
			ID int `json:"id"`
		} `json:"workspace"`
	}
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, fmt.Errorf("read the windows: %w", err)
	}
	sort.SliceStable(all, func(i, j int) bool {
		a, b := all[i], all[j]
		if a.Workspace.ID != b.Workspace.ID {
			return a.Workspace.ID < b.Workspace.ID
		}
		if a.At[1] != b.At[1] {
			return a.At[1] < b.At[1]
		}
		return a.At[0] < b.At[0]
	})
	out := []Window{}
	for _, w := range all {
		if w.Workspace.ID <= 0 || !w.Mapped || w.Hidden || !windowAddress.MatchString(w.Address) {
			continue
		}
		out = append(out, Window{
			Address:   w.Address,
			Workspace: w.Workspace.ID,
			App:       name(w.Class),
			Class:     w.Class,
			Title:     cutText(w.Title, maxWindowTitle),
			Focused:   w.FocusHistoryID == 0,
		})
	}
	return out, nil
}

// appNames maps a window class to the name of its app. It reads the
// desktop entries again after appNamesTTL, because the user can install
// an app while fluxd runs.
type appNames struct {
	mu   sync.Mutex
	read time.Time
	// byClass holds the names by the lower-case StartupWMClass, and byID
	// by the lower-case file name of the entry without .desktop.
	byClass map[string]string
	byID    map[string]string
}

const appNamesTTL = 5 * time.Minute

var desktopApps = &appNames{}

// name returns the app name of class: the Name of the desktop entry with
// that StartupWMClass or that file name, else the last part of the class
// with a capital first letter.
func (a *appNames) name(class string) string {
	if class == "" {
		return ""
	}
	a.mu.Lock()
	if a.byClass == nil || time.Since(a.read) > appNamesTTL {
		a.byClass, a.byID = readDesktopEntries(applicationDirs())
		a.read = time.Now()
	}
	key := strings.ToLower(class)
	n := a.byClass[key]
	if n == "" {
		n = a.byID[key]
	}
	a.mu.Unlock()
	if n != "" {
		return n
	}
	return className(class)
}

// className returns the last part of a class such as org.gnome.Nautilus,
// with a capital first letter.
func className(class string) string {
	if class == "" {
		return ""
	}
	last := class[strings.LastIndex(class, ".")+1:]
	if last == "" {
		last = class
	}
	return strings.ToUpper(last[:1]) + last[1:]
}

// applicationDirs returns the folders of the desktop entries, the user
// folder first, as in the XDG Base Directory specification.
func applicationDirs() []string {
	home, _ := os.UserHomeDir()
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" && home != "" {
		dataHome = filepath.Join(home, ".local", "share")
	}
	dataDirs := os.Getenv("XDG_DATA_DIRS")
	if dataDirs == "" {
		dataDirs = "/usr/local/share:/usr/share"
	}
	var out []string
	if dataHome != "" {
		out = append(out, filepath.Join(dataHome, "applications"))
	}
	for _, d := range strings.Split(dataDirs, ":") {
		if d != "" {
			out = append(out, filepath.Join(d, "applications"))
		}
	}
	return out
}

// readDesktopEntries reads the Name and the StartupWMClass of the desktop
// entries in dirs. An entry in an earlier folder wins.
func readDesktopEntries(dirs []string) (byClass, byID map[string]string) {
	byClass, byID = map[string]string{}, map[string]string{}
	for _, dir := range dirs {
		files, _ := filepath.Glob(filepath.Join(dir, "*.desktop"))
		for _, f := range files {
			name, class := readDesktopEntry(f)
			if name == "" {
				continue
			}
			id := strings.ToLower(strings.TrimSuffix(filepath.Base(f), ".desktop"))
			if _, ok := byID[id]; !ok {
				byID[id] = name
			}
			if c := strings.ToLower(class); c != "" {
				if _, ok := byClass[c]; !ok {
					byClass[c] = name
				}
			}
		}
	}
	return byClass, byID
}

// maxDesktopEntry is the most bytes of a desktop entry that fluxd reads.
const maxDesktopEntry = 64 << 10

// readDesktopEntry returns the Name and the StartupWMClass of the
// [Desktop Entry] group of the file f.
func readDesktopEntry(f string) (name, class string) {
	file, err := os.Open(f)
	if err != nil {
		return "", ""
	}
	defer file.Close()
	s := bufio.NewScanner(io.LimitReader(file, maxDesktopEntry))
	in := false
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if strings.HasPrefix(line, "[") {
			if in {
				break
			}
			in = line == "[Desktop Entry]"
			continue
		}
		if !in {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "Name":
			name = strings.TrimSpace(value)
		case "StartupWMClass":
			class = strings.TrimSpace(value)
		}
	}
	return name, class
}
