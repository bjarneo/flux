package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxNotifications is the number of phone notifications kept per device.
const maxNotifications = 100

// Limits on the data of 1 phone notification. The state holds each
// notification and the desktop shows it, so a device cannot make either
// one large. maxNotifID is the longest notification ID and reply ID. An
// Android notification key has about 100 bytes.
const (
	maxNotifApp     = 256
	maxNotifTitle   = 256
	maxNotifText    = 4 << 10
	maxNotifActions = 8
	maxNotifAction  = 64
	maxNotifID      = 512
)

// maxNotifyJobs is the number of desktop notification calls that can wait.
// A slow notification server then cannot make the queue grow without a
// limit.
const maxNotifyJobs = 64

// reconcileWait is how long fluxd waits for the notifications that a phone
// sends again after it connects. Then fluxd closes the desktop
// notifications that the phone did not send again.
const reconcileWait = 15 * time.Second

// contentQueue runs jobs in order on 1 goroutine. The goroutine starts
// with the first job and ends when the queue is empty. d.mu guards it.
type contentQueue struct {
	jobs    []func()
	running bool
}

// clipFetch is the clipboard image that 1 device sends.
type clipFetch struct {
	cancel context.CancelFunc

	// stale is true when a newer text or image of the device came. The
	// image then does not go on the clipboard or into the history. d.mu
	// guards it.
	stale bool
}

// contentState is the state of the workers and the limits for shares, the
// clipboard, notifications, media, calls, and Do Not Disturb. d.mu guards
// it. The zero value is ready to use.
type contentState struct {
	// notifyQ shows and closes desktop notifications for the devices, in
	// the order of the packets. mediaQ runs the media requests and the
	// call events. clipQ puts the newest text from a device on the
	// clipboard. dndQ applies the newest Do Not Disturb state of a phone.
	notifyQ contentQueue
	mediaQ  contentQueue
	clipQ   contentQueue
	dndQ    contentQueue

	// lastClip is the last text that Watch reported. A device that
	// connects gets this text, and not a new read of the clipboard, so it
	// never gets a copy that Watch skipped, such as a password.
	lastClip string
	// receives counts the running incoming file transfers of each device.
	receives map[string]int
	// clipImages is the clipboard image that each device sends.
	clipImages map[string]*clipFetch
	// cleaned holds the folders from which fluxd removed the temporary
	// files of old incoming transfers.
	cleaned map[string]bool
}

// runContent adds job to q and starts the worker of q when it does not
// run. With max 0, q keeps only the newest waiting job. Otherwise it
// returns false and drops the job when q holds max jobs.
func (d *Daemon) runContent(q *contentQueue, max int, job func()) bool {
	return d.runContentIf(q, max, nil, job)
}

// runContentIf is runContent with the condition ok, which runs under d.mu
// before q changes. When ok returns false, runContentIf returns false and
// q keeps its jobs. A nil ok is always true.
func (d *Daemon) runContentIf(q *contentQueue, max int, ok func() bool, job func()) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case ok != nil && !ok():
		return false
	case max == 0:
		clear(q.jobs)
		q.jobs = append(q.jobs[:0], job)
	case len(q.jobs) >= max:
		return false
	default:
		q.jobs = append(q.jobs, job)
	}
	if !q.running {
		q.running = true
		go d.drainContent(q)
	}
	return true
}

// drainContent runs the jobs of q until q is empty.
func (d *Daemon) drainContent(q *contentQueue) {
	for {
		d.mu.Lock()
		if len(q.jobs) == 0 {
			q.running = false
			d.mu.Unlock()
			return
		}
		job := q.jobs[0]
		q.jobs[0] = nil
		q.jobs = q.jobs[1:]
		d.mu.Unlock()
		job()
	}
}

// runNotify runs a desktop notification call on the notification worker,
// so that a slow notification server does not stop the read loop of a
// device.
func (d *Daemon) runNotify(job func()) {
	if !d.runContent(&d.content.notifyQ, maxNotifyJobs, job) {
		d.logf("the notification server is slow: dropped a desktop notification")
	}
}

// notifyAsync shows a desktop notification from the notification worker.
func (d *Daemon) notifyAsync(n desktop.Notification) {
	if d.notifier == nil {
		return
	}
	d.runNotify(func() { d.notify(n) })
}

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

