package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

func smsPacket(body map[string]any) *proto.Packet {
	return proto.New(proto.TypeSmsMessages, body)
}

func wireMessage(id, thread, date int64, typ, read int, addresses ...map[string]any) map[string]any {
	list := []map[string]any{}
	list = append(list, addresses...)
	return map[string]any{"_id": id, "thread_id": thread, "body": "text", "date": date, "type": typ, "read": read, "sub_id": 2, "addresses": list}
}

func addr(a, name string) map[string]any {
	if name == "" {
		return map[string]any{"address": a}
	}
	return map[string]any{"address": a, "contactName": name}
}

func TestSmsWireMessage(t *testing.T) {
	cases := []struct {
		typ                       int
		outgoing, pending, failed bool
	}{
		{1, false, false, false},
		{2, true, false, false},
		{4, true, true, false},
		{5, true, false, true},
		{6, true, true, false},
	}
	for _, c := range cases {
		var w smsWire
		if err := json.Unmarshal(mustJSON(wireMessage(1, 1, 1790000000500, c.typ, 1)), &w); err != nil {
			t.Fatal(err)
		}
		m := w.message()
		if m.Outgoing != c.outgoing || m.Pending != c.pending || m.Failed != c.failed {
			t.Errorf("type %d: outgoing %v, pending %v, failed %v", c.typ, m.Outgoing, m.Pending, m.Failed)
		}
		if m.Time != 1790000000 || m.ms != 1790000000500 {
			t.Errorf("type %d: time %d, ms %d", c.typ, m.Time, m.ms)
		}
	}

	w := smsWire{Addresses: []struct {
		Address     string `json:"address"`
		ContactName string `json:"contactName"`
	}{{" +4798765432 ", "Dan Kim"}, {"", ""}, {"+4791234567", ""}}}
	m := w.message()
	if !slices.Equal(m.Addresses, []string{"+4798765432", "+4791234567"}) || m.Address != "+4798765432" || m.Name != "Dan Kim" {
		t.Fatalf("addresses %v, address %q, name %q", m.Addresses, m.Address, m.Name)
	}
	if c := m.conversation(); c.Name != "Dan Kim, +4791234567" {
		t.Fatalf("group name %q", c.Name)
	}
	if m.subID != -1 {
		t.Fatalf("a message without sub_id has SIM %d", m.subID)
	}
}

func TestHandleSmsConversations(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("p1")
	// A phone sends the newest message first. 2 messages in the same second
	// keep the newer one as the latest.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{
		wireMessage(8, 1, 1790000000900, 1, 0, addr("+4791234567", "Mom")),
		wireMessage(7, 1, 1790000000100, 2, 1, addr("+4791234567", "Mom")),
		wireMessage(3, 2, 1780000000000, 1, 1, addr("72345", "")),
	}}))
	convos := sortedConversations(dev.conversations)
	if len(convos) != 2 || convos[0].Thread != 1 || convos[0].id != 8 || !convos[0].Unread || convos[0].Name != "Mom" {
		t.Fatalf("conversations: %+v", convos)
	}
	if convos[1].Name != "72345" {
		t.Fatalf("a conversation without a contact shows the address: %+v", convos[1])
	}

	// The user reads the message on the phone. The same message comes again.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(8, 1, 1790000000900, 1, 1, addr("+4791234567", "Mom"))}}))
	if dev.conversations[1].Unread {
		t.Fatal("the read message must clear the unread conversation")
	}
	// An older message does not replace the latest message.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(5, 1, 1789000000000, 1, 0, addr("+4791234567", "Mom"))}}))
	if dev.conversations[1].id != 8 {
		t.Fatalf("an older message replaced the latest: %+v", dev.conversations[1])
	}
	// A sent message on its way.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(9, 1, 1790000001000, 4, 1, addr("+4791234567", "Mom"))}}))
	if c := dev.conversations[1]; !c.Outgoing || !c.Pending || c.Unread {
		t.Fatalf("pending message: %+v", c)
	}
}

