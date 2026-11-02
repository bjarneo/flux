package main

import (
	"fmt"
	"strconv"
	"strings"
)

const motionUsage = "Usage: flux-cli motion [on|off|start|stop|auto on|off|sensitivity 0.5|1|1.6|size small|medium|large|idle SECONDS]"

// motionStatus is the part of the state that `flux-cli motion` prints.
type motionStatus struct {
	Settings struct {
		MotionCues        bool    `json:"motionCues"`
		MotionAuto        bool    `json:"motionAuto"`
		MotionSensitivity float64 `json:"motionSensitivity"`
		MotionSize        string  `json:"motionSize"`
		MotionIdle        int     `json:"motionIdle"`
	} `json:"settings"`
	Motion struct {
		Running    bool   `json:"running"`
		DeviceName string `json:"deviceName"`
		Auto       bool   `json:"auto"`
		Active     bool   `json:"active"`
		Error      string `json:"error"`
	} `json:"motion"`
}

// motion turns motion cues on or off, starts or stops them, changes their
// settings, or shows their state.
func motion(args []string, device string) error {
	set := func(key string, value any) error {
		return call("settings.set", map[string]any{"key": key, "value": value})
	}
	second := ""
	if len(args) > 1 {
		second = args[1]
	}
	switch first(args) {
	case "on":
		if err := set("motionCues", true); err != nil {
			return err
		}
		fmt.Println("Motion cues are on. A paired phone can send its motion. Start them with: flux-cli motion start")
		fmt.Println("Motion cues are experimental and not medical advice. Use them as a passenger only.")
		return nil
	case "off":
		if err := set("motionCues", false); err != nil {
			return err
		}
		fmt.Println("Motion cues are off.")
		return nil
	case "start":
		if err := call("motion.start", map[string]any{"device": device}); err != nil {
			return err
		}
		fmt.Println("Asked the phone to send its motion. The dots show when the first motion arrives.")
		return nil
	case "stop":
		if err := call("motion.stop", nil); err != nil {
			return err
		}
		fmt.Println("Motion cues stopped.")
		return nil
	case "auto":
		if second != "on" && second != "off" {
			return fmt.Errorf("%s", motionUsage)
		}
		if err := set("motionAuto", second == "on"); err != nil {
			return err
		}
		fmt.Printf("Automatic start is %s.\n", second)
		return nil
	case "sensitivity":
		v, err := strconv.ParseFloat(second, 64)
		if err != nil {
			return fmt.Errorf("%s", motionUsage)
		}
		return set("motionSensitivity", v)
	case "size":
		return set("motionSize", strings.ToLower(second))
	case "idle":
		v, err := strconv.Atoi(second)
		if err != nil {
			return fmt.Errorf("%s", motionUsage)
		}
		return set("motionIdle", v)
	case "", "status":
	default:
		return fmt.Errorf("unknown argument %q. %s", first(args), motionUsage)
	}
	var s motionStatus
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	fmt.Print(motionText(s))
	return nil
}

// motionText returns the text of `flux-cli motion`.
func motionText(s motionStatus) string {
	var b strings.Builder
	if !s.Settings.MotionCues {
		b.WriteString("Motion cues are off. Turn them on with: flux-cli motion on\n")
		return b.String()
	}
	switch {
	case s.Motion.Running && s.Motion.Active:
		fmt.Fprintf(&b, "Motion cues show the motion of %s.\n", s.Motion.DeviceName)
	case s.Motion.Running:
		fmt.Fprintf(&b, "Motion cues wait for the motion of %s.\n", s.Motion.DeviceName)
	default:
		b.WriteString("Motion cues are on and stopped. Start them with: flux-cli motion start\n")
	}
	if s.Motion.Error != "" {
		fmt.Fprintf(&b, "Last phone error: %s\n", s.Motion.Error)
	}
	auto := "off"
	if s.Settings.MotionAuto {
		auto = "on, when the phone detects a vehicle"
	}
	fmt.Fprintf(&b, "Automatic start: %s\n", auto)
	fmt.Fprintf(&b, "Sensitivity: %g\nSize: %s\nIdle stop: %d seconds\n", s.Settings.MotionSensitivity, s.Settings.MotionSize, s.Settings.MotionIdle)
	return b.String()
}