// cutText returns at most the first max bytes of s. It cuts at the start
// of a UTF-8 character, so the result stays valid UTF-8.
func cutText(s string, max int) string {
	if len(s) <= max {
		return s
	}
	n := max
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// notificationActions returns the actions that fluxd keeps: at most
// maxNotifActions, each with at most maxNotifAction bytes. The phone finds
// an action by its full name, so fluxd drops a longer action and does not
// cut it.
func notificationActions(list []string) []string {
	out := []string{}
	for _, a := range list {
		if a == "" || len(a) > maxNotifAction {
			continue
		}
		out = append(out, a)
		if len(out) == maxNotifActions {
			break
		}
	}
	return out
}

func (d *Daemon) handleNotification(dev *Device, l *lan.Link, p *proto.Packet) {
	var b struct {
		ID          string     `json:"id"`
		AppName     string     `json:"appName"`
		Title       string     `json:"title"`
		Text        string     `json:"text"`
		Time        flexString `json:"time"`
		IsCancel    flexString `json:"isCancel"`
		IsClearable flexString `json:"isClearable"`
		Silent      flexString `json:"silent"`
		OnlyOnce    flexString `json:"onlyOnce"`
		ReplyID     string     `json:"requestReplyId"`
		Actions     []string   `json:"actions"`
	}
	if p.Decode(&b) != nil || b.ID == "" || len(b.ID) > maxNotifID {
		return
	}
	if b.IsCancel.bool() {
		d.mu.Lock()
		dev.notifications = removeNotification(dev.notifications, b.ID)
		d.mu.Unlock()
		d.closeNotification(dev, b.ID)
		d.markDirty()
		return
	}
	ms, _ := strconv.ParseInt(string(b.Time), 10, 64)
	n := &PhoneNotification{
		ID: b.ID, App: cutText(b.AppName, maxNotifApp), Title: cutText(b.Title, maxNotifTitle),
		Text: cutText(b.Text, maxNotifText), Time: ms / 1000, ReplyID: b.ReplyID,
		Actions: notificationActions(b.Actions), Clear: b.IsClearable.bool() || b.IsClearable == "",
	}
	if len(n.ReplyID) > maxNotifID {
		n.ReplyID = ""
	}
	if n.Time == 0 {
		n.Time = time.Now().Unix()
	}
	d.mu.Lock()
	_, seen := dev.notifDesktop[b.ID]
	dev.notifications = removeNotification(dev.notifications, b.ID)
	dev.notifications = append([]*PhoneNotification{n}, dev.notifications...)
	if len(dev.notifications) > maxNotifications {
		for _, gone := range dev.notifications[maxNotifications:] {
			delete(dev.notifDesktop, gone.ID)
		}
		dev.notifications = dev.notifications[:maxNotifications]
	}
	show := d.cfg.Notifications && !b.Silent.bool() && !(seen && b.OnlyOnce.bool())
	d.mu.Unlock()
	d.markDirty()
	if show {
		d.showNotification(dev, n)
	}
}

// showNotification shows a phone notification on the desktop. The
// notification worker runs the calls of all packets in order. Each call
// reads the desktop ID that the call before it stored, so an update
// replaces the desktop notification and does not add a second one.
func (d *Daemon) showNotification(dev *Device, n *PhoneNotification) {
	if d.notifier == nil {
		return
	}
	d.runNotify(func() {
		d.mu.Lock()
		// A newer packet for the same notification, a cancel, an unpair, or
		// the switch makes this packet old.
		current := dev.Paired && d.cfg.Notifications && findNotification(dev.notifications, n.ID) == n
		replaces, name := dev.notifDesktop[n.ID], dev.Name
		d.mu.Unlock()
		if !current {
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
			app = name
		}
		id := d.notify(desktop.Notification{
			AppName: app + " · " + name, Title: n.Title, Body: n.Text,
			Actions: actions, ReplacesID: replaces,
		})
		if id == 0 {
			return
		}
		d.mu.Lock()
		// The phone can remove the notification during the call. A newer
		// packet for it keeps the ID, so that it replaces this notification.
		gone := findNotification(dev.notifications, n.ID) == nil
		if !gone {
			dev.notifDesktop[n.ID] = id
		}
		d.mu.Unlock()
		if gone {
			_ = d.notifier.Close(id)
		}
	})
}

// closeNotification closes the desktop notification of the phone
// notification id when the phone no longer has it.
func (d *Daemon) closeNotification(dev *Device, id string) {
	d.closeNotifications(dev, []string{id})
}

// closeNotifications closes the desktop notifications of the phone
// notifications ids that the phone no longer has. 1 job closes all of
// them, so a long list does not fill the queue of the notification worker.
func (d *Daemon) closeNotifications(dev *Device, ids []string) {
	if d.notifier == nil || len(ids) == 0 {
		return
	}
	d.runNotify(func() {
		var desk []uint32
		d.mu.Lock()
		for _, id := range ids {
			deskID, ok := dev.notifDesktop[id]
			// The phone can send the notification again after the cancel.
			if !ok || findNotification(dev.notifications, id) != nil {
				continue
			}
			delete(dev.notifDesktop, id)
			if deskID != 0 {
				desk = append(desk, deskID)
			}
		}
		d.mu.Unlock()
		for _, deskID := range desk {
			_ = d.notifier.Close(deskID)
		}
	})
}

// requestNotifications asks a phone that connects for all of its
// notifications. The phone sends each notification that it still has.
// onLink empties the list before the first packet of the link, so a
// notification that arrives before this request stays. After
// reconcileWait, fluxd closes the desktop notifications that the phone
// did not send again.
func (d *Daemon) requestNotifications(dev *Device, l *lan.Link) {
	_ = l.Send(proto.New(proto.TypeNotificationRequest, map[string]any{"request": true}))
	if d.notifier == nil {
		return
	}
	time.AfterFunc(reconcileWait, func() {
		d.mu.Lock()
		var stale []string
		if dev.link == l {
			for id := range dev.notifDesktop {
				if findNotification(dev.notifications, id) == nil {
					stale = append(stale, id)
				}
			}
		}
		d.mu.Unlock()
		d.closeNotifications(dev, stale)
	})
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
	if err := d.dismissOnPhone(dev, id); err != nil {
		return err
	}
	d.closeNotification(dev, id)
	d.markDirty()
	return nil
}

// dismissOnPhone asks the phone to remove the notification id and removes
// it from the list of the device. The caller closes the desktop
// notification.
func (d *Daemon) dismissOnPhone(dev *Device, id string) error {
	if err := d.send(dev, proto.New(proto.TypeNotificationRequest, map[string]any{"cancel": id})); err != nil {
		return err
	}
	d.mu.Lock()
	dev.notifications = removeNotification(dev.notifications, id)
	d.mu.Unlock()
	return nil
}

// DismissAllNotifications dismisses each phone notification that the user
// can dismiss, on the phone and on this computer. It returns the number of
// dismissed notifications. An ongoing notification, such as a media
// player, stays.
func (d *Daemon) DismissAllNotifications(dev *Device) (int, error) {
	d.mu.Lock()
	ids := dismissable(dev.notifications)
	d.mu.Unlock()
	var done []string
	var err error
	for _, id := range ids {
		if err = d.dismissOnPhone(dev, id); err != nil {
			break
		}
		done = append(done, id)
	}
	if len(done) > 0 {
		d.closeNotifications(dev, done)
		d.markDirty()
	}
	return len(done), err
}

// dismissable returns the IDs of the notifications that the user can
// dismiss.
func dismissable(list []*PhoneNotification) []string {
	var ids []string
	for _, n := range list {
		if n.Clear {
			ids = append(ids, n.ID)
		}
	}
	return ids
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

// NotificationAction runs an action of a phone notification. The
// notification and the action must be in the list that the phone sent.
func (d *Daemon) NotificationAction(dev *Device, id, action string) error {
	d.mu.Lock()
	n := findNotification(dev.notifications, id)
	d.mu.Unlock()
	if n == nil || !slices.Contains(n.Actions, action) {
		return apiErr("not_found", "The notification has no action %q", action)
	}
	return d.send(dev, proto.New(proto.TypeNotificationAction, map[string]any{"key": id, "action": action}))
}

// onNotificationAction handles a click on a button of a desktop
// notification that fluxd showed.
func (d *Daemon) onNotificationAction(_ uint32, key string) {
	kind, rest, _ := strings.Cut(key, ":")
	switch kind {
	case "open":
		_ = desktop.Open(rest)
	case "reveal":
		_ = desktop.Open(filepath.Dir(rest))
	case "pair-accept", "pair-reject":
		// The key binds the click to the pairing that the notification
		// showed. A later pairing of the device has another key.
		id, key, _ := strings.Cut(rest, ":")
		if dev := d.lookup(id); dev != nil && key != "" {
			if kind == "pair-accept" {
				_ = d.AcceptPair(dev, key)
			} else {
				_ = d.RejectPair(dev, key)
			}
		}
	case "desktop-stop":
		_ = d.StopDesktop()
	case "browse-stop":
		d.stopBrowse(rest)
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

func cacheDir() string { return config.CacheDir() }
