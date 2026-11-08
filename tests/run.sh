#!/bin/sh
# Run the test suite in a Debian 13 armhf container (the Pi's OS and CPU
# architecture, emulated). Needs Docker.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Build with a throwaway hash, never the real one.
cp -R "$here/build.sh" "$here/fetch-firmware.sh" "$here/templates" "$here/printserver" "$work/"
printf '%s\n' '$y$j9T$testsalt$testhashtesthashtesthashtesthashtest0' > "$work/.password-hash"
# build.sh must refuse a folder that is not a Pi boot partition.
mkdir -p "$work/out"
if "$work/build.sh" "$work/out" >/dev/null 2>&1; then
    echo "FAIL: build.sh wrote to a folder that is not a boot partition"; exit 1
fi
touch "$work/out/cmdline.txt" "$work/out/kernel7.img"
"$work/build.sh" "$work/out" >/dev/null
echo "ok: build.sh only writes to a Pi boot partition"

# build.sh must refuse a missing or malformed hash.
printf 'not-a-hash\n' > "$work/.password-hash"
if "$work/build.sh" "$work/bad" >/dev/null 2>&1; then
    echo "FAIL: build.sh accepted a malformed hash"; exit 1
fi
rm "$work/.password-hash"
if "$work/build.sh" "$work/bad" >/dev/null 2>&1; then
    echo "FAIL: build.sh ran without a hash"; exit 1
fi
echo "ok: build.sh rejects missing and malformed hashes"

docker run --rm --platform linux/arm/v7 \
    -v "$work/out:/boot/firmware:ro" \
    -v "$here/tests/in-container.sh:/in-container.sh:ro" \
    -e RENDER="${RENDER:-0}" \
    debian:trixie sh /in-container.sh
