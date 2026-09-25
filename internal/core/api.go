package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

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

// lookup finds a device by ID or by name. Names match without case.
func (d *Daemon) lookup(key string) *Device {
	d.mu.Lock()
	defer d.mu.Unlock()
	if dev, ok := d.devices[key]; ok {
		return dev
	}
	for _, dev := range d.devices {
		if strings.EqualFold(dev.Name, key) {
			return dev
		}
	}
	return nil
}

// pick returns the device that a request names. Without a name it returns
// the only connected paired device.
func (d *Daemon) pick(key string) (*Device, error) {
	if key != "" {
		if dev := d.lookup(key); dev != nil {
			return dev, nil
		}
		return nil, apiErr("not_found", "No device named %q", key)
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

// Snapshot returns the full state as JSON.
func (d *Daemon) Snapshot() json.RawMessage {
	d.mu.Lock()
	defer d.mu.Unlock()
	devs := make([]*Device, 0, len(d.devices))
	for _, dev := range d.devices {
		devs = append(devs, dev)
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
		// A device that is not paired shows only while it is connected.
		if !dev.Paired && dev.link == nil {
			continue
		}
		views = append(views, dev.view())
	}
	clip := d.clipboard
	if clip == nil {
		clip = []ClipEntry{}
	}
	transfers := d.transfers
	if transfers == nil {
		transfers = []*Transfer{}
	}
	commands := d.cfg.Commands
	if commands == nil {
		commands = []config.Command{}
	}
	return mustJSON(map[string]any{
		"self": map[string]any{
			"id": d.selfID, "name": d.nameLocked(), "type": proto.DeviceType(),
			"tcpPort": d.lanPort(),
		},
		"devices":   views,
		"clipboard": clip,
		"transfers": transfers,
		"commands":  commands,
		"settings": map[string]any{
			"autoClipboard":    d.cfg.AutoClipboard,
			"notifications":    d.cfg.Notifications,
			"shareHome":        d.cfg.ShareHome,
			"pauseMediaOnCall": d.cfg.PauseMediaOnCall,
			"downloadDir":      d.cfg.DownloadPath(),
		},
		"webcam":   d.webcamViewLocked(),
		"ringing":  d.ringing,
		"ringFrom": d.ringFrom,
	})
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
	Player    string          `json:"player"`
	Action    string          `json:"action"`
	Position  int64           `json:"position"`
	Thread    int64           `json:"thread"`
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
func (d *Daemon) Call(_ context.Context, method string, raw json.RawMessage) (any, error) {
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
	case "ring.stop":
		d.StopRing()
		return ok, nil
	case "webcam.stop":
		return ok, d.StopWebcam()
	case "webcam.config":
		return ok, d.ConfigureWebcam(p.Config, p.Reset)
	case "clipboard.copy":
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
	}

	dev, err := d.pick(p.Device)
	if err != nil {
		return nil, err
	}
	switch method {
	case "pair.request":
		return ok, d.RequestPair(dev)
	case "pair.accept":
		return ok, d.AcceptPair(dev)
	case "pair.reject":
		return ok, d.RejectPair(dev)
	case "pair.unpair":
		return ok, d.Unpair(dev)
	}
	if !dev.Paired {
		return nil, apiErr("not_paired", "%s is not paired", dev.Name)
	}
	switch method {
	case "ring":
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
	case "notification.reply":
		return ok, d.ReplyNotification(dev, p.ID, p.Message)
	case "notification.action":
		return ok, d.NotificationAction(dev, p.ID, p.Action)
	case "media.action":
		return ok, d.PhoneMediaAction(dev, p.Player, p.Action)
	case "media.seek":
		return ok, d.PhoneMediaSeek(dev, p.Player, p.Position)
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
	case "browse.open":
		roots, err := d.BrowseOpen(dev)
		if err != nil {
			return nil, err
		}
		return map[string]any{"roots": roots}, nil
	case "browse.list":
		entries, err := d.BrowseList(dev, p.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"entries": entries}, nil
	case "browse.get":
		t, err := d.BrowseGet(dev, p.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"transfer": t.ID}, nil
	}
	return nil, apiErr("unknown_method", "Unknown method %q", method)
}

// addCommand saves a new command in config.toml and sends the list to the
// connected phones.
func (d *Daemon) addCommand(name, command string) (any, error) {
	name, command = strings.TrimSpace(name), strings.TrimSpace(command)
	if name == "" || command == "" {
		return nil, apiErr("bad_params", "Give a name and a command")
	}
	c := config.Command{ID: config.NewID(4), Name: name, Command: command}
	d.mu.Lock()
	d.cfg.Commands = append(d.cfg.Commands, c)
	cfg := *d.cfg
	d.mu.Unlock()
	if err := config.Save(&cfg); err != nil {
		return nil, err
	}
	d.commandsChanged()
	return map[string]any{"id": c.ID}, nil
}

// removeCommand deletes a command from config.toml and sends the list to
// the connected phones.
func (d *Daemon) removeCommand(id string) error {
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
	cfg := *d.cfg
	d.mu.Unlock()
	if !found {
		return apiErr("not_found", "No command with ID %s", id)
	}
	if err := config.Save(&cfg); err != nil {
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
	d.mu.Lock()
	switch {
	case key == "autoClipboard" && isBool:
		d.cfg.AutoClipboard = b
	case key == "notifications" && isBool:
		d.cfg.Notifications = b
	case key == "shareHome" && isBool:
		d.cfg.ShareHome = b
	case key == "pauseMediaOnCall" && isBool:
		d.cfg.PauseMediaOnCall = b
	case key == "name" && isString:
		d.cfg.Name = strings.TrimSpace(s)
	case key == "downloadDir" && isString:
		d.cfg.DownloadDir = strings.TrimSpace(s)
	default:
		d.mu.Unlock()
		return apiErr("bad_setting", "Unknown setting %q or wrong value type", key)
	}
	cfg := *d.cfg
	d.mu.Unlock()
	if err := config.Save(&cfg); err != nil {
		return err
	}
	if key == "name" {
		d.announce()
	}
	d.markDirty()
	return nil
}

// Reload reads config.toml again. fluxd calls it on SIGHUP.
func (d *Daemon) Reload() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	d.mu.Lock()
	d.cfg = cfg
	d.mu.Unlock()
	d.commandsChanged()
	return nil
}

func hostname() string {
	h, _ := os.Hostname()
	return h
}
