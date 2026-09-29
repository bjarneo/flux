package lan

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"
)

// dialDelay is how long dialFirst waits for one host before it also tries
// the next host. RFC 8305 uses the same idea for IPv6 and IPv4.
const dialDelay = 300 * time.Millisecond

// dialFirst opens a TCP connection to the first address that accepts.
// Each address is a host and a port. It starts with addrs[0]. It starts
// the next address when the previous address fails or does not answer
// within dialDelay. So the first address wins when it answers in time, and
// an address that does not answer delays the others by dialDelay only.
// dialFirst returns the connection and the index of its address, and it
// closes the connections that come later.
func dialFirst(ctx context.Context, d *net.Dialer, addrs []string) (net.Conn, int, error) {
	if len(addrs) == 0 {
		return nil, -1, errors.New("no address")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		conn net.Conn
		i    int
		err  error
	}
	results := make(chan result, len(addrs))
	next, pending := 0, 0
	start := func() {
		i := next
		next++
		pending++
		go func() {
			c, err := d.DialContext(ctx, "tcp", addrs[i])
			results <- result{c, i, err}
		}()
	}
	start()
	timer := time.NewTimer(dialDelay)
	defer timer.Stop()
	var errs []string
	for pending > 0 {
		select {
		case r := <-results:
			pending--
			if r.err == nil {
				// The context ends when dialFirst returns, so the other dials
				// stop. A dial can still succeed first, so close its connection.
				go func(n int) {
					for range n {
						if late := <-results; late.conn != nil {
							late.conn.Close()
						}
					}
				}(pending)
				return r.conn, r.i, nil
			}
			errs = append(errs, r.err.Error())
		case <-timer.C:
		}
		if next < len(addrs) {
			start()
			timer.Reset(dialDelay)
		}
	}
	return nil, -1, errors.New(strings.Join(errs, ", "))
}
