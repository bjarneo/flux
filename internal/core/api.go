package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"

	"flux/internal/config"
	"flux/internal/proto"
)

// Error is an API error with a stable code for scripts.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

func apiErr(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

func offline(dev *Device) *Error { return apiErr("offline", "%s is offline", dev.Name) }

// lookup finds a device by ID or by name. It returns nil when no device
// or more than 1 device matches. See find.
func (d *Daemon) lookup(key string) *Device {
	dev, _ := d.find(key, nil)
	return dev
}

// find returns the device that key names. An exact device ID wins. A name
// matches without case, and only a device that is paired or connected,
// because any host on the network can send a name. match, when it is not
// nil, limits the devices that a name finds, and runs under d.mu. When more
// than 1 device has the name, find takes the paired ones. It returns an
// ambiguous error that lists the IDs when that leaves more than 1 device.
func (d *Daemon) find(key string, match func(*Device) bool) (*Device, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if dev, ok := d.devices[key]; ok {
		return dev, nil
	}
	var found, paired []*Device
	for _, dev := range d.devices {
		if !strings.EqualFold(dev.Name, key) || (!dev.Paired && dev.link == nil) || (match != nil && !match(dev)) {
			continue
		}
		found = append(found, dev)
		if dev.Paired {
			paired = append(paired, dev)
		}
	}
	if len(paired) > 0 {
		found = paired
	}
	switch len(found) {
	case 0:
		return nil, apiErr("not_found", "No device named %q", key)
	case 1:
		return found[0], nil
	}
	ids := make([]string, 0, len(found))
	for _, dev := range found {
		ids = append(ids, dev.ID)
	}
	sort.Strings(ids)
	return nil, apiErr("ambiguous", "%d devices are named %q: %s. Give the device ID", len(found), key, strings.Join(ids, ", "))
}

// pick returns the device that a request names. Without a name it returns
// the only connected paired device.
func (d *Daemon) pick(key string) (*Device, error) { return d.pickMatch(key, nil) }

// pickMatch is pick with a limit on the devices that a name finds. See
// find.
func (d *Daemon) pickMatch(key string, match func(*Device) bool) (*Device, error) {
	if key != "" {
		return d.find(key, match)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	var found []*Device
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil {
			found = append(found, dev)
		}
	}
	switch len(found) {
	case 0:
		return nil, apiErr("no_device", "No paired device is connected")
	case 1:
		return found[0], nil
	}
	names := make([]string, 0, len(found))
	for _, dev := range found {
		names = append(names, dev.Name)
	}
	sort.Strings(names)
	return nil, apiErr("ambiguous", "%d devices are connected (%s). Use --device", len(found), strings.Join(names, ", "))
}

// Snapshot returns the full state as JSON. It copies the state under d.mu
// and encodes the copy after the unlock, so that the packets of the devices
// do not wait for the encode.
func (d *Daemon) Snapshot() json.RawMessage {
	d.mu.Lock()
	devs := make([]*Device, 0, len(d.devices))
	for _, dev := range d.devices {
		// A device that is not paired shows only while it is connected.
		if dev.Paired || dev.link != nil {
			devs = append(devs, dev)
		}
	}
	sort.Slice(devs, func(i, j int) bool {
		a, b := devs[i], devs[j]
		if a.Paired != b.Paired {
			return a.Paired
		}
		if (a.link != nil) != (b.link != nil) {
			return a.link != nil
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})
	views := make([]DeviceView, 0, len(devs))
	for _, dev := range devs {
		v := dev.view()
		if !dev.Paired {
			// The phone data of a device that is not paired stays out of
			// the state, also after an unpair.
			v.Battery, v.Notifications, v.Conversations = nil, []*PhoneNotification{}, []*Conversation{}
		}
		v.AppUpdate = d.appUpdateLocked(dev)
		// The handlers change these lists in place.
		v.Notifications = slices.Clone(v.Notifications)
		v.Addresses = slices.Clone(v.Addresses)
		views = append(views, v)
	}
	clip := d.clipPreviewLocked()
	transfers := make([]*Transfer, 0, len(d.transfers))
	for _, t := range d.transfers {
		transfers = append(transfers, t.copyLocked())
	}
	commands := slices.Clone(d.cfg.Commands)
	if commands == nil {
		commands = []config.Command{}
	}
	state := map[string]any{
		"self": map[string]any{
			"id": d.selfID, "name": d.nameLocked(), "type": proto.DeviceType(),
			"tcpPort": d.lanPort(), "version": d.opts.Version,
			"pendingVersion": d.pendingVersion,
		},
		"devices":   views,
		"update":    d.updateViewLocked(),
		"clipboard": clip,
		"transfers": transfers,
		"commands":  commands,
		"settings": map[string]any{
			"autoClipboard":    d.cfg.AutoClipboard,
			"notifications":    d.cfg.Notifications,
			"shareHome":        d.cfg.ShareHome,
			"pauseMediaOnCall": d.cfg.PauseMediaOnCall,
			"downloadDir":      d.cfg.DownloadPath(),
			"syncDnd":          d.cfg.SyncDnd,
			"herdr":            d.cfg.Herdr,
			"herdrControl":     d.cfg.HerdrControl,
			"herdrTerminals":   d.cfg.HerdrTerminals,
			"remoteInput":      d.cfg.RemoteInput,
			"remoteDesktop":    d.cfg.RemoteDesktop,
			"checkUpdates":     d.cfg.CheckUpdates,
		},
		"webcam":  d.webcamViewLocked(),
		"mic":     d.micViewLocked(),
		"screen":  d.screenViewLocked(),
		"desktop": d.desktopViewLocked(),
		"browse":  d.browseViewLocked(),
		"herdr":   d.herdrViewLocked(),
	}
	d.mu.Unlock()
	return mustJSON(state)
}

func (d *Daemon) lanPort() int {
	if d.lan == nil {
		return 0
	}
	return d.lan.TCPPort()
}

func (d *Daemon) command(id string) (config.Command, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, c := range d.cfg.Commands {
		if c.ID == id {
			return c, true
		}
	}
	return config.Command{}, false
}

// params is the union of all request parameters.
type params struct {
	Device    string          `json:"device"`
	ID        string          `json:"id"`
	Text      string          `json:"text"`
	URL       string          `json:"url"`
	Message   string          `json:"message"`
	Paths     []string        `json:"paths"`
	Path      string          `json:"path"`
	Action    string          `json:"action"`
	Thread    int64           `json:"thread"`
	Address   string          `json:"address"`
	Addresses []string        `json:"addresses"`
	Body      string          `json:"body"`
	Title     string          `json:"title"`
	Key       string          `json:"key"`
	Name      string          `json:"name"`
	Command   string          `json:"command"`
	Value     any             `json:"value"`
	Config    json.RawMessage `json:"config"`
	Reset     bool            `json:"reset"`
}

// Call runs one API method.
func (d *Daemon) Call(ctx context.Context, method string, raw json.RawMessage) (any, error) {
	var p params
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, apiErr("bad_params", "params: %v", err)
		}
	}
	ok := map[string]any{}

	// Methods that need no device.
	switch method {
	case "state":
		return d.Snapshot(), nil
	case "discover":
		d.announce()
		return ok, nil
	case "webcam.start", "mic.start":
		// The request picks its own device: only a device that accepts
		// flux.stream.request counts.
		id, name, err := d.requestStream(strings.TrimSuffix(method, ".start"), p.Device)
		if err != nil {
			return nil, err
		}
		return map[string]any{"device": id, "name": name}, nil
	case "webcam.stop":
		return ok, d.StopWebcam()
	case "webcam.config":
		return ok, d.ConfigureWebcam(p.Config, p.Reset)
	case "mic.stop":
		return ok, d.StopMic()
	case "screen.stop":
		return ok, d.StopScreen()
	case "desktop.stop":
		return ok, d.StopDesktop()
	case "browse.stop":
		return ok, d.StopBrowse(p.Device)
	case "approve.request", "approve.enroll":
		return d.startApproval(ctx, method, raw)
	case "approve.wait":
		return d.ApproveWait(ctx, p.ID)
	case "approve.cancel":
		return ok, d.ApproveCancel(p.ID)
	case "clipboard.copy":
		if p.ID != "" {
			return ok, d.CopyClip(p.ID)
		}
		if p.Path != "" {
			return ok, d.CopyClipImage(p.Path)
		}
		if p.Text == "" {
			return nil, apiErr("bad_params", "text is empty")
		}
		return ok, d.clip.Set(p.Text)
	case "transfer.cancel":
		return ok, d.CancelTransfer(p.ID)
	case "commands.add":
		return d.addCommand(p.Name, p.Command)
	case "commands.remove":
		return ok, d.removeCommand(p.ID)
	case "commands.run":
		c, found := d.command(p.ID)
		if !found {
			return nil, apiErr("not_found", "No command with ID %s", p.ID)
		}
		return ok, d.runLocal(c)
	case "settings.set":
		return ok, d.setSetting(p.Key, p.Value)
	case "update.install":
		return ok, d.installUpdate()
	}

	// An unknown method gets its own error before the device choice, so
	// that a typo or an earlier fluxd does not look like a missing device.
	if !deviceMethods[method] {
		return nil, apiErr("unknown_method", "Unknown method %q", method)
	}
	// A name finds only the devices that the pairing method can act on.
	var match func(*Device) bool
	switch method {
	case "pair.request":
		match = func(dev *Device) bool { return !dev.Paired && dev.link != nil }
	case "pair.accept", "pair.reject":
		match = func(dev *Device) bool { return dev.pairState == "incoming" || dev.pairState == "confirm" }
	}
	dev, err := d.pickMatch(p.Device, match)
	var e *Error
	if errors.As(err, &e) && e.Code == "not_found" {
		switch method {
		case "pair.request":
			// A paired device with the name gets the answer that it is
			// paired.
			dev, err = d.pick(p.Device)
		case "pair.accept", "pair.reject":
			err = apiErr("no_request", "No device named %q has an open pair request", p.Device)
		}
	}
	if err != nil {
		return nil, err
	}
	switch method {
	case "pair.request", "pair.accept", "pair.reject", "pair.unpair":
		return d.pairCall(method, dev, p.Key)
	}
	d.mu.Lock()
	paired, ring, name := dev.Paired, dev.accepts(proto.TypeFindMyPhone), dev.Name
	d.mu.Unlock()
	if !paired {
		return nil, apiErr("not_paired", "%s is not paired", name)
	}
	switch method {
	case "addresses.add", "addresses.remove":
		change := d.AddAddress
		if method == "addresses.remove" {
			change = d.RemoveAddress
		}
		addr, addrs, err := change(dev, p.Address)
		if err != nil {
			return nil, err
		}
		return map[string]any{"device": name, "address": addr, "addresses": addrs}, nil
	case "ring":
		if !ring {
			return nil, apiErr("not_supported", "%s cannot ring. Flux rings only phones and tablets", name)
		}
		return ok, d.send(dev, proto.New(proto.TypeFindMyPhone, map[string]any{}))
	case "ping":
		body := map[string]any{}
		if p.Message != "" {
			body["message"] = p.Message
		}
		return ok, d.send(dev, proto.New(proto.TypePing, body))
	case "clipboard.send":
		return ok, d.SendClipboard(dev, p.Text)
	case "share.files":
		ts, err := d.SendFiles(dev, p.Paths)
		if err != nil {
			return nil, err
		}
		ids := make([]string, 0, len(ts))
		for _, t := range ts {
			ids = append(ids, t.ID)
		}
		return map[string]any{"transfers": ids}, nil
	case "share.text":
		return ok, d.ShareText(dev, "text", p.Text)
	case "share.url":
		return ok, d.ShareText(dev, "url", p.URL)
	case "notification.dismiss":
		return ok, d.DismissNotification(dev, p.ID)
	case "notification.dismissAll":
		n, err := d.DismissAllNotifications(dev)
		if err != nil {
			return nil, err
		}
		return map[string]any{"dismissed": n}, nil
	case "notification.reply":
		return ok, d.ReplyNotification(dev, p.ID, p.Message)
	case "notification.action":
		return ok, d.NotificationAction(dev, p.ID, p.Action)
	case "sms.refresh":
		return ok, d.RefreshSms(dev)
	case "sms.thread":
		msgs, err := d.SmsThread(dev, p.Thread)
		if err != nil {
			return nil, err
		}
		return map[string]any{"messages": msgs}, nil
	case "notify.send":
		return ok, d.SendNotification(dev, p.Title, p.Body)
	case "sms.send":
		return ok, d.SendSms(dev, p.Addresses, p.Body)
	case "update.sendApp":
		return ok, d.sendAppUpdate(dev)
	}
	return nil, apiErr("unknown_method", "Unknown method %q", method)
}

