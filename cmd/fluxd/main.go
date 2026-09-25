// Command fluxd is the Flux daemon. It connects this computer to phones
// that run Flux for Android.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"flux/internal/config"
	"flux/internal/core"
	"flux/internal/ipc"
)

var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	headless := flag.Bool("headless", false, "test mode: no desktop integration, discovery on loopback only")
	udpPort := flag.Int("udp-port", 0, "UDP discovery port (default 1716)")
	tcpPort := flag.Int("tcp-port", 0, "first TCP port to try (default 1716)")
	flag.Parse()
	// systemd sets INVOCATION_ID. A fluxd that the user starts by hand
	// ignores the marker of `flux off`.
	if os.Getenv("INVOCATION_ID") != "" && config.IsOff() {
		log.Printf("fluxd is off. To turn it on, run: flux on")
		return
	}
	if *showVersion {
		fmt.Println("fluxd", version)
		return
	}
	logger := log.New(os.Stderr, "", 0)
	if os.Getenv("INVOCATION_ID") == "" {
		logger.SetFlags(log.LstdFlags)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	d, err := core.New(ctx, logger, core.Options{Headless: *headless, UDPPort: *udpPort, FirstTCPPort: *tcpPort})
	if err != nil {
		logger.Fatalf("fluxd: %v", err)
	}

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	go func() {
		for range hup {
			if err := d.Reload(); err != nil {
				logger.Printf("reload: %v", err)
			} else {
				logger.Printf("reloaded %s", config.Path())
			}
		}
	}()

	errs := make(chan error, 2)
	go func() { errs <- ipc.Serve(ctx, config.SocketPath(), d) }()
	go func() { errs <- d.Run() }()
	running := 2
	var failure error
	select {
	case failure = <-errs:
		running--
	case <-ctx.Done():
	}
	// Stop both parts and wait, so the socket file and the mDNS record
	// are gone before the process exits.
	stop()
	deadline := time.After(2 * time.Second)
	for ; running > 0; running-- {
		select {
		case <-errs:
		case <-deadline:
			running = 0
		}
	}
	if failure != nil {
		logger.Fatalf("fluxd: %v", failure)
	}
}
