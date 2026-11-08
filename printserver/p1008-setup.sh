#!/bin/sh
# Create or repair the shared CUPS queue for an HP LaserJet P1008 on USB.
# Runs at boot and each time the printer is plugged in or powered on.
# Firmware upload is handled separately by the printer-driver-foo2zjs
# udev rule (/usr/lib/udev/hpljP1008), which reads
# /usr/lib/firmware/hp/sihpP1006.dl.
set -eu

QUEUE="HP_LaserJet_P1008"
PPD_FILE="HP-LaserJet_P1008.ppd"

log() {
    logger -t p1008-setup -- "$*" 2>/dev/null || true
    echo "$*"
}

# Wait for CUPS.
i=0
until lpstat -r >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        log "CUPS is not running, giving up"
        exit 1
    fi
    sleep 2
done

# Give the foo2zjs hotplug script time to send the firmware first, then
# look for the printer. It can take a few seconds to show up after power-on.
sleep "${P1008_SETTLE:-15}"
uri=""
i=0
while [ "$i" -lt 10 ]; do
    uri=$(lpinfo --include-schemes usb -v 2>/dev/null |
        awk '$2 ~ /^usb:\/\/HP\/LaserJet%20P1008/ { print $2; exit }')
    [ -n "$uri" ] && break
    i=$((i + 1))
    sleep 3
done

if [ -z "$uri" ]; then
    log "HP LaserJet P1008 not connected, nothing to do"
    exit 0
fi

current=$(lpstat -v "$QUEUE" 2>/dev/null | sed -n 's/^device for [^:]*: //p')

if [ "$current" != "$uri" ]; then
    model=$(lpinfo -m 2>/dev/null | awk -v f="$PPD_FILE" 'index($1, f) { print $1; exit }')
    if [ -z "$model" ]; then
        log "foo2xqx driver for the P1008 not found, is printer-driver-foo2zjs installed?"
        exit 1
    fi
    lpadmin -p "$QUEUE" -E -v "$uri" -m "$model" \
        -D "HP LaserJet P1008" -L "Home" \
        -o printer-is-shared=true \
        -o printer-error-policy=retry-job \
        -o PageSize=A4
    log "queue $QUEUE set up on $uri with $model"
fi

# Remove any other queue for this printer (for example one added by
# system-config-printer or HPLIP with an hp:/ URI), so Windows sees a
# single shared printer.
lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\): \(.*\)$/\1 \2/p' |
    while read -r name dev; do
        [ "$name" = "$QUEUE" ] && continue
        case "$dev" in
            "$uri"|*LaserJet*P1008*)
                lpadmin -x "$name" && log "removed duplicate queue $name ($dev)" ;;
        esac
    done

lpadmin -d "$QUEUE"
cupsenable "$QUEUE"
cupsaccept "$QUEUE"
log "queue $QUEUE ready"
