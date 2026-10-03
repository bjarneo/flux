package core

import "flux/internal/proto"

// onOldApp marks a paired device that announces itself with the identity
// of an app from before Flux 0.8. That app cannot link with this fluxd, and
// the connection ends in the TLS handshake. fluxd logs it once. A device
// that is not paired, such as a phone with KDE Connect, stays out of the
// list.
func (d *Daemon) onOldApp(id proto.Identity, ip string) {
	d.mu.Lock()
	dev, ok := d.devices[id.DeviceID]
	if !ok || !dev.Paired || dev.oldApp {
		d.mu.Unlock()
		return
	}
	dev.oldApp = true
	name := dev.Name
	d.mu.Unlock()
	d.markDirty()
	d.logf("%s (%s) runs a Flux app older than 0.8, which cannot connect to this fluxd. Install the latest Flux app on it", name, ip)
}
