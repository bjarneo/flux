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
	if b["nowPlaying"] != "Band - Song" {
		t.Errorf("nowPlaying: got %v", b["nowPlaying"])
	}
	b = body(desktop.Player{Name: "chromium", Volume: 100})
	if _, ok := b["volume"]; ok {
		t.Errorf("a player that takes no volume sent %v", b["volume"])
	}
}
