# HP LaserJet P1008 print server on a Raspberry Pi 2

A Raspberry Pi 2 Model B shares a USB HP LaserJet P1008 over the network. Windows on ARM has no driver for the P1008, so the Pi does the work. CUPS converts each job with the open source `foo2xqx` driver and shares the printer over IPP. Windows prints to it with its built-in Microsoft IPP Class Driver, so the laptop needs no HP software.

Everything installs on first boot from files on the SD card. Nobody needs to log in to the Pi.

## What is in this repo

- `build.sh` writes the first-boot files onto a freshly flashed card.
- `templates/user-data.tmpl` is the cloud-init config: hostname `ajitem-pi-printer`, user `ajitem`, SSH and timezone Asia/Kolkata. It installs and starts `printserver-firstboot.service`, which does the rest.
- `templates/network-config` uses Ethernet with DHCP. The Pi 2 has no Wi-Fi.
- `printserver/firstboot.sh` and `printserver-firstboot.service` install CUPS, foo2zjs and Avahi, then set up sharing, the firmware and the queue service. The Pi 2 has no battery-backed clock and starts at the image's build date, so the script waits for network time before it runs apt. Otherwise apt rejects the repository signatures as not yet valid. It retries on failure and runs at every boot until it succeeds, then writes `/var/lib/printserver/setup-done`.
- `fetch-firmware.sh` downloads the P1008 firmware and converts it to `printserver/sihpP1006.dl`. The P1008 forgets its firmware at every power-off, and the foo2zjs udev rule sends it again each time the printer comes on. The firmware is HP's proprietary code, so it is not kept in this repo. The script fetches `sihpP1006.tar.gz` from `https://www.quirinux.org/printers` (the source foo2zjs `getweb p1008` uses), checks its SHA256, converts it with foo2zjs's `arm2hpdl` in Docker and checks the result. `build.sh` runs it when needed.
- `printserver/p1008-setup.sh`, `p1008-setup.service` and `90-p1008-queue.rules` create the shared queue `HP_LaserJet_P1008` at boot and whenever the printer is plugged in or switched on. The script is safe to run any number of times. It also removes the 600×600 dpi mode from the queue. The P1008 prints faint and streaky at 600×600, and Windows' IPP Class Driver always asks for it. With only 1200×600 on offer, Windows prints at full density. A side-by-side test on the real printer (same PDF, 600×600 vs 1200×600) showed the difference.
- `PARENTS.md` is the one-page guide for adding the printer on Windows, iPhone and Android.
- `tests/run.sh` checks `build.sh`, the cloud-init config, the first-boot script and the queue script in an emulated 32-bit Debian 13 container. It takes about 15 minutes. Page rendering is skipped by default because cups-filters crashes under QEMU. `RENDER=1 ./tests/run.sh` tries it anyway.

## Build a card

1. Download Raspberry Pi OS (32-bit, armhf) and check it against the SHA256 on raspberrypi.com. A Pi 2 v1.1 cannot run the 64-bit image. This build used `2026-10-06-raspios-trixie-armhf-lite.img.xz`. Lite has no desktop and unpacks to 2.6 GB, so it fits an 8 GB card. The full image needs 9 GB.

2. Create the password hash. You type the password, only the hash is saved:

   ```bash
   docker run --rm -it -v "$PWD:/w" debian:trixie sh -c 'apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y whois >/dev/null 2>&1 && echo "Type the password, then Enter:" && mkpasswd -m yescrypt | grep "^\\$" > /w/.password-hash'
   ```

   `.password-hash` is ignored by git.

3. Find the SD card's disk number. Check the size and name carefully, the next step wipes it:

   ```bash
   diskutil list external
   ```

4. Flash it, replacing `N` with the disk number:

   ```bash
   diskutil unmountDisk /dev/diskN
   ```

   ```bash
   xz -dc ~/Downloads/2026-10-06-raspios-trixie-armhf-lite.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress
   ```

5. Remove and reinsert the card so `bootfs` mounts, then run the build. The first build downloads the firmware, which needs Docker and internet:

   ```bash
   ./build.sh /Volumes/bootfs
   ```

   ```bash
   diskutil eject /dev/diskN
   ```

## First boot

Connect Ethernet and power. First boot takes about 20 to 30 minutes on a Pi 2. It resizes the disk, waits for network time, then installs CUPS and the driver. Without internet it keeps retrying and finishes once a connection is available.

The printer can be plugged in at any point. The queue appears about 20 seconds after the printer is connected and switched on.

## Checking on it

```bash
ssh ajitem@ajitem-pi-printer.local
```

- `systemctl status printserver-firstboot` shows setup progress, and `journalctl -u printserver-firstboot` the full log. `ls /var/lib/printserver/setup-done` exists once setup has finished.
- `cloud-init status --long` covers the earlier steps (user, hostname, SSH). It reports `done` even when a package install fails, so check the first-boot service too.
- `lpstat -t` lists the queue and any stuck jobs.
- `journalctl -u p1008-setup` shows queue setup. `journalctl -t hpljP1008` shows firmware uploads.
- The CUPS web page is at `https://ajitem-pi-printer.local:631`. Admin pages ask for the `ajitem` login.
- From a Mac on the same network, `dns-sd -B _ipp._tcp` should list `HP LaserJet P1008 @ ajitem-pi-printer`.

## Troubleshooting

- **Setup never finishes.** `journalctl -u printserver-firstboot -n 50` shows why. Usually there's no internet, or the clock has not synced (`timedatectl`).
- **Windows prints faded or streaky, the Mac prints fine.** Check that `lpoptions -p HP_LaserJet_P1008 -l | grep Resolution` lists only `1200x600dpi`. If 600x600 is back, run `sudo systemctl start p1008-setup`, then remove and re-add the printer in Windows so it rereads the supported resolutions.
- **Jobs fail with "Filter failed".** In testing under 32-bit ARM emulation on a Mac, the CUPS filters `pdftopdf` and `bannertopdf` crashed with a segfault. This appears to be an emulation problem, but it was not confirmed on a real Pi. Check `grep -E 'crashed|exited' /var/log/cups/error_log` after the first real print.
- **Printer prints nothing or the queue is missing.** Switch the printer off and on. That reloads the firmware and reruns the setup. If it still fails, run `sudo systemctl start p1008-setup` and read `journalctl -u p1008-setup`.
- **Firmware missing.** `ls /usr/lib/firmware/hp/` must list `sihpP1006.dl`.
- **Windows cannot find the printer.** Add it by URL as described in `PARENTS.md`. If `.local` names do not resolve on that network, give the Pi a fixed address in the router and use the IP address instead.
