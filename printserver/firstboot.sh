#!/bin/sh
# One-time print server setup, run by printserver-firstboot.service.
# The service runs at every boot until this script succeeds, so a Pi that
# first starts without internet sets itself up once it gets a connection.
set -eu

SRC=/boot/firmware/printserver
DONE=/var/lib/printserver/setup-done
USER_NAME=ajitem

log() { echo "printserver-firstboot: $*"; }

# 1. Wait for network time. The Pi 2 has no battery-backed clock and starts
#    at the image's build date, so apt rejects current repository signatures
#    as "not live yet" until the clock is right.
if command -v timedatectl >/dev/null 2>&1; then
    i=0
    until [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; do
        i=$((i + 1))
        if [ "$i" -ge 120 ]; then
            log "clock still not synced after 10 minutes, will retry"
            exit 1
        fi
        sleep 5
    done
    log "clock synced: $(date -u)"
fi

# 2. Install packages. --error-on=any makes a failed or unsigned index an
#    error instead of silently falling back to the image's stale lists.
export DEBIAN_FRONTEND=noninteractive
n=0
until apt-get update --error-on=any &&
      apt-get install -y cups printer-driver-foo2zjs avahi-daemon unattended-upgrades; do
    n=$((n + 1))
    if [ "$n" -ge 5 ]; then
        log "package install failed 5 times, will retry"
        exit 1
    fi
    log "package install failed, retrying in 30 seconds"
    sleep 30
done
log "packages installed"

# 3. Firmware, queue setup script, its service and udev rule.
install -D -m 0644 "$SRC/sihpP1006.dl" /usr/lib/firmware/hp/sihpP1006.dl
install -D -m 0755 "$SRC/p1008-setup.sh" /usr/local/sbin/p1008-setup
install -D -m 0644 "$SRC/p1008-setup.service" /etc/systemd/system/p1008-setup.service
install -D -m 0644 "$SRC/90-p1008-queue.rules" /etc/udev/rules.d/90-p1008-queue.rules

# HPLIP and system-config-printer udev rules, if present, try to set up their
# own queue for an HP printer. Mask them so only foo2zjs (firmware) and
# p1008-setup (queue) act on the P1008.
ln -sf /dev/null /etc/udev/rules.d/56-hpmud.rules
ln -sf /dev/null /etc/udev/rules.d/70-printers.rules

# 4. CUPS: share printers on the LAN, let the admin user manage them.
usermod -aG lpadmin "$USER_NAME"
systemctl enable --now cups.service avahi-daemon.service unattended-upgrades.service
cupsctl --share-printers --remote-admin

systemctl daemon-reload
udevadm control --reload
systemctl enable p1008-setup.service

mkdir -p "$(dirname "$DONE")"
date -u > "$DONE"
log "setup done"

# 5. If the printer is already plugged in, load its firmware and create the
#    queue now rather than at the next plug-in or reboot.
udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=03f0 || true
systemctl start --no-block p1008-setup.service
