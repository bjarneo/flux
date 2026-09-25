package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxNotifications is the number of phone notifications kept per device.
const maxNotifications = 100

// PhoneNotification is a notification that a phone shares.
type PhoneNotification struct {
	ID      string   `json:"id"`
	App     string   `json:"app"`
	Title   string   `json:"title"`
	Text    string   `json:"text"`
	Time    int64    `json:"time"`
	ReplyID string   `json:"replyId"`
	Actions []string `json:"actions"`
	Clear   bool     `json:"dismissable"`
	Icon    string   `json:"icon,omitempty"`
}

// flexString decodes a JSON string, number, or boolean as a string.
type flexString string

func (f *flexString) UnmarshalJSON(b []byte) error {
	var s string
	if json.Unmarshal(b, &s) == nil {
		*f = flexString(s)
		return nil
	}
	*f = flexString(strings.Trim(string(b), `"`))
	return nil
}

func (f flexString) bool() bool { return f == "true" || f == "1" }

func (d *Daemon) handleNotification(dev *Device, l *lan.Link, p *proto.Packet) {
	var b struct {
		ID          string     `json:"id"`
		AppName     string     `json:"appName"`
		Ticker      string     `json:"ticker"`
		Title       string     `json:"title"`
		Text        string     `json:"text"`
		Time        flexString `json:"time"`
		IsCancel    flexString `json:"isCancel"`
		IsClearable flexString `json:"isClearable"`
		Silent      flexString `json:"silent"`
		OnlyOnce    flexString `json:"onlyOnce"`
		ReplyID     string     `json:"requestReplyId"`
		Actions     []string   `json:"actions"`
		PayloadHash string     `json:"payloadHash"`
	}
	if p.Decode(&b) != nil || b.ID == "" {
		return
	}
	if b.IsCancel.bool() {
		d.mu.Lock()
		dev.notifications = removeNotification(dev.notifications, b.ID)
		deskID := dev.notifDesktop[b.ID]
		delete(dev.notifDesktop, b.ID)
		d.mu.Unlock()
		if deskID != 0 && d.notifier != nil {
			_ = d.notifier.Close(deskID)
		}
		d.markDirty()
		return
	}
	title, text := b.Title, b.Text
	if title == "" && text == "" {
		title = b.Ticker
	}
	ms, _ := strconv.ParseInt(string(b.Time), 10, 64)
	n := &PhoneNotification{
		ID: b.ID, App: b.AppName, Title: title, Text: text, Time: ms / 1000,
		ReplyID: b.ReplyID, Actions: b.Actions, Clear: b.IsClearable.bool() || b.IsClearable == "",
	}
	if n.Time == 0 {
		n.Time = time.Now().Unix()
	}
	if n.Actions == nil {
		n.Actions = []string{}
	}
	d.mu.Lock()
	_, seen := dev.notifDesktop[b.ID]
	existing := findNotification(dev.notifications, b.ID)
	dev.notifications = removeNotification(dev.notifications, b.ID)
	dev.notifications = append([]*PhoneNotification{n}, dev.notifications...)
	if len(dev.notifications) > maxNotifications {
		dev.notifications = dev.notifications[:maxNotifications]
	}
	if existing != nil {
		n.Icon = existing.Icon
	}
	show := d.cfg.Notifications && !b.Silent.bool() && !(seen && b.OnlyOnce.bool())
	replaces := dev.notifDesktop[b.ID]
	d.mu.Unlock()
	d.markDirty()

	go func() {
		if p.HasPayload() && n.Icon == "" {
			if path := d.fetchIcon(l, p, b.PayloadHash); path != "" {
				d.mu.Lock()
				n.Icon = path
				d.mu.Unlock()
				d.markDirty()
			}
		}
		if !show {
			return
		}
		var actions []desktop.Action
		for _, a := range n.Actions {
			actions = append(actions, desktop.Action{Key: "notif-action:" + dev.ID + ":" + b64(n.ID) + ":" + b64(a), Label: a})
		}
		if n.Clear {
			actions = append(actions, desktop.Action{Key: "notif-dismiss:" + dev.ID + ":" + b64(n.ID), Label: "Dismiss on phone"})
		}
		app := n.App
		if app == "" {
			app = dev.Name
		}
		id := d.notify(desktop.Notification{
			AppName: app + " · " + dev.Name, Title: n.Title, Body: n.Text,
			IconPath: n.Icon, Actions: actions, ReplacesID: replaces,
		})
		if id != 0 {
			d.mu.Lock()
			dev.notifDesktop[n.ID] = id
			d.mu.Unlock()
		}
	}()
}

