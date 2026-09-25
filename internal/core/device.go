package core

import (
	"crypto/x509"
	"slices"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// Device is one known device: paired, or seen on the network.
type Device struct {
	ID       string
	Name     string
	Type     string
	IP       string
	Port     int // TCP listener port of the device
	Version  int
	Incoming []string
	Outgoing []string
	Paired   bool
	PairedAt string
	Cert     *x509.Certificate
	LastSeen time.Time

	link     *lan.Link
	mdnsSeen time.Time

	pairState string // "", "requested", or "incoming"
	pairTime  int64
	pairKey   string
	pairTimer *time.Timer

	battery       *Battery
	signal        *Signal
	notifications []*PhoneNotification
	notifDesktop  map[string]uint32
	media         *PhoneMedia
	conversations map[int64]*Conversation
	threadWait    map[int64][]chan []SmsMessage
	sftpWait      []chan SftpInfo
	sftpSSH       *ssh.Client
	sftpClient    *sftp.Client
	sftpRoots     []BrowseRoot
	theme         string
}

// Battery is the battery state of a device.
type Battery struct {
	Charge   int  `json:"charge"`
	Charging bool `json:"charging"`
}

// Signal is the cellular signal of a phone.
type Signal struct {
	Type     string `json:"type"`
	Strength int    `json:"strength"`
}

func newDevice(id string) *Device {
	return &Device{
		ID:            id,
		notifDesktop:  map[string]uint32{},
		conversations: map[int64]*Conversation{},
		threadWait:    map[int64][]chan []SmsMessage{},
	}
}

func (dev *Device) applyTrust(t config.TrustedDevice) {
	dev.Name, dev.Type, dev.IP, dev.Port = t.Name, t.Type, t.LastIP, t.LastPort
	dev.Paired, dev.PairedAt = true, t.PairedAt
	if c, err := proto.ParseCertPEM(t.CertPEM); err == nil {
		dev.Cert = c
	}
}

func (dev *Device) setIdentity(id proto.Identity) {
	dev.Name = proto.CleanName(id.DeviceName)
	dev.Type = id.DeviceType
	dev.Version = id.ProtocolVersion
	dev.Incoming = id.IncomingCapabilities
	dev.Outgoing = id.OutgoingCapabilities
}

// supports reports whether the device sends packets of the type.
func (dev *Device) supports(typ string) bool { return slices.Contains(dev.Outgoing, typ) }

// accepts reports whether the device receives packets of the type.
func (dev *Device) accepts(typ string) bool { return slices.Contains(dev.Incoming, typ) }

// plugins returns the features that the device offers to this computer.
// The window uses them to show or hide tabs. Each check looks at the
// direction that the feature needs. For example, the Browse files tab
// needs a device that sends kdeconnect.sftp, not one that only asks for it.
func (dev *Device) plugins() []string {
	checks := []struct {
		name string
		ok   bool
	}{
		{"battery", dev.supports(proto.TypeBattery)},
		{"clipboard", dev.supports(proto.TypeClipboard) || dev.accepts(proto.TypeClipboard)},
		{"share", dev.accepts(proto.TypeShare)},
		{"notifications", dev.supports(proto.TypeNotification)},
		{"findmyphone", dev.accepts(proto.TypeFindMyPhone)},
		{"mpris", dev.supports(proto.TypeMpris)},
		{"sms", dev.supports(proto.TypeSmsMessages)},
		{"runcommand", dev.supports(proto.TypeRunCommandRequest)},
		{"sftp", dev.sharesStorage()},
		{"connectivity", dev.supports(proto.TypeConnectivity)},
	}
	out := []string{}
	for _, c := range checks {
		if c.ok {
			out = append(out, c.name)
		}
	}
	return out
}

// sharesStorage reports whether the device runs an SFTP server for its own
// storage, which the Browse files tab needs. fluxd also sends
// kdeconnect.sftp, but only to answer Browse PC, so a desktop does not
// count.
func (dev *Device) sharesStorage() bool {
	return dev.supports(proto.TypeSftp) && dev.Type != "desktop" && dev.Type != "laptop"
}

func (dev *Device) closeSftp() {
	if dev.sftpClient != nil {
		dev.sftpClient.Close()
		dev.sftpClient = nil
	}
	if dev.sftpSSH != nil {
		dev.sftpSSH.Close()
		dev.sftpSSH = nil
	}
	dev.sftpRoots = nil
}

// DeviceView is the device as the UI sees it.
type DeviceView struct {
	ID            string               `json:"id"`
	Name          string               `json:"name"`
	Type          string               `json:"type"`
	IP            string               `json:"ip"`
	Paired        bool                 `json:"paired"`
	Online        bool                 `json:"online"`
	PairState     string               `json:"pairState"`
	PairKey       string               `json:"pairKey"`
	PairedAt      string               `json:"pairedAt"`
	LastSeen      int64                `json:"lastSeen"`
	Battery       *Battery             `json:"battery"`
	Signal        *Signal              `json:"signal"`
	Plugins       []string             `json:"plugins"`
	Notifications []*PhoneNotification `json:"notifications"`
	Media         *PhoneMedia          `json:"media"`
	Conversations []*Conversation      `json:"conversations"`
}

func (dev *Device) view() DeviceView {
	state := dev.pairState
	if state == "" && dev.Paired {
		state = "paired"
	} else if state == "" {
		state = "none"
	}
	v := DeviceView{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, IP: dev.IP,
		Paired: dev.Paired, Online: dev.link != nil,
		PairState: state, PairKey: dev.pairKey, PairedAt: dev.PairedAt,
		Battery: dev.battery, Signal: dev.signal,
		Plugins: dev.plugins(), Notifications: dev.notifications, Media: dev.media,
	}
	if v.Type == "" {
		v.Type = "phone"
	}
	if !dev.LastSeen.IsZero() {
		v.LastSeen = dev.LastSeen.Unix()
	}
	if v.Notifications == nil {
		v.Notifications = []*PhoneNotification{}
	}
	v.Conversations = sortedConversations(dev.conversations)
	return v
}
