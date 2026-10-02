package core

import (
	"context"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// requestDaemon returns a daemon with 1 paired phone on a real link that
// accepts flux.stream.request, and the packets that the phone gets.
func requestDaemon(t *testing.T) (*Daemon, *Device, *lan.Link, chan *proto.Packet) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	d := &Daemon{
		cfg:     &config.Config{Name: "arch"},
		devices: map[string]*Device{},
		dirty:   make(chan struct{}, 1),
		ctx:     ctx,
		logger:  log.New(io.Discard, "", 0),
	}
	dev := &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxStreamRequest}}
	d.devices[phoneID] = dev
	return d, dev, onDesk, packets(onPhone)
}

// nextRequest returns the kind of the next flux.stream.request on ch. A
// ping is the marker that the test sends after a step that must send
// nothing, so nextRequest returns "" for it.
func nextRequest(t *testing.T, ch chan *proto.Packet) string {
	t.Helper()
	select {
	case p := <-ch:
		switch p.Type {
		case proto.TypeFluxStreamRequest:
			body := p.Fields()
			if len(body) != 1 {
				t.Fatalf("the request has other fields: %v", body)
			}
			kind, _ := body["kind"].(string)
			return kind
		case proto.TypePing:
			return ""
		}
		t.Fatalf("unexpected packet %s", p.Type)
	case <-time.After(5 * time.Second):
		t.Fatal("no packet within 5 seconds")
	}
	return ""
}

// noRequest checks that no request waits on the link: the marker comes
// first.
func noRequest(t *testing.T, onDesk *lan.Link, ch chan *proto.Packet, what string) {
	t.Helper()
	if err := onDesk.Send(proto.New(proto.TypePing, nil)); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "" {
		t.Fatalf("%s sent a request for %s", what, kind)
	}
}

// TestStreamRequestAutomatic checks the automatic choice: only a paired,
// connected device that accepts the request counts.
func TestStreamRequestAutomatic(t *testing.T) {
	d, _, onDesk, ch := requestDaemon(t)
	request := []string{proto.TypeFluxStreamRequest}
	// A device that does not list the type, an offline device, and a
	// device that is not paired do not count. Their links never send.
	d.devices["old"] = &Device{ID: "old", Name: "Old phone", Paired: true, link: &lan.Link{}, Incoming: []string{proto.TypeFluxTheme}}
	d.devices["away"] = &Device{ID: "away", Name: "Away phone", Paired: true, Incoming: request}
	d.devices["new"] = &Device{ID: "new", Name: "New phone", link: &lan.Link{}, Incoming: request}

	if err := d.RequestWebcam(""); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "webcam" {
		t.Fatalf("kind %q", kind)
	}
	if err := d.RequestMic(""); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "mic" {
		t.Fatalf("kind %q", kind)
	}
	noRequest(t, onDesk, ch, "2 requests")
}

