package core

import "math"

// The motion model turns the acceleration of the phone into the targets of
// the motion cues that the omarchy-shell plugin draws. The dots move
// against the motion of the vehicle, as the content would if it had mass:
// a left turn moves them right, and a start moves them down, toward the
// passenger. Screen x grows to the right and screen y grows down.

// motionSample is 1 acceleration reading of the phone, gravity removed, in
// m/s² and in the device axes of Android. T is a monotonic time in ms.
type motionSample struct {
	T     int64   `json:"t"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	Z     float64 `json:"z"`
	Mount string  `json:"mount"`
}

// motionTargets are the values that the overlay animates toward.
type motionTargets struct {
	// OffsetX and OffsetY move all dots, in logical pixels.
	OffsetX float64 `json:"offsetX"`
	OffsetY float64 `json:"offsetY"`
	// FlowX and FlowY are the drift speeds of the dots, in logical pixels
	// per second.
	FlowX float64 `json:"flowX"`
	FlowY float64 `json:"flowY"`
	// Density is from 0 to 1. It shows the extra dots.
	Density float64 `json:"density"`
}

// Model constants. They follow omarchy-motion-cues.
const (
	motionQuiet      = 0.045 // m/s² below which an axis counts as 0
	motionFlowQuiet  = 0.12  // m/s² below which the flow stops
	motionOffsetGain = 30    // px for each m/s²
	motionOffsetMax  = 46    // px
	motionOffsetTau  = 0.13  // s
	motionFlowGain   = 75    // px/s for each m/s²
	motionFlowMax    = 180   // px/s
	motionFlowTau    = 0.22  // s
	motionAttackTau  = 0.18  // s
	motionReleaseTau = 0.55  // s
	motionMaxStrain  = 6     // m/s²
	motionRampWidth  = 0.45  // m/s²
	motionMinDt      = 0.001 // s
	motionMaxDt      = 0.15  // s
	// motionMaxValue is the largest acceleration that a sample can have.
	// A larger value is a sensor error.
	motionMaxValue = 200
)

// motionSteps are the strengths at which the 5 groups of extra dots show.
var motionSteps = [5]float64{0.8, 1.3, 1.9, 2.6, 3.4}

// motionModel keeps the smoothed state between samples.
type motionModel struct {
	scale    float64
	started  bool
	lastT    int64
	offX     float64
	offY     float64
	flowX    float64
	flowY    float64
	strength float64
}

func newMotionModel(scale float64) *motionModel {
	return &motionModel{scale: scale}
}

// validSample reports whether s has finite values within the sensor range.
func validSample(s motionSample) bool {
	for _, v := range [3]float64{s.X, s.Y, s.Z} {
		if math.IsNaN(v) || math.IsInf(v, 0) || math.Abs(v) > motionMaxValue {
			return false
		}
	}
	return true
}

// axes returns the lateral, forward, and vertical acceleration for the
// mount. "flat" is a phone that lies screen up with its top forward.
// "upright" is a phone in a holder, screen to the passenger, top up.
func (s motionSample) axes() (lateral, forward, vertical float64) {
	if s.Mount == "upright" {
		return s.X, -s.Z, s.Y
	}
	return s.X, s.Y, s.Z
}

func quiet(v float64) float64 {
	if math.Abs(v) < motionQuiet {
		return 0
	}
	return v
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }

// approach moves v toward target with the time constant tau.
func approach(v, target, dt, tau float64) float64 {
	return v + (target-v)*(1-math.Exp(-dt/tau))
}

func smoothstep(e0, e1, x float64) float64 {
	t := clamp((x-e0)/(e1-e0), 0, 1)
	return t * t * (3 - 2*t)
}

// reset forgets the smoothed state. The next sample starts again from rest.
func (m *motionModel) reset() {
	*m = motionModel{scale: m.scale}
}

// step adds 1 sample and returns the new targets. A sample with a time
// that goes back starts the model again, for example after the phone
// restarted its sensor.
func (m *motionModel) step(s motionSample) motionTargets {
	if m.started && s.T < m.lastT {
		m.reset()
	}
	dt := motionMaxDt
	if m.started {
		dt = clamp(float64(s.T-m.lastT)/1000, motionMinDt, motionMaxDt)
	}
	m.started, m.lastT = true, s.T

	lat, fwd, vert := s.axes()
	lat, fwd, vert = quiet(lat), quiet(fwd), quiet(vert)
	k := m.scale

	m.offX = approach(m.offX, clamp(-lat*motionOffsetGain*k, -motionOffsetMax, motionOffsetMax), dt, motionOffsetTau)
	m.offY = approach(m.offY, clamp(fwd*motionOffsetGain*k, -motionOffsetMax, motionOffsetMax), dt, motionOffsetTau)

	flowX, flowY := 0.0, 0.0
	if math.Hypot(lat, fwd) >= motionFlowQuiet {
		flowX = clamp(-lat*motionFlowGain*k, -motionFlowMax, motionFlowMax)
		flowY = clamp(fwd*motionFlowGain*k, -motionFlowMax, motionFlowMax)
	}
	m.flowX = approach(m.flowX, flowX, dt, motionFlowTau)
	m.flowY = approach(m.flowY, flowY, dt, motionFlowTau)

	strength := math.Min(motionMaxStrain, math.Sqrt(lat*lat+fwd*fwd+vert*vert)*k)
	tau := motionReleaseTau
	if strength > m.strength {
		tau = motionAttackTau
	}
	m.strength = approach(m.strength, strength, dt, tau)
	return m.targets()
}

// moving reports whether s has enough motion to keep the cues on.
func (s motionSample) moving() bool {
	lat, fwd, vert := s.axes()
	return math.Sqrt(lat*lat+fwd*fwd+vert*vert) >= motionFlowQuiet
}

func (m *motionModel) targets() motionTargets {
	density := 0.0
	for _, at := range motionSteps {
		density += smoothstep(at-motionRampWidth/2, at+motionRampWidth/2, m.strength)
	}
	round := func(v float64) float64 { return math.Round(v*4) / 4 }
	return motionTargets{
		OffsetX: round(m.offX),
		OffsetY: round(m.offY),
		FlowX:   round(m.flowX),
		FlowY:   round(m.flowY),
		Density: math.Round(density/float64(len(motionSteps))*1000) / 1000,
	}
}
