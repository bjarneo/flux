package core

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"slices"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// PhoneMedia is the state of the media player on a phone.
type PhoneMedia struct {
	Player   string   `json:"player"`
	Players  []string `json:"players"`
	Title    string   `json:"title"`
	Artist   string   `json:"artist"`
	Album    string   `json:"album"`
	Playing  bool     `json:"playing"`
	Position int64    `json:"position"` // ms
	Length   int64    `json:"length"`   // ms
	CanSeek  bool     `json:"canSeek"`
	Art      string   `json:"art,omitempty"`
	// Updated is the time in ms when Position was measured. The UI moves the
	// position bar forward from this time while the player plays.
	Updated int64 `json:"updated"`
	artURL  string
}

type mprisBody struct {
	PlayerList           []string `json:"playerList"`
	Player               string   `json:"player"`
	Title                *string  `json:"title"`
	Artist               *string  `json:"artist"`
	Album                *string  `json:"album"`
	IsPlaying            *bool    `json:"isPlaying"`
	Pos                  *int64   `json:"pos"`
	Length               *int64   `json:"length"`
	CanSeek              *bool    `json:"canSeek"`
	AlbumArtURL          string   `json:"albumArtUrl"`
	TransferringAlbumArt bool     `json:"transferringAlbumArt"`
}

// handlePhoneMedia updates the phone player state from a kdeconnect.mpris
// packet.
func (d *Daemon) handlePhoneMedia(dev *Device, l *lan.Link, p *proto.Packet) {
	var b mprisBody
	if p.Decode(&b) != nil {
		return
	}
	if b.TransferringAlbumArt && p.HasPayload() {
		go d.fetchArt(dev, l, p, b.AlbumArtURL)
		return
	}
	d.mu.Lock()
	m := dev.media
	if m == nil {
		m = &PhoneMedia{}
		dev.media = m
	}
	var request []string
	if b.PlayerList != nil {
		m.Players = b.PlayerList
		if len(b.PlayerList) == 0 {
			dev.media = nil
		} else if !slices.Contains(b.PlayerList, m.Player) {
			m.Player = b.PlayerList[0]
			request = append(request, m.Player)
		}
	}
	if b.Player != "" && b.Player == m.Player {
		if b.Title != nil {
			m.Title = *b.Title
		}
		if b.Artist != nil {
			m.Artist = *b.Artist
		}
		if b.Album != nil {
			m.Album = *b.Album
		}
		if b.IsPlaying != nil {
			m.Playing = *b.IsPlaying
		}
		if b.Pos != nil {
			m.Position = *b.Pos
		}
		if b.Length != nil {
			m.Length = *b.Length
		}
		if b.CanSeek != nil {
			m.CanSeek = *b.CanSeek
		}
		m.Updated = time.Now().UnixMilli()
		if b.AlbumArtURL != "" && b.AlbumArtURL != m.artURL {
			m.artURL = b.AlbumArtURL
			m.Art = cachedArt(b.AlbumArtURL)
			if m.Art == "" {
				_ = l.Send(proto.New(proto.TypeMprisRequest, map[string]any{"player": m.Player, "albumArtUrl": b.AlbumArtURL}))
			}
		}
	}
	d.mu.Unlock()
	for _, name := range request {
		_ = l.Send(proto.New(proto.TypeMprisRequest, map[string]any{"player": name, "requestNowPlaying": true, "requestVolume": true}))
	}
	d.markDirty()
}

func artPath(url string) string {
	sum := sha1.Sum([]byte(url))
	return filepath.Join(cacheDir(), "art", hex.EncodeToString(sum[:]))
}

func cachedArt(url string) string {
	p := artPath(url)
	if _, err := os.Stat(p); err == nil {
		return p
	}
	return ""
}

func (d *Daemon) fetchArt(dev *Device, l *lan.Link, p *proto.Packet, url string) {
	ctx, cancel := context.WithTimeout(d.ctx, 20*time.Second)
	defer cancel()
	rc, err := l.FetchPayload(ctx, p)
	if err != nil {
		return
	}
	defer rc.Close()
	path := artPath(url)
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	f, err := os.Create(path + ".part")
	if err != nil {
		return
	}
	_, err = io.Copy(f, io.LimitReader(rc, 16<<20))
	f.Close()
	if err != nil || os.Rename(path+".part", path) != nil {
		os.Remove(path + ".part")
		return
	}
	d.mu.Lock()
	if dev.media != nil && dev.media.artURL == url {
		dev.media.Art = path
	}
	d.mu.Unlock()
	d.markDirty()
}

// PhoneMediaAction controls the player on a phone.
func (d *Daemon) PhoneMediaAction(dev *Device, player, action string) error {
	switch action {
	case "PlayPause", "Play", "Pause", "Next", "Previous", "Stop":
	default:
		return apiErr("bad_action", "Unknown media action %q", action)
	}
	if player == "" {
		d.mu.Lock()
		if dev.media != nil {
			player = dev.media.Player
		}
		d.mu.Unlock()
	}
	return d.send(dev, proto.New(proto.TypeMprisRequest, map[string]any{"player": player, "action": action}))
}

// PhoneMediaSeek moves the phone player to a position in ms.
func (d *Daemon) PhoneMediaSeek(dev *Device, player string, position int64) error {
	return d.send(dev, proto.New(proto.TypeMprisRequest, map[string]any{"player": player, "SetPosition": position}))
}

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
		d.sendPlayerList(l)
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
	}
	if b.RequestNowPlaying || b.RequestVolume {
		d.sendNowPlaying(l, b.Player)
	}
}

func (d *Daemon) sendPlayerList(l *lan.Link) {
	names := []string{}
	for _, pl := range d.media.Players() {
		names = append(names, pl.Name)
	}
	_ = l.Send(proto.New(proto.TypeMpris, map[string]any{"playerList": names, "supportAlbumArtPayload": false}))
}

func (d *Daemon) sendNowPlaying(l *lan.Link, name string) {
	pl, ok := d.media.Player(name)
	if !ok {
		return
	}
	now := pl.Title
	if pl.Artist != "" {
		now = pl.Artist + " - " + pl.Title
	}
	_ = l.Send(proto.New(proto.TypeMpris, map[string]any{
		"player": pl.Name, "title": pl.Title, "artist": pl.Artist, "album": pl.Album,
		"nowPlaying": now, "isPlaying": pl.Playing, "pos": pl.Position, "length": pl.Length,
		"volume": pl.Volume, "canPlay": pl.CanPlay, "canPause": pl.CanPause,
		"canGoNext": pl.CanGoNext, "canGoPrevious": pl.CanGoPrevious, "canSeek": pl.CanSeek,
		"albumArtUrl": pl.ArtURL,
	}))
}

// onDesktopMediaChange pushes player changes on this computer to every
// paired device that controls media.
func (d *Daemon) onDesktopMediaChange(name string) {
	d.mu.Lock()
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.supports(proto.TypeMprisRequest) {
			links = append(links, dev.link)
		}
	}
	d.mu.Unlock()
	for _, l := range links {
		if name == "" {
			d.sendPlayerList(l)
		} else {
			d.sendNowPlaying(l, name)
		}
	}
}
