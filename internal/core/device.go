package core

import (
	"bytes"
	"crypto/x509"
	"slices"
	"time"

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

	// App and AppVersion come from the identity of the device.
	App        string
	AppVersion string

	// Addresses are the extra host names and IP addresses of a paired
	// device. They come from the trust store.
	Addresses []string

	link     *lan.Link
	mdnsSeen time.Time
	// dialTries counts the dials since the device was last seen. dialAt is
	// the time of the last dial.
	dialTries int
	dialAt    time.Time
	// inputRefused is true after fluxd logged remote input that it
	// ignored, so that it logs that once.
	inputRefused bool
	// oldApp is true after the device announced an app from before Flux
	// 0.8, until it links.
	oldApp bool

	pairState string // "", "requested", "confirm", or "incoming"
	pairTime  int64
	pairKey   string
	pairTimer *time.Timer

	battery       *Battery
	batteryLow    bool // the low-battery notification of this discharge showed
	notifications []*PhoneNotification
	notifDesktop  map[string]uint32
	conversations map[int64]*Conversation
	threadWait    map[int64][]chan []SmsMessage

	// pairLink and pairCert are the link and the certificate on which the
	// open pairing started. pairKey comes from pairCert, and only pairCert
	// can be pinned. pairAt is the time of the last pair request, and
	// pairNote is the desktop notification of an incoming request.
	pairLink *lan.Link
	pairCert *x509.Certificate
	pairAt   time.Time
	pairNote uint32

	// badTrust is true when devices.json has an entry for the device with a
	// certificate that does not parse. The device then counts as not
	// paired, and fluxd refuses every link of the device.
	badTrust bool

	// seenIP and seenPort are the address that discovery last reported for
	// a paired device, at seenAt. fluxd dials it, but only a link that
	// passes the pin check changes IP and Port.
	seenIP   string
	seenPort int
	seenAt   time.Time

	// ignored counts the packets of the current link that fluxd dropped,
	// because the device is not paired.
	ignored int

	// pairEnded is the time of the last pair false, reject, or timeout of
	// a pairing in state "incoming" or "confirm", or of the end of the link
	// of an incoming request. A new pair request of the device counts only
	// pairRetry after it.
	//
	// unpairPeer is true when a pairing in state "confirm" ended with its
	// link. The device pinned this computer, so fluxd sends pair false on
	// the next link that shows unpairCert, the certificate of that
	// pairing. The device stays in the list of fluxd until then.
	pairEnded  time.Time
	unpairPeer bool
	unpairCert *x509.Certificate

	// confirmQueue holds the packets that the device sent on the link of a
	// pairing in state "confirm". The device counts itself as paired when
	// it answers, so it sends its first packets, such as the battery, at
	// once. fluxd handles them after the user confirms the pairing, and
	// drops them when the pairing ends in another way.
	confirmQueue []*proto.Packet

	// outbox holds the text messages that fluxd sent through the device
	// and that the device has not reported yet, the oldest first.
	// outboxSeq numbers the entries.
	outbox    []OutboxMessage
	outboxSeq int64
}

// Battery is the battery state of a device.
type Battery struct {
	Charge   int  `json:"charge"`
	Charging bool `json:"charging"`
}

func newDevice(id string) *Device {
	return &Device{
		ID:            id,
		notifDesktop:  map[string]uint32{},
		conversations: map[int64]*Conversation{},
		threadWait:    map[int64][]chan []SmsMessage{},
	}
}

// applyTrust copies a trust entry to the device. A certificate that does
// not parse makes the device count as not paired, and fluxd then refuses
// its links. applyTrust returns the parse error.
func (dev *Device) applyTrust(t config.TrustedDevice) error {
	dev.Name, dev.Type, dev.IP, dev.Port = proto.CleanName(t.Name), proto.CleanType(t.Type), t.LastIP, t.LastPort
	c, err := proto.ParseCertPEM(t.CertPEM)
	if err != nil {
		dev.badTrust = true
		return err
	}
	dev.Addresses = t.Addresses
	dev.Paired, dev.PairedAt = true, t.PairedAt
	dev.Cert = c
	return nil
}

// maxAppText is the longest app name and app version that fluxd keeps.
const maxAppText = 32

func (dev *Device) setIdentity(id proto.Identity) {
	dev.Name = proto.CleanName(id.DeviceName)
	dev.Type = proto.CleanType(id.DeviceType)
	dev.Version = id.ProtocolVersion
	dev.Incoming = id.IncomingCapabilities
	dev.Outgoing = id.OutgoingCapabilities
	dev.App, dev.AppVersion = proto.CleanText(id.App, maxAppText), proto.CleanText(id.AppVersion, maxAppText)
	dev.oldApp = false
	// A device that stops sharing a feature keeps no old data of it.
	if !dev.supports(proto.TypeNotification) {
		dev.notifications = nil
	}
	if !dev.supports(proto.TypeSmsMessages) && len(dev.conversations) > 0 {
		dev.conversations = map[int64]*Conversation{}
	}
	if !dev.supports(proto.TypeSmsMessages) {
		dev.outbox = nil
	}
}

