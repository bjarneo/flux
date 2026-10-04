package core

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"time"

	"flux/internal/proto"
)

// Desktop audio uses 20 ms frames of stereo, 48 kHz, signed 16-bit little-endian PCM.
const desktopAudioBytes = 48000 * 2 * 2 / 50

func desktopAudioArgs() []string {
	return []string{"--raw", "--rate", "48000", "--channels", "2", "--format", "s16", "--latency", "40ms",
		"--properties", "{ stream.capture.sink = true }", "-"}
}

func pumpDesktopAudio(r io.Reader, w io.Writer) error {
	frame := make([]byte, desktopAudioBytes)
	fw := frameWriter{w: w}
	for {
		if _, err := io.ReadFull(r, frame); err != nil {
			return err
		}
		if err := fw.write(frameAudio, frame); err != nil {
			return err
		}
	}
}

func (d *Daemon) runDesktopAudio(ctx context.Context, s *desktopSession, w io.Writer) {
	err := func() error {
		path, err := exec.LookPath("pw-record")
		if err != nil {
			return fmt.Errorf("desktop audio needs pw-record on the computer")
		}
		cmd := childCommand(ctx, path, desktopAudioArgs()...)
		cmd.WaitDelay = time.Second
		out, err := cmd.StdoutPipe()
		if err != nil {
			return err
		}
		if err := cmd.Start(); err != nil {
			return err
		}
		d.mu.Lock()
		if d.desktop == s {
			s.view.Audio = true
		}
		d.mu.Unlock()
		d.markDirty()
		err = pumpDesktopAudio(out, w)
		out.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
		return err
	}()
	d.mu.Lock()
	current := d.desktop == s
	if current {
		s.view.Audio = false
		if ctx.Err() == nil && err != nil {
			s.view.AudioError = err.Error()
		}
	}
	d.mu.Unlock()
	if current && ctx.Err() == nil && err != nil {
		_ = s.link.Send(proto.New(proto.TypeFluxDesktop, map[string]any{"state": "audio", "message": err.Error()}))
	}
	d.markDirty()
}