// deviceMethods are the methods of Call that act on a device.
var deviceMethods = map[string]bool{
	"pair.request": true, "pair.accept": true, "pair.reject": true, "pair.unpair": true,
	"addresses.add": true, "addresses.remove": true,
	"ring": true, "ping": true,
	"clipboard.send": true, "share.files": true, "share.text": true, "share.url": true,
	"notification.dismiss": true, "notification.dismissAll": true, "notification.reply": true, "notification.action": true,
	"sms.refresh": true, "sms.thread": true, "sms.send": true,
	"notify.send":    true,
	"update.sendApp": true,
}

// cfgSaves orders the changes of the configuration and their saves, so
// that config.toml always gets the newest change.
var cfgSaves sync.Mutex

// configCopyLocked returns a copy of d.cfg to save. The caller holds
// cfgSaves and d.mu.
func (d *Daemon) configCopyLocked() config.Config {
	cfg := *d.cfg
	cfg.Commands = slices.Clone(cfg.Commands)
	return cfg
}

// addCommand saves a new command in config.toml and sends the list to the
// connected phones.
func (d *Daemon) addCommand(name, command string) (any, error) {
	name, command = strings.TrimSpace(name), strings.TrimSpace(command)
	if name == "" || command == "" {
		return nil, apiErr("bad_params", "Give a name and a command")
	}
	c := config.Command{ID: config.NewID(4), Name: name, Command: command}
	cfgSaves.Lock()
	d.mu.Lock()
	d.cfg.Commands = append(d.cfg.Commands, c)
	cfg := d.configCopyLocked()
	d.mu.Unlock()
	err := config.Save(&cfg)
	cfgSaves.Unlock()
	if err != nil {
		return nil, err
	}
	d.commandsChanged()
	return map[string]any{"id": c.ID}, nil
}

