package core

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// This computer can ask a device to start its camera or its microphone.
// The flux.stream.request packet only asks. The device shows a prompt or a
// notification, and it starts the stream with flux.webcam or flux.mic only
// after its user taps start on the device. fluxd then handles that start
// as each other start from the device.

// streamRequestGap is the shortest time between 2 requests of 1 kind to 1
// device. The device ignores a request in the same time too.
const streamRequestGap = 3 * time.Second

// streamAsk names a request: the kind, "webcam" or "mic", and the device
// ID.
type streamAsk struct{ kind, device string }

// streamWhat returns the name of a kind for the messages.
func streamWhat(kind string) string {
	if kind == "mic" {
		return "the mic"
	}
	return "the webcam"
}

// RequestWebcam asks a device to start its camera as the webcam of this
// computer. device is a name or an ID. An empty device selects the only
// paired, connected device that accepts the request. The user of the
// device must tap start before the camera turns on.
func (d *Daemon) RequestWebcam(device string) error {
	_, _, err := d.requestStream("webcam", device)
	return err
}

// RequestMic asks a device to start its microphone for this computer. It
// selects the device as RequestWebcam does. The user of the device must tap
// start before the microphone turns on.
func (d *Daemon) RequestMic(device string) error {
	_, _, err := d.requestStream("mic", device)
	return err
}

// requestStream sends a flux.stream.request for kind to the device that
// key names, and returns the ID and the name of that device.
func (d *Daemon) requestStream(kind, key string) (id, name string, err error) {
	var named *Device
	if key != "" {
		if named, err = d.find(key, nil); err != nil {
			return "", "", err
		}
	}
	now := time.Now()
	var l *lan.Link
	d.mu.Lock()
	dev, err := d.streamTargetLocked(kind, named)
	if err == nil {
		id, name, l = dev.ID, dev.Name, dev.link
		ask := streamAsk{kind, dev.ID}
		if last, ok := d.sessions.streamAsked[ask]; ok && now.Sub(last) < streamRequestGap {
			err = apiErr("too_soon", "%s got a request for %s less than %d seconds ago. Wait, then ask again", name, streamWhat(kind), int(streamRequestGap.Seconds()))
		} else {
			d.streamAskedLocked(ask, now)
		}
	}
	d.mu.Unlock()
	if err != nil {
		return "", "", err
	}
	if err := l.Send(proto.New(proto.TypeFluxStreamRequest, map[string]any{"kind": kind})); err != nil {
		return "", "", fmt.Errorf("cannot send the request to %s: %w", name, err)
	}
	d.logf("%s: asked for %s", name, streamWhat(kind))
	return id, name, nil
}

// streamTargetLocked returns the device that a request for kind goes to:
// named, or else the only paired, connected device that accepts the
// request. It refuses the request while a stream of that kind runs. The
// caller holds d.mu.
func (d *Daemon) streamTargetLocked(kind string, named *Device) (*Device, error) {
	what := streamWhat(kind)
	if d.opts.Headless {
		return nil, apiErr("not_supported", "fluxd runs in headless mode and cannot take %s", what)
	}
	var from *Device
	switch {
	case kind == "webcam" && d.webcam != nil:
		from = d.webcam.dev
	case kind == "mic" && d.mic != nil:
		from = d.mic.dev
	}
	if from != nil {
		return nil, apiErr("already_active", "%s already streams %s to this computer. To stop it, run: flux-cli %s stop", from.Name, what, kind)
	}
	if named != nil {
		switch {
		case !named.Paired:
			return nil, apiErr("not_paired", "%s is not paired", named.Name)
		case named.link == nil:
			return nil, offline(named)
		case !named.accepts(proto.TypeFluxStreamRequest):
			return nil, apiErr("not_supported", "%s cannot start %s from this computer. Update Flux on %s", named.Name, what, named.Name)
		}
		return named, nil
	}
	var found []*Device
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxStreamRequest) {
			found = append(found, dev)
		}
	}
	switch len(found) {
	case 0:
		return nil, apiErr("no_device", "No connected device can start %s from this computer. If the Flux app on the device is old, update it", what)
	case 1:
		return found[0], nil
	}
	names := make([]string, 0, len(found))
	for _, dev := range found {
		names = append(names, dev.Name)
	}
	sort.Strings(names)
	return nil, apiErr("ambiguous", "%d connected devices can start %s (%s). Use --device", len(found), what, strings.Join(names, ", "))
}

// streamAskedLocked keeps the time of a request, and forgets the requests
// that are older than streamRequestGap. The caller holds d.mu.
func (d *Daemon) streamAskedLocked(ask streamAsk, now time.Time) {
	if d.sessions.streamAsked == nil {
		d.sessions.streamAsked = map[streamAsk]time.Time{}
	}
	for k, t := range d.sessions.streamAsked {
		if now.Sub(t) >= streamRequestGap {
			delete(d.sessions.streamAsked, k)
		}
	}
	d.sessions.streamAsked[ask] = now
}
