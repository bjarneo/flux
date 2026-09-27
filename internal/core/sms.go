package core

import (
	"slices"
	"sort"
	"strings"
	"time"

	"flux/internal/proto"
)

// SmsMessage is one text message.
type SmsMessage struct {
	ID     int64  `json:"id"`
	Thread int64  `json:"thread"`
	Body   string `json:"body"`
	// Address is the first address. A received message starts with its
	// sender. Name is the contact name of Address, or Address itself.
	Address   string   `json:"address"`
	Addresses []string `json:"addresses"`
	Name      string   `json:"name"`
	Time      int64    `json:"time"` // seconds
	Outgoing  bool     `json:"outgoing"`
	// Pending is a sent message that is still on its way. Failed is a sent
	// message that the phone could not send.
	Pending bool `json:"pending"`
	Failed  bool `json:"failed"`
	Read    bool `json:"read"`

	ms    int64    // the time in milliseconds
	subID int64    // the SIM, or -1
	names []string // the contact name or the address of each address
}

// Conversation is the latest message of one SMS thread.
type Conversation struct {
	Thread int64 `json:"thread"`
	// Name lists the contact names of the other people, or their
	// addresses. Addresses has more than 1 address in a group.
	Name      string   `json:"name"`
	Address   string   `json:"address"`
	Addresses []string `json:"addresses"`
	Last      string   `json:"last"`
	Time      int64    `json:"time"`
	Unread    bool     `json:"unread"`
	Outgoing  bool     `json:"outgoing"`
	Pending   bool     `json:"pending"`
	Failed    bool     `json:"failed"`

	id    int64
	ms    int64
	subID int64
}

type smsWire struct {
	ID     int64  `json:"_id"`
	Thread int64  `json:"thread_id"`
	Body   string `json:"body"`
	Date   int64  `json:"date"`
	Type   int    `json:"type"`
	Read   int    `json:"read"`
	SubID  *int64 `json:"sub_id"`
	// ContactName is a Flux extension. KDE Connect phones send only the
	// address.
	Addresses []struct {
		Address     string `json:"address"`
		ContactName string `json:"contactName"`
	} `json:"addresses"`
}

// Android message types. The MMS boxes use the same values.
const (
	smsTypeInbox  = 1
	smsTypeOutbox = 4
	smsTypeFailed = 5
	smsTypeQueued = 6
)

func (w smsWire) message() SmsMessage {
	m := SmsMessage{
		ID: w.ID, Thread: w.Thread, Body: w.Body, Time: w.Date / 1000,
		Outgoing: w.Type != smsTypeInbox,
		Pending:  w.Type == smsTypeOutbox || w.Type == smsTypeQueued,
		Failed:   w.Type == smsTypeFailed,
		Read:     w.Read != 0, Addresses: []string{},
		ms: w.Date, subID: -1,
	}
	if w.SubID != nil {
		m.subID = *w.SubID
	}
	for _, a := range w.Addresses {
		addr := strings.TrimSpace(a.Address)
		if addr == "" {
			continue
		}
		name := strings.TrimSpace(a.ContactName)
		if name == "" {
			name = addr
		}
		m.Addresses = append(m.Addresses, addr)
		m.names = append(m.names, name)
	}
	if len(m.Addresses) > 0 {
		m.Address, m.Name = m.Addresses[0], m.names[0]
	}
	return m
}

func (m SmsMessage) conversation() *Conversation {
	return &Conversation{
		Thread: m.Thread, Name: strings.Join(m.names, ", "), Address: m.Address, Addresses: m.Addresses,
		Last: m.Body, Time: m.Time, Unread: !m.Read && !m.Outgoing,
		Outgoing: m.Outgoing, Pending: m.Pending, Failed: m.Failed,
		id: m.ID, ms: m.ms, subID: m.subID,
	}
}

