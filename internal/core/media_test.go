package core

import (
	"encoding/json"
	"testing"

	"flux/internal/desktop"
)

func TestNowPlayingSendsVolumeOnlyWhenPlayerTakesIt(t *testing.T) {
	body := func(pl desktop.Player) map[string]any {
		var b map[string]any
		if err := json.Unmarshal(nowPlaying(pl).Body, &b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	b := body(desktop.Player{Name: "spotify", Title: "Song", Artist: "Band", Volume: 40, CanSetVolume: true})
	if b["volume"] != float64(40) {
		t.Errorf("volume: got %v, want 40", b["volume"])
	}
	b = body(desktop.Player{Name: "chromium", Volume: 100})
	if _, ok := b["volume"]; ok {
		t.Errorf("a player that takes no volume sent %v", b["volume"])
	}
}

func TestNowPlayingSendsOnlyWebArt(t *testing.T) {
	art := func(url string) any {
		var b map[string]any
		if err := json.Unmarshal(nowPlaying(desktop.Player{Name: "mpv", ArtURL: url}).Body, &b); err != nil {
			t.Fatal(err)
		}
		return b["albumArtUrl"]
	}
	if got := art("https://i.scdn.co/image/ab67616d"); got != "https://i.scdn.co/image/ab67616d" {
		t.Errorf("web art %v", got)
	}
	for _, url := range []string{"file:///home/u/.cache/mpv/cover.jpg", "/home/u/cover.jpg", "data:image/png;base64,AAAA"} {
		if got := art(url); got != "" {
			t.Errorf("%s went out as %v", url, got)
		}
	}
}
