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

// handlePacket routes one packet from a device to its plugin. Only
// flux.pair passes before the paired check. A packet from a link that is
// no longer the link of the device counts for nothing.
func (d *Daemon) handlePacket(dev *Device, l *lan.Link, p *proto.Packet) {
	d.mu.Lock()
	current := dev.link == l
	paired := dev.Paired && current
	if current {
		dev.LastSeen = time.Now()
	}
	name := dev.Name
	d.mu.Unlock()

	if !current {
		return
	}
	if p.Type == proto.TypePair {
		d.handlePair(dev, l, p)
		return
	}
	if !paired {
		d.mu.Lock()
		if dev.pairState == "confirm" && dev.pairLink == l {
			if len(dev.confirmQueue) < maxConfirmQueue {
				dev.confirmQueue = append(dev.confirmQueue, p)
			}
			d.mu.Unlock()
			return
		}
		dev.ignored++
		first := dev.ignored == 1
		d.mu.Unlock()
		// A device can send such packets in a loop, so the log shows the
		// first one of each link.
		if first {
			d.logf("%s: ignored %s from a device that is not paired", name, logType(p.Type))
		}
		return
	}
	switch p.Type {
	case proto.TypeFluxTunnel:
		var b struct {
			ID    string `json:"id"`
			Port  int    `json:"port"`
			Error string `json:"error"`
		}
		if p.Decode(&b) == nil {
			l.TunnelReady(b.ID, b.Port, b.Error)
		}
	case proto.TypeIdentity:
		var id proto.Identity
		if p.Decode(&id) == nil && id.DeviceID == dev.ID {
			d.mu.Lock()
			hadTheme := dev.accepts(proto.TypeFluxTheme)
			dev.setIdentity(id)
			newTheme := !hadTheme && dev.accepts(proto.TypeFluxTheme)
			d.mu.Unlock()
			d.markDirty()
			// A phone that starts to follow the theme gets it at once. A
			// slow send of the theme to another phone must not delay the
			// packets of this link.
			if newTheme {
				go d.sendThemeTo(dev, l)
			}
		}
	case proto.TypePing:
		d.handlePing(dev, p)
	case proto.TypeBattery:
		d.handleBattery(dev, p)
	case proto.TypeClipboard, proto.TypeClipboardConnect:
		d.handleClipboard(dev, p)
	case proto.TypeFluxClipboardImage:
		d.handleClipboardImage(dev, l, p)
	case proto.TypeShare:
		d.handleShare(dev, l, p)
	case proto.TypeShareUpdate:
		// The totals of a multi-file share. Flux counts files as they arrive.
	case proto.TypeNotification:
		d.handleNotification(dev, l, p)
	case proto.TypeRunCommand:
		// The command list of another desktop. fluxd does not run commands
		// on other devices.
	case proto.TypeRunCommandRequest:
		d.handleRunCommand(dev, l, p)
	case proto.TypeMprisRequest:
		d.handleDesktopMediaRequest(l, p)
	case proto.TypeSftpRequest:
		d.handleBrowseRequest(dev, l, p)
	case proto.TypeFluxWebcam:
		d.handleWebcam(dev, l, p)
	case proto.TypeFluxDnd:
		d.handleDnd(dev, p)
	case proto.TypeFluxMic:
		d.handleMic(dev, l, p)
	case proto.TypeFluxScreen:
		d.handleScreen(dev, l, p)
	case proto.TypeFluxDesktop:
		d.handleDesktop(dev, l, p)
	case proto.TypeFluxShortcuts:
		d.handleShortcuts(dev, l, p)
	case proto.TypeFluxApprove:
		d.handleApprove(dev, p)
	case proto.TypeFluxHerdr:
		d.handleHerdr(dev, l, p)
	case proto.TypeMousepadRequest:
		d.handleMousepad(dev, p)
	case proto.TypeSmsMessages:
		d.handleSms(dev, p)
	case proto.TypeTelephony:
		d.handleTelephony(dev, p)
	default:
		d.logf("%s: no handler for %s", name, logType(p.Type))
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
	name := d.nameOf(dev)
	d.toast("%s: %s", name, text)
	d.notifyAsync(desktop.Notification{AppName: name, Title: "Ping from " + name, Body: body.Message})
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
	dev.battery = &Battery{Charge: body.Charge, Charging: body.Charging}
	alert := dev.lowBatteryAlert(body.Threshold == 1, body.Charge, body.Charging)
	name := dev.Name
	d.mu.Unlock()
	if alert {
		d.notifyAsync(desktop.Notification{AppName: "Flux", Title: name + " battery is low", Body: strconv.Itoa(body.Charge) + "% left", Urgency: 2})
	}
	d.markDirty()
}

// lowCharge is the charge in percent at or below which a battery that
// does not charge is low.
const lowCharge = 15

// lowBatteryAlert reports whether a battery packet shows the low-battery
// notification. A Flux device marks each reading at or below lowCharge as
// low, also after a reconnect. The notification shows once per discharge.
// It shows again after the battery charges or rises above lowCharge.
func (dev *Device) lowBatteryAlert(low bool, charge int, charging bool) bool {
	switch {
	case low:
		alert := !dev.batteryLow
		dev.batteryLow = true
		return alert
	case charging || charge > lowCharge:
		dev.batteryLow = false
	}
	return false
}

// sendBattery sends the battery of this computer. A desktop without a
// battery sends nothing.
func (d *Daemon) sendBattery(l *lan.Link) {
	b := desktop.ReadBattery()
	if !b.Present {
		return
	}
	threshold := 0
	if b.Charge <= lowCharge && !b.Charging {
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
	name := d.nameOf(dev)
	cmd, ok := d.command(body.Key)
	if !ok {
		d.logf("%s: no command with ID %q", name, body.Key)
		return
	}
	d.logf("%s runs %s: %s", name, cmd.ID, cmd.Command)
	if err := d.runLocal(cmd); err != nil {
		d.toast("%s could not run %s: %v", name, cmd.Name, err)
		return
	}
	d.toast("%s ran %s", name, cmd.Name)
}

// runDesktopCommand starts a shell command on the desktop. Tests replace
// it.
var runDesktopCommand = desktop.RunCommand

// runLocal starts a command and logs a failure with its output.
func (d *Daemon) runLocal(cmd config.Command) error {
	return runDesktopCommand(cmd.Command, func(err error, out []byte) {
		if err != nil {
			d.logf("command %s failed: %v: %s", cmd.ID, err, strings.TrimSpace(string(out)))
			d.toast("%s failed: %v", cmd.Name, err)
		}
	})
}

// sendCommandList sends the command list. The protocol encodes the list as
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
	_ = l.Send(proto.New(proto.TypeRunCommand, map[string]any{"commandList": b.String()}))
}
