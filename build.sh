#!/bin/sh
# Build the first-boot files for the print server card.
#
#   ./build.sh                    write them to ./out/bootfs
#   ./build.sh /Volumes/bootfs    write them straight onto a freshly flashed card
#
# Needs .password-hash next to this script (see README.md).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=${1:-"$here/out/bootfs"}
hash_file="$here/.password-hash"

if [ ! -s "$hash_file" ]; then
    echo "Missing $hash_file. See README.md for how to create it." >&2
    exit 1
fi
hash=$(tr -d '\r\n' < "$hash_file")
# shellcheck disable=SC2016,SC1003 # literal patterns, not expansions
case "$hash" in
    '$y$'*|'$6$'*) ;;
    *) echo "$hash_file does not look like a yescrypt or SHA-512 crypt hash" >&2; exit 1 ;;
esac
# shellcheck disable=SC2016,SC1003 # literal patterns, not expansions
case "$hash" in
    *'"'*|*'\'*|*'|'*) echo "$hash_file contains unexpected characters" >&2; exit 1 ;;
esac

if [ "$#" -gt 0 ]; then
    [ -f "$dest/cmdline.txt" ] || { echo "$dest does not look like a Raspberry Pi boot partition" >&2; exit 1; }
    [ -f "$dest/kernel7.img" ] || { echo "$dest has no 32-bit kernel (kernel7.img); a Pi 2 needs the armhf image" >&2; exit 1; }
fi

# The P1008 firmware is HP's code and is not kept in git. Fetch it once.
"$here/fetch-firmware.sh"

mkdir -p "$dest/printserver"
sed "s|__PASSWORD_HASH__|$hash|" "$here/templates/user-data.tmpl" > "$dest/user-data"
cp "$here/templates/network-config" "$dest/network-config"
printf 'instance-id: ajitem-pi-printer-%s\n' "$(date +%Y%m%d%H%M%S)" > "$dest/meta-data"
cp "$here/printserver/firstboot.sh" \
   "$here/printserver/printserver-firstboot.service" \
   "$here/printserver/p1008-setup.sh" \
   "$here/printserver/p1008-setup.service" \
   "$here/printserver/90-p1008-queue.rules" \
   "$here/printserver/sihpP1006.dl" \
   "$dest/printserver/"

# Raspberry Pi OS reads these from /boot/firmware on first boot
# (/etc/cloud/cloud.cfg.d/99_raspberry-pi.cfg), so cmdline.txt stays as is.

echo "Wrote first-boot files to $dest"
