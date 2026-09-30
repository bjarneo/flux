#!/bin/sh
# Undo the system setup of post-install.sh before Flux is removed.
set -u
systemctl --global disable fluxd.service 2>/dev/null || true
# Remove the fingerprint approval from PAM, while flux-cli is still here.
# Without it, each login runs a pam_exec line for a helper that is gone.
# The PAM line names /usr/lib/flux/flux-approve, so only an install with
# the prefix /usr owns it. make uninstall sets FLUX_PREFIX, and pacman
# does not. The key files in /etc/flux/approve stay.
prefix=${FLUX_PREFIX:-/usr}
if [ "$prefix" = /usr ] && [ -x /usr/bin/flux-cli ]; then
	/usr/bin/flux-cli approve disable || true
fi
# Remove only the module files that post-install.sh wrote.
if grep -qxs 'options v4l2loopback devices=0' /etc/modprobe.d/flux-v4l2loopback.conf; then
	rm -f /etc/modprobe.d/flux-v4l2loopback.conf /etc/modules-load.d/flux-v4l2loopback.conf
fi
