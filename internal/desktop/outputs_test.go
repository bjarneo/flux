package desktop

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// sinksJSON is the output of pactl --format=json list sinks on a laptop
// with an Omarchy speaker tuning, cut to the fields that Flux reads.
const sinksJSON = `[
 {"index": 40, "name": "omarchy_speaker_tuning", "description": "Laptop Speakers",
  "channel_map": "front-left,front-right", "mute": false,
  "volume": {"front-left": {"value": 65536, "value_percent": "100%"}, "front-right": {"value": 65536, "value_percent": "100%"}},
  "properties": {"object.id": "40"}, "ports": []},
 {"index": 53106, "name": "alsa_output.speaker", "description": "HD Audio Speaker",
  "channel_map": "front-left,front-right", "mute": false,
  "volume": {"front-left": {"value": 58982}, "front-right": {"value": 58982}},
  "properties": {"object.id": "32"}, "ports": [{"name": "[Out] Speaker", "availability": "availability unknown"}]},
 {"index": 53107, "name": "alsa_output.headphones", "description": "HD Audio Headphones",
  "channel_map": "front-left,front-right", "mute": true,
  "volume": {"front-left": {"value": 32768}, "front-right": {"value": 16384}},
  "properties": {"object.id": "105"}, "ports": [{"name": "[Out] Headphones", "availability": "not available"}]},
 {"index": 53108, "name": "alsa_output.hdmi", "description": "",
  "channel_map": "front-left,front-right", "mute": false,
  "volume": {"front-right": {"value": 19661}, "front-left": {"value": 39322}},
  "properties": {"object.id": "86", "device.description": "HDMI Monitor"},
  "ports": [{"availability": "not available"}, {"availability": "available"}]}
]`

func TestParseOutputs(t *testing.T) {
	outs, err := parseOutputs([]byte(sinksJSON), "omarchy_speaker_tuning", "alsa_output.speaker")
	if err != nil {
		t.Fatal(err)
	}
	// The speakers behind the tuning and the headphones that are not
	// plugged in stay out of the list.
	want := []Output{
		{Name: "omarchy_speaker_tuning", Description: "Laptop Speakers", Volume: 100, Default: true, channels: []int{65536, 65536}},
		{Name: "alsa_output.hdmi", Description: "HDMI Monitor", Volume: 60, channels: []int{39322, 19661}},
	}
	if !reflect.DeepEqual(outs, want) {
		t.Fatalf("got %+v\nwant %+v", outs, want)
	}

	// The default output shows also when its ports are not available.
	outs, err = parseOutputs([]byte(sinksJSON), "alsa_output.headphones", "")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, o := range outs {
		names = append(names, o.Name)
		if o.Name == "alsa_output.headphones" && (!o.Default || !o.Muted || o.Volume != 50) {
			t.Fatalf("headphones: %+v", o)
		}
	}
	if strings.Join(names, " ") != "omarchy_speaker_tuning alsa_output.speaker alsa_output.headphones alsa_output.hdmi" {
		t.Fatalf("outputs: %v", names)
	}

	if _, err := parseOutputs([]byte(`{"name":`), "", ""); err == nil {
		t.Fatal("a broken list must fail")
	}
	if outs, err := parseOutputs([]byte(`[]`), "", ""); err != nil || outs == nil || len(outs) != 0 {
		t.Fatalf("an empty list: %v, %v", outs, err)
	}
}

func TestVolumeArgs(t *testing.T) {
	cases := []struct {
		channels []int
		percent  int
		want     []string
	}{
		{[]int{65536, 65536}, 50, []string{"32768", "32768"}},
		// The quieter channel keeps its part of the loudest one.
		{[]int{65536, 32768}, 50, []string{"32768", "16384"}},
		{[]int{0, 0}, 25, []string{"16384"}},
		{nil, 100, []string{"65536"}},
		{[]int{65536}, 200, []string{"98304"}},
		{[]int{65536}, -5, []string{"0"}},
	}
	for _, c := range cases {
		if got := volumeArgs(c.channels, c.percent); !reflect.DeepEqual(got, c.want) {
			t.Errorf("volumeArgs(%v, %d) = %v, want %v", c.channels, c.percent, got, c.want)
		}
	}
}