// handleSms stores messages from a phone. The answer to a thread request
// goes to the waiting callers. Each message can also update the
// conversation list.
func (d *Daemon) handleSms(dev *Device, p *proto.Packet) {
	var b struct {
		Messages []smsWire `json:"messages"`
		// ThreadID is a Flux extension. A Flux phone names the thread in
		// the answer to a thread request, so that a new message does not
		// count as the answer.
		ThreadID *int64 `json:"threadID"`
	}
	if p.Decode(&b) != nil {
		return
	}
	msgs := make([]SmsMessage, 0, len(b.Messages))
	threads := map[int64]bool{}
	for _, w := range b.Messages {
		m := w.message()
		msgs = append(msgs, m)
		threads[m.Thread] = true
	}
	d.mu.Lock()
	for _, m := range msgs {
		// A newer message replaces the latest message of its thread. The
		// same message can come again with a new type or read state.
		c, ok := dev.conversations[m.Thread]
		if !ok || m.ms > c.ms || (m.ms == c.ms && m.ID == c.id) {
			dev.conversations[m.Thread] = m.conversation()
		}
	}
	// Other phones send the answer without a thread, so a packet with 1
	// thread counts as the answer.
	answer, found := int64(0), false
	switch {
	case b.ThreadID != nil:
		answer, found = *b.ThreadID, true
	case !dev.fluxApp() && len(threads) == 1:
		for t := range threads {
			answer, found = t, true
		}
	}
	if found {
		for _, ch := range dev.threadWait[answer] {
			select {
			case ch <- msgs:
			default:
			}
		}
		delete(dev.threadWait, answer)
	}
	d.mu.Unlock()
	d.markDirty()
}

// RefreshSms asks the phone for the latest message of each thread.
func (d *Daemon) RefreshSms(dev *Device) error {
	return d.send(dev, proto.New(proto.TypeSmsConversations, map[string]any{}))
}

// SmsThread asks the phone for the messages of a thread and waits up to 8
// seconds for the answer.
func (d *Daemon) SmsThread(dev *Device, thread int64) ([]SmsMessage, error) {
	ch := make(chan []SmsMessage, 1)
	d.mu.Lock()
	dev.threadWait[thread] = append(dev.threadWait[thread], ch)
	d.mu.Unlock()
	if err := d.send(dev, proto.New(proto.TypeSmsConversation, map[string]any{"threadID": thread, "numberToRequest": 100})); err != nil {
		d.stopWait(dev, thread, ch)
		return nil, err
	}
	select {
	case msgs := <-ch:
		sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].ms < msgs[j].ms })
		return msgs, nil
	case <-time.After(8 * time.Second):
		d.stopWait(dev, thread, ch)
		return nil, apiErr("timeout", "%s did not send the conversation", dev.Name)
	}
}

// stopWait removes a caller that no longer waits for a thread.
func (d *Daemon) stopWait(dev *Device, thread int64, ch chan []SmsMessage) {
	d.mu.Lock()
	defer d.mu.Unlock()
	w := slices.DeleteFunc(dev.threadWait[thread], func(c chan []SmsMessage) bool { return c == ch })
	if len(w) == 0 {
		delete(dev.threadWait, thread)
	} else {
		dev.threadWait[thread] = w
	}
}

// SendSms sends a text message through the phone. A reply to a known
// conversation goes out on the SIM of that conversation.
func (d *Daemon) SendSms(dev *Device, addresses []string, body string) error {
	list := make([]map[string]string, 0, len(addresses))
	clean := make([]string, 0, len(addresses))
	for _, a := range addresses {
		if a = strings.TrimSpace(a); a != "" {
			list = append(list, map[string]string{"address": a})
			clean = append(clean, a)
		}
	}
	if len(list) == 0 || strings.TrimSpace(body) == "" {
		return apiErr("bad_params", "Give at least 1 address and a message")
	}
	d.mu.Lock()
	flux := dev.fluxApp()
	sub := conversationSim(dev.conversations, clean)
	d.mu.Unlock()
	if len(list) > 1 && flux {
		return apiErr("unsupported", "%s sends a text message to 1 address. Send group messages on the phone", dev.Name)
	}
	b := map[string]any{"version": 2, "addresses": list, "messageBody": body}
	if sub >= 0 {
		b["subID"] = sub
	}
	return d.send(dev, proto.New(proto.TypeSmsRequest, b))
}

// conversationSim returns the SIM of the newest conversation with exactly
// these addresses, or -1.
func conversationSim(convos map[int64]*Conversation, addresses []string) int64 {
	want := slices.Sorted(slices.Values(addresses))
	sub, newest := int64(-1), int64(-1)
	for _, c := range convos {
		if c.subID < 0 || c.ms <= newest || !slices.Equal(slices.Sorted(slices.Values(c.Addresses)), want) {
			continue
		}
		sub, newest = c.subID, c.ms
	}
	return sub
}

func sortedConversations(m map[int64]*Conversation) []*Conversation {
	out := make([]*Conversation, 0, len(m))
	for _, c := range m {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ms > out[j].ms })
	return out
}