// pinLocked returns the certificate that a new link of the device must
// present: the pinned certificate of a paired device, or the certificate of
// an open pairing. ok is false when any certificate can link. A nil
// certificate with ok true refuses every link. The caller holds d.mu.
func (dev *Device) pinLocked() (cert *x509.Certificate, ok bool) {
	switch {
	case dev.badTrust:
		return nil, true
	case dev.Paired:
		return dev.Cert, true
	case dev.pairState != "" && dev.pairCert != nil:
		return dev.pairCert, true
	}
	return nil, false
}

// refuseLocked returns why fluxd refuses the link l of the device, or ""
// when the link can replace the current link. The caller holds d.mu.
func (dev *Device) refuseLocked(l *lan.Link) string {
	pin, ok := dev.pinLocked()
	switch {
	case !ok:
		return ""
	case pin == nil:
		return "devices.json has no valid certificate for the device. To pair it again, run: flux-cli unpair " + dev.ID
	case l.Cert == nil || !bytes.Equal(pin.Raw, l.Cert.Raw):
		if dev.Paired {
			return "the certificate differs from the certificate of the pairing"
		}
		return "a pairing with another certificate is open"
	}
	return ""
}

// nameOf returns the name of the device. An identity packet can change the
// name at any time, so a handler reads it under d.mu.
func (d *Daemon) nameOf(dev *Device) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return dev.Name
}

// stillPaired reports whether dev is paired now. A transfer or a herdr
// call can take seconds, and it must not act for the device after an
// unpair.
func (d *Daemon) stillPaired(dev *Device) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return dev.Paired
}

// supports reports whether the device sends packets of the type.
func (dev *Device) supports(typ string) bool { return slices.Contains(dev.Outgoing, typ) }

// accepts reports whether the device receives packets of the type.
func (dev *Device) accepts(typ string) bool { return slices.Contains(dev.Incoming, typ) }

// plugins returns the features that the device offers to this computer.
// The window uses them to show or hide tabs. Each check looks at the
// direction that the feature needs.
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
		{"sms", dev.supports(proto.TypeSmsMessages)},
		{"runcommand", dev.supports(proto.TypeRunCommandRequest)},
		// The device can start its camera and its microphone when this
		// computer asks, after a tap of its user.
		{"streamrequest", dev.accepts(proto.TypeFluxStreamRequest)},
	}
	out := []string{}
	for _, c := range checks {
		if c.ok {
			out = append(out, c.name)
		}
	}
	return out
}

// DeviceView is the device as the UI sees it.
type DeviceView struct {
	ID            string               `json:"id"`
	Name          string               `json:"name"`
	Type          string               `json:"type"`
	IP            string               `json:"ip"`
	Addresses     []string             `json:"addresses"`
	Paired        bool                 `json:"paired"`
	Online        bool                 `json:"online"`
	PairState     string               `json:"pairState"`
	PairKey       string               `json:"pairKey"`
	PairedAt      string               `json:"pairedAt"`
	LastSeen      int64                `json:"lastSeen"`
	Battery       *Battery             `json:"battery"`
	Plugins       []string             `json:"plugins"`
	Notifications []*PhoneNotification `json:"notifications"`
	Conversations []*Conversation      `json:"conversations"`

	// App and AppVersion name the Flux app of the device and its version,
	// or are empty for an earlier app. AppUpdate is the version of a newer
	// Android app in the latest release, or "".
	App        string `json:"app"`
	AppVersion string `json:"appVersion"`
	AppUpdate  string `json:"appUpdate"`
	// OldApp is true when the device runs a Flux app from before 0.8,
	// which cannot connect to this fluxd.
	OldApp bool `json:"oldApp"`

	// Fingerprint is 16 hex digits from the certificate of the device, or
	// "" when fluxd knows no certificate. It tells 2 devices with the same
	// name apart.
	Fingerprint string `json:"fingerprint"`

	// Outbox lists the text messages that fluxd sent through the device
	// and that the device has not reported yet, the oldest first.
	Outbox []OutboxMessage `json:"outbox"`
}

func (dev *Device) view() DeviceView {
	state := dev.pairState
	if state == "" && dev.Paired {
		state = "paired"
	} else if state == "" {
		state = "none"
	}
	v := DeviceView{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, IP: dev.IP, Addresses: dev.Addresses,
		Paired: dev.Paired, Online: dev.link != nil,
		PairState: state, PairKey: dev.pairKey, PairedAt: dev.PairedAt,
		Battery: dev.battery,
		Plugins: dev.plugins(), Notifications: dev.notifications,
		App: dev.App, AppVersion: dev.AppVersion, OldApp: dev.oldApp,
		Fingerprint: proto.Fingerprint(dev.Cert),
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
	if v.Addresses == nil {
		v.Addresses = []string{}
	}
	v.Conversations = sortedConversations(dev.conversations)
	// A timer of the outbox changes an entry in place.
	v.Outbox = slices.Clone(dev.outbox)
	if v.Outbox == nil {
		v.Outbox = []OutboxMessage{}
	}
	return v
}
