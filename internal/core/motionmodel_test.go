package core

import (
	"encoding/json"
	"math"
	"testing"
)

// feed sends n samples, 1 every 33 ms from t0, all with the same values,
// and returns the last targets.
func feed(m *motionModel, t0 int64, n int, s motionSample) motionTargets {
	var out motionTargets
	for i := range n {
		s.T = t0 + int64(i)*33
		out = m.step(s)
	}
	return out
}

func TestMotionModelDirection(t *testing.T) {
	cases := []struct {
		name         string
		s            motionSample
		wantX, wantY int // the sign of each offset
	}{
		{"turn right moves dots left", motionSample{X: 1.5, Mount: "flat"}, -1, 0},
		{"turn left moves dots right", motionSample{X: -1.5, Mount: "flat"}, 1, 0},
		{"speed up moves dots down", motionSample{Y: 1.5, Mount: "flat"}, 0, 1},
		{"brake moves dots up", motionSample{Y: -1.5, Mount: "flat"}, 0, -1},
		{"upright speed up uses -z", motionSample{Z: -1.5, Mount: "upright"}, 0, 1},
		{"upright ignores y for forward", motionSample{Y: 1.5, Mount: "upright"}, 0, 0},
		{"empty mount is flat", motionSample{Y: 1.5}, 0, 1},
	}
	sign := func(v float64) int {
		switch {
		case v > 0:
			return 1
		case v < 0:
			return -1
		}
		return 0
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := feed(newMotionModel(1), 0, 30, c.s)
			if sign(got.OffsetX) != c.wantX || sign(got.OffsetY) != c.wantY {
				t.Fatalf("offset (%v, %v), want signs (%d, %d)", got.OffsetX, got.OffsetY, c.wantX, c.wantY)
			}
			// The flow goes the same way as the offset.
			if sign(got.FlowX) != c.wantX || sign(got.FlowY) != c.wantY {
				t.Fatalf("flow (%v, %v), want signs (%d, %d)", got.FlowX, got.FlowY, c.wantX, c.wantY)
			}
		})
	}
}

func TestMotionModelDeadZone(t *testing.T) {
	got := feed(newMotionModel(1.6), 0, 60, motionSample{X: 0.04, Y: -0.04, Z: 0.04})
	if got != (motionTargets{}) {
		t.Fatalf("noise under the dead zone moved the cues: %+v", got)
	}
	// Over the axis dead zone but under the flow dead zone: an offset, no flow.
	got = feed(newMotionModel(1), 0, 60, motionSample{X: 0.08})
	if got.OffsetX == 0 || got.FlowX != 0 {
		t.Fatalf("small motion: %+v", got)
	}
}

func TestMotionModelClamps(t *testing.T) {
	got := feed(newMotionModel(1.6), 0, 120, motionSample{X: 50, Y: -50, Z: 50})
	if got.OffsetX != -motionOffsetMax || got.OffsetY != -motionOffsetMax {
		t.Fatalf("offset %v %v, want ±%d", got.OffsetX, got.OffsetY, motionOffsetMax)
	}
	if got.FlowX != -motionFlowMax || got.FlowY != -motionFlowMax {
		t.Fatalf("flow %v %v, want ±%d", got.FlowX, got.FlowY, motionFlowMax)
	}
	if got.Density != 1 {
		t.Fatalf("density %v, want 1", got.Density)
	}
}

func TestMotionModelSensitivity(t *testing.T) {
	low := feed(newMotionModel(0.5), 0, 60, motionSample{X: 0.5})
	high := feed(newMotionModel(1.6), 0, 60, motionSample{X: 0.5})
	if math.Abs(high.OffsetX) <= math.Abs(low.OffsetX) {
		t.Fatalf("sensitivity 1.6 gave %v, 0.5 gave %v", high.OffsetX, low.OffsetX)
	}
}

func TestMotionModelSmoothsAndRests(t *testing.T) {
	m := newMotionModel(1)
	first := m.step(motionSample{T: 0, X: 1})
	steady := feed(m, 33, 60, motionSample{X: 1})
	if math.Abs(first.OffsetX) >= math.Abs(steady.OffsetX) {
		t.Fatalf("no smoothing: first %v, steady %v", first.OffsetX, steady.OffsetX)
	}
	rest := feed(m, 33*61, 90, motionSample{})
	if rest.OffsetX != 0 || rest.FlowX != 0 || rest.Density != 0 {
		t.Fatalf("the cues did not come to rest: %+v", rest)
	}
}

func TestMotionModelDensityRelease(t *testing.T) {
	m := newMotionModel(1)
	strong := feed(m, 0, 30, motionSample{X: 4})
	if strong.Density < 0.6 {
		t.Fatalf("strong motion density %v", strong.Density)
	}
	// The release is slower than the attack: 100 ms later, density stays.
	after := feed(m, 30*33, 3, motionSample{})
	if after.Density == 0 || after.Density > strong.Density {
		t.Fatalf("density after 100 ms of rest: %v (strong %v)", after.Density, strong.Density)
	}
}

func TestMotionModelTimeGoesBack(t *testing.T) {
	m := newMotionModel(1)
	feed(m, 10_000, 60, motionSample{X: 3})
	// A restarted sensor sends an older time: the model starts from rest.
	got := m.step(motionSample{T: 5, X: 0})
	if got != (motionTargets{}) {
		t.Fatalf("after a time jump back: %+v", got)
	}
}

func TestMotionModelLongGap(t *testing.T) {
	m := newMotionModel(1)
	m.step(motionSample{T: 0})
	// A gap of 10 s counts as at most 150 ms.
	got := m.step(motionSample{T: 10_000, X: 1})
	want := -motionOffsetGain * (1 - math.Exp(-motionMaxDt/motionOffsetTau))
	if math.Abs(got.OffsetX-want) > 0.25 {
		t.Fatalf("offset after a long gap %v, want about %v", got.OffsetX, want)
	}
}

func TestValidSample(t *testing.T) {
	for _, s := range []motionSample{
		{X: math.NaN()}, {Y: math.Inf(1)}, {Z: math.Inf(-1)}, {X: 200.5}, {Y: -201},
	} {
		if validSample(s) {
			t.Errorf("%+v counts as valid", s)
		}
	}
	if !validSample(motionSample{X: 199, Y: -199, Z: 0}) {
		t.Error("a sample in range counts as not valid")
	}
}

// FuzzMotionBody checks that any flux.motion body decodes and runs through
// the model without a panic and without values out of range.
func FuzzMotionBody(f *testing.F) {
	f.Add(`{"samples":[{"t":1,"x":0.5,"y":-1,"z":0,"mount":"flat"}]}`)
	f.Add(`{"action":"vehicle","in":true}`)
	f.Add(`{"samples":[{"t":-9e18,"x":1e308,"mount":"upright"},{"t":9e18}]}`)
	f.Fuzz(func(t *testing.T, body string) {
		var b motionBody
		if json.Unmarshal([]byte(body), &b) != nil {
			return
		}
		m := newMotionModel(1.6)
		for _, s := range b.Samples {
			if !validSample(s) {
				continue
			}
			out := m.step(s)
			if math.Abs(out.OffsetX) > motionOffsetMax || math.Abs(out.OffsetY) > motionOffsetMax ||
				math.Abs(out.FlowX) > motionFlowMax || math.Abs(out.FlowY) > motionFlowMax ||
				out.Density < 0 || out.Density > 1 || math.IsNaN(out.OffsetX+out.OffsetY+out.FlowX+out.FlowY+out.Density) {
				t.Fatalf("targets out of range: %+v", out)
			}
		}
	})
}
