package proto

import (
	"os"
	"regexp"
	"strconv"
	"strings"
)

// Packet types that Flux uses.
const (
	TypeIdentity            = "kdeconnect.identity"
	TypePair                = "kdeconnect.pair"
	TypePing                = "kdeconnect.ping"
	TypeBattery             = "kdeconnect.battery"
	TypeClipboard           = "kdeconnect.clipboard"
	TypeClipboardConnect    = "kdeconnect.clipboard.connect"
	TypeShare               = "kdeconnect.share.request"
	TypeShareUpdate         = "kdeconnect.share.request.update"
	TypeNotification        = "kdeconnect.notification"
	TypeNotificationRequest = "kdeconnect.notification.request"
	TypeNotificationReply   = "kdeconnect.notification.reply"
	TypeNotificationAction  = "kdeconnect.notification.action"
	TypeFindMyPhone         = "kdeconnect.findmyphone.request"
	TypeRunCommand          = "kdeconnect.runcommand"
	TypeRunCommandRequest   = "kdeconnect.runcommand.request"
	TypeMpris               = "kdeconnect.mpris"
	TypeMprisRequest        = "kdeconnect.mpris.request"
	TypeSftp                = "kdeconnect.sftp"
	TypeSftpRequest         = "kdeconnect.sftp.request"
	TypeSmsMessages         = "kdeconnect.sms.messages"
	TypeSmsRequest          = "kdeconnect.sms.request"
	TypeSmsConversations    = "kdeconnect.sms.request_conversations"
	TypeSmsConversation     = "kdeconnect.sms.request_conversation"
	TypeConnectivity        = "kdeconnect.connectivity_report"

	// TypeFluxTunnel carries the port of a listener that a Flux phone opens,
	// so that fluxd can connect out for payloads and Browse PC. The phone
	// sends it, and fluxd receives it.
	TypeFluxTunnel = "flux.tunnel"
	// TypeFluxWebcam starts and stops the phone as a webcam. Both sides
	// send it.
	TypeFluxWebcam = "flux.webcam"
	// TypeFluxDnd carries the Do Not Disturb state, {"on": bool}. Each side
	// sends it after a local change. Both sides send it.
	TypeFluxDnd = "flux.dnd"
)

// Incoming lists the packet types that Flux accepts. The phone enables a
// plugin only when the other side lists the matching type.
var Incoming = []string{
	TypePing, TypeBattery, TypeClipboard, TypeClipboardConnect,
	TypeShare, TypeShareUpdate, TypeNotification, TypeFindMyPhone,
	TypeRunCommandRequest, TypeMpris, TypeMprisRequest, TypeSftp,
	TypeSftpRequest, TypeSmsMessages, TypeConnectivity, TypeFluxTunnel,
	TypeFluxWebcam, TypeFluxDnd,
}

// Outgoing lists the packet types that Flux sends.
var Outgoing = []string{
	TypePing, TypeBattery, TypeClipboard, TypeClipboardConnect, TypeShare,
	TypeNotificationRequest, TypeNotificationReply, TypeNotificationAction,
	TypeFindMyPhone, TypeRunCommand, TypeMpris, TypeMprisRequest,
	TypeSftpRequest, TypeSmsRequest, TypeSmsConversations,
	TypeSmsConversation, TypeSftp, TypeFluxWebcam, TypeFluxDnd,
}

// Identity is the body of a kdeconnect.identity packet.
type Identity struct {
	DeviceID             string   `json:"deviceId"`
	DeviceName           string   `json:"deviceName"`
	DeviceType           string   `json:"deviceType"`
	ProtocolVersion      int      `json:"protocolVersion"`
	IncomingCapabilities []string `json:"incomingCapabilities"`
	OutgoingCapabilities []string `json:"outgoingCapabilities"`
	TCPPort              int      `json:"tcpPort,omitempty"`
	// TargetDeviceID and TargetProtocolVersion go only in the plain-text
	// identity that the connecting side writes before TLS. The receiver
	// closes the socket when they do not match its own identity.
	TargetDeviceID        string `json:"targetDeviceId,omitempty"`
	TargetProtocolVersion any    `json:"targetProtocolVersion,omitempty"`
}

// TargetVersion returns targetProtocolVersion as a number. Android sends it
// as a string.
func (id Identity) TargetVersion() int {
	switch v := id.TargetProtocolVersion.(type) {
	case float64:
		return int(v)
	case string:
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

var (
	deviceIDRe       = regexp.MustCompile(`^[a-zA-Z0-9_-]{32,38}$`)
	nameInvalidChars = regexp.MustCompile(`["',;:.!?()\[\]<>]`)
)

// ValidDeviceID reports whether id has the KDE Connect device ID format.
func ValidDeviceID(id string) bool { return deviceIDRe.MatchString(id) }

// CleanName removes the characters that KDE Connect does not allow in a
// device name and limits the name to 32 characters.
func CleanName(name string) string {
	name = strings.TrimSpace(nameInvalidChars.ReplaceAllString(name, ""))
	if r := []rune(name); len(r) > 32 {
		name = strings.TrimSpace(string(r[:32]))
	}
	if name == "" {
		name = "omarchy"
	}
	return name
}

// DeviceType returns "laptop" when the machine has a battery and "desktop"
// when it does not.
func DeviceType() string {
	if b, err := os.ReadFile("/sys/class/dmi/id/chassis_type"); err == nil {
		switch strings.TrimSpace(string(b)) {
		case "8", "9", "10", "11", "14", "30", "31", "32":
			return "laptop"
		}
	}
	matches, _ := os.ReadDir("/sys/class/power_supply")
	for _, m := range matches {
		if strings.HasPrefix(m.Name(), "BAT") {
			return "laptop"
		}
	}
	return "desktop"
}

// NewIdentity returns the identity that Flux sends.
func NewIdentity(id, name string, tcpPort int) Identity {
	return Identity{
		DeviceID:             id,
		DeviceName:           CleanName(name),
		DeviceType:           DeviceType(),
		ProtocolVersion:      ProtocolVersion,
		IncomingCapabilities: Incoming,
		OutgoingCapabilities: Outgoing,
		TCPPort:              tcpPort,
	}
}