// removeCommand deletes a command from config.toml and sends the list to
// the connected phones.
func (d *Daemon) removeCommand(id string) error {
	cfgSaves.Lock()
	d.mu.Lock()
	out := make([]config.Command, 0, len(d.cfg.Commands))
	found := false
	for _, c := range d.cfg.Commands {
		if c.ID == id {
			found = true
			continue
		}
		out = append(out, c)
	}
	d.cfg.Commands = out
	cfg := d.configCopyLocked()
	d.mu.Unlock()
	if !found {
		cfgSaves.Unlock()
		return apiErr("not_found", "No command with ID %s", id)
	}
	err := config.Save(&cfg)
	cfgSaves.Unlock()
	if err != nil {
		return err
	}
	d.commandsChanged()
	return nil
}

func (d *Daemon) commandsChanged() {
	for _, l := range d.pairedLinks() {
		d.sendCommandList(l)
	}
	d.markDirty()
}

func (d *Daemon) setSetting(key string, value any) error {
	b, isBool := value.(bool)
	s, isString := value.(string)
	cfgSaves.Lock()
	d.mu.Lock()
	before := *d.cfg
	switch {
	case key == "autoClipboard" && isBool:
		d.cfg.AutoClipboard = b
	case key == "notifications" && isBool:
		d.cfg.Notifications = b
	case key == "shareHome" && isBool:
		d.cfg.ShareHome = b
	case key == "pauseMediaOnCall" && isBool:
		d.cfg.PauseMediaOnCall = b
	case key == "syncDnd" && isBool:
		d.cfg.SyncDnd = b
	case key == "herdr" && isBool:
		d.cfg.Herdr = b
	case key == "herdrControl" && isBool:
		d.cfg.HerdrControl = b
	case key == "herdrTerminals" && isBool:
		d.cfg.HerdrTerminals = b
	case key == "remoteInput" && isBool:
		d.cfg.RemoteInput = b
	case key == "remoteDesktop" && isBool:
		d.cfg.RemoteDesktop = b
	case key == "checkUpdates" && isBool:
		d.cfg.CheckUpdates = b
	case key == "name" && isString:
		d.cfg.Name = strings.TrimSpace(s)
	case key == "downloadDir" && isString:
		d.cfg.DownloadDir = strings.TrimSpace(s)
	default:
		d.mu.Unlock()
		cfgSaves.Unlock()
		return apiErr("bad_setting", "Unknown setting %q or wrong value type", key)
	}
	cfg := d.configCopyLocked()
	d.mu.Unlock()
	err := config.Save(&cfg)
	cfgSaves.Unlock()
	if err != nil {
		return d.unsavedSetting(key, &before, err)
	}
	if key == "name" {
		d.announce()
	}
	if key == "herdr" || key == "herdrControl" || key == "herdrTerminals" {
		d.herdrChanged()
	}
	if key == "remoteInput" || key == "remoteDesktop" {
		d.inputChanged()
	}
	if key == "shareHome" {
		d.shareHomeChanged()
	}
	if key == "syncDnd" {
		d.wakeDnd()
	}
	if key == "autoClipboard" && !b {
		// An image that is on its way to the phones stops.
		d.stopClipSend()
	}
	if key == "checkUpdates" {
		d.wakeRelease()
	}
	d.markDirty()
	return nil
}

