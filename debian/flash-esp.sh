#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Rebuild out/esp.img to exactly the tablet's esp partition size, then flash it.
# Run on the HOST with the tablet in fastboot mode (fastboot + USB).
#
#   debian/flash-esp.sh              # detect size -> rebuild -> fastboot flash esp
#   debian/flash-esp.sh --no-flash   # only rebuild out/esp.img at that size
#
# The size comes from `fastboot getvar partition-size:<part>`, so the FAT image
# covers the whole esp partition (room for other boot entries later) and never
# overflows it.  Without this, out/esp.img is compact (just the content) and may
# be smaller than the partition.
#
# Environment:
#   FASTBOOT      fastboot tool        (default: fastboot)
#   FB_ESP_PART   fastboot esp name    (default: esp)
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
FB=${FASTBOOT:-fastboot}
ESP_PART=${FB_ESP_PART:-esp}

DO_FLASH=1
for arg in "$@"; do
	case $arg in
	--no-flash) DO_FLASH=0 ;;
	-h | --help)
		sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
	esac
done

log() { printf '\033[1;34m[flash-esp]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[flash-esp] error:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$FB" >/dev/null 2>&1 || die "$FB not found"
"$FB" devices 2>/dev/null | grep -q . || die "no device in fastboot mode ($FB devices)"

# `fastboot getvar partition-size:esp` prints e.g. "partition-size:esp: 0x14dfa000".
out=$("$FB" getvar "partition-size:$ESP_PART" 2>&1 || true)
hex=$(printf '%s\n' "$out" | sed -n 's/.*partition-size:[^:]*: *//p' | tr -d '\r' | head -n1)
[ -n "$hex" ] || die "cannot read partition-size:$ESP_PART from fastboot (got: $out)"
size=$((hex))
[ "$size" -gt 0 ] || die "bad $ESP_PART partition size: $hex"
log "$ESP_PART partition size: $size bytes"

log "rebuild out/esp.img at $size bytes"
ESP_SIZE=$size "$HERE/make-img.sh" --esp-only

if [ "$DO_FLASH" -eq 1 ]; then
	log "$FB flash $ESP_PART out/esp.img"
	"$FB" flash "$ESP_PART" "$HERE/out/esp.img"
	log "done; $FB reboot and pick the entry in rEFInd"
fi
