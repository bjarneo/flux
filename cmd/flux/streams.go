package main

import (
	"fmt"
)

// mic shows the phone microphone state, or stops it.
func mic(args []string) error {
	if first(args) == "stop" {
		return call("mic.stop", nil)
	}
	var s struct {
		Mic *struct {
			Active   bool   `json:"active"`
			Source   string `json:"source"`
			FromName string `json:"fromName"`
			Rate     int    `json:"rate"`
			Channels int    `json:"channels"`
			Error    string `json:"error"`
		} `json:"mic"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	m := s.Mic
	switch {
	case m == nil:
		fmt.Println("No phone microphone. Start it in Flux for Android: Microphone, then Start.")
	case m.Error != "":
		fmt.Println("The phone microphone failed:", m.Error)
	case m.Active:
		fmt.Printf("%s is live as %s, %d Hz, %s\n", m.FromName, m.Source, m.Rate, channelsName(m.Channels))
	default:
		fmt.Printf("%s is starting as %s\n", m.FromName, m.Source)
	}
	return nil
}

func channelsName(n int) string {
	if n == 2 {
		return "stereo"
	}
	return "mono"
}

// screen shows the screen mirror state, or stops it.
func screen(args []string) error {
	if first(args) == "stop" {
		return call("screen.stop", nil)
	}
	var s struct {
		Screen *struct {
			Active   bool   `json:"active"`
			FromName string `json:"fromName"`
			Width    int    `json:"width"`
			Height   int    `json:"height"`
			Player   string `json:"player"`
			Error    string `json:"error"`
		} `json:"screen"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	v := s.Screen
	switch {
	case v == nil:
		fmt.Println("No phone screen. Start it in Flux for Android: Mirror screen.")
	case v.Error != "":
		fmt.Println("The screen mirror failed:", v.Error)
	case v.Active:
		fmt.Printf("%s shows its screen in %s, %dx%d\n", v.FromName, v.Player, v.Width, v.Height)
	default:
		fmt.Printf("%s is starting its screen mirror\n", v.FromName)
	}
	return nil
}
