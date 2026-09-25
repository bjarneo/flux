#!/bin/sh
# Undo the system setup of post-install.sh before Flux is removed.
set -u
systemctl --global disable fluxd.service 2>/dev/null || true
# Remove only the module files that post-install.sh wrote.
if grep -qxs 'options v4l2loopback devices=0' /etc/modprobe.d/flux-v4l2loopback.conf; then
	rm -f /etc/modprobe.d/flux-v4l2loopback.conf /etc/modules-load.d/flux-v4l2loopback.conf
fi
