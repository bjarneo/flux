package core

import (
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// Media goes one way. A paired device controls the players on this
// computer. fluxd does not show or control the players of a device.

// maxMediaJobs is the number of media requests and call events that can
// wait for the media worker.
const maxMediaJobs = 32

// runMedia runs a media request or a call event on the media worker. The
// worker runs the jobs in order. The D-Bus calls to the players then do
// not stop the read loop of a device.
func (d *Daemon) runMedia(job func()) {
	if !d.runContent(&d.content.mediaQ, maxMediaJobs, job) {
		d.logf("the media players are slow: dropped a media request")
	}
}

// mediaRequest is the body of a flux.mpris.request packet.
type mediaRequest struct {
	RequestPlayerList bool   `json:"requestPlayerList"`
	Player            string `json:"player"`
	RequestNowPlaying bool   `json:"requestNowPlaying"`
	RequestVolume     bool   `json:"requestVolume"`
	Action            string `json:"action"`
	SetPosition       *int64 `json:"SetPosition"`
	SetVolume         *int   `json:"setVolume"`
}

// handleDesktopMediaRequest lets a phone control the players on this
// computer.
func (d *Daemon) handleDesktopMediaRequest(l *lan.Link, p *proto.Packet) {
	if d.media == nil {
		return
	}
	var b mediaRequest
	if p.Decode(&b) != nil {
		return
	}
	d.runMedia(func() { d.answerMedia(l, b) })
}

// answerMedia runs 1 media request of a phone. A request waits on the
// worker, so it runs only while l is still the link of a paired device.
func (d *Daemon) answerMedia(l *lan.Link, b mediaRequest) {
	if !d.isPairedLink(l) {
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

// isPairedLink reports whether l is the current link of a paired device.
func (d *Daemon) isPairedLink(l *lan.Link) bool {
	if l == nil {
		return false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, dev := range d.devices {
		if dev.link == l {
			return dev.Paired
		}
	}
	return false
}

// sendPlayers sends the player list and the state of each player to the
// links. The phone then selects the player that plays.
func (d *Daemon) sendPlayers(links ...*lan.Link) {
	players := d.media.Players()
	names := make([]string, 0, len(players))
	for _, pl := range players {
		names = append(names, pl.Name)
	}
	packets := []*proto.Packet{proto.New(proto.TypeMpris, map[string]any{"playerList": names})}
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

// nowPlaying returns the flux.mpris packet with the state of a
// player.
func nowPlaying(pl desktop.Player) *proto.Packet {
	body := map[string]any{
		"player": pl.Name, "title": pl.Title, "artist": pl.Artist, "album": pl.Album,
		"isPlaying": pl.Playing, "pos": pl.Position, "length": pl.Length,
		"canGoNext": pl.CanGoNext, "canGoPrevious": pl.CanGoPrevious, "canSeek": pl.CanSeek,
		"albumArtUrl": "",
	}
	// A file: URL shows a local path and the user name to the device. Only
	// a web URL goes out.
	if art, ok := webURL(pl.ArtURL); ok {
		body["albumArtUrl"] = art
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