func TestHandleSmsConversationsAnswer(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("p1")
	threads := func() []int64 {
		var out []int64
		for _, c := range sortedConversations(dev.conversations) {
			out = append(out, c.Thread)
		}
		slices.Sort(out)
		return out
	}
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{
		wireMessage(1, 1, 1790000000000, 1, 1), wireMessage(2, 2, 1790000001000, 1, 1), wireMessage(3, 3, 1790000002000, 1, 1),
	}}))

	// An answer without the marker comes from an older app. It only adds.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(1, 1, 1790000000000, 1, 1)}}))
	if got := threads(); !slices.Equal(got, []int64{1, 2, 3}) {
		t.Fatalf("an answer without the marker removed threads: %v", got)
	}
	// The marker in the answer to a thread request changes nothing.
	d.handleSms(dev, smsPacket(map[string]any{"conversations": true, "threadID": 1, "messages": []any{wireMessage(1, 1, 1790000000000, 1, 1)}}))
	if got := threads(); !slices.Equal(got, []int64{1, 2, 3}) {
		t.Fatalf("a thread answer removed threads: %v", got)
	}

	// The user deleted thread 2 on the phone. The phone splits its answer
	// into 2 packets. The first packet has the marker and replaces the
	// list, and the second packet adds to it.
	d.handleSms(dev, smsPacket(map[string]any{"conversations": true, "messages": []any{wireMessage(3, 3, 1790000002000, 1, 1)}}))
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(1, 1, 1790000000000, 1, 1)}}))
	if got := threads(); !slices.Equal(got, []int64{1, 3}) {
		t.Fatalf("threads after the answer: %v", got)
	}
	// A new message after the answer adds its thread.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(4, 4, 1790000003000, 1, 0)}}))
	if got := threads(); !slices.Equal(got, []int64{1, 3, 4}) {
		t.Fatalf("threads after a new message: %v", got)
	}
}

func TestHandleSmsThreadAnswer(t *testing.T) {
	d := &Daemon{}
	wait := func(dev *Device, thread int64) chan []SmsMessage {
		ch := make(chan []SmsMessage, 1)
		dev.threadWait[thread] = append(dev.threadWait[thread], ch)
		return ch
	}
	one := map[string]any{"messages": []any{wireMessage(8, 1, 1790000000000, 1, 0)}}

	// A Flux phone names the thread in the answer. A new message of the
	// same thread is not the answer.
	flux := newDevice("flux")
	flux.Outgoing = []string{proto.TypeSmsMessages, proto.TypeFluxTunnel}
	ch := wait(flux, 1)
	d.handleSms(flux, smsPacket(one))
	if len(ch) != 0 {
		t.Fatal("a new message from a Flux phone must not answer the thread request")
	}
	d.handleSms(flux, smsPacket(map[string]any{"threadID": 1, "messages": []any{wireMessage(7, 1, 1789000000000, 2, 1), wireMessage(8, 1, 1790000000000, 1, 0)}}))
	if got := <-ch; len(got) != 2 {
		t.Fatalf("the answer has %d messages", len(got))
	}
	if _, ok := flux.threadWait[1]; ok {
		t.Fatal("the answered thread must not wait")
	}
	// An empty thread also answers.
	ch = wait(flux, 4)
	d.handleSms(flux, smsPacket(map[string]any{"threadID": 4, "messages": []any{}}))
	if got := <-ch; len(got) != 0 {
		t.Fatalf("the empty answer has %d messages", len(got))
	}
}

func TestSendSmsGroupToFluxPhone(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("flux")
	dev.Name = "Pixel 8"
	dev.Outgoing = []string{proto.TypeSmsMessages, proto.TypeFluxTunnel}
	var e *Error
	if err := d.SendSms(dev, []string{"+4791234567", "+4798765432"}, "Hi"); !errors.As(err, &e) || e.Code != "unsupported" {
		t.Fatalf("group message to a Flux phone: %v", err)
	}
	if err := d.SendSms(dev, []string{" "}, "Hi"); !errors.As(err, &e) || e.Code != "bad_params" {
		t.Fatalf("empty address: %v", err)
	}
	// 1 address passes the checks and needs the link.
	if err := d.SendSms(dev, []string{"+4791234567"}, "Hi"); !errors.As(err, &e) || e.Code != "offline" {
		t.Fatalf("1 address: %v", err)
	}
}

