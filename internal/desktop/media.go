package desktop

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/godbus/dbus/v5"
)

const (
	mprisPrefix      = "org.mpris.MediaPlayer2."
	mprisPath        = dbus.ObjectPath("/org/mpris/MediaPlayer2")
	mprisRootIface   = "org.mpris.MediaPlayer2"
	mprisPlayerIface = "org.mpris.MediaPlayer2.Player"
	propsIface       = "org.freedesktop.DBus.Properties"
)

// Player is the state of one MPRIS media player on the desktop.
type Player struct {
	// Name is the short name that the phone shows, such as "spotify".
	Name string
	// Bus is the full D-Bus name of the player.
	Bus string
	// Identity is the name that the player gives itself, if any.
	Identity                     string
	Title, Artist, Album, ArtURL string
	Playing                      bool
	// Position and Length are in milliseconds.
	Position, Length int64
	// Volume is 0 to 100.
	Volume                                               int
	CanPlay, CanPause, CanGoNext, CanGoPrevious, CanSeek bool
}

// Media controls the MPRIS media players on the session bus.
type Media struct {
	conn    *dbus.Conn
	signals chan *dbus.Signal

	mu       sync.Mutex
	byName   map[string]string // short name to bus name
	byOwner  map[string]string // unique owner name to short name
	onChange []func(name string)
}

var instanceSuffix = regexp.MustCompile(`\.instance[\w.]*$`)

// shortName removes the MPRIS prefix and the instance suffix from a bus
// name. "org.mpris.MediaPlayer2.firefox.instance_1_42" becomes "firefox".
func shortName(bus string) string {
	name := strings.TrimPrefix(bus, mprisPrefix)
	name = instanceSuffix.ReplaceAllString(name, "")
	if name == "" {
		name = "player"
	}
	return name
}

// shortNames gives each bus name a unique short name. Bus names are
// sorted, so the result is the same for the same set of players. A second
// player with the same short name gets " 2", the third gets " 3".
func shortNames(buses []string) map[string]string {
	sorted := append([]string(nil), buses...)
	sort.Strings(sorted)
	out := make(map[string]string, len(sorted))
	used := map[string]int{}
	for _, bus := range sorted {
		base := shortName(bus)
		used[base]++
		name := base
		if n := used[base]; n > 1 {
			name = fmt.Sprintf("%s %d", base, n)
		}
		out[name] = bus
	}
	return out
}

// NewMedia connects to the session bus and tracks the MPRIS players.
func NewMedia() (*Media, error) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil, err
	}
	m := &Media{conn: conn, signals: make(chan *dbus.Signal, 64)}
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(mprisPath),
		dbus.WithMatchInterface(propsIface),
		dbus.WithMatchMember("PropertiesChanged"),
	); err != nil {
		conn.Close()
		return nil, err
	}
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath("/org/freedesktop/DBus"),
		dbus.WithMatchInterface("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg0Namespace("org.mpris.MediaPlayer2"),
	); err != nil {
		conn.Close()
		return nil, err
	}
	conn.Signal(m.signals)
	m.refresh()
	go m.dispatch()
	return m, nil
}

// refresh reads the list of players from the bus.
func (m *Media) refresh() {
	var names []string
	if err := m.conn.BusObject().Call("org.freedesktop.DBus.ListNames", 0).Store(&names); err != nil {
		return
	}
	var buses []string
	for _, n := range names {
		if strings.HasPrefix(n, mprisPrefix) {
			buses = append(buses, n)
		}
	}
	byName := shortNames(buses)
	byOwner := make(map[string]string, len(byName))
	for name, bus := range byName {
		var owner string
		if err := m.conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, bus).Store(&owner); err == nil {
			byOwner[owner] = name
		}
	}
	m.mu.Lock()
	m.byName, m.byOwner = byName, byOwner
	m.mu.Unlock()
}

func (m *Media) dispatch() {
	for sig := range m.signals {
		var name string
		switch sig.Name {
		case "org.freedesktop.DBus.NameOwnerChanged":
			m.refresh()
			name = ""
		case propsIface + ".PropertiesChanged":
			m.mu.Lock()
			n, ok := m.byOwner[sig.Sender]
			m.mu.Unlock()
			if !ok {
				continue
			}
			name = n
		default:
			continue
		}
		m.mu.Lock()
		fns := append([]func(string){}, m.onChange...)
		m.mu.Unlock()
		for _, fn := range fns {
			fn(name)
		}
	}
}

// Players returns the state of every player, sorted by name.
func (m *Media) Players() []Player {
	m.mu.Lock()
	names := make([]string, 0, len(m.byName))
	for name := range m.byName {
		names = append(names, name)
	}
	m.mu.Unlock()
	sort.Strings(names)
	out := make([]Player, 0, len(names))
	for _, name := range names {
		if p, ok := m.Player(name); ok {
			out = append(out, p)
		}
	}
	return out
}

