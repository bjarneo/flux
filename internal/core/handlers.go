package core

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// handlePacket routes one packet from a device to its plugin.
func (d *Daemon) handlePacket(dev *Device, l *lan.Link, p *proto.Packet) {
	d.mu.Lock()
	dev.LastSeen = time.Now()
	paired := dev.Paired
	d.mu.Unlock()

	if p.Type == proto.TypePair {
		d.handlePair(dev, p)
		return
	}
	if p.Type == proto.TypeFluxTunnel {
		var b struct {
			ID    string `json:"id"`
			Port  int    `json:"port"`
			Error string `json:"error"`
		}
		if p.Decode(&b) == nil {
			l.TunnelReady(b.ID, b.Port, b.Error)
		}
		return
	}
	if !paired {
		d.logf("%s: ignored %s from a device that is not paired", dev.Name, p.Type)
		return
	}
	switch p.Type {
	case proto.TypeIdentity:
		var id proto.Identity
		if p.Decode(&id) == nil && id.DeviceID == dev.ID {
			d.mu.Lock()
			dev.setIdentity(id)
			d.mu.Unlock()
			d.markDirty()
		}
	case proto.TypePing:
		d.handlePing(dev, p)
	case proto.TypeBattery:
		d.handleBattery(dev, p)
	case proto.TypeConnectivity:
		d.handleConnectivity(dev, p)
	case proto.TypeClipboard, proto.TypeClipboardConnect:
		d.handleClipboard(dev, p)
	case proto.TypeShare:
		d.handleShare(dev, l, p)
	case proto.TypeShareUpdate:
		// The totals of a multi-file share. Flux counts files as they arrive.
	case proto.TypeNotification:
		d.handleNotification(dev, l, p)
	case proto.TypeFindMyPhone:
		d.handleFindMyPhone(dev)
	case proto.TypeRunCommand:
		// The command list of another desktop. fluxd does not run commands
		// on other devices.
	case proto.TypeRunCommandRequest:
		d.handleRunCommand(dev, l, p)
	case proto.TypeMpris:
		d.handlePhoneMedia(dev, l, p)
	case proto.TypeMprisRequest:
		d.handleDesktopMediaRequest(l, p)
	case proto.TypeSftp:
		d.handleSftp(dev, p)
	case proto.TypeSftpRequest:
		d.handleBrowseRequest(dev, l, p)
	case proto.TypeFluxWebcam:
		d.handleWebcam(dev, l, p)
	case proto.TypeSmsMessages:
		d.handleSms(dev, p)
	case proto.TypeTelephony:
		d.handleTelephony(dev, p)
	default:
		d.logf("%s: no handler for %s", dev.Name, p.Type)
	}
}

func (d *Daemon) handlePing(dev *Device, p *proto.Packet) {
	var body struct {
		Message string `json:"message"`
	}
	_ = p.Decode(&body)
	text := body.Message
	if text == "" {
		text = "Ping"
	}
	d.toast("%s: %s", dev.Name, text)
	d.notify(desktop.Notification{AppName: dev.Name, Title: "Ping from " + dev.Name, Body: body.Message})
}

func (d *Daemon) handleBattery(dev *Device, p *proto.Packet) {
	var body struct {
		Charge    int  `json:"currentCharge"`
		Charging  bool `json:"isCharging"`
		Threshold int  `json:"thresholdEvent"`
	}
	if p.Decode(&body) != nil {
		return
	}
	d.mu.Lock()
	if body.Charge < 0 {
		dev.battery = nil
	} else {
		dev.battery = &Battery{Charge: body.Charge, Charging: body.Charging}
	}
	d.mu.Unlock()
	if body.Threshold == 1 {
		d.notify(desktop.Notification{AppName: "Flux", Title: dev.Name + " battery is low", Body: strconv.Itoa(body.Charge) + "% left", Urgency: 2})
	}
	d.markDirty()
}

// sendBattery sends the battery of this computer. A desktop without a
// battery sends nothing.
func (d *Daemon) sendBattery(l *lan.Link) {
	b := desktop.ReadBattery()
	if !b.Present {
		return
	}
	threshold := 0
	if b.Charge <= 15 && !b.Charging {
		threshold = 1
	}
	_ = l.Send(proto.New(proto.TypeBattery, map[string]any{"currentCharge": b.Charge, "isCharging": b.Charging, "thresholdEvent": threshold}))
}

