#!/bin/sh
# Runs inside debian:trixie (armhf). /boot/firmware holds build.sh output.
set -eu
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

export DEBIAN_FRONTEND=noninteractive
# Use the Raspberry Pi archive too, so cloud-init is the Pi's patched build
# (it adds keys such as enable_ssh that stock Debian rejects).
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends ca-certificates curl >/dev/null 2>&1
curl -fsSL -o /tmp/keyring.deb \
    https://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-archive-keyring/raspberrypi-archive-keyring_2025.1+rpt1_all.deb
dpkg -i /tmp/keyring.deb >/dev/null
keyring=$(dpkg -L raspberrypi-archive-keyring | grep -E '/usr/share/keyrings/.*\.(gpg|pgp)$' | head -1)
echo "deb [signed-by=$keyring] https://archive.raspberrypi.com/debian trixie main" \
    > /etc/apt/sources.list.d/raspi.list
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends cloud-init python3-yaml >/dev/null 2>&1
dpkg-query -W cloud-init | grep -q rpt || fail "cloud-init is not the Raspberry Pi build"

# 1. cloud-init config is valid YAML and passes the cloud-init schema.
cloud-init schema -c /boot/firmware/user-data --annotate >/tmp/schema.out 2>&1 ||
    { cat /tmp/schema.out; fail "user-data schema"; }
pass "user-data passes cloud-init schema ($(cloud-init --version 2>&1))"
cloud-init schema -c /boot/firmware/network-config --schema-type network-config >/dev/null 2>&1 ||
    fail "network-config schema"
pass "network-config passes cloud-init schema"
grep -q 'testsalt' /boot/firmware/user-data || fail "password hash not substituted"
! grep -q '__PASSWORD_HASH__' /boot/firmware/user-data || fail "placeholder left in user-data"
pass "password hash substituted"

