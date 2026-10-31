// Command flux-android-tsnet runs a userspace tailnet node for Flux for
// Android. It joins the tailnet without a VPN interface and forwards the
// Flux ports to the listeners of the app on loopback.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	// Android denies app UIDs the NETLINK_ROUTE socket, so netmon cannot
	// list interfaces. This registers the synthetic fallback, and it also
	// brings the Android DNS and CA roots that a standalone binary needs.
	_ "tailscale.com/feature/androidbin"

	"tailscale.com/tsnet"
)

func main() {
	var (
		stateDir   = flag.String("state-dir", "", "directory for the node state")
		hostname   = flag.String("hostname", "flux-phone", "tailnet hostname")
		host       = flag.String("host", "127.0.0.1", "forward target host")
		parentPID  = flag.Int("parent-pid", 0, "exit when this process is gone")
		watchStdin = flag.Bool("watch-stdin", true, "exit when stdin closes")
		ports      = flag.String("ports", "", "comma separated ports, or empty for the Flux ports")
	)
	flag.Parse()

	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	if *stateDir == "" {
		fatalf("state-dir is required")
	}
	authKey := os.Getenv("TS_AUTHKEY")
	if authKey == "" {
		fatalf("TS_AUTHKEY is required")
	}
	list, err := parsePorts(*ports)
	if err != nil {
		fatalf("ports: %v", err)
	}

	srv := &tsnet.Server{
		Dir:      *stateDir,
		Hostname: *hostname,
		AuthKey:  authKey,
		Logf:     log.Printf,
	}
	defer srv.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if *watchStdin {
		go exitOnStdinEOF(cancel)
	}

	upCtx, cancelUp := context.WithTimeout(ctx, 2*time.Minute)
	defer cancelUp()
	status, err := srv.Up(upCtx)
	if err != nil {
		fatalf("tailnet up: %v", err)
	}
	if len(status.TailscaleIPs) == 0 {
		fatalf("tailnet up without an address")
	}
	fmt.Printf("ready %s\n", status.TailscaleIPs[0])
	_ = os.Stdout.Sync()

	if *parentPID > 0 {
		go watchParent(*parentPID, cancel)
	}

	for _, port := range list {
		ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", port))
		if err != nil {
			fatalf("listen %d: %v", port, err)
		}
		go serve(ctx, ln, net.JoinHostPort(*host, fmt.Sprint(port)), log.Printf)
	}
	log.Printf("forwarding %d ports to %s", len(list), *host)
	<-ctx.Done()
}

// fatalf reports a startup error on stdout, which the app reads, and exits.
func fatalf(format string, args ...any) {
	fmt.Printf("error %s\n", fmt.Sprintf(format, args...))
	_ = os.Stdout.Sync()
	os.Exit(1)
}
