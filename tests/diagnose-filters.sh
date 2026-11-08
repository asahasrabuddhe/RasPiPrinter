#!/bin/sh
# Does the CUPS pdftopdf filter crash on 32-bit ARM, or only under emulation?
# Runs the same filter on the same PDF in three containers.
set -u

inner='
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
if [ "${RPI:-0}" = 1 ]; then
    apt-get -qq install -y --no-install-recommends ca-certificates curl >/dev/null 2>&1
    curl -fsSL -o /tmp/k.deb https://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-archive-keyring/raspberrypi-archive-keyring_2025.1+rpt1_all.deb
    dpkg -i /tmp/k.deb >/dev/null
    kr=$(dpkg -L raspberrypi-archive-keyring | grep -E "/usr/share/keyrings/.*\.(gpg|pgp)$" | head -1)
    echo "deb [signed-by=$kr] https://archive.raspberrypi.com/debian trixie main" > /etc/apt/sources.list.d/raspi.list
    apt-get -qq update >/dev/null
fi
apt-get -qq install -y cups-filters ghostscript >/dev/null 2>&1
echo "arch: $(dpkg --print-architecture)  cups-filters: $(dpkg-query -W -f="\${Version}" cups-filters)  libqpdf: $(dpkg-query -W -f="\${Version}" "libqpdf*" 2>/dev/null | head -1)"
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -o /tmp/page.pdf -c "/Helvetica findfont 36 scalefont setfont 72 700 moveto (test) show showpage"
PPD= CONTENT_TYPE=application/pdf FINAL_CONTENT_TYPE=application/vnd.cups-pdf \
    /usr/lib/cups/filter/pdftopdf 1 user title 1 "" /tmp/page.pdf > /tmp/out.pdf 2>/tmp/err.txt
rc=$?
echo "pdftopdf exit code: $rc (139 = segfault), output bytes: $(wc -c < /tmp/out.pdf)"
'

for case in "linux/arm/v7 1 32-bit ARM, Pi archive" "linux/arm/v7 0 32-bit ARM, plain Debian" "linux/arm64 0 64-bit ARM, native"; do
    platform=${case%% *}; rest=${case#* }; rpi=${rest%% *}; label=${rest#* }
    echo "== $label"
    docker run --rm --platform "$platform" -e RPI="$rpi" debian:trixie sh -c "$inner" 2>&1 | grep -v '^debconf'
done