// Player returns the state of the player with the short name.
func (m *Media) Player(name string) (Player, bool) {
	bus, ok := m.bus(name)
	if !ok {
		return Player{}, false
	}
	obj := m.conn.Object(bus, mprisPath)
	var props map[string]dbus.Variant
	if err := obj.Call(propsIface+".GetAll", 0, mprisPlayerIface).Store(&props); err != nil {
		return Player{}, false
	}
	p := Player{Name: name, Bus: bus}
	if v, err := obj.GetProperty(mprisRootIface + ".Identity"); err == nil {
		p.Identity, _ = v.Value().(string)
	}
	p.Playing = str(props["PlaybackStatus"]) == "Playing"
	p.Position = toInt64(props["Position"]) / 1000
	if v, ok := props["Volume"]; ok {
		if f, ok := v.Value().(float64); ok {
			p.Volume = int(f*100 + 0.5)
		}
	}
	p.CanPlay = boolean(props["CanPlay"])
	p.CanPause = boolean(props["CanPause"])
	p.CanGoNext = boolean(props["CanGoNext"])
	p.CanGoPrevious = boolean(props["CanGoPrevious"])
	p.CanSeek = boolean(props["CanSeek"])
	if v, ok := props["Metadata"]; ok {
		meta, _ := v.Value().(map[string]dbus.Variant)
		p.Title = str(meta["xesam:title"])
		p.Album = str(meta["xesam:album"])
		p.ArtURL = str(meta["mpris:artUrl"])
		p.Length = toInt64(meta["mpris:length"]) / 1000
		if artists, ok := meta["xesam:artist"].Value().([]string); ok {
			p.Artist = strings.Join(artists, ", ")
		} else {
			p.Artist = str(meta["xesam:artist"])
		}
	}
	return p, true
}

var validActions = map[string]bool{"PlayPause": true, "Play": true, "Pause": true, "Next": true, "Previous": true, "Stop": true}

// Action calls a player method. The action is PlayPause, Play, Pause,
// Next, Previous, or Stop.
func (m *Media) Action(name, action string) error {
	if !validActions[action] {
		return fmt.Errorf("unknown media action %q", action)
	}
	obj, err := m.object(name)
	if err != nil {
		return err
	}
	return obj.Call(mprisPlayerIface+"."+action, 0).Err
}

// Seek moves the position by offsetUs microseconds.
func (m *Media) Seek(name string, offsetUs int64) error {
	obj, err := m.object(name)
	if err != nil {
		return err
	}
	return obj.Call(mprisPlayerIface+".Seek", 0, offsetUs).Err
}

// SetPosition moves the position of the current track to ms milliseconds.
func (m *Media) SetPosition(name string, ms int64) error {
	obj, err := m.object(name)
	if err != nil {
		return err
	}
	v, err := obj.GetProperty(mprisPlayerIface + ".Metadata")
	if err != nil {
		return err
	}
	meta, _ := v.Value().(map[string]dbus.Variant)
	var track dbus.ObjectPath
	switch id := meta["mpris:trackid"].Value().(type) {
	case dbus.ObjectPath:
		track = id
	case string:
		track = dbus.ObjectPath(id)
	}
	if !track.IsValid() {
		return errors.New("player has no track ID")
	}
	return obj.Call(mprisPlayerIface+".SetPosition", 0, track, ms*1000).Err
}

// SetVolume sets the volume from 0 to 100.
func (m *Media) SetVolume(name string, volume int) error {
	obj, err := m.object(name)
	if err != nil {
		return err
	}
	volume = max(0, min(100, volume))
	return obj.SetProperty(mprisPlayerIface+".Volume", dbus.MakeVariant(float64(volume)/100))
}

// OnChange adds a function that runs when a player changes. The name is
// empty when a player starts or stops.
func (m *Media) OnChange(fn func(name string)) {
	m.mu.Lock()
	m.onChange = append(m.onChange, fn)
	m.mu.Unlock()
}

// Shutdown closes the bus connection.
func (m *Media) Shutdown() {
	m.conn.RemoveSignal(m.signals)
	m.conn.Close()
	close(m.signals)
}

func (m *Media) bus(name string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	bus, ok := m.byName[name]
	return bus, ok
}

func (m *Media) object(name string) (dbus.BusObject, error) {
	bus, ok := m.bus(name)
	if !ok {
		return nil, fmt.Errorf("no media player %q", name)
	}
	return m.conn.Object(bus, mprisPath), nil
}

func str(v dbus.Variant) string {
	s, _ := v.Value().(string)
	return s
}

func boolean(v dbus.Variant) bool {
	b, _ := v.Value().(bool)
	return b
}

func toInt64(v dbus.Variant) int64 {
	switch n := v.Value().(type) {
	case int64:
		return n
	case uint64:
		return int64(n)
	case int32:
		return int64(n)
	case uint32:
		return int64(n)
	case float64:
		return int64(n)
	}
	return 0
}
