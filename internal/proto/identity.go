package proto

import (
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

// Packet types that Flux uses.
const (
	TypeIdentity            = "flux.identity"
	TypePair                = "flux.pair"
	TypePing                = "flux.ping"
	TypeBattery             = "flux.battery"
	TypeClipboard           = "flux.clipboard"
	TypeClipboardConnect    = "flux.clipboard.connect"
	TypeShare               = "flux.share.request"
	TypeShareUpdate         = "flux.share.request.update"
	TypeNotification        = "flux.notification"
	TypeNotificationRequest = "flux.notification.request"
	TypeNotificationReply   = "flux.notification.reply"
	TypeNotificationAction  = "flux.notification.action"
	TypeFindMyPhone         = "flux.findmyphone.request"
	TypeRunCommand          = "flux.runcommand"
	TypeRunCommandRequest   = "flux.runcommand.request"
	TypeMpris               = "flux.mpris"
	TypeMprisRequest        = "flux.mpris.request"
	TypeSftp                = "flux.sftp"
	TypeSftpRequest         = "flux.sftp.request"
	TypeSmsMessages         = "flux.sms.messages"
	TypeSmsRequest          = "flux.sms.request"
	TypeSmsConversations    = "flux.sms.request_conversations"
	TypeSmsConversation     = "flux.sms.request_conversation"
	TypeTelephony           = "flux.telephony"
	// TypeMousepadRequest moves the pointer, clicks, scrolls, and types on
	// this computer. The phone sends it. docs/remote-input.md describes
	// the body.
	TypeMousepadRequest = "flux.mousepad.request"

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
	// TypeFluxMic starts and stops the phone as a microphone. Both sides
	// send it.
	TypeFluxMic = "flux.mic"
	// TypeFluxScreen starts and stops the mirror of the phone screen. Both
	// sides send it.
	TypeFluxScreen = "flux.screen"
	// TypeFluxApprove carries approval and enrollment requests to the phone,
	// and the signed answers back. docs/approve.md describes it.
	TypeFluxApprove = "flux.approve"
	// TypeFluxHerdr carries the herdr agents of the computer to the phone,
	// and the requests of the phone for the agent list and recent output.
	// Both sides send it. docs/herdr.md describes it.
	TypeFluxHerdr = "flux.herdr"
	// TypeFluxClipboardImage carries an image that one side copied. The
	// payload is the image, and the body names its MIME type, {"mime":
	// "image/png"}. Both sides send it. A phone lists it as incoming only
	// while its clipboard sync is on.
	TypeFluxClipboardImage = "flux.clipboard.image"
	// TypeFluxInput tells the phone whether this computer accepts remote
	// input and whether it shows its screen on the phone, {"enabled":
	// bool, "desktop": bool}. fluxd sends it after the link starts and
	// after a setting changes.
	TypeFluxInput = "flux.input"
	// TypeFluxDesktop starts and stops the stream of this screen to the
	// phone. Both sides send it.
	TypeFluxDesktop = "flux.desktop"
	// TypeFluxShortcuts carries the Hyprland key bindings and workspaces to
	// the phone, and runs a binding or a workspace action for it. Both
	// sides send it.
	TypeFluxShortcuts = "flux.shortcuts"
	// TypeFluxTheme carries the active Omarchy theme of this computer to
	// the phone: the name, the mode, the colors, and the Hyprland active
	// border. fluxd sends it after the link starts and after the theme
	// changes, only to a device that lists it as incoming. docs/omarchy.md
	// describes the body.
	TypeFluxTheme = "flux.theme"
)

// Incoming lists the packet types that Flux accepts. The phone enables a
// plugin only when the other side lists the matching type.
var Incoming = []string{
	TypePing, TypeBattery, TypeClipboard, TypeClipboardConnect,
	TypeShare, TypeShareUpdate, TypeNotification, TypeRunCommandRequest,
	TypeMprisRequest, TypeSftpRequest,
	TypeSmsMessages, TypeTelephony,
	TypeFluxTunnel, TypeFluxWebcam, TypeFluxDnd, TypeFluxMic, TypeFluxScreen,
	TypeFluxApprove, TypeFluxHerdr, TypeFluxClipboardImage, TypeMousepadRequest,
	TypeFluxDesktop, TypeFluxShortcuts,
}

// Outgoing lists the packet types that Flux sends.
var Outgoing = []string{
	TypePing, TypeBattery, TypeClipboard, TypeClipboardConnect, TypeShare,
	TypeNotification, TypeNotificationRequest, TypeNotificationReply, TypeNotificationAction,
	TypeFindMyPhone, TypeRunCommand, TypeMpris,
	TypeSmsRequest, TypeSmsConversations,
	TypeSmsConversation, TypeSftp, TypeFluxWebcam, TypeFluxDnd,
	TypeFluxMic, TypeFluxScreen, TypeFluxApprove, TypeFluxHerdr,
	TypeFluxClipboardImage, TypeFluxInput, TypeFluxDesktop, TypeFluxShortcuts,
	TypeFluxTheme,
}

// Identity is the body of a flux.identity packet.
type Identity struct {
	DeviceID             string   `json:"deviceId"`
	DeviceName           string   `json:"deviceName"`
	DeviceType           string   `json:"deviceType"`
	ProtocolVersion      int      `json:"protocolVersion"`
	IncomingCapabilities []string `json:"incomingCapabilities"`
	OutgoingCapabilities []string `json:"outgoingCapabilities"`
	TCPPort              int      `json:"tcpPort,omitempty"`
	// App and AppVersion name the Flux program that sends the identity
	// and its version: "fluxd", "android", "android-debug", "ios", or
	// "macos", and a version such as "0.7.0". An earlier Flux app sends
	// neither.
	App        string `json:"app,omitempty"`
	AppVersion string `json:"appVersion,omitempty"`
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

// ValidDeviceID reports whether id has the Flux device ID format.
func ValidDeviceID(id string) bool { return deviceIDRe.MatchString(id) }

// CleanName removes the characters that Flux does not allow in a
// device name, control characters, and bidi controls. It limits the name to
// 32 characters. A name then cannot move the cursor of a terminal, add a
// line to a log, or change the order of the text around it.
func CleanName(name string) string {
	name = strings.Map(dropControl, name)
	name = strings.TrimSpace(nameInvalidChars.ReplaceAllString(name, ""))
	if r := []rune(name); len(r) > 32 {
		name = strings.TrimSpace(string(r[:32]))
	}
	if name == "" {
		name = "omarchy"
	}
	return name
}

// IsControl reports whether r is a control character or a bidi control:
// C0, DEL, C1, and the marks, embeddings, overrides, and isolates that
// change the direction of text. A terminal or a text view does not show
// them as text.
func IsControl(r rune) bool {
	switch {
	case unicode.IsControl(r):
		return true
	case r == 0x061c, r == 0x200e, r == 0x200f:
		return true
	case r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069:
		return true
	}
	return false
}

func dropControl(r rune) rune {
	if IsControl(r) {
		return -1
	}
	return r
}

// CleanText removes control characters and bidi controls from s and
// limits it to max characters. Flux uses it for short text from the
// network, such as the app version of a device.
func CleanText(s string, max int) string {
	s = strings.TrimSpace(strings.Map(dropControl, s))
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}

// deviceTypes are the device types that Flux knows.
var deviceTypes = []string{"phone", "tablet", "desktop", "laptop", "tv"}

// CleanType returns t when it is a device type that Flux knows, and ""
// for any other value. The UI shows "" as a phone.
func CleanType(t string) string {
	if slices.Contains(deviceTypes, t) {
		return t
	}
	return ""
}

// DeviceType returns "laptop" when the machine has a battery and "desktop"
// when it does not. It reads sysfs on the first call only.
func DeviceType() string { return deviceType() }

var deviceType = sync.OnceValue(readDeviceType)

func readDeviceType() string {
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
