package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// The audio outputs of this computer. Flux reads and changes them with
// pactl from libpulse, which talks to the PulseAudio server of PipeWire.
// Omarchy uses the same tool for its output menu. pactl names an output
// by its node name, which stays the same after a restart. wpctl names it
// by an object ID, which can change.

// outputTimeout limits each run of pactl and of the Omarchy audio tools.
const outputTimeout = 3 * time.Second

// maxOutputs is the largest number of outputs that List returns.
const maxOutputs = 32

// fullVolume is the raw PulseAudio volume of 100%.
const fullVolume = 65536

// ErrNoPactl tells the user to install pactl.
var ErrNoPactl = errors.New("the audio outputs need pactl on the computer. Install it with: sudo pacman -S libpulse")

// Output is 1 audio output of this computer, a PulseAudio sink.
type Output struct {
	// Name is the node name, for example
	// alsa_output.pci-0000_00_1f.3.analog-stereo.
	Name string
	// Description is the name that the user sees, for example "Laptop
	// Speakers".
	Description string
	// Volume is the volume of the loudest channel, in percent. It can be
	// more than 100.
	Volume int
	Muted  bool
	// Default is true for the output that apps play to.
	Default bool

	// channels holds the raw volume of each channel, in the order of the
	// channel map.
	channels []int
}

// Outputs reads and changes the audio outputs.
type Outputs struct {
	// run runs a command and returns its standard output. Tests give a
	// fake.
	run func(ctx context.Context, name string, args ...string) ([]byte, error)
	// look finds a command on PATH.
	look func(name string) (string, error)
}

// NewOutputs returns the audio outputs of this computer.
func NewOutputs() *Outputs {
	return &Outputs{run: runOutputCommand, look: exec.LookPath}
}

// runOutputCommand runs a tool in the C locale. pactl translates the
// availability of a port also in JSON.
func runOutputCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, outputTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	cmd.WaitDelay = time.Second
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return out, fmt.Errorf("%s: %s", name, lastOutputLine(msg))
		}
		return out, fmt.Errorf("%s: %w", name, err)
	}
	return out, nil
}

func lastOutputLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// pactl runs pactl, or returns ErrNoPactl when it is not installed.
func (o *Outputs) pactl(ctx context.Context, args ...string) ([]byte, error) {
	if _, err := o.look("pactl"); err != nil {
		return nil, ErrNoPactl
	}
	return o.run(ctx, "pactl", args...)
}

// List returns the outputs that a user can select, in the order of
// pactl. Like the output menu of Omarchy, it leaves out an output whose
// ports are all not available, such as headphones that are not plugged
// in, and the speakers behind an Omarchy speaker tuning. The default
// output is always in the list.
func (o *Outputs) List(ctx context.Context) ([]Output, error) {
	out, err := o.pactl(ctx, "--format=json", "list", "sinks")
	if err != nil {
		return nil, err
	}
	def, err := o.Default(ctx)
	if err != nil {
		return nil, err
	}
	fronted := ""
	if _, err := o.look("omarchy-audio-tuning"); err == nil {
		if b, err := o.run(ctx, "omarchy-audio-tuning", "fronted-sink"); err == nil {
			fronted = strings.TrimSpace(string(b))
		}
	}
	return parseOutputs(out, def, fronted)
}

