package approve

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type scenario struct {
	name string
	// setup returns the options, and sets the fake fluxd.
	setup func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options
	line  string
}

func signed(ph *phone, t *testing.T) func(map[string]any) (map[string]any, map[string]any) {
	return func(p map[string]any) (map[string]any, map[string]any) {
		sig := ph.signRequest(t, requestFrom(p))
		return map[string]any{"state": "approved", "signature": base64.StdEncoding.EncodeToString(sig)}, nil
	}
}

// Each row of the failure table that prints a line gives the line of
// docs/approve.md. The 4 other rows give no line.
func TestHelperPrintsTheReason(t *testing.T) {
	const prompt = "Approve on Pixel 8 for terminal /dev/pts/3, or wait for the password prompt.\n"
	deny := func(map[string]any) (map[string]any, map[string]any) { return map[string]any{"state": "denied"}, nil }
	cases := []scenario{
		{"unsafe key file", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			if err := os.Chmod(key, 0o666); err != nil {
				t.Fatal(err)
			}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, reasonKeyFile},
		{"key file with no key block", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			if err := os.WriteFile(key, []byte("not a key\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, reasonKeyFile},
		{"no fluxd", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			return helperOptions(t, key, filepath.Join(t.TempDir(), "s"), &bytes.Buffer{})
		}, reasonFluxd},
		{"fluxd of another user", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			o := helperOptions(t, key, f.path, &bytes.Buffer{})
			o.PeerUID = os.Getuid() + 1
			return o
		}, reasonFluxd},
		{"phone not connected", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.startErr = map[string]any{"code": "offline", "message": "Pixel 8 is offline"}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, reasonPhone},
		{"phone not paired", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.startErr = map[string]any{"code": "not_paired", "message": "Pixel 8 is not paired"}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, reasonPhone},
		{"another approval waits", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.startErr = map[string]any{"code": "busy", "message": "Another request waits for this phone"}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, reasonBusy},
		{"denied", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = deny
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, prompt + reasonDenied},
		{"no answer in time", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = func(map[string]any) (map[string]any, map[string]any) {
				return nil, map[string]any{"code": "timeout", "message": "x"}
			}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, prompt + reasonTimeout},
		{"wrong key", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = signed(newPhone(t), t)
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, prompt + reasonSignature},
		{"changed field", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = func(p map[string]any) (map[string]any, map[string]any) {
				r := requestFrom(p)
				r.Service = "login"
				sig := ph.signRequest(t, r)
				return map[string]any{"state": "approved", "signature": base64.StdEncoding.EncodeToString(sig)}, nil
			}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, prompt + reasonSignature},
		{"stale time", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = signed(ph, t)
			o := helperOptions(t, key, f.path, &bytes.Buffer{})
			base := time.Now()
			calls := 0
			// The helper reads the clock for the request, and again for the
			// check. The second time is 1 hour later.
			o.Now = func() time.Time {
				calls++
				if calls == 1 {
					return base
				}
				return base.Add(time.Hour)
			}
			return o
		}, prompt + reasonStale},
		{"the phone cannot sign", func(t *testing.T, ph *phone, key string, f *fakeFluxd) Options {
			f.answer = func(map[string]any) (map[string]any, map[string]any) {
				return map[string]any{"state": "failed", "message": "\x1b[2Jevil text"}, nil
			}
			return helperOptions(t, key, f.path, &bytes.Buffer{})
		}, prompt + reasonPhoneFailed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ph := newPhone(t)
			key := writeTestKey(t, ph)
			f := newFakeFluxd(t)
			f.answer = deny
			o := c.setup(t, ph, key, f)
			var out bytes.Buffer
			o.Out = &out
			if err := Run(context.Background(), o); err == nil {
				t.Fatal("want an error")
			}
			want := c.line
			if !strings.HasSuffix(want, "\n") {
				want += "\n"
			}
			if out.String() != want {
				t.Fatalf("output %q, want %q", out.String(), want)
			}
			// The line holds no text that fluxd or the phone sent.
			if strings.Contains(out.String(), "evil") || strings.Contains(out.String(), "\x1b") {
				t.Fatalf("the line holds text of the phone: %q", out.String())
			}
		})
	}
}

// The 4 rows with no line: no key file, the service sshd, a request of
// another user, and a PAM caller that stops.
func TestHelperPrintsNothingForSilentRows(t *testing.T) {
	ph := newPhone(t)
	key := writeTestKey(t, ph)
	hang := func(map[string]any) (map[string]any, map[string]any) { return nil, nil }
	cases := []struct {
		name  string
		setup func(o *Options)
		ctx   func() (context.Context, func())
	}{
		{"no key file", func(o *Options) { o.KeyPath = filepath.Join(t.TempDir(), "none.pub") }, nil},
		{"sshd", func(o *Options) { o.Service = "sshd" }, nil},
		{"targetpw", func(o *Options) { o.RUser = "bob"; o.UserUID = 1000 }, nil},
		{"a caller of another user", func(o *Options) { o.CallerUID = 1001; o.UserUID = 1000 }, nil},
		{"polkit without a setuid helper", func(o *Options) { o.Service = "polkit-1"; o.CallerUID = 0; o.UserUID = 1000 }, nil},
		{"the PAM caller stops", func(o *Options) {}, func() (context.Context, func()) {
			ctx, stop := context.WithCancel(context.Background())
			go func() {
				time.Sleep(200 * time.Millisecond)
				stop()
			}()
			return ctx, stop
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFakeFluxd(t)
			f.answer = hang
			var out bytes.Buffer
			o := helperOptions(t, key, f.path, &out)
			c.setup(&o)
			ctx := context.Background()
			if c.ctx != nil {
				var stop func()
				ctx, stop = c.ctx()
				defer stop()
			}
			err := Run(ctx, o)
			if err == nil {
				t.Fatal("want an error")
			}
			if Reason(err) != "" {
				t.Fatalf("Reason gives %q", Reason(err))
			}
			// A silent row prints nothing. When the PAM caller stops after the
			// request, only the line that tells the user to look at the phone
			// shows, and no reason follows it.
			want := ""
			if c.ctx != nil {
				want = "Approve on Pixel 8 for terminal /dev/pts/3, or wait for the password prompt.\n"
			}
			if out.String() != want {
				t.Fatalf("the helper printed %q, want %q", out.String(), want)
			}
		})
	}
}

func TestReasonOfPlainErrors(t *testing.T) {
	for _, err := range []error{nil, errors.New("x"), ErrNoKey, ErrService, ErrRequester} {
		if got := Reason(err); got != "" {
			t.Errorf("Reason(%v) = %q", err, got)
		}
	}
}
