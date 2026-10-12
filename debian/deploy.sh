#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Host-side deployment for the Debian image (the manual flow from nabu-debian,
# automated).  It does NOT flash esp.img — that is built from scratch and would
# wipe the existing ESP boot chain.  Instead:
#
#   1. fastboot boot  <TWRP image>
#   2. unzip out/EFI.zip and copy EFI/ onto the ESP (from TWRP, via adb)
#   3. adb sideload <boot-manager patch>      (installer_bootmanager_NOSB.zip)
#   4. adb reboot fastboot
#   5. fastboot flash <part> out/linux.img
#   6. fastboot reboot
#
# Run this on the HOST (it needs adb and fastboot, and the tablet's USB), not
# inside the build container.
#
# Environment (all optional):
#   TWRP_IMG          modded TWRP to fastboot-boot
#   BOOTMANAGER_ZIP   boot-manager patch to sideload
#   EFI_ZIP           EFI tree zip (default out/EFI.zip)
#   ROOT_IMG          rootfs image   (default out/linux.img)
#   FB_ROOT_PART      fastboot partition name for the rootfs (default linux)
#   ESP_MNT           ESP mountpoint inside TWRP (default /esp)
#   ADB / FASTBOOT    tool paths (default: from PATH)
#   DEPLOY_YES=1      skip the confirmation prompt
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
OUT=$HERE/out

ADB=${ADB:-adb}
FASTBOOT=${FASTBOOT:-fastboot}
TWRP_IMG=${TWRP_IMG:-$HOME/Downloads/nabu-ubuntu/V4-MODDED-TWRP-LINUX.img}
BOOTMANAGER_ZIP=${BOOTMANAGER_ZIP:-$HOME/Downloads/nabu-ubuntu/installer_bootmanager_NOSB.zip}
EFI_ZIP=${EFI_ZIP:-$OUT/EFI.zip}
ROOT_IMG=${ROOT_IMG:-$OUT/linux.img}
FB_ROOT_PART=${FB_ROOT_PART:-linux}
ESP_MNT=${ESP_MNT:-/esp}
DEPLOY_YES=${DEPLOY_YES:-0}

while [ $# -gt 0 ]; do
	case $1 in
	-y | --yes) DEPLOY_YES=1 ;;
	-h | --help) sed -n '2,30p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() {
	printf '\033[1;31m[deploy] error:\033[0m %s\n' "$*" >&2
	exit 1
}

command -v "$ADB" >/dev/null 2>&1 || [ -x "$ADB" ] || die "adb not found: $ADB"
command -v "$FASTBOOT" >/dev/null 2>&1 || [ -x "$FASTBOOT" ] || die "fastboot not found: $FASTBOOT"
[ -f "$TWRP_IMG" ] || die "missing TWRP image: $TWRP_IMG (set TWRP_IMG)"
[ -f "$BOOTMANAGER_ZIP" ] || die "missing boot-manager patch: $BOOTMANAGER_ZIP (set BOOTMANAGER_ZIP)"
[ -f "$EFI_ZIP" ] || die "missing $EFI_ZIP (run 'make debian-img' first)"
[ -f "$ROOT_IMG" ] || die "missing $ROOT_IMG (run 'make debian-img' first)"

if [ "$DEPLOY_YES" != 1 ]; then
	printf 'About to boot TWRP, overwrite the ESP EFI/ tree, sideload the boot\n'
	printf 'manager and flash %s with %s.\n' "$FB_ROOT_PART" "$ROOT_IMG"
	printf 'Continue? [y/N] '
	read -r ans
	case $ans in
	y | Y | yes | YES) ;;
	*) die "aborted" ;;
	esac
fi

wait_fastboot() {
	local i
	for i in $(seq 1 60); do
		"$FASTBOOT" devices 2>/dev/null | grep -q . && return 0
		sleep 2
	done
	return 1
}

state() { "$ADB" get-state 2>/dev/null || true; }
ready() { case "$(state)" in device | recovery) return 0 ;; *) return 1 ;; esac; }
ash() { "$ADB" shell "$@" | tr -d '\r'; }

# ---- 1. get into TWRP ------------------------------------------------------
if [ "$(state)" = recovery ] ||
	{ [ "$(state)" = device ] && [ -n "$(ash 'test -d /twres && echo yes')" ]; }; then
	log "device already in TWRP; not booting it again"
