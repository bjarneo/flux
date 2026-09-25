package desktop

import (
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	notifyDest  = "org.freedesktop.Notifications"
	notifyPath  = dbus.ObjectPath("/org/freedesktop/Notifications")
	notifyIface = "org.freedesktop.Notifications"
)

// Action is one button on a desktop notification.
type Action struct{ Key, Label string }

// Notification is a desktop notification.
type Notification struct {
	AppName, Title, Body, IconPath string
	Actions                        []Action
	// Urgency is 0 for low, 1 for normal, and 2 for critical.
	Urgency byte
	// Timeout is the display time. 0 uses the server default. A negative
	// value keeps the notification until the user closes it.
	Timeout    time.Duration
	ReplacesID uint32
	Category   string
}

// Notifier shows notifications through org.freedesktop.Notifications on
// the session bus.
type Notifier struct {
	conn *dbus.Conn
	obj  dbus.BusObject

	mu       sync.Mutex
	onAction []func(id uint32, key string)
	onClosed []func(id uint32)
	signals  chan *dbus.Signal
}

// NewNotifier connects to the session bus and listens for the action and
// close signals of the notification server.
func NewNotifier() (*Notifier, error) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil, err
	}
	n := &Notifier{conn: conn, obj: conn.Object(notifyDest, notifyPath), signals: make(chan *dbus.Signal, 32)}
	for _, member := range []string{"ActionInvoked", "NotificationClosed"} {
		if err := conn.AddMatchSignal(
			dbus.WithMatchObjectPath(notifyPath),
			dbus.WithMatchInterface(notifyIface),
			dbus.WithMatchMember(member),
		); err != nil {
			conn.Close()
			return nil, err
		}
	}
	conn.Signal(n.signals)
	go n.dispatch()
	return n, nil
}

func (n *Notifier) dispatch() {
	for sig := range n.signals {
		switch sig.Name {
		case notifyIface + ".ActionInvoked":
			if len(sig.Body) < 2 {
				continue
			}
			id, _ := sig.Body[0].(uint32)
			key, _ := sig.Body[1].(string)
			n.mu.Lock()
			fns := append([]func(uint32, string){}, n.onAction...)
			n.mu.Unlock()
			for _, fn := range fns {
				fn(id, key)
			}
		case notifyIface + ".NotificationClosed":
			if len(sig.Body) < 1 {
				continue
			}
			id, _ := sig.Body[0].(uint32)
			n.mu.Lock()
			fns := append([]func(uint32){}, n.onClosed...)
			n.mu.Unlock()
			for _, fn := range fns {
				fn(id)
			}
		}
	}
}

// Show displays a notification and returns its server ID.
func (n *Notifier) Show(note Notification) (uint32, error) {
	actions := make([]string, 0, 2*len(note.Actions))
	for _, a := range note.Actions {
		actions = append(actions, a.Key, a.Label)
	}
	hints := map[string]dbus.Variant{"urgency": dbus.MakeVariant(note.Urgency)}
	if note.Category != "" {
		hints["category"] = dbus.MakeVariant(note.Category)
	}
	icon := note.IconPath
	if icon != "" && strings.HasPrefix(icon, "/") {
		hints["image-path"] = dbus.MakeVariant("file://" + icon)
	}
	timeout := int32(-1)
	switch {
	case note.Timeout < 0:
		timeout = 0
	case note.Timeout > 0:
		timeout = int32(note.Timeout / time.Millisecond)
	}
	var id uint32
	err := n.obj.Call(notifyIface+".Notify", 0,
		note.AppName, note.ReplacesID, icon, note.Title, note.Body,
		actions, hints, timeout,
	).Store(&id)
	return id, err
}

// Close removes a notification from the screen.
func (n *Notifier) Close(id uint32) error {
	return n.obj.Call(notifyIface+".CloseNotification", 0, id).Err
}

// OnAction adds a function that runs when the user clicks an action.
func (n *Notifier) OnAction(fn func(id uint32, key string)) {
	n.mu.Lock()
	n.onAction = append(n.onAction, fn)
	n.mu.Unlock()
}

// OnClosed adds a function that runs when a notification closes.
func (n *Notifier) OnClosed(fn func(id uint32)) {
	n.mu.Lock()
	n.onClosed = append(n.onClosed, fn)
	n.mu.Unlock()
}

// Shutdown closes the bus connection.
func (n *Notifier) Shutdown() {
	n.conn.RemoveSignal(n.signals)
	n.conn.Close()
	close(n.signals)
}