# 2. Run every runcmd step as cloud-init would, then the first-boot script
#    they install, with systemd, udev and the clock stubbed (no init system
#    in a container). The script installs CUPS and the driver itself.
useradd -m ajitem
mkdir -p /tmp/stub
cat > /tmp/stub/systemctl <<'SH'
#!/bin/sh
echo "systemctl $*" >> /tmp/stub.log
case "$*" in *--now*cups.service*) pidof cupsd >/dev/null || cupsd; sleep 2 ;; esac
exit 0
SH
printf '#!/bin/sh\necho "udevadm $*" >> /tmp/stub.log\n' > /tmp/stub/udevadm
# Clock reports "not synced" twice, then synced, to exercise the wait.
cat > /tmp/stub/timedatectl <<'SH'
#!/bin/sh
n=$(cat /tmp/clock-calls 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > /tmp/clock-calls
[ "$n" -ge 3 ] && echo yes || echo no
SH
chmod +x /tmp/stub/*
python3 - <<'PY' > /tmp/runcmd.sh
import yaml, shlex
cfg = yaml.safe_load(open("/boot/firmware/user-data"))
print("set -e")
for step in cfg["runcmd"]:
    print(" ".join(shlex.quote(str(a)) for a in step) if isinstance(step, list) else step)
PY
PATH=/tmp/stub:$PATH sh /tmp/runcmd.sh || fail "a runcmd step failed"
[ -x /usr/local/sbin/printserver-firstboot ] || fail "first-boot script not installed"
[ -f /etc/systemd/system/printserver-firstboot.service ] || fail "first-boot unit not installed"
grep -q 'enable printserver-firstboot.service' /tmp/stub.log || fail "first-boot service not enabled"
grep -q 'start --no-block printserver-firstboot.service' /tmp/stub.log || fail "first-boot service not started"
pass "runcmd installs, enables and starts printserver-firstboot.service"

PATH=/tmp/stub:$PATH /usr/local/sbin/printserver-firstboot > /tmp/firstboot.out 2>&1 ||
    { tail -30 /tmp/firstboot.out; fail "first-boot script failed"; }
[ "$(cat /tmp/clock-calls)" -ge 3 ] || fail "script did not wait for the clock"
grep -q 'clock synced' /tmp/firstboot.out || fail "no clock synced message"
pass "first-boot script waits for network time before apt"
for pkg in cups printer-driver-foo2zjs ghostscript cups-filters avahi-daemon unattended-upgrades; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || fail "$pkg not installed"
done
pass "first-boot script installed cups, foo2zjs, ghostscript, cups-filters, avahi, unattended-upgrades"
[ -s /usr/lib/firmware/hp/sihpP1006.dl ] || fail "firmware not installed"
cmp -s /usr/lib/firmware/hp/sihpP1006.dl /boot/firmware/printserver/sihpP1006.dl || fail "firmware differs"
[ -x /usr/local/sbin/p1008-setup ] || fail "setup script not installed"
[ -f /etc/systemd/system/p1008-setup.service ] || fail "unit not installed"
[ -f /etc/udev/rules.d/90-p1008-queue.rules ] || fail "udev rule not installed"
[ "$(readlink /etc/udev/rules.d/56-hpmud.rules)" = /dev/null ] || fail "hpmud rule not masked"
id -nG ajitem | grep -qw lpadmin || fail "ajitem not in lpadmin"
grep -q 'enable p1008-setup.service' /tmp/stub.log || fail "p1008-setup not enabled"
grep -q 'trigger --action=add' /tmp/stub.log || fail "udev not re-triggered for an attached printer"
[ -f /var/lib/printserver/setup-done ] || fail "done marker missing"
cupsctl | grep -q '_share_printers=1' || fail "printer sharing off"
cupsctl | grep -q '_remote_admin=1' || fail "remote admin off"
pass "first-boot script: firmware, units, groups, CUPS sharing and done marker in place"

# The foo2zjs firmware loader must map the P1008 to the firmware we ship.
sed -n '/\*P1008)/,/;;/p' /usr/lib/udev/hplj1000 | grep -q 'FWMODEL=P1006' ||
    fail "foo2zjs no longer maps P1008 to sihpP1006.dl"
grep -q 'ATTRS{product}=="HP LaserJet P1008"' /usr/lib/udev/rules.d/85-hplj10xx.rules ||
    fail "foo2zjs udev rule for P1008 missing"
pass "foo2zjs loads sihpP1006.dl for the P1008"

# 3. The setup script, against a simulated printer.
# Real usb backend lives on in usb.real; the fake one reports a P1008.
mv /usr/lib/cups/backend/usb /usr/lib/cups/backend/usb.real
cat > /usr/lib/cups/backend/usb <<'SH'
#!/bin/sh
if [ $# -eq 0 ] && [ -f /tmp/printer-on ]; then
  echo 'direct usb://HP/LaserJet%20P1008?serial=SN0001 "HP LaserJet P1008" "HP LaserJet P1008" "MFG:Hewlett-Packard;MDL:HP LaserJet P1008;CMD:ACL;CLS:PRINTER;FWVER:20071211;" ""'
fi
[ $# -gt 0 ] && cat > /dev/null
exit 0
SH
chmod 0755 /usr/lib/cups/backend/usb
export P1008_SETTLE=0

# Not connected: exits 0, creates nothing.
out=$(/usr/local/sbin/p1008-setup 2>&1) || fail "script failed with no printer: $out"
echo "$out" | grep -q 'not connected' || fail "no 'not connected' message"
! lpstat -v HP_LaserJet_P1008 >/dev/null 2>&1 || fail "queue created without a printer"
pass "no printer: exits cleanly, no queue"

# Connected, with two stale queues the desktop tools might have added.
touch /tmp/printer-on
ppd=foo2zjs:0/ppd/foo2zjs/HP-LaserJet_P1008.ppd
lpadmin -p HP_LaserJet_P1008_auto -E -v 'usb://HP/LaserJet%20P1008?serial=SN0001' -m "$ppd"
printf '#!/bin/sh\n[ $# -gt 0 ] && cat > /dev/null\nexit 0\n' > /usr/lib/cups/backend/hp  # HPLIP stand-in
chmod 0755 /usr/lib/cups/backend/hp
lpadmin -p HP_LaserJet_P1008_hplip -E -v 'hp:/usb/HP_LaserJet_P1008?serial=SN0001' -m "$ppd"
lpadmin -p Other -E -v 'socket://192.0.2.1' -m "$ppd"
/usr/local/sbin/p1008-setup > /tmp/setup.out 2>&1 || { cat /tmp/setup.out; fail "setup failed"; }
lpstat -v HP_LaserJet_P1008 | grep -q 'usb://HP/LaserJet%20P1008?serial=SN0001' || fail "queue URI wrong"
lpstat -d | grep -q 'HP_LaserJet_P1008$' || fail "not the default printer"
lpoptions -p HP_LaserJet_P1008 | grep -q 'printer-is-shared=true' || fail "queue not shared"
lpoptions -p HP_LaserJet_P1008 | grep -q 'printer-make-and-model=.*foo2xqx' || fail "wrong driver"
lpoptions -p HP_LaserJet_P1008 -l | grep -q '^PageSize.*\*A4' || fail "default paper not A4"
lpstat -p HP_LaserJet_P1008 | grep -q 'enabled' || fail "queue not enabled"
! lpstat -v HP_LaserJet_P1008_auto >/dev/null 2>&1 || fail "duplicate usb queue kept"
! lpstat -v HP_LaserJet_P1008_hplip >/dev/null 2>&1 || fail "duplicate hp: queue kept"
lpstat -v Other >/dev/null 2>&1 || fail "unrelated queue removed"
pass "printer on: shared A4 foo2xqx queue, default, duplicates removed, others kept"
! grep -q '^\*Resolution 600x600dpi' /etc/cups/ppd/HP_LaserJet_P1008.ppd || fail "faint 600x600 mode still offered"
grep -q '^\*Resolution 1200x600dpi' /etc/cups/ppd/HP_LaserJet_P1008.ppd || fail "1200x600 mode missing"
grep -q '^\*DefaultResolution: 1200x600dpi' /etc/cups/ppd/HP_LaserJet_P1008.ppd || fail "default resolution not 1200x600"
pass "queue offers only 1200x600 dpi (600x600 prints faint)"

# Second run (printer power-cycled): no changes, still ready.
cupsdisable HP_LaserJet_P1008
/usr/local/sbin/p1008-setup > /tmp/setup2.out 2>&1 || fail "second run failed"
! grep -q 'set up on' /tmp/setup2.out || fail "second run recreated the queue"
! grep -q 'removed the faint' /tmp/setup2.out || fail "second run edited the PPD again"
lpstat -p HP_LaserJet_P1008 | grep -q 'enabled' || fail "second run did not re-enable a stopped queue"
pass "second run: idempotent, re-enables a stopped queue"

# A job renders through the real foo2xqx filter chain into P1008 data.
if [ "${RENDER:-0}" != 1 ]; then
    echo "skip: page rendering (cups-filters crashes under QEMU; set RENDER=1 to try)"
    echo "All tests passed."
    exit 0
fi
grep -q '^FileDevice' /etc/cups/cups-files.conf || echo 'FileDevice Yes' >> /etc/cups/cups-files.conf
kill "$(cat /run/cups/cupsd.pid 2>/dev/null || pidof cupsd)"; sleep 2; cupsd; sleep 2
lpadmin -p Capture -E -v file:///tmp/capture.xqx -m "$ppd" -o PageSize=A4
# Print what Windows' IPP Class Driver sends: PDF and PWG raster.
gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sPAPERSIZE=a4 -o /tmp/page.pdf \
    -c '/Helvetica findfont 36 scalefont setfont 72 700 moveto (P1008 test page) show showpage'
gs -q -dBATCH -dNOPAUSE -sDEVICE=pwgraster -r300 -sPAPERSIZE=a4 -o /tmp/page.pwg /tmp/page.pdf
for doc in pdf:/tmp/page.pdf:application/pdf pwg:/tmp/page.pwg:image/pwg-raster; do
    kind=${doc%%:*}; rest=${doc#*:}; file=${rest%%:*}; mime=${rest#*:}
    rm -f /tmp/capture.xqx
    lp -d Capture -o document-format="$mime" "$file" >/dev/null
    i=0
    while lpstat -o Capture 2>/dev/null | grep -q Capture; do
        i=$((i + 1))
        if [ "$i" -gt 300 ] || lpstat -p Capture | grep -q disabled; then
            lpstat -l -o
            grep -E 'exited|crashed|failed|rror' /var/log/cups/error_log | tail -20
            fail "$kind job did not print"
        fi
        sleep 2
    done
    [ -s /tmp/capture.xqx ] || fail "no output from foo2xqx for $kind"
    xqxdecode < /tmp/capture.xqx > /tmp/decode.txt 2>&1 || true
    grep -qiE 'start.?page' /tmp/decode.txt || { head -20 /tmp/decode.txt; fail "$kind output is not XQX printer data"; }
    pass "$kind job renders to XQX printer data ($(wc -c < /tmp/capture.xqx) bytes)"
done

echo "All tests passed."
