package proto

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// FuzzUnmarshal parses packet lines from the network. A line must not
// panic, and a packet that parses must have a type and a body.
func FuzzUnmarshal(f *testing.F) {
	for _, seed := range []string{
		`{"id":1727260000000,"type":"flux.ping","body":{"message":"hi"}}`,
		`{"id":"1727260000000","type":"flux.pair","body":{"pair":true,"timestamp":1790000000}}`,
		`{"id":1.5e12,"type":"flux.share.request","body":{"filename":"a.jpg"},"payloadSize":3,"payloadTransferInfo":{"port":12070}}`,
		`{"type":"flux.tunnel","body":null}`,
		`{"type":""}`,
		`{"id":"x","type":"flux.ping"}`,
		`[]`,
		`{"type":"flux.ping","body":{"message":"\u001b]52;c;aGk=\u0007"}}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, line []byte) {
		p, err := Unmarshal(line)
		if err != nil {
			return
		}
		if p.Type == "" || len(p.Type) > maxTypeSize || len(p.Body) == 0 {
			t.Fatalf("packet %+v", p)
		}
		_ = p.Fields()
		_ = p.HasPayload()
		if _, err := p.Marshal(); err != nil {
			t.Fatalf("marshal: %v", err)
		}
	})
}

// FuzzIdentity parses identity packets as the discovery socket and the
// link setup do, and checks the cleaned fields.
func FuzzIdentity(f *testing.F) {
	for _, seed := range []string{
		`{"type":"flux.identity","body":{"deviceId":"9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b","deviceName":"Pixel 8","deviceType":"phone","protocolVersion":8,"tcpPort":12100}}`,
		`{"type":"flux.identity","body":{"deviceId":"9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b","deviceName":"\u001bc\r\nPixel","deviceType":"\u001b]52;c;aGk=\u0007","targetDeviceId":"x","targetProtocolVersion":"8"}}`,
		`{"type":"flux.identity","body":{"deviceId":"short","deviceName":"\u202eevil","app":"android","appVersion":"0.7.0"}}`,
		`{"type":"flux.identity","body":{"targetProtocolVersion":8.9,"incomingCapabilities":["flux.ping"]}}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, line []byte) {
		p, err := Unmarshal(line)
		if err != nil || p.Type != TypeIdentity {
			return
		}
		var id Identity
		if p.Decode(&id) != nil {
			return
		}
		_ = ValidDeviceID(id.DeviceID)
		_ = id.TargetVersion()
		name := CleanName(id.DeviceName)
		if name == "" || utf8.RuneCountInString(name) > 32 || strings.ContainsFunc(name, IsControl) {
			t.Fatalf("CleanName(%q) = %q", id.DeviceName, name)
		}
		if typ := CleanType(id.DeviceType); typ != "" && !strings.Contains("phone tablet desktop laptop tv", typ) {
			t.Fatalf("CleanType(%q) = %q", id.DeviceType, typ)
		}
		if v := CleanText(id.AppVersion, 32); utf8.RuneCountInString(v) > 32 || strings.ContainsFunc(v, IsControl) {
			t.Fatalf("CleanText(%q) = %q", id.AppVersion, v)
		}
	})
}