func TestConversationSim(t *testing.T) {
	convos := map[int64]*Conversation{
		1: {Addresses: []string{"+4791234567"}, ms: 10, subID: 1},
		2: {Addresses: []string{"+4791234567"}, ms: 20, subID: 2},
		3: {Addresses: []string{"+4798765432", "+4791234567"}, ms: 30, subID: 3},
		4: {Addresses: []string{"72345"}, ms: 40, subID: -1},
	}
	cases := []struct {
		addresses []string
		want      int64
	}{
		{[]string{"+4791234567"}, 2},
		{[]string{"+4791234567", "+4798765432"}, 3},
		{[]string{"72345"}, -1},
		{[]string{"+4700000000"}, -1},
	}
	for _, c := range cases {
		if got := conversationSim(convos, c.addresses); got != c.want {
			t.Errorf("%v: SIM %d, want %d", c.addresses, got, c.want)
		}
	}
}

// TestSmsThreadWaitersShareSortedAnswer gives 1 answer to 2 callers that
// wait for the same thread. Each caller only reads the answer, so the race
// detector finds no race, and both get the messages oldest first.
func TestSmsThreadWaitersShareSortedAnswer(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("flux")
	chans := []chan []SmsMessage{make(chan []SmsMessage, 1), make(chan []SmsMessage, 1)}
	dev.threadWait[1] = chans
	var wg sync.WaitGroup
	results := make([][]int64, len(chans))
	for i, ch := range chans {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, m := range <-ch {
				results[i] = append(results[i], m.ID)
			}
		}()
	}
	// A phone sends the newest message first.
	d.handleSms(dev, smsPacket(map[string]any{"threadID": 1, "messages": []any{
		wireMessage(3, 1, 1790000000300, 1, 0), wireMessage(2, 1, 1790000000200, 2, 1), wireMessage(1, 1, 1790000000100, 1, 1),
	}}))
	wg.Wait()
	for i, ids := range results {
		if !slices.Equal(ids, []int64{1, 2, 3}) {
			t.Errorf("caller %d got %v", i, ids)
		}
	}
}

// TestHandleSmsLimits checks that fluxd keeps the newest conversations
// only, cuts the last message and the name of each one, and keeps a
// limited number of short addresses.
func TestHandleSmsLimits(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("p1")
	var msgs []any
	for i := range maxConversations + 100 {
		msgs = append(msgs, wireMessage(int64(i), int64(i), 1790000000000+int64(i), 1, 0))
	}
	// A long address is dropped, not cut.
	many := []map[string]any{addr(strings.Repeat("8", maxSmsAddress+1), "")}
	for range maxSmsAddresses + 10 {
		many = append(many, addr(strings.Repeat("9", maxSmsAddress), strings.Repeat("N", maxSmsName+10)))
	}
	long := wireMessage(99999, 99999, 1800000000000, 1, 0, many...)
	long["body"] = strings.Repeat("x", 100<<10)
	msgs = append(msgs, long)
	d.handleSms(dev, smsPacket(map[string]any{"messages": msgs}))
	if len(dev.conversations) != maxConversations {
		t.Fatalf("%d conversations", len(dev.conversations))
	}
	if _, ok := dev.conversations[0]; ok {
		t.Error("the oldest conversation stays")
	}
	c := dev.conversations[99999]
	if c == nil {
		t.Fatal("the newest conversation is gone")
	}
	if len(c.Last) != maxSmsLast || len(c.Addresses) != maxSmsAddresses || c.Address != strings.Repeat("9", maxSmsAddress) {
		t.Errorf("last %d bytes, %d addresses, address %q", len(c.Last), len(c.Addresses), c.Address)
	}
	if len(c.Name) != maxSmsName {
		t.Errorf("name %d bytes", len(c.Name))
	}
}

