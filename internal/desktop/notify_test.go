package desktop

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func TestEscapeMarkup(t *testing.T) {
	if got := escapeMarkup(`a<b & c > d <font color="red">`); got != `a&lt;b &amp; c &gt; d &lt;font color="red"&gt;` {
		t.Errorf("escaped %q", got)
	}
	if got := escapeMarkup("Tom & Jerry <3"); got != "Tom &amp; Jerry &lt;3" {
		t.Errorf("escaped %q", got)
	}
}

func TestCutUTF8(t *testing.T) {
	if got := cutUTF8("ééé", 3); got != "é" {
		t.Errorf("cut %q", got)
	}
	if got := cutUTF8("abc", 5); got != "abc" {
		t.Errorf("short text changed to %q", got)
	}
}

// actionSignal returns an ActionInvoked signal from sender.
func actionSignal(sender string, id uint32, key string) *dbus.Signal {
	return &dbus.Signal{Sender: sender, Path: notifyPath, Name: notifyIface + ".ActionInvoked", Body: []any{id, key}}
}

// TestNotifierActionFilter checks that an action counts only when the
// notification server sends it for a key of a notification that Show
// displayed.
func TestNotifierActionFilter(t *testing.T) {
	n := &Notifier{owner: ":1.10"}
	var got []string
	n.OnAction(func(_ uint32, key string) { got = append(got, key) })
	n.mu.Lock()
	n.rememberLocked(7, []string{"open:/home/u/Downloads/a.pdf", "reveal:/home/u/Downloads/a.pdf"})
	n.mu.Unlock()

	n.handle(actionSignal(":1.99", 7, "open:/home/u/Downloads/a.pdf"))
	n.handle(actionSignal(":1.10", 7, "pair-accept:attacker"))
	n.handle(actionSignal(":1.10", 8, "open:/home/u/Downloads/a.pdf"))
	n.handle(actionSignal(":1.10", 7, "open:/home/u/Downloads/a.pdf"))
	if len(got) != 1 || got[0] != "open:/home/u/Downloads/a.pdf" {
		t.Fatalf("actions %q", got)
	}

	// A close forgets the notification.
	n.handle(&dbus.Signal{Sender: ":1.10", Path: notifyPath, Name: notifyIface + ".NotificationClosed", Body: []any{uint32(7), uint32(2)}})
	n.handle(actionSignal(":1.10", 7, "open:/home/u/Downloads/a.pdf"))
	if len(got) != 1 {
		t.Fatalf("an action of a closed notification ran: %q", got)
	}

	// A new server owner forgets the old notifications, and only the bus
	// daemon can name the owner.
	n.mu.Lock()
	n.rememberLocked(9, []string{"open:x"})
	n.mu.Unlock()
	n.handle(&dbus.Signal{Sender: ":1.99", Name: busDest + ".NameOwnerChanged", Body: []any{notifyDest, ":1.10", ":1.99"}})
	if n.owner != ":1.10" {
		t.Fatalf("a client changed the owner to %s", n.owner)
	}
	n.handle(&dbus.Signal{Sender: busDest, Name: busDest + ".NameOwnerChanged", Body: []any{notifyDest, ":1.10", ":1.20"}})
	n.handle(actionSignal(":1.20", 9, "open:x"))
	if n.owner != ":1.20" || len(got) != 1 {
		t.Fatalf("owner %s, actions %q", n.owner, got)
	}
}

// TestNotifierKeepsActionsOfActivatedServer checks that a server that the
// first Show starts keeps the actions of that notification. The signal
// that names the new owner can come after Show records the ID.
func TestNotifierKeepsActionsOfActivatedServer(t *testing.T) {
	n := &Notifier{}
	var got []string
	n.OnAction(func(_ uint32, key string) { got = append(got, key) })
	n.mu.Lock()
	n.rememberLocked(1, []string{"open:x"})
	n.mu.Unlock()
	n.handle(&dbus.Signal{Sender: busDest, Name: busDest + ".NameOwnerChanged", Body: []any{notifyDest, "", ":1.30"}})
	n.handle(actionSignal(":1.30", 1, "open:x"))
	if len(got) != 1 {
		t.Fatalf("the first notification of a new server lost its actions: %q", got)
	}

	// A server that stops takes its notifications with it.
	n.handle(&dbus.Signal{Sender: busDest, Name: busDest + ".NameOwnerChanged", Body: []any{notifyDest, ":1.30", ""}})
	n.handle(&dbus.Signal{Sender: busDest, Name: busDest + ".NameOwnerChanged", Body: []any{notifyDest, "", ":1.31"}})
	n.handle(actionSignal(":1.31", 1, "open:x"))
	if len(got) != 1 {
		t.Fatalf("an action of a stopped server ran: %q", got)
	}
}

