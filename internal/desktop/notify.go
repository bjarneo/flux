package desktop

import (
	"context"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/godbus/dbus/v5"
)

const (
	notifyDest  = "org.freedesktop.Notifications"
	notifyPath  = dbus.ObjectPath("/org/freedesktop/Notifications")
	notifyIface = "org.freedesktop.Notifications"

	// busDest is the name of the bus daemon. Only the bus daemon sends
	// NameOwnerChanged.
	busDest = "org.freedesktop.DBus"
	busPath = dbus.ObjectPath("/org/freedesktop/DBus")
)

// busTimeout limits each call to a service on the session bus. A service
// that hangs, such as a stopped media player, then cannot stop fluxd.
const busTimeout = 2 * time.Second

// maxTitle and maxBody are the most bytes of a title and a body that Show
// sends to the notification server. Text from a device, such as a ping
// message, cannot then make the server lay out megabytes of text.
const (
	maxTitle = 1 << 10
	maxBody  = 8 << 10
)

// maxShown is the number of notifications with actions that the Notifier
// remembers. A server that sends no NotificationClosed cannot grow the
// list without a limit.
const maxShown = 256

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

	// owner is the unique bus name of the notification server, or "" when
	// no server runs. Only its signals count. shown holds the action keys
	// of each notification with actions that Show displayed. order holds
	// the same IDs, the oldest first.
	owner string
	shown map[uint32][]string
	order []uint32
}

// NewNotifier connects to the session bus and listens for the action and
// close signals of the notification server.
func NewNotifier() (*Notifier, error) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil, err
	}
	n := &Notifier{conn: conn, obj: conn.Object(notifyDest, notifyPath), signals: make(chan *dbus.Signal, 32), shown: map[uint32][]string{}}
	// The bus sends these signals to fluxd only when the sender owns
	// org.freedesktop.Notifications. Another client on the bus cannot
	// send an action to fluxd.
	rules := [][]dbus.MatchOption{
		{dbus.WithMatchSender(notifyDest), dbus.WithMatchObjectPath(notifyPath), dbus.WithMatchInterface(notifyIface), dbus.WithMatchMember("ActionInvoked")},
		{dbus.WithMatchSender(notifyDest), dbus.WithMatchObjectPath(notifyPath), dbus.WithMatchInterface(notifyIface), dbus.WithMatchMember("NotificationClosed")},
		{dbus.WithMatchSender(busDest), dbus.WithMatchObjectPath(busPath), dbus.WithMatchInterface(busDest), dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, notifyDest)},
	}
	for _, rule := range rules {
		if err := conn.AddMatchSignal(rule...); err != nil {
			conn.Close()
			return nil, err
		}
	}
	conn.Signal(n.signals)
	// The owner stays empty while no server runs. A server that starts
	// later sends NameOwnerChanged. dispatch starts after this read, so the
	// owner from a later signal replaces this one.
	n.owner = n.nameOwner()
	go n.dispatch()
	return n, nil
}

// nameOwner returns the unique bus name of the notification server, or ""
// when no server runs.
func (n *Notifier) nameOwner() string {
	ctx, cancel := context.WithTimeout(context.Background(), busTimeout)
	defer cancel()
	var owner string
	if err := n.conn.BusObject().CallWithContext(ctx, busDest+".GetNameOwner", 0, notifyDest).Store(&owner); err != nil {
		return ""
	}
	return owner
}

func (n *Notifier) dispatch() {
	for sig := range n.signals {
		n.handle(sig)
	}
}