func TestSendSmsLength(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("flux")
	dev.Name = "Pixel 8"
	var e *Error
	if err := d.SendSms(dev, []string{"+4791234567"}, strings.Repeat("é", maxSmsSend+1)); !errors.As(err, &e) || e.Code != "bad_params" {
		t.Fatalf("long message: %v", err)
	}
	if err := d.SendSms(dev, []string{"+4791234567"}, strings.Repeat("é", maxSmsSend)); !errors.As(err, &e) || e.Code != "offline" {
		t.Fatalf("message at the limit: %v", err)
	}
}

func TestSamePhone(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"+47 912 34 567", "91234567", true},
		{"+4791234567", "004791234567", true},
		{"+4791234567", "+4791234568", false},
		{"72345", "72345", true},
		{"72345", "072345", false},
		{"Telenor", "telenor", true},
		{"Telenor", "Telia", false},
		{"12", "12", true},
		{"a@b.no", "A@B.NO", true},
	}
	for _, c := range cases {
		if got := samePhone(c.a, c.b); got != c.want {
			t.Errorf("samePhone(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

// smsDaemon returns a daemon with a paired phone that has a link, and the
// packets that the phone gets on that link.
func smsDaemon(t *testing.T) (*Daemon, *Device, chan *proto.Packet) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	desk, phone, _, phoneID := linkPair(t, ctx)
	d := &Daemon{cfg: &config.Config{}, devices: map[string]*Device{}, logger: log.New(io.Discard, "", 0)}
	dev := newDevice(phoneID)
	dev.Name, dev.Paired, dev.link = "Pixel 8", true, desk
	dev.Outgoing = []string{proto.TypeSmsMessages}
	d.devices[dev.ID] = dev
	return d, dev, packets(phone)
}

// outboxOf returns the outbox of the device in the state of the daemon.
func outboxOf(t *testing.T, d *Daemon) []OutboxMessage {
	t.Helper()
	var s struct {
		Devices []struct {
			Outbox []OutboxMessage `json:"outbox"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(d.Snapshot(), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Devices) != 1 {
		t.Fatalf("%d devices in the state", len(s.Devices))
	}
	if s.Devices[0].Outbox == nil {
		t.Fatal("the state has no outbox list")
	}
	return s.Devices[0].Outbox
}

// TestSmsOutbox checks that a sent text message stays in the outbox of the
// device until the phone reports it.
func TestSmsOutbox(t *testing.T) {
	d, dev, fromDesk := smsDaemon(t)
	now := time.Now()
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{
		wireMessage(1, 12, now.Add(-time.Hour).UnixMilli(), 1, 1, addr("+4791234567", "Kari")),
	}}))
	if got := outboxOf(t, d); len(got) != 0 {
		t.Fatalf("outbox before a send: %+v", got)
	}

	if _, err := d.Call(context.Background(), "sms.send", mustJSON(map[string]any{"device": dev.ID, "addresses": []string{"+4791234567"}, "body": "On my way"})); err != nil {
		t.Fatal(err)
	}
	select {
	case p := <-fromDesk:
		if p.Type != proto.TypeSmsRequest {
			t.Fatalf("the phone got %s", p.Type)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the phone got no request")
	}
	got := outboxOf(t, d)
	if len(got) != 1 {
		t.Fatalf("outbox after a send: %+v", got)
	}
	if e := got[0]; e.Thread != 12 || e.Address != "+4791234567" || e.Body != "On my way" || !e.Outgoing || !e.Pending || e.Failed || e.Time < now.Unix() {
		t.Fatalf("entry %+v", e)
	}

	// A received message, another text, and an old message with the same
	// text are not the sent message.
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{
		wireMessage(2, 12, now.UnixMilli(), 1, 0, addr("+4791234567", "Kari")),
		wireMessage(3, 12, now.UnixMilli(), 2, 1, addr("+4791234567", "Kari")),
	}}))
	old := wireMessage(4, 12, now.Add(-(smsClockSlack+10)*time.Second).UnixMilli(), 2, 1, addr("+4791234567", "Kari"))
	old["body"] = "On my way"
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{old}}))
	if got := outboxOf(t, d); len(got) != 1 {
		t.Fatalf("a different message removed the entry: %+v", got)
	}

	// The phone reports the message on its way. The clock of the phone is a
	// minute behind.
	sent := wireMessage(5, 12, now.Add(-time.Minute).UnixMilli(), 4, 1, addr("+4791234567", "Kari"))
	sent["body"] = "On my way"
	d.handleSms(dev, smsPacket(map[string]any{"threadID": 12, "messages": []any{sent}}))
	if got := outboxOf(t, d); len(got) != 0 {
		t.Fatalf("the reported message stays in the outbox: %+v", got)
	}
}

// TestSmsOutboxNewNumber checks that a message to a number without a
// conversation has thread -1, and that the report of the phone matches
// the number in another format.
func TestSmsOutboxNewNumber(t *testing.T) {
	d, dev, _ := smsDaemon(t)
	if err := d.SendSms(dev, []string{"+47 912 34 567"}, "Hello"); err != nil {
		t.Fatal(err)
	}
	got := outboxOf(t, d)
	if len(got) != 1 || got[0].Thread != -1 || got[0].Address != "+47 912 34 567" {
		t.Fatalf("outbox %+v", got)
	}
	sent := wireMessage(1, 30, time.Now().UnixMilli(), 2, 1, addr("91234567", ""))
	sent["body"] = "Hello"
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{sent}}))
	if got := outboxOf(t, d); len(got) != 0 {
		t.Fatalf("the reported message stays in the outbox: %+v", got)
	}
}

// TestSmsOutboxFails checks that an entry that the phone does not report
// in smsSendWait shows as failed, and that a late report removes it.
func TestSmsOutboxFails(t *testing.T) {
	old := smsSendWait
	smsSendWait = 50 * time.Millisecond
	t.Cleanup(func() { smsSendWait = old })
	d, dev, _ := smsDaemon(t)
	if err := d.SendSms(dev, []string{"+4791234567"}, "Are you there?"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the failed entry", func() bool {
		return field(d, func() bool { return len(dev.outbox) == 1 && dev.outbox[0].Failed })
	})
	if e := outboxOf(t, d)[0]; e.Pending || !e.Failed {
		t.Fatalf("entry %+v", e)
	}
	late := wireMessage(1, 12, time.Now().UnixMilli(), 2, 1, addr("+4791234567", ""))
	late["body"] = "Are you there?"
	d.handleSms(dev, smsPacket(map[string]any{"messages": []any{late}}))
	if got := outboxOf(t, d); len(got) != 0 {
		t.Fatalf("the late report did not remove the entry: %+v", got)
	}
}

// TestSmsOutboxLimits checks that a send that fails leaves no entry, and
// that the outbox keeps the newest maxOutbox entries.
func TestSmsOutboxLimits(t *testing.T) {
	d, dev := approveDaemon()
	dev.conversations = map[int64]*Conversation{}
	if err := d.SendSms(dev, []string{"+4791234567"}, "Hi"); errCode(err) != "offline" {
		t.Fatalf("send without a link: %v", err)
	}
	if len(dev.outbox) != 0 {
		t.Fatalf("a send that failed left an entry: %+v", dev.outbox)
	}
	for i := range maxOutbox + 5 {
		d.addOutbox(dev, "+4791234567", fmt.Sprint(i))
	}
	if len(dev.outbox) != maxOutbox || dev.outbox[0].Body != "5" || dev.outbox[maxOutbox-1].Body != fmt.Sprint(maxOutbox+4) {
		t.Fatalf("%d entries, first %q", len(dev.outbox), dev.outbox[0].Body)
	}
}
