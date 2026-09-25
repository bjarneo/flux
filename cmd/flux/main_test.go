package main

import "testing"

func TestWebcamSettings(t *testing.T) {
	cfg, err := webcamSettings([]string{"aspect=1:1", "resolution=1080", "mirror=true", "brightness=-0.2", "whiteBalance=daylight"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg["aspect"] != "1:1" || cfg["resolution"] != 1080.0 || cfg["mirror"] != true || cfg["brightness"] != -0.2 || cfg["whiteBalance"] != "daylight" {
		t.Fatalf("settings: %#v", cfg)
	}
	if _, err := webcamSettings([]string{"aspect"}); err == nil {
		t.Fatal("a setting without = must fail")
	}
	if _, err := webcamSettings([]string{"white_balance=daylight"}); err == nil {
		t.Fatal("an unknown setting must fail")
	}
}