// Default returns the name of the default output.
func (o *Outputs) Default(ctx context.Context) (string, error) {
	out, err := o.pactl(ctx, "get-default-sink")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// SetDefault makes the output the default. On Omarchy,
// omarchy-audio-output-set-default also moves the apps that play now to
// the output, as the Omarchy output menu does.
func (o *Outputs) SetDefault(ctx context.Context, name string) error {
	if _, err := o.look("omarchy-audio-output-set-default"); err == nil {
		if id, err := o.objectID(ctx, name); err == nil {
			_, err = o.run(ctx, "omarchy-audio-output-set-default", strconv.Itoa(id), name)
			return err
		}
	}
	_, err := o.pactl(ctx, "set-default-sink", name)
	return err
}

// SetVolume sets the volume of the output, in percent from 0 to 150. The
// loudest channel gets the volume, and the other channels keep their
// part of it, so the balance stays.
func (o *Outputs) SetVolume(ctx context.Context, name string, percent int) error {
	s, err := o.Find(ctx, name)
	if err != nil {
		return err
	}
	args := append([]string{"set-sink-volume", name}, volumeArgs(s.channels, percent)...)
	_, err = o.pactl(ctx, args...)
	return err
}

// SetMute mutes the output or turns its sound on again.
func (o *Outputs) SetMute(ctx context.Context, name string, muted bool) error {
	v := "0"
	if muted {
		v = "1"
	}
	_, err := o.pactl(ctx, "set-sink-mute", name, v)
	return err
}

// Find returns the output with the name, also when List leaves it out.
// Default is false in the result.
func (o *Outputs) Find(ctx context.Context, name string) (Output, error) {
	out, err := o.pactl(ctx, "--format=json", "list", "sinks")
	if err != nil {
		return Output{}, err
	}
	sinks, err := decodeSinks(out)
	if err != nil {
		return Output{}, err
	}
	for _, s := range sinks {
		if s.Name == name {
			return s.output(), nil
		}
	}
	return Output{}, fmt.Errorf("the computer has no audio output %q", name)
}

// objectID returns the PipeWire object ID of the output.
func (o *Outputs) objectID(ctx context.Context, name string) (int, error) {
	out, err := o.pactl(ctx, "--format=json", "list", "sinks")
	if err != nil {
		return 0, err
	}
	sinks, err := decodeSinks(out)
	if err != nil {
		return 0, err
	}
	for _, s := range sinks {
		if s.Name == name {
			return strconv.Atoi(s.Properties["object.id"])
		}
	}
	return 0, fmt.Errorf("the computer has no audio output %q", name)
}

// sink is 1 sink in the output of pactl --format=json list sinks.
type sink struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	ChannelMap  string `json:"channel_map"`
	Mute        bool   `json:"mute"`
	Volume      map[string]struct {
		Value int `json:"value"`
	} `json:"volume"`
	Ports []struct {
		Availability string `json:"availability"`
	} `json:"ports"`
	Properties map[string]string `json:"properties"`
}

func decodeSinks(data []byte) ([]sink, error) {
	var sinks []sink
	if err := json.Unmarshal(data, &sinks); err != nil {
		return nil, fmt.Errorf("read the audio outputs: %w", err)
	}
	return sinks, nil
}

// output returns the sink as an Output. The channels follow the channel
// map, because a JSON object has no order.
func (s sink) output() Output {
	o := Output{Name: s.Name, Description: s.Description, Muted: s.Mute}
	if o.Description == "" {
		o.Description = s.Properties["device.description"]
	}
	if o.Description == "" {
		o.Description = s.Name
	}
	names := strings.Split(s.ChannelMap, ",")
	if s.ChannelMap == "" || len(names) != len(s.Volume) {
		names = names[:0]
		for n := range s.Volume {
			names = append(names, n)
		}
	}
	for _, n := range names {
		v, ok := s.Volume[n]
		if !ok {
			continue
		}
		o.channels = append(o.channels, v.Value)
		o.Volume = max(o.Volume, percentOf(v.Value))
	}
	return o
}

// available reports whether a user can select the sink: it has no ports,
// or at least 1 port that is not "not available".
func (s sink) available() bool {
	if len(s.Ports) == 0 {
		return true
	}
	for _, p := range s.Ports {
		if p.Availability != "not available" {
			return true
		}
	}
	return false
}

// parseOutputs returns the outputs in the output of pactl --format=json
// list sinks. def is the default output, and fronted is the output behind
// an Omarchy speaker tuning, or "".
func parseOutputs(data []byte, def, fronted string) ([]Output, error) {
	sinks, err := decodeSinks(data)
	if err != nil {
		return nil, err
	}
	outs := []Output{}
	for _, s := range sinks {
		if s.Name == "" {
			continue
		}
		if s.Name != def && (!s.available() || s.Name == fronted) {
			continue
		}
		o := s.output()
		o.Default = s.Name == def
		outs = append(outs, o)
		if len(outs) == maxOutputs {
			break
		}
	}
	return outs, nil
}

// percentOf returns a raw volume in percent.
func percentOf(raw int) int {
	return int(math.Round(float64(raw) * 100 / fullVolume))
}

// volumeArgs returns the raw volume of each channel for a volume of
// percent on the loudest channel. The other channels keep their part of
// the loudest one. Without channels, it returns 1 value for all.
func volumeArgs(channels []int, percent int) []string {
	percent = max(0, min(150, percent))
	target := int(math.Round(float64(percent) * fullVolume / 100))
	loudest := 0
	for _, c := range channels {
		loudest = max(loudest, c)
	}
	if len(channels) == 0 || loudest == 0 {
		return []string{strconv.Itoa(target)}
	}
	args := make([]string, len(channels))
	for i, c := range channels {
		args[i] = strconv.Itoa(int(math.Round(float64(c) * float64(target) / float64(loudest))))
	}
	return args
}
