package core

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

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