// fakeOutputs returns Outputs that run no tool. It records each command,
// and answers the list and the default output from the fixture. tools
// are the commands on PATH.
func fakeOutputs(def string, tools ...string) (*Outputs, *[]string) {
	var ran []string
	o := &Outputs{
		look: func(name string) (string, error) {
			for _, t := range tools {
				if t == name {
					return "/usr/bin/" + name, nil
				}
			}
			return "", errors.New("not found")
		},
		run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			line := strings.TrimSpace(name + " " + strings.Join(args, " "))
			switch line {
			case "pactl --format=json list sinks":
				return []byte(sinksJSON), nil
			case "pactl get-default-sink":
				return []byte(def + "\n"), nil
			case "omarchy-audio-tuning fronted-sink":
				return []byte("alsa_output.speaker\n"), nil
			}
			ran = append(ran, line)
			return nil, nil
		},
	}
	return o, &ran
}

func TestOutputsList(t *testing.T) {
	o, _ := fakeOutputs("alsa_output.hdmi", "pactl", "omarchy-audio-tuning")
	outs, err := o.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(outs) != 2 || outs[1].Name != "alsa_output.hdmi" || !outs[1].Default || outs[0].Default {
		t.Fatalf("got %+v", outs)
	}
	// Without the Omarchy tool, the speakers show too.
	o, _ = fakeOutputs("alsa_output.hdmi", "pactl")
	if outs, _ = o.List(context.Background()); len(outs) != 3 {
		t.Fatalf("got %+v", outs)
	}
	o, _ = fakeOutputs("x")
	if _, err := o.List(context.Background()); !errors.Is(err, ErrNoPactl) {
		t.Fatalf("without pactl: %v", err)
	}
}

func TestOutputsChange(t *testing.T) {
	ctx := context.Background()
	o, ran := fakeOutputs("omarchy_speaker_tuning", "pactl")
	if err := o.SetVolume(ctx, "alsa_output.headphones", 100); err != nil {
		t.Fatal(err)
	}
	if err := o.SetMute(ctx, "alsa_output.hdmi", true); err != nil {
		t.Fatal(err)
	}
	if err := o.SetMute(ctx, "alsa_output.hdmi", false); err != nil {
		t.Fatal(err)
	}
	if err := o.SetDefault(ctx, "alsa_output.hdmi"); err != nil {
		t.Fatal(err)
	}
	if err := o.SetVolume(ctx, "missing", 10); err == nil {
		t.Fatal("an unknown output must fail")
	}
	want := []string{
		"pactl set-sink-volume alsa_output.headphones 65536 32768",
		"pactl set-sink-mute alsa_output.hdmi 1",
		"pactl set-sink-mute alsa_output.hdmi 0",
		"pactl set-default-sink alsa_output.hdmi",
	}
	if !reflect.DeepEqual(*ran, want) {
		t.Fatalf("ran %q\nwant %q", *ran, want)
	}
	if out, err := o.Find(ctx, "alsa_output.headphones"); err != nil || !out.Muted || out.Description != "HD Audio Headphones" {
		t.Fatalf("find: %+v, %v", out, err)
	}

	// On Omarchy, the Omarchy tool sets the default and moves the apps.
	o, ran = fakeOutputs("omarchy_speaker_tuning", "pactl", "omarchy-audio-output-set-default")
	if err := o.SetDefault(ctx, "alsa_output.hdmi"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(*ran, []string{"omarchy-audio-output-set-default 86 alsa_output.hdmi"}) {
		t.Fatalf("ran %q", *ran)
	}
}