// batteryLoop sends the battery to all paired devices when it changes.
func (d *Daemon) batteryLoop(ctx context.Context) {
	last := desktop.ReadBattery()
	tick := time.NewTicker(60 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		b := desktop.ReadBattery()
		if b == last || !b.Present {
			continue
		}
		last = b
		for _, l := range d.pairedLinks() {
			d.sendBattery(l)
		}
	}
}

func (d *Daemon) handleConnectivity(dev *Device, p *proto.Packet) {
	var body struct {
		Signals map[string]struct {
			Type     string `json:"networkType"`
			Strength int    `json:"signalStrength"`
		} `json:"signalStrengths"`
	}
	if p.Decode(&body) != nil {
		return
	}
	d.mu.Lock()
	dev.signal = nil
	best := -1
	for _, s := range body.Signals {
		if s.Strength > best {
			best = s.Strength
			dev.signal = &Signal{Type: s.Type, Strength: s.Strength}
		}
	}
	d.mu.Unlock()
	d.markDirty()
}

func (d *Daemon) handleFindMyPhone(dev *Device) {
	d.mu.Lock()
	d.ringing, d.ringFrom = true, dev.Name
	d.mu.Unlock()
	d.ringer.Start()
	d.notify(desktop.Notification{
		AppName: "Flux", Title: dev.Name + " is ringing this computer",
		Actions: []desktop.Action{{Key: "ring-stop", Label: "I found it"}},
		Urgency: 2, Timeout: -1,
	})
	d.markDirty()
	// Stop after 2 minutes, so a lost phone cannot ring the PC forever.
	time.AfterFunc(2*time.Minute, func() { d.StopRing() })
}

// StopRing stops the local ring.
func (d *Daemon) StopRing() {
	d.ringer.Stop()
	d.mu.Lock()
	changed := d.ringing
	d.ringing, d.ringFrom = false, ""
	d.mu.Unlock()
	if changed {
		d.markDirty()
	}
}

func (d *Daemon) handleRunCommand(dev *Device, l *lan.Link, p *proto.Packet) {
	var body struct {
		Key         string `json:"key"`
		RequestList bool   `json:"requestCommandList"`
	}
	if p.Decode(&body) != nil {
		return
	}
	if body.RequestList {
		d.sendCommandList(l)
	}
	if body.Key == "" {
		return
	}
	cmd, ok := d.command(body.Key)
	if !ok {
		d.logf("%s: no command with ID %q", dev.Name, body.Key)
		return
	}
	d.logf("%s runs %s: %s", dev.Name, cmd.ID, cmd.Command)
	if err := d.runLocal(cmd); err != nil {
		d.toast("%s could not run %s: %v", dev.Name, cmd.Name, err)
		return
	}
	d.toast("%s ran %s", dev.Name, cmd.Name)
}

// runLocal starts a command and logs a failure with its output.
func (d *Daemon) runLocal(cmd config.Command) error {
	return desktop.RunCommand(cmd.Command, func(err error, out []byte) {
		if err != nil {
			d.logf("command %s failed: %v: %s", cmd.ID, err, strings.TrimSpace(string(out)))
			d.toast("%s failed: %v", cmd.Name, err)
		}
	})
}

// sendCommandList sends the command list. KDE Connect encodes the list as
// a JSON string inside the body. The object is written in config order,
// because a JSON map from encoding/json sorts the keys, and phones show the
// commands in the order they read them.
func (d *Daemon) sendCommandList(l *lan.Link) {
	d.mu.Lock()
	var b strings.Builder
	b.WriteByte('{')
	for i, c := range d.cfg.Commands {
		if i > 0 {
			b.WriteByte(',')
		}
		key, _ := json.Marshal(c.ID)
		val, _ := json.Marshal(map[string]string{"name": c.Name, "command": c.Command})
		b.Write(key)
		b.WriteByte(':')
		b.Write(val)
	}
	b.WriteByte('}')
	d.mu.Unlock()
	// canAddCommand is false: the user edits the commands in config.toml.
	_ = l.Send(proto.New(proto.TypeRunCommand, map[string]any{"commandList": b.String(), "canAddCommand": false}))
}