else
	log "waiting for a device in fastboot mode..."
	wait_fastboot ||
		die "no fastboot device (power off, then hold Vol- while plugging USB)"
	log "fastboot boot $TWRP_IMG"
	"$FASTBOOT" boot "$TWRP_IMG"
fi

log "waiting for TWRP adb..."
for _ in $(seq 1 90); do ready && break; sleep 2; done
ready || die "no adb device; is the tablet in TWRP?"
log "adb state: $(state)"

# ---- 2. copy the EFI tree onto the ESP -------------------------------------
if ! ash "grep -qs ' $ESP_MNT ' /proc/mounts"; then
	esp_dev=$(ash "ls -d /dev/block/bootdevice/by-partlabel/esp /dev/block/by-partlabel/esp 2>/dev/null | head -1" | tail -1)
	[ -n "$esp_dev" ] || die "ESP partition not found (by-partlabel/esp)"
	log "mounting ESP $esp_dev -> $ESP_MNT"
	ash "mkdir -p '$ESP_MNT' && mount -t vfat '$esp_dev' '$ESP_MNT'" ||
		die "mounting the ESP failed"
else
	log "ESP already mounted at $ESP_MNT"
fi
if ash "test -f '$ESP_MNT/EFI/BOOT/bootaa64.efi'"; then
	log "ESP already carries EFI/BOOT/bootaa64.efi (rEFInd)"
else
	log "ESP has no EFI/BOOT (blank ESP); our EFI/ tree supplies rEFInd"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nabu-efi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
log "extracting $EFI_ZIP"
if command -v unzip >/dev/null 2>&1; then
	unzip -q -o "$EFI_ZIP" -d "$tmp"
else
	python3 -m zipfile -e "$EFI_ZIP" "$tmp"
fi
[ -d "$tmp/EFI" ] || die "$EFI_ZIP has no EFI/ tree"

log "copying EFI/ onto the ESP"
ash "mkdir -p '$ESP_MNT/EFI'"
for entry in "$tmp"/EFI/*; do
	"$ADB" push "$entry" "$ESP_MNT/EFI/"
done
ash "sync"

if [ -f "$tmp/EFI/debian/nabu-debian.efi" ]; then
	want=$(md5sum "$tmp/EFI/debian/nabu-debian.efi" | awk '{print $1}')
	got=$(ash "md5sum '$ESP_MNT/EFI/debian/nabu-debian.efi'" | awk '{print $1}')
	[ "$want" = "$got" ] || die "UKI verify on the ESP failed ($got != $want)"
	log "UKI on the ESP verified (md5 $want)"
fi

# ---- 3. sideload the boot-manager patch ------------------------------------
# TWRP only accepts adb sideload after you enable "Advanced -> ADB Sideload"
# (adbd restarts in sideload mode); wait for that state, then send the file.
log "in TWRP: Advanced -> ADB Sideload, then swipe to start (waiting...)"
sideload_ready() { [ "$("$ADB" get-state 2>/dev/null)" = sideload ]; }
for _ in $(seq 1 300); do
	sideload_ready && break
	sleep 2
done
sideload_ready ||
	die "device did not enter ADB Sideload mode (Advanced -> ADB Sideload)"
log "adb sideload $BOOTMANAGER_ZIP"
"$ADB" sideload "$BOOTMANAGER_ZIP" || die "sideload failed"
log "sideload finished"

log "waiting for TWRP to come back after sideload..."
for _ in $(seq 1 60); do ready && break; sleep 2; done

# ---- 4. reboot to fastboot -------------------------------------------------
log "adb reboot fastboot"
"$ADB" reboot fastboot || true
wait_fastboot || die "device did not reach fastboot"

# ---- 5. flash the rootfs ---------------------------------------------------
log "fastboot flash $FB_ROOT_PART $ROOT_IMG"
"$FASTBOOT" flash "$FB_ROOT_PART" "$ROOT_IMG"

# ---- 6. reboot -------------------------------------------------------------
log "fastboot reboot"
"$FASTBOOT" reboot

log "done; the tablet will boot rEFInd — pick \"Debian\" or \"Reboot to Android\""
