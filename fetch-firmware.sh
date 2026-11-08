#!/bin/sh
# Download the HP LaserJet P1008 firmware and convert it to the .dl file
# foo2zjs sends to the printer. It is HP's proprietary code, so it is not
# kept in git. Needs curl and Docker (for the foo2zjs arm2hpdl tool).
#
# Source: the location foo2zjs's own `getweb p1008` uses. The P1008 shares
# the P1006 firmware.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest="$here/printserver/sihpP1006.dl"
url="https://www.quirinux.org/printers/sihpP1006.tar.gz"
tar_sha256="b9efe6926fc4cac578b18b5ef8adab13e87c80a25430309110e3f61ace5bcf8f"
dl_sha256="b9293c793ea8666b6ea9fd624c2bb1f00ef697c3e710cf1189396442df7ad2a2"

sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$dest" ] && [ "$(sha256 "$dest")" = "$dl_sha256" ]; then
    echo "Firmware already present: $dest"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading $url"
curl -fsSL -o "$work/sihpP1006.tar.gz" "$url"
if [ "$(sha256 "$work/sihpP1006.tar.gz")" != "$tar_sha256" ]; then
    echo "Checksum mismatch for sihpP1006.tar.gz, refusing to use it" >&2
    exit 1
fi

echo "Converting with arm2hpdl (foo2zjs) in Docker"
docker run --rm -v "$work:/w" debian:trixie sh -c '
    apt-get -qq update >/dev/null &&
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends printer-driver-foo2zjs >/dev/null 2>&1 &&
    cd /w && tar xzf sihpP1006.tar.gz sihpP1006.img && arm2hpdl sihpP1006.img > sihpP1006.dl'

if [ "$(sha256 "$work/sihpP1006.dl")" != "$dl_sha256" ]; then
    echo "Converted firmware has an unexpected checksum, refusing to use it" >&2
    exit 1
fi
mkdir -p "$(dirname "$dest")"
cp "$work/sihpP1006.dl" "$dest"
echo "Firmware saved to $dest"
