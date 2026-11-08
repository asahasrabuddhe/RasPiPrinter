#!/bin/sh
# Print the same page through the P1008 driver chain twice: as PDF (what a
# Mac sends) and as 8-bit grayscale PWG raster (what Windows' IPP Class
# Driver sends). Saves the printer's decoded page bitmaps to tests/out/ so
# the two can be compared. Runs natively on Apple Silicon (arm64).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/out"

docker run --rm --platform linux/arm64 -v "$here/out:/out" debian:trixie sh -c '
set -eu
export DEBIAN_FRONTEND=noninteractive
echo "Installing CUPS, foo2zjs and Ghostscript..."
apt-get -qq update >/dev/null
apt-get -qq install -y cups printer-driver-foo2zjs ghostscript netpbm >/dev/null 2>&1
echo "FileDevice Yes" >> /etc/cups/cups-files.conf
cupsd; sleep 2
ppd=foo2zjs:0/ppd/foo2zjs/HP-LaserJet_P1008.ppd
lpadmin -p Capture -E -v file:///tmp/capture.xqx -m "$ppd" -o PageSize=A4 2>/dev/null

# A test page: big and small text, thin lines, a solid black box.
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sPAPERSIZE=a4 -o /tmp/page.pdf -c "
/Helvetica findfont 40 scalefont setfont 60 760 moveto (Windows vs Mac test) show
/Helvetica findfont 11 scalefont setfont 60 720 moveto (The quick brown fox jumps over the lazy dog 0123456789) show
/Helvetica findfont 8 scalefont setfont 60 700 moveto (Small 8 point text for detail) show
0.5 setlinewidth 60 650 moveto 535 650 lineto stroke
60 500 200 100 rectfill
showpage"
# What Windows sends: 600 dpi, 8-bit gray, anti-aliased text.
gs -q -dBATCH -dNOPAUSE -sDEVICE=pwgraster -r600 -dTextAlphaBits=4 -dGraphicsAlphaBits=4 \
   -sPAPERSIZE=a4 -o /tmp/page.pwg /tmp/page.pdf

for doc in pdf:/tmp/page.pdf:application/pdf raster:/tmp/page.pwg:image/pwg-raster; do
    kind=${doc%%:*}; rest=${doc#*:}; file=${rest%%:*}; mime=${rest#*:}
    rm -f /tmp/capture.xqx
    echo "Printing as $kind ($mime)..."
    lp -d Capture -o document-format="$mime" "$file" >/dev/null
    i=0
    while lpstat -o Capture 2>/dev/null | grep -q Capture; do
        i=$((i + 1)); [ $i -gt 120 ] && { grep -E "crashed|exited" /var/log/cups/error_log | tail; exit 1; }
        sleep 1
    done
    mkdir -p /tmp/dec-$kind && cd /tmp/dec-$kind
    xqxdecode -d page < /tmp/capture.xqx > /dev/null 2>&1 || true
    pbm=$(ls -1 *.pbm 2>/dev/null | head -1)
    [ -n "$pbm" ] || { echo "no decoded page for $kind"; ls; exit 1; }
    cp "$pbm" /out/$kind.pbm
    pnmtopng /out/$kind.pbm > /out/$kind.png 2>/dev/null
    # Crop the text area at full resolution for a close look.
    pamcut -left 300 -top 0 -width 2400 -height 900 /out/$kind.pbm 2>/dev/null | pnmtopng > /out/$kind-text.png 2>/dev/null || true
    echo "  $kind: $(head -2 /out/$kind.pbm | tail -1) pixels, black pixels in text area: $(pamcut -left 300 -top 0 -width 2400 -height 900 /out/$kind.pbm | pamsumm -sum -brief 2>/dev/null)"
    cd /
done
echo "Saved decoded pages to tests/out/"
'
