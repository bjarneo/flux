#!/bin/sh
# Undo the system setup of post-install.sh before Flux is removed.
set -u
systemctl --global disable fluxd.service 2>/dev/null || true
# Remove the fingerprint approval from PAM, while flux-cli is still here.
# Without it, each login runs a pam_exec line for a helper that is gone.
# The key files in /etc/flux/approve stay.
for cli in /usr/bin/flux-cli /usr/local/bin/flux-cli; do
	if [ -x "$cli" ]; then
		"$cli" approve disable || true
		break
	fi
done
# Remove only the module files that post-install.sh wrote.
if grep -qxs 'options v4l2loopback devices=0' /etc/modprobe.d/flux-v4l2loopback.conf; then
	rm -f /etc/modprobe.d/flux-v4l2loopback.conf /etc/modules-load.d/flux-v4l2loopback.conf
fi
