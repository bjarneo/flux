#!/bin/sh
# System setup for Flux after an install or an upgrade. It runs as root and
# is safe to run again. `make install` and the pacman package run it.
set -u

# Load the udev rule that gives the user at the seat access to the
# v4l2loopback control device.
udevadm control --reload 2>/dev/null || true

# The phone as webcam: v4l2loopback is optional. Omarchy can already use
# the module for a laptop camera, so Flux never changes existing module
# options. Only when nothing configures the module, Flux loads it with no
# devices. fluxd adds its own "Flux Camera" device at run time.
if modinfo v4l2loopback >/dev/null 2>&1; then
	if ! grep -Eqs '^v4l2loopback ' /proc/modules &&
		! grep -rqs '^options v4l2loopback' /etc/modprobe.d /usr/lib/modprobe.d /run/modprobe.d; then
		echo 'options v4l2loopback devices=0' >/etc/modprobe.d/flux-v4l2loopback.conf
		echo 'v4l2loopback' >/etc/modules-load.d/flux-v4l2loopback.conf
		modprobe v4l2loopback 2>/dev/null || true
	fi
	[ -e /dev/v4l2loopback ] && udevadm trigger --action=change /dev/v4l2loopback 2>/dev/null
fi

# Start fluxd in every graphical session.
systemctl --global enable fluxd.service 2>/dev/null || true

# Restart a running fluxd of an earlier version, because it does not see
# the new binary. A fluxd that restarts by itself after an update writes
# the self-restart marker, and it waits for the end of a transfer or a
# stream. try-restart never starts a fluxd that does not run.
for dir in /run/user/*; do
	uid=${dir##*/}
	[ -S "$dir/bus" ] || continue
	[ -e "$dir/flux/self-restart" ] && continue
	pgrep -u "$uid" -x fluxd >/dev/null 2>&1 || continue
	name=$(id -un "$uid" 2>/dev/null) || continue
	systemctl --user --machine="$name@" try-restart fluxd.service || true
done

echo "Flux is installed. As your user, run: flux-cli setup"
echo "The short name flux works after the next login, when no other flux command exists."
