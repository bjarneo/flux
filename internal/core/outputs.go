package core

import (
	"context"
	"errors"
	"slices"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// The audio outputs of this computer on the Media screen of the phone. The
// phone asks for the outputs with flux.audio.request, and fluxd answers
// with flux.audio. The phone can also select the default output, and set
// the volume and the mute state of each output. Like media control, each
// paired device can do this.

// audioOutputs reads and changes the audio outputs. desktop.Outputs runs
// pactl. Tests give a fake.
type audioOutputs interface {
	List(ctx context.Context) ([]desktop.Output, error)
	Default(ctx context.Context) (string, error)
	Find(ctx context.Context, name string) (desktop.Output, error)
	SetDefault(ctx context.Context, name string) error
	SetVolume(ctx context.Context, name string, percent int) error
	SetMute(ctx context.Context, name string, muted bool) error
}

// audioRequest is the body of a flux.audio.request packet. Request asks
// for the outputs. Output names the output that Default, Volume, or Mute
// changes.
type audioRequest struct {
	Request bool   `json:"request"`
	Output  string `json:"output"`
	Default bool   `json:"default"`
	Volume  *int   `json:"volume"`
	Mute    *bool  `json:"mute"`
}

// changes reports whether the request changes an output.
func (b audioRequest) changes() bool {
	return b.Output != "" && (b.Default || b.Volume != nil || b.Mute != nil)
}

// maxOutputText is the longest name or description of an output that
// fluxd sends.
const maxOutputText = 256

// errNoOutputs is the answer of a headless fluxd.
var errNoOutputs = errors.New("the audio outputs are off in headless mode")

// handleAudioRequest answers a flux.audio.request of a paired device. The
// work runs on the media worker, so a slow pactl does not stop the read
// loop of the device.
func (d *Daemon) handleAudioRequest(l *lan.Link, p *proto.Packet) {
	var b audioRequest
	if p.Decode(&b) != nil || (!b.Request && !b.changes()) {
		return
	}
	d.runMedia(func() { d.answerAudio(l, b) })
}

// answerAudio runs 1 output request and sends the outputs to the device.
// After a change, it sends them only when no other media job waits, so
// that a drag of a volume control gets 1 answer at its end.
func (d *Daemon) answerAudio(l *lan.Link, b audioRequest) {
	if !d.isPairedLink(l) {
		return
	}
	if d.outputs == nil {
		_ = l.Send(audioPacket(nil, errNoOutputs))
		return
	}
	ctx := d.ctx
	var err error
	if b.changes() {
		err = d.changeOutput(ctx, b)
		if err != nil {
			d.logf("audio output %s: %v", peerText(b.Output), err)
		}
		d.mu.Lock()
		waiting := len(d.content.mediaQ.jobs) > 0
		d.mu.Unlock()
		if waiting && err == nil && !b.Request {
			return
		}
	}
	outs, lerr := d.outputs.List(ctx)
	if lerr != nil {
		err = lerr
	}
	_ = l.Send(audioPacket(outs, err))
}

// changeOutput makes 1 change. The output must be in the list that the
// phone sees, so that a device cannot pass any other text to pactl.
func (d *Daemon) changeOutput(ctx context.Context, b audioRequest) error {
	outs, err := d.outputs.List(ctx)
	if err != nil {
		return err
	}
	if !slices.ContainsFunc(outs, func(o desktop.Output) bool { return o.Name == b.Output }) {
		return apiErr("not_found", "The computer has no audio output %s", peerText(b.Output))
	}
	if b.Default {
		if err := d.outputs.SetDefault(ctx, b.Output); err != nil {
			return err
		}
	}
	if b.Volume != nil {
		if err := d.outputs.SetVolume(ctx, b.Output, max(0, min(150, *b.Volume))); err != nil {
			return err
		}
	}
	if b.Mute != nil {
		if err := d.outputs.SetMute(ctx, b.Output, *b.Mute); err != nil {
			return err
		}
	}
	return nil
}

// audioPacket returns the flux.audio packet with the outputs, and the
// error when err is not nil.
func audioPacket(outs []desktop.Output, err error) *proto.Packet {
	list := make([]map[string]any, 0, len(outs))
	for _, o := range outs {
		list = append(list, map[string]any{
			"name":        proto.CleanText(o.Name, maxOutputText),
			"description": proto.CleanText(o.Description, maxOutputText),
			"volume":      o.Volume,
			"muted":       o.Muted,
			"default":     o.Default,
		})
	}
	body := map[string]any{"outputs": list}
	if err != nil {
		body["error"] = err.Error()
	}
	return proto.New(proto.TypeFluxAudio, body)
}
