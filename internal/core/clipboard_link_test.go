package core

import (
	"bytes"
	"context"
	"crypto/x509"
	"net"
	"testing"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// linkPair connects 2 providers on loopback and returns the link on each
// side and the device ID of each side.
func linkPair(t *testing.T, ctx context.Context) (desk, phone *lan.Link, deskID, phoneID string) {
	t.Helper()
	start := func(name string, port int) (*lan.Provider, chan *lan.Link, string) {
		cert, id, err := proto.LoadOrCreateCert(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		links := make(chan *lan.Link, 1)
		p := lan.New(lan.Config{
			Cert:         cert,
			Identity:     func() proto.Identity { return proto.NewIdentity(id, name, 0) },
			Trusted:      func(string) (*x509.Certificate, bool) { return nil, false },
			HasLink:      func(string) bool { return false },
			OnLink:       func(l *lan.Link) { links <- l },
			Logf:         t.Logf,
			UDPPort:      port,
			FirstTCPPort: port + 1,
		})
		if err := p.Start(ctx); err != nil {
			t.Fatal(err)
		}
		return p, links, id
	}
	deskProv, deskLinks, deskID := start("desk", 29260)
	_, phoneLinks, phoneID := start("phone", 29320)
	deskProv.AnnounceTo(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 29320})
	wait := func(ch chan *lan.Link) *lan.Link {
		select {
		case l := <-ch:
			return l
		case <-time.After(5 * time.Second):
			t.Fatal("no link within 5 seconds")
			return nil
		}
	}
	return wait(deskLinks), wait(phoneLinks), deskID, phoneID
}

// waitImage polls the clipboard until it holds an image.
func waitImage(t *testing.T, clip *memClipboard) []byte {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		clip.mu.Lock()
		img := clip.image
		clip.mu.Unlock()
		if img != nil {
			return img
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("no image on the clipboard within 5 seconds")
	return nil
}

// TestClipImageOverLink sends a clipboard image through real links in both
// directions: a local copy on one side, then Send clipboard on the other.
func TestClipImageOverLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	onDesk, onPhone, deskID, phoneID := linkPair(t, ctx)

	a, clipA := clipDaemon(t, true)
	b, clipB := clipDaemon(t, true)
	a.ctx, b.ctx = ctx, ctx
	phoneDev := &Device{ID: phoneID, Name: "phone", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxClipboardImage}}
	deskDev := &Device{ID: deskID, Name: "desk", Paired: true, link: onPhone, Incoming: []string{proto.TypeFluxClipboardImage}}
	a.devices[phoneID] = phoneDev
	b.devices[deskID] = deskDev
	go onDesk.Receive(func(p *proto.Packet) { a.handlePacket(phoneDev, onDesk, p) })
	go onPhone.Receive(func(p *proto.Packet) { b.handlePacket(deskDev, onPhone, p) })

	img := append(testPNG(7), bytes.Repeat([]byte{0xab}, 200_000)...)
	a.onLocalImage(img, "image/png")
	if got := waitImage(t, clipB); !bytes.Equal(got, img) {
		t.Fatalf("the phone got %d bytes, want %d", len(got), len(img))
	}
	if len(b.clipboard) != 1 || b.clipboard[0].Dir != "in" || b.clipboard[0].Image == "" {
		t.Fatalf("phone history %+v", b.clipboard)
	}

	// Send clipboard without text sends the image on the clipboard.
	if err := b.SendClipboard(deskDev, ""); err != nil {
		t.Fatal(err)
	}
	if got := waitImage(t, clipA); !bytes.Equal(got, img) {
		t.Fatalf("the desk got %d bytes, want %d", len(got), len(img))
	}

	// A device that does not accept images gets an error, not the image.
	deskDev.Incoming = nil
	if err := b.SendClipboard(deskDev, ""); err == nil {
		t.Fatal("sent an image to a device that does not accept images")
	}
}