// Reload reads config.toml again. fluxd calls it on SIGHUP.
func (d *Daemon) Reload() error {
	cfgSaves.Lock()
	cfg, err := config.Load()
	if err != nil {
		cfgSaves.Unlock()
		return err
	}
	d.mu.Lock()
	d.cfg = cfg
	auto := cfg.AutoClipboard
	d.mu.Unlock()
	cfgSaves.Unlock()
	d.commandsChanged()
	d.herdrChanged()
	d.inputChanged()
	d.shareHomeChanged()
	d.wakeDnd()
	d.wakeRelease()
	if !auto {
		// An image that is on its way to the phones stops.
		d.stopClipSend()
	}
	return nil
}

// unsavedSetting handles a switch that config.toml could not keep. before
// is the configuration before the change. A switch that gives a device
// access to this computer must not turn on after the error, so it gets its
// old value back. A switch that turned off stops the sessions at once and
// stays off until fluxd restarts. Each other setting gets its old value
// back, so that fluxd and the window keep the value of config.toml.
func (d *Daemon) unsavedSetting(key string, before *config.Config, err error) error {
	var field *bool
	var old bool
	d.mu.Lock()
	switch key {
	case "remoteInput":
		field, old = &d.cfg.RemoteInput, before.RemoteInput
	case "remoteDesktop":
		field, old = &d.cfg.RemoteDesktop, before.RemoteDesktop
	case "shareHome":
		field, old = &d.cfg.ShareHome, before.ShareHome
	case "herdrControl":
		field, old = &d.cfg.HerdrControl, before.HerdrControl
	case "herdrTerminals":
		field, old = &d.cfg.HerdrTerminals, before.HerdrTerminals
	case "autoClipboard":
		d.cfg.AutoClipboard = before.AutoClipboard
	case "notifications":
		d.cfg.Notifications = before.Notifications
	case "pauseMediaOnCall":
		d.cfg.PauseMediaOnCall = before.PauseMediaOnCall
	case "syncDnd":
		d.cfg.SyncDnd = before.SyncDnd
	case "herdr":
		d.cfg.Herdr = before.Herdr
	case "checkUpdates":
		d.cfg.CheckUpdates = before.CheckUpdates
	case "name":
		d.cfg.Name = before.Name
	case "downloadDir":
		d.cfg.DownloadDir = before.DownloadDir
	}
	if field == nil {
		d.mu.Unlock()
		d.markDirty()
		return fmt.Errorf("%s did not change, because config.toml could not keep the change: %w", key, err)
	}
	on := *field
	if on {
		*field = old
	}
	d.mu.Unlock()
	switch key {
	case "shareHome":
		d.shareHomeChanged()
	case "herdrControl", "herdrTerminals":
		d.herdrChanged()
	default:
		d.inputChanged()
	}
	d.markDirty()
	if on {
		return fmt.Errorf("%s did not change, because config.toml could not keep the change: %w", key, err)
	}
	return fmt.Errorf("%s is off until fluxd restarts, because config.toml could not keep the change: %w", key, err)
}

func hostname() string {
	h, _ := os.Hostname()
	return h
}
