package core

import (
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// Media goes one way. A paired device controls the players on this
// computer. fluxd does not show or control the players of a device.

// handleDesktopMediaRequest lets a phone control the players on this
// computer.
func (d *Daemon) handleDesktopMediaRequest(l *lan.Link, p *proto.Packet) {
	if d.media == nil {
		return
	}
	var b struct {
		RequestPlayerList bool   `json:"requestPlayerList"`
		Player            string `json:"player"`
		RequestNowPlaying bool   `json:"requestNowPlaying"`
		RequestVolume     bool   `json:"requestVolume"`
		Action            string `json:"action"`
		Seek              *int64 `json:"Seek"`
		SetPosition       *int64 `json:"SetPosition"`
		SetVolume         *int   `json:"setVolume"`
	}
	if p.Decode(&b) != nil {
		return
	}
	if b.RequestPlayerList {
		d.sendPlayers(l)
	}
	if b.Player == "" {
		return
	}
	var err error
	switch {
	case b.Action != "":
		err = d.media.Action(b.Player, b.Action)
	case b.Seek != nil:
		err = d.media.Seek(b.Player, *b.Seek)
	case b.SetPosition != nil:
		err = d.media.SetPosition(b.Player, *b.SetPosition)
	case b.SetVolume != nil:
		err = d.media.SetVolume(b.Player, *b.SetVolume)
	}
	if err != nil {
		d.logf("media %s: %v", b.Player, err)
		// A phone shows a change before the player confirms it. Send the
		// state again, so that each phone drops a change that failed.
		d.onDesktopMediaChange(b.Player)
	} else if b.RequestNowPlaying || b.RequestVolume {
		d.sendNowPlaying(l, b.Player)
	}
}

// sendPlayers sends the player list and the state of each player to the
// links. The phone then selects the player that plays.
func (d *Daemon) sendPlayers(links ...*lan.Link) {
	players := d.media.Players()
	names := make([]string, 0, len(players))
	for _, pl := range players {
		names = append(names, pl.Name)
	}
	packets := []*proto.Packet{proto.New(proto.TypeMpris, map[string]any{"playerList": names, "supportAlbumArtPayload": false})}
	for _, pl := range players {
		packets = append(packets, nowPlaying(pl))
	}
	for _, l := range links {
		for _, p := range packets {
			_ = l.Send(p)
		}
	}
}

func (d *Daemon) sendNowPlaying(l *lan.Link, name string) {
	if pl, ok := d.media.Player(name); ok {
		_ = l.Send(nowPlaying(pl))
	}
}

// nowPlaying returns the kdeconnect.mpris packet with the state of a
// player.
func nowPlaying(pl desktop.Player) *proto.Packet {
	now := pl.Title
	if pl.Artist != "" {
		now = pl.Artist + " - " + pl.Title
	}
	body := map[string]any{
		"player": pl.Name, "title": pl.Title, "artist": pl.Artist, "album": pl.Album,
		"nowPlaying": now, "isPlaying": pl.Playing, "pos": pl.Position, "length": pl.Length,
		"canPlay": pl.CanPlay, "canPause": pl.CanPause,
		"canGoNext": pl.CanGoNext, "canGoPrevious": pl.CanGoPrevious, "canSeek": pl.CanSeek,
		"albumArtUrl": pl.ArtURL,
	}
	// The phone shows a volume control only when the packet has a volume.
	if pl.CanSetVolume {
		body["volume"] = pl.Volume
	}
	return proto.New(proto.TypeMpris, body)
}

// mediaLinks returns the links of the paired devices that control the
// players on this computer.
func (d *Daemon) mediaLinks() []*lan.Link {
	d.mu.Lock()
	defer d.mu.Unlock()
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.supports(proto.TypeMprisRequest) {
			links = append(links, dev.link)
		}
	}
	return links
}

// onDesktopMediaChange pushes player changes on this computer to every
// paired device that controls media. The name is empty when a player
// starts or stops.
func (d *Daemon) onDesktopMediaChange(name string) {
	links := d.mediaLinks()
	if len(links) == 0 {
		return
	}
	if name == "" {
		d.sendPlayers(links...)
		return
	}
	pl, ok := d.media.Player(name)
	if !ok {
		return
	}
	p := nowPlaying(pl)
	for _, l := range links {
		_ = l.Send(p)
	}
}