// TestStreamRequestByDevice checks --device with a name and with an ID,
// and the IPC result that names the device.
func TestStreamRequestByDevice(t *testing.T) {
	d, dev, _, ch := requestDaemon(t)
	// A second device that accepts the request makes the automatic choice
	// fail, but a name or an ID still selects 1 device.
	d.devices["tablet"] = &Device{ID: "tablet", Name: "Tab S9", Paired: true, link: &lan.Link{}, Incoming: []string{proto.TypeFluxStreamRequest}}

	res, err := d.Call(context.Background(), "webcam.start", []byte(`{"device":"pixel 8"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m := res.(map[string]any); m["device"] != dev.ID || m["name"] != "Pixel 8" {
		t.Fatalf("result %v", m)
	}
	if kind := nextRequest(t, ch); kind != "webcam" {
		t.Fatalf("kind %q", kind)
	}
	if _, err := d.Call(context.Background(), "mic.start", []byte(`{"device":"`+dev.ID+`"}`)); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "mic" {
		t.Fatalf("kind %q", kind)
	}
}

// TestStreamRequestNoDevice checks the errors when no device can take the
// request.
func TestStreamRequestNoDevice(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	dev.Incoming = []string{proto.TypeFluxTheme}

	err := d.RequestWebcam("")
	if errCode(err) != "no_device" || !strings.Contains(err.Error(), "the webcam") || !strings.Contains(err.Error(), "update") {
		t.Fatalf("no device: %v", err)
	}
	if err := d.RequestMic(""); errCode(err) != "no_device" || !strings.Contains(err.Error(), "the mic") {
		t.Fatalf("no device: %v", err)
	}
	// A device that does not list the type gets nothing, also by name.
	if err := d.RequestWebcam("Pixel 8"); errCode(err) != "not_supported" || !strings.Contains(err.Error(), "Update Flux on Pixel 8") {
		t.Fatalf("a device without the type: %v", err)
	}
	if err := d.RequestWebcam("Galaxy"); errCode(err) != "not_found" {
		t.Fatalf("an unknown name: %v", err)
	}
	noRequest(t, onDesk, ch, "a device without the type")

	dev.Incoming = []string{proto.TypeFluxStreamRequest}
	dev.Paired = false
	if err := d.RequestWebcam(dev.ID); errCode(err) != "not_paired" {
		t.Fatalf("a device that is not paired: %v", err)
	}
	dev.Paired = true
	dev.link = nil
	if err := d.RequestWebcam(dev.ID); errCode(err) != "offline" {
		t.Fatalf("an offline device: %v", err)
	}
	dev.link = onDesk
	noRequest(t, onDesk, ch, "a device that cannot take the request")
}

// TestStreamRequestSeveralDevices checks that the automatic choice lists
// the devices and asks for --device.
func TestStreamRequestSeveralDevices(t *testing.T) {
	d, _, onDesk, ch := requestDaemon(t)
	d.devices["tablet"] = &Device{ID: "tablet", Name: "Tab S9", Paired: true, link: &lan.Link{}, Incoming: []string{proto.TypeFluxStreamRequest}}
	err := d.RequestMic("")
	if errCode(err) != "ambiguous" || !strings.Contains(err.Error(), "Pixel 8, Tab S9") || !strings.Contains(err.Error(), "--device") {
		t.Fatalf("2 devices: %v", err)
	}
	noRequest(t, onDesk, ch, "2 devices")
}

// TestStreamRequestActive checks that a stream of the kind refuses the
// request, and that a stream of the other kind does not.
func TestStreamRequestActive(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	d.webcam = &webcamSession{dev: dev}
	err := d.RequestWebcam("")
	if errCode(err) != "already_active" || !strings.Contains(err.Error(), "flux-cli webcam stop") {
		t.Fatalf("a live webcam: %v", err)
	}
	noRequest(t, onDesk, ch, "a live webcam")
	if err := d.RequestMic(""); err != nil {
		t.Fatalf("the mic with a live webcam: %v", err)
	}
	if kind := nextRequest(t, ch); kind != "mic" {
		t.Fatalf("kind %q", kind)
	}

	d.webcam = nil
	d.mic = &micSession{dev: dev}
	if err := d.RequestMic(dev.ID); errCode(err) != "already_active" || !strings.Contains(err.Error(), "flux-cli mic stop") {
		t.Fatalf("a live mic: %v", err)
	}
	noRequest(t, onDesk, ch, "a live mic")
}

// TestStreamRequestGap checks that a second request of 1 kind to 1 device
// waits streamRequestGap, and that the other kind does not wait.
func TestStreamRequestGap(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	if err := d.RequestWebcam(""); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "webcam" {
		t.Fatalf("kind %q", kind)
	}
	err := d.RequestWebcam("")
	if errCode(err) != "too_soon" || !strings.Contains(err.Error(), "3 seconds") {
		t.Fatalf("a second request: %v", err)
	}
	noRequest(t, onDesk, ch, "a second request in the gap")
	if err := d.RequestMic(""); err != nil {
		t.Fatalf("the other kind: %v", err)
	}
	if kind := nextRequest(t, ch); kind != "mic" {
		t.Fatalf("kind %q", kind)
	}

	// The gap ends.
	d.mu.Lock()
	d.sessions.streamAsked[streamAsk{"webcam", dev.ID}] = time.Now().Add(-streamRequestGap)
	d.mu.Unlock()
	if err := d.RequestWebcam(""); err != nil {
		t.Fatalf("a request after the gap: %v", err)
	}
	if kind := nextRequest(t, ch); kind != "webcam" {
		t.Fatalf("kind %q", kind)
	}
}

// TestStreamRequestHeadless checks that a headless daemon asks for
// nothing, because it cannot take the stream.
func TestStreamRequestHeadless(t *testing.T) {
	d, _, onDesk, ch := requestDaemon(t)
	d.opts.Headless = true
	if err := d.RequestWebcam(""); errCode(err) != "not_supported" {
		t.Fatalf("headless: %v", err)
	}
	noRequest(t, onDesk, ch, "a headless daemon")
}

// TestStreamRequestPlugin checks that the state lists the feature only for
// a device that accepts the request.
func TestStreamRequestPlugin(t *testing.T) {
	dev := &Device{Incoming: []string{proto.TypeFluxStreamRequest}}
	if !strings.Contains(strings.Join(dev.plugins(), " "), "streamrequest") {
		t.Fatalf("plugins %v", dev.plugins())
	}
	dev.Incoming = []string{proto.TypeFluxWebcam, proto.TypeFluxMic}
	if strings.Contains(strings.Join(dev.plugins(), " "), "streamrequest") {
		t.Fatalf("plugins %v", dev.plugins())
	}
}
