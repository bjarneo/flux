package desktop

import (
	"context"
	"os"
	"os/exec"
	"sync"
	"time"
)

// ringSounds are the sounds that the ringer tries, in order.
var ringSounds = []string{
	"/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga",
	"/usr/share/sounds/freedesktop/stereo/bell.oga",
	"/usr/share/sounds/freedesktop/stereo/complete.oga",
}

// Ringer plays a sound in a loop with pw-play until Stop.
type Ringer struct {
	mu     sync.Mutex
	cancel context.CancelFunc
}

// Start begins to ring. It does nothing when the ringer already rings.
func (r *Ringer) Start() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel = cancel
	go loopSound(ctx, ringSound())
}

// Stop ends the ring.
func (r *Ringer) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		r.cancel()
		r.cancel = nil
	}
}

// Ringing reports whether the ringer rings.
func (r *Ringer) Ringing() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cancel != nil
}

func ringSound() string {
	for _, s := range ringSounds {
		if _, err := os.Stat(s); err == nil {
			return s
		}
	}
	return ringSounds[0]
}

// loopSound plays the sound again after each play ends. When pw-play
// fails, it waits 1 second before the next try.
func loopSound(ctx context.Context, sound string) {
	for ctx.Err() == nil {
		start := time.Now()
		err := exec.CommandContext(ctx, "pw-play", sound).Run()
		if ctx.Err() != nil {
			return
		}
		if err != nil || time.Since(start) < 200*time.Millisecond {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}
