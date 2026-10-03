package main

import (
	"context"
	"log"
	"time"

	"flux/internal/desktop"
)

// kdeConnectDelay is how long fluxd waits before it looks for kdeconnectd.
// At login, KDE Connect starts from autostart, often after fluxd.
const kdeConnectDelay = 30 * time.Second

// warnKDEConnect logs a kdeconnectd that runs, because it uses UDP port
// 1716 like fluxd. fluxd only warns. `flux-cli setup` turns KDE Connect off.
func warnKDEConnect(ctx context.Context, logger *log.Logger, procs desktop.Procs, delay time.Duration) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(delay):
	}
	for _, pid := range desktop.KDEConnectPIDs(procs) {
		logger.Printf("kdeconnectd (PID %d) also uses UDP port 1716, so phones cannot always reach fluxd. To stop it and keep it off at login, run: flux-cli setup", pid)
	}
}
