package core

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// noteServer is a notification server on a private bus. It records the
// notifications that it shows and the IDs that it closes.
type noteServer struct {
	mu     sync.Mutex
	next   uint32
	shown  map[uint32][]string
	closed []uint32
}

func (s *noteServer) Notify(app string, replaces uint32, icon, title, body string, actions []string, hints map[string]dbus.Variant, timeout int32) (uint32, *dbus.Error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	id := replaces
	if id == 0 {
		s.next++
		id = s.next
	}
	s.shown[id] = actions
	return id, nil
}

func (s *noteServer) CloseNotification(id uint32) *dbus.Error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = append(s.closed, id)
	return nil
}

// actionsOf returns the action keys and labels of the notification id.
func (s *noteServer) actionsOf(id uint32) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.shown[id]
}

func (s *noteServer) isClosed(id uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Contains(s.closed, id)
}

// withNotifier gives the daemon a Notifier that talks to a notification
// server on a private bus. The test skips when dbus-daemon is missing.
func withNotifier(t *testing.T, d *Daemon) *noteServer {
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
	addr = strings.TrimSpace(addr)
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", addr)

	conn, err := dbus.Connect(addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	srv := &noteServer{shown: map[uint32][]string{}}
	if err := conn.Export(srv, "/org/freedesktop/Notifications", "org.freedesktop.Notifications"); err != nil {
		t.Fatal(err)
	}
	if reply, err := conn.RequestName("org.freedesktop.Notifications", dbus.NameFlagDoNotQueue); err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		t.Fatalf("own the notification name: %v, %v", reply, err)
	}
	n, err := desktop.NewNotifier()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(n.Shutdown)
	// The link handlers read d.notifier without the lock. The write under
	// d.mu comes before each link, because onLink takes d.mu.
	d.mu.Lock()
	d.notifier = n
	d.mu.Unlock()
	return srv
}

// notePair is phonePair with a Notifier that the daemon has before the
// phone links. It returns the daemon, the notification server, the device
// on the daemon, the link on the phone, and the packets that the phone
// receives.
func notePair(t *testing.T, ctx context.Context) (*Daemon, *noteServer, *Device, *lan.Link, chan *proto.Packet) {
	t.Helper()
	d, _ := pairDaemon(t, ctx)
	srv := withNotifier(t, d)
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	onPhone := newTestPeer(t, ctx, cert).dial(t, ctx, d, d.lan.TCPPort())
	fromDesk := packets(onPhone)
	dev, _ := linked(t, d, id)
	return d, srv, dev, onPhone, fromDesk
}

// TestPairNotification checks the notification of a pair request. Its
// buttons name the key of the request, so a click without the key or with
// another key does nothing. A reject closes the notification, and the
// device waits before a new request counts.
func TestPairNotification(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, srv, dev, onPhone, fromDesk := notePair(t, ctx)

	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the notification", func() bool { return field(d, func() uint32 { return dev.pairNote }) != 0 })
	note := field(d, func() uint32 { return dev.pairNote })
	key := field(d, func() string { return dev.pairKey })
	want := []string{"pair-accept:" + dev.ID + ":" + key, "Accept", "pair-reject:" + dev.ID + ":" + key, "Reject"}
	if got := srv.actionsOf(note); !slices.Equal(got, want) {
		t.Fatalf("actions %q, want %q", got, want)
	}

	d.onNotificationAction(note, "pair-accept:"+dev.ID)
	d.onNotificationAction(note, "pair-reject:"+dev.ID+":0000000000000000")
	if field(d, func() string { return dev.pairState }) != "incoming" {
		t.Fatal("a click without the key of the request counted")
	}
	d.onNotificationAction(note, "pair-reject:"+dev.ID+":"+key)
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("after the reject %v", body)
	}
	waitFor(t, "the close of the notification", func() bool { return srv.isClosed(note) })

	// A new request waits for pairRetry. Then the Accept button of its
	// notification pairs the device and closes the notification.
	d.mu.Lock()
	dev.pairAt, dev.pairEnded = time.Time{}, time.Time{}
	d.mu.Unlock()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix() + 1})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the second notification", func() bool { return field(d, func() uint32 { return dev.pairNote }) != 0 })
	note = field(d, func() uint32 { return dev.pairNote })
	d.onNotificationAction(note, "pair-accept:"+dev.ID+":"+field(d, func() string { return dev.pairKey }))
	if body := nextPair(t, fromDesk); body["pair"] != true {
		t.Fatalf("after the accept %v", body)
	}
	waitFor(t, "the close of the second notification", func() bool { return srv.isClosed(note) })
	if !field(d, func() bool { return dev.Paired }) {
		t.Fatal("the Accept button did not pair the device")
	}
}

// TestConfirmNotification checks the notification of a pairing in state
// "confirm": its Confirm button pins the phone.
func TestConfirmNotification(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, srv, dev, onPhone, fromDesk := notePair(t, ctx)
	key := confirmState(t, d, dev, onPhone, fromDesk)
	waitFor(t, "the notification", func() bool { return field(d, func() uint32 { return dev.pairNote }) != 0 })
	note := field(d, func() uint32 { return dev.pairNote })
	want := []string{"pair-accept:" + dev.ID + ":" + key, "Confirm", "pair-reject:" + dev.ID + ":" + key, "Reject"}
	if got := srv.actionsOf(note); !slices.Equal(got, want) {
		t.Fatalf("actions %q, want %q", got, want)
	}
	d.onNotificationAction(note, want[0])
	if !field(d, func() bool { return dev.Paired }) || pinned(t, d, dev.ID) == nil {
		t.Fatal("the Confirm button did not pin the phone")
	}
	waitFor(t, "the close of the notification", func() bool { return srv.isClosed(note) })
}

// TestUnpairClosesPhoneNotifications checks that an unpair closes the
// desktop notifications of the phone. Their buttons no longer reach the
// phone.
func TestUnpairClosesPhoneNotifications(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, srv, dev, onPhone, fromDesk := notePair(t, ctx)
	d.mu.Lock()
	d.cfg.Notifications = true
	d.mu.Unlock()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })
	if err := d.AcceptPair(dev, ""); err != nil {
		t.Fatal(err)
	}
	nextPair(t, fromDesk)

	if err := onPhone.Send(proto.New(proto.TypeNotification, map[string]any{"id": "sms-1", "appName": "Messages", "title": "Anna", "text": "The code is 4711"})); err != nil {
		t.Fatal(err)
	}
	var desk uint32
	waitFor(t, "the phone notification", func() bool {
		desk = field(d, func() uint32 { return dev.notifDesktop["sms-1"] })
		return desk != 0
	})
	if err := d.Unpair(dev); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the close of the phone notification", func() bool { return srv.isClosed(desk) })
}