var hashRe = regexp.MustCompile(`^[a-zA-Z0-9]{1,128}$`)

// fetchIcon downloads a notification icon into the cache. It returns the
// path, or "" when the download fails.
func (d *Daemon) fetchIcon(l *lan.Link, p *proto.Packet, hash string) string {
	if !hashRe.MatchString(hash) {
		hash = strconv.FormatInt(int64(p.ID), 10)
	}
	dir := filepath.Join(cacheDir(), "icons")
	path := filepath.Join(dir, hash+".png")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	ctx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
	defer cancel()
	rc, err := l.FetchPayload(ctx, p)
	if err != nil {
		return ""
	}
	defer rc.Close()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return ""
	}
	f, err := os.Create(path + ".part")
	if err != nil {
		return ""
	}
	_, err = io.Copy(f, io.LimitReader(rc, 4<<20))
	f.Close()
	if err != nil {
		os.Remove(path + ".part")
		return ""
	}
	if os.Rename(path+".part", path) != nil {
		return ""
	}
	return path
}

func findNotification(list []*PhoneNotification, id string) *PhoneNotification {
	for _, n := range list {
		if n.ID == id {
			return n
		}
	}
	return nil
}

func removeNotification(list []*PhoneNotification, id string) []*PhoneNotification {
	out := list[:0]
	for _, n := range list {
		if n.ID != id {
			out = append(out, n)
		}
	}
	return out
}

// DismissNotification removes a notification on the phone.
func (d *Daemon) DismissNotification(dev *Device, id string) error {
	if err := d.send(dev, proto.New(proto.TypeNotificationRequest, map[string]any{"cancel": id})); err != nil {
		return err
	}
	d.mu.Lock()
	dev.notifications = removeNotification(dev.notifications, id)
	deskID := dev.notifDesktop[id]
	delete(dev.notifDesktop, id)
	d.mu.Unlock()
	if deskID != 0 && d.notifier != nil {
		_ = d.notifier.Close(deskID)
	}
	d.markDirty()
	return nil
}

// ReplyNotification sends an inline reply to a phone notification.
func (d *Daemon) ReplyNotification(dev *Device, id, message string) error {
	d.mu.Lock()
	n := findNotification(dev.notifications, id)
	d.mu.Unlock()
	if n == nil || n.ReplyID == "" {
		return apiErr("no_reply", "This notification does not accept a reply")
	}
	return d.send(dev, proto.New(proto.TypeNotificationReply, map[string]any{"requestReplyId": n.ReplyID, "message": message}))
}

// NotificationAction runs an action of a phone notification.
func (d *Daemon) NotificationAction(dev *Device, id, action string) error {
	return d.send(dev, proto.New(proto.TypeNotificationAction, map[string]any{"key": id, "action": action}))
}

// onNotificationAction handles a click on a button of a desktop
// notification that fluxd showed.
func (d *Daemon) onNotificationAction(_ uint32, key string) {
	kind, rest, _ := strings.Cut(key, ":")
	switch kind {
	case "ring-stop":
		d.StopRing()
	case "open":
		_ = desktop.Open(rest)
	case "reveal":
		_ = desktop.Open(filepath.Dir(rest))
	case "pair-accept", "pair-reject":
		if dev := d.lookup(rest); dev != nil {
			if kind == "pair-accept" {
				_ = d.AcceptPair(dev)
			} else {
				_ = d.RejectPair(dev)
			}
		}
	case "notif-dismiss":
		devID, id, _ := strings.Cut(rest, ":")
		if dev := d.lookup(devID); dev != nil {
			_ = d.DismissNotification(dev, unb64(id))
		}
	case "notif-action":
		parts := strings.SplitN(rest, ":", 3)
		if len(parts) == 3 {
			if dev := d.lookup(parts[0]); dev != nil {
				_ = d.NotificationAction(dev, unb64(parts[1]), unb64(parts[2]))
			}
		}
	}
}

// b64 encodes a value for a desktop notification action key. Phone
// notification IDs can contain the ":" separator.
func b64(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }

func unb64(s string) string {
	b, _ := base64.RawURLEncoding.DecodeString(s)
	return string(b)
}

func cacheDir() string {
	if d := os.Getenv("XDG_CACHE_HOME"); d != "" {
		return filepath.Join(d, "flux")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "flux")
}
