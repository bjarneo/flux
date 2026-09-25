package core

import (
	"sort"
	"time"

	"flux/internal/proto"
)

// SmsMessage is one text message.
type SmsMessage struct {
	ID       int64  `json:"id"`
	Thread   int64  `json:"thread"`
	Body     string `json:"body"`
	Address  string `json:"address"`
	Time     int64  `json:"time"` // seconds
	Outgoing bool   `json:"outgoing"`
	Read     bool   `json:"read"`
}

// Conversation is the latest message of one SMS thread.
type Conversation struct {
	Thread  int64  `json:"thread"`
	Name    string `json:"name"`
	Address string `json:"address"`
	Last    string `json:"last"`
	Time    int64  `json:"time"`
	Unread  bool   `json:"unread"`
}

type smsWire struct {
	ID        int64  `json:"_id"`
	Thread    int64  `json:"thread_id"`
	Body      string `json:"body"`
	Date      int64  `json:"date"`
	Type      int    `json:"type"`
	Read      int    `json:"read"`
	Addresses []struct {
		Address string `json:"address"`
	} `json:"addresses"`
}

// Android message types. Type 2 is a sent message.
const smsTypeSent = 2

func (w smsWire) message() SmsMessage {
	m := SmsMessage{ID: w.ID, Thread: w.Thread, Body: w.Body, Time: w.Date / 1000, Outgoing: w.Type == smsTypeSent, Read: w.Read != 0}
	if len(w.Addresses) > 0 {
		m.Address = w.Addresses[0].Address
	}
	return m
}

// handleSms stores messages from a phone. A reply to a thread request goes
// to the waiting caller. Other packets update the conversation list.
func (d *Daemon) handleSms(dev *Device, p *proto.Packet) {
	var b struct {
		Messages []smsWire `json:"messages"`
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
		c, ok := dev.conversations[m.Thread]
		if !ok || m.Time >= c.Time {
			addr := m.Address
			dev.conversations[m.Thread] = &Conversation{
				Thread: m.Thread, Name: addr, Address: addr, Last: m.Body, Time: m.Time, Unread: !m.Read && !m.Outgoing,
			}
		}
	}
	if len(threads) == 1 {
		for thread := range threads {
			for _, ch := range dev.threadWait[thread] {
				select {
				case ch <- msgs:
				default:
				}
			}
			delete(dev.threadWait, thread)
		}
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
		return nil, err
	}
	select {
	case msgs := <-ch:
		sort.Slice(msgs, func(i, j int) bool { return msgs[i].Time < msgs[j].Time })
		return msgs, nil
	case <-time.After(8 * time.Second):
		return nil, apiErr("timeout", "%s did not send the conversation", dev.Name)
	}
}

// SendSms sends a text message through the phone.
func (d *Daemon) SendSms(dev *Device, addresses []string, body string) error {
	if len(addresses) == 0 || body == "" {
		return apiErr("bad_params", "Give at least 1 address and a message")
	}
	list := make([]map[string]string, 0, len(addresses))
	for _, a := range addresses {
		list = append(list, map[string]string{"address": a})
	}
	return d.send(dev, proto.New(proto.TypeSmsRequest, map[string]any{"version": 2, "addresses": list, "messageBody": body}))
}

func sortedConversations(m map[int64]*Conversation) []*Conversation {
	out := make([]*Conversation, 0, len(m))
	for _, c := range m {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Time > out[j].Time })
	return out
}