// handle runs the functions for 1 signal. It takes an action or a close
// only from the current notification server. It takes an action only for
// a key of a notification that Show displayed with that key.
func (n *Notifier) handle(sig *dbus.Signal) {
	switch sig.Name {
	case busDest + ".NameOwnerChanged":
		if sig.Sender != busDest || len(sig.Body) < 3 {
			return
		}
		name, _ := sig.Body[0].(string)
		old, _ := sig.Body[1].(string)
		owner, _ := sig.Body[2].(string)
		if name != notifyDest {
			return
		}
		n.mu.Lock()
		n.owner = owner
		// A new server does not know the notifications of the old one. When
		// no server ran before, the first Show can start one with D-Bus
		// activation, and the IDs that Show records are from the new server.
		if old != "" {
			clear(n.shown)
			n.order = nil
		}
		n.mu.Unlock()
	case notifyIface + ".ActionInvoked":
		if sig.Path != notifyPath || len(sig.Body) < 2 {
			return
		}
		id, _ := sig.Body[0].(uint32)
		key, _ := sig.Body[1].(string)
		n.mu.Lock()
		ok := n.fromServerLocked(sig) && slices.Contains(n.shown[id], key)
		fns := append([]func(uint32, string){}, n.onAction...)
		n.mu.Unlock()
		if !ok {
			return
		}
		for _, fn := range fns {
			fn(id, key)
		}
	case notifyIface + ".NotificationClosed":
		if sig.Path != notifyPath || len(sig.Body) < 1 {
			return
		}
		id, _ := sig.Body[0].(uint32)
		n.mu.Lock()
		ok := n.fromServerLocked(sig)
		if ok {
			n.forgetLocked(id)
		}
		fns := append([]func(uint32){}, n.onClosed...)
		n.mu.Unlock()
		if !ok {
			return
		}
		for _, fn := range fns {
			fn(id)
		}
	}
}

// fromServerLocked reports whether the notification server sent sig.
func (n *Notifier) fromServerLocked(sig *dbus.Signal) bool {
	return n.owner != "" && sig.Sender == n.owner
}

// rememberLocked records the action keys of the notification id. A
// notification without actions removes the keys of the same ID.
func (n *Notifier) rememberLocked(id uint32, keys []string) {
	if len(keys) == 0 {
		n.forgetLocked(id)
		return
	}
	if n.shown == nil {
		n.shown = map[uint32][]string{}
	}
	if _, ok := n.shown[id]; !ok {
		n.order = append(n.order, id)
	}
	n.shown[id] = keys
	for len(n.order) > maxShown {
		delete(n.shown, n.order[0])
		n.order = n.order[1:]
	}
}

// forgetLocked removes the action keys of the notification id.
func (n *Notifier) forgetLocked(id uint32) {
	if _, ok := n.shown[id]; !ok {
		return
	}
	delete(n.shown, id)
	n.order = slices.DeleteFunc(n.order, func(o uint32) bool { return o == id })
}

// markupEscaper escapes the characters that the body markup of the
// notification specification uses.
var markupEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")

// escapeMarkup returns the body as text that the notification server
// shows as it is. The Omarchy shell and mako read the body as markup.
// Without the escape, text such as "a<b" loses characters, and a tag from
// a phone changes the look of the notification.
func escapeMarkup(body string) string { return markupEscaper.Replace(body) }

// cutUTF8 returns at most the first max bytes of s. It cuts at the start
// of a UTF-8 character.
func cutUTF8(s string, max int) string {
	if len(s) <= max {
		return s
	}
	n := max
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// Show displays a notification and returns its server ID. The body is
// plain text.
func (n *Notifier) Show(note Notification) (uint32, error) {
	actions := make([]string, 0, 2*len(note.Actions))
	keys := make([]string, 0, len(note.Actions))
	for _, a := range note.Actions {
		actions = append(actions, a.Key, a.Label)
		keys = append(keys, a.Key)
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
	ctx, cancel := context.WithTimeout(context.Background(), busTimeout)
	defer cancel()
	var id uint32
	err := n.obj.CallWithContext(ctx, notifyIface+".Notify", 0,
		note.AppName, note.ReplacesID, icon, cutUTF8(note.Title, maxTitle), escapeMarkup(cutUTF8(note.Body, maxBody)),
		actions, hints, timeout,
	).Store(&id)
	if err == nil {
		n.mu.Lock()
		n.rememberLocked(id, keys)
		n.mu.Unlock()
	}
	return id, err
}

// Close removes a notification from the screen.
func (n *Notifier) Close(id uint32) error {
	ctx, cancel := context.WithTimeout(context.Background(), busTimeout)
	defer cancel()
	return n.obj.CallWithContext(ctx, notifyIface+".CloseNotification", 0, id).Err
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