func TestNotifierRemembersALimitedNumber(t *testing.T) {
	n := &Notifier{}
	n.mu.Lock()
	defer n.mu.Unlock()
	for id := range uint32(maxShown + 10) {
		n.rememberLocked(id, []string{"open:x"})
	}
	if len(n.shown) != maxShown || len(n.order) != maxShown {
		t.Fatalf("%d notifications, %d in order", len(n.shown), len(n.order))
	}
	if _, ok := n.shown[0]; ok {
		t.Fatal("the oldest notification stays")
	}
	// A notification without actions replaces one with actions.
	n.rememberLocked(maxShown+9, nil)
	if _, ok := n.shown[maxShown+9]; ok {
		t.Fatal("a replaced notification keeps its actions")
	}
}

// fakeServer is a notification server on a private bus.
type fakeServer struct{ bodies chan string }

func (s *fakeServer) Notify(app string, replaces uint32, icon, title, body string, actions []string, hints map[string]dbus.Variant, timeout int32) (uint32, *dbus.Error) {
	s.bodies <- body
	return 7, nil
}

func (s *fakeServer) CloseNotification(id uint32) *dbus.Error { return nil }

// privateBus starts a dbus-daemon for the test and returns its address.
func privateBus(t *testing.T) string {
	t.Helper()
	bin, err := exec.LookPath("dbus-daemon")
	if err != nil {
		t.Skip("dbus-daemon is not installed")
	}
	dir := t.TempDir()
	conf := `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=` + filepath.Join(dir, "bus") + `</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
`
	if err := os.WriteFile(filepath.Join(dir, "bus.conf"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, "--config-file="+filepath.Join(dir, "bus.conf"), "--nofork", "--print-address")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("dbus-daemon does not start: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	addr, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		t.Fatalf("dbus-daemon printed no address: %v", err)
	}
	return strings.TrimSpace(addr)
}

// TestNotifierOnPrivateBus runs the Notifier against a fake server on a
// private bus. An action that another client sends does not reach fluxd,
// and the body arrives escaped.
func TestNotifierOnPrivateBus(t *testing.T) {
	addr := privateBus(t)
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", addr)

	server, err := dbus.Connect(addr)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	fake := &fakeServer{bodies: make(chan string, 1)}
	if err := server.Export(fake, notifyPath, notifyIface); err != nil {
		t.Fatal(err)
	}
	if reply, err := server.RequestName(notifyDest, dbus.NameFlagDoNotQueue); err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		t.Fatalf("own %s: %v, %v", notifyDest, reply, err)
	}

	n, err := NewNotifier()
	if err != nil {
		t.Fatal(err)
	}
	defer n.Shutdown()
	keys := make(chan string, 4)
	n.OnAction(func(_ uint32, key string) { keys <- key })
	id, err := n.Show(Notification{Title: "Text", Body: "a<b & c", Actions: []Action{{Key: "open:/tmp/a.pdf", Label: "Open"}}})
	if err != nil || id != 7 {
		t.Fatalf("Show: %d, %v", id, err)
	}
	if body := <-fake.bodies; body != "a&lt;b &amp; c" {
		t.Errorf("the server got the body %q", body)
	}

	other, err := dbus.Connect(addr)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := other.Emit(notifyPath, notifyIface+".ActionInvoked", uint32(7), "open:/tmp/a.pdf"); err != nil {
		t.Fatal(err)
	}
	// The bus handles the messages of 1 connection in order. After this
	// answer, the signal of the other client is on its way or dropped.
	var busID string
	if err := other.BusObject().Call(busDest+".GetId", 0).Store(&busID); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"pair-accept:attacker", "open:/tmp/a.pdf"} {
		if err := server.Emit(notifyPath, notifyIface+".ActionInvoked", uint32(7), key); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case key := <-keys:
		if key != "open:/tmp/a.pdf" {
			t.Fatalf("action %q", key)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the action of the server did not arrive")
	}
	select {
	case key := <-keys:
		t.Fatalf("a second action arrived: %q", key)
	case <-time.After(200 * time.Millisecond):
	}
}
