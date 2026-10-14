#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the two raw partition images used to install Debian on the tablet,
# following the layout every nabu Linux distribution uses:
#
#   out/esp.img     vfat ESP: the dual-boot boot menu.  Default (DUALBOOT=1)
#                   it carries the same chain as the other nabu distros:
#                   rEFInd + Reboot2Android.efi (from boot/nabu-dualboot-efi.zip,
#                   see fetch-efi.sh) plus our Debian UKI at
#                   EFI/debian/nabu-debian.efi.  Boot it to choose Debian or
#                   "Reboot to Android".  With DUALBOOT=0 it holds only the UKI
#                   (EFI/debian/nabu-debian.efi + a BOOTAA64.EFI fallback).
#   out/linux.img   ext4 rootfs: COMPACT (only the actual data, ~5-6 GiB), not
#                   the whole partition.  It is written to the "linux"
#                   partition and then grown to the partition size with
#                   resize2fs (out/flash.sh or x-systemd.growfs on first boot).
#
# Flashing:
#   out/flash-fastboot.sh   run on a PC: fastboot flash esp/linux + reboot
#   out/flash.sh            run on the tablet: dd + resize2fs + boot entry
#
# Sizes: both images are compact.  The FAT image is just big enough for its
# content, so it stays flashable to any esp partition (override with ESP_SIZE);
# the ext4 image holds the data and grows to its partition at first boot
# (override with ROOT_SIZE).
#
#   ./make-img.sh                 # both images
#   ./make-img.sh --esp-only
#   ./make-img.sh --linux-only
#   ./make-img.sh --no-dualboot   # plain UKI-only ESP (no rEFInd)
#   ESP_SIZE=350105600 ./make-img.sh --esp-only   # pin the size instead of compact
#
# The ext4 image is assembled unprivileged with mkfs.ext4 -d (e2fsprogs >=
# 1.47).  The FAT image is populated with mcopy (mtools) or a loop mount.
# Run this anywhere, not only on the tablet.

set -euo pipefail

# mkfs.ext4 -d copies inode ownership from the staging tree, but a non-root tar
# cannot restore root:root, so everything would end up owned by the desktop
# user and setuid (e.g. /usr/bin/sudo) would be a no-op.  Run the whole build
# under fakeroot so system files stay root-owned in the image.
if [ "$(id -u)" -ne 0 ] && [ -z "${NABU_FAKEROOT:-}" ]; then
	if command -v fakeroot >/dev/null 2>&1; then
		NABU_FAKEROOT=1 exec fakeroot -- "$0" "$@"
	fi
	echo "make-img.sh: need root or fakeroot, otherwise the rootfs image loses root ownership (setuid/sudo break)" >&2
	exit 1
fi

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
OUT=$HERE/out

# ESP: a compact FAT32 image just big enough for its content (override with
# ESP_SIZE).  ESP_MIN is the smallest FAT32 image worth building.
ESP_SIZE=${ESP_SIZE:-}
ESP_MIN=${ESP_MIN:-67108864}      # 64 MiB minimum for the ESP image
# Root: compact image target; grows to the partition at flash time.
ROOT_SIZE=${ROOT_SIZE:-}
ROOT_DEFAULT=${ROOT_DEFAULT:-0}   # 0 => auto: data + 2 GiB headroom, aligned
VOLID=${ESP_VOLID:-ESPNABU}
ROOT_LABEL=${ROOT_LABEL:-${NABU_LABEL:-linux}}

UKI_REL=${UKI_REL:-EFI/debian/nabu-debian.efi}
ROOT_PART=${ROOT_PART:-/dev/disk/by-partlabel/${NABU_LABEL:-linux}}
ESP_PART=${ESP_PART:-/dev/disk/by-partlabel/esp}
ROOT_DEV_ALT=${ROOT_DEV_ALT:-/dev/disk/by-partlabel/userdata}

# Dual-boot ESP (rEFInd + Reboot2Android), like TheMojoMan/Fedora/postmarketOS.
DUALBOOT=${DUALBOOT:-1}
BOOT_ZIP=${BOOT_ZIP:-$HERE/boot/nabu-dualboot-efi.zip}
REFIND_CONF=${REFIND_CONF:-$HERE/config/refind.conf}
# Loader the on-device flash.sh points the NVRAM entry at (overridable).
LOADER_REL=${LOADER_REL:-}
BOOT_LABEL=${BOOT_LABEL:-}

# fastboot partition names for out/flash-fastboot.sh
FB_ESP_PART=${FB_ESP_PART:-esp}
FB_ROOT_PART=${FB_ROOT_PART:-${NABU_LABEL:-linux}}

DO_ESP=1
DO_ROOT=1
MAKE_FLASH=1
MAKE_FASTBOOT=1
while [ $# -gt 0 ]; do
	case $1 in
	--esp-only) DO_ROOT=0 ;;
	--linux-only | --root-only) DO_ESP=0 ;;
	--no-flash) MAKE_FLASH=0 ;;
	--no-fastboot) MAKE_FASTBOOT=0 ;;
	--no-dualboot) DUALBOOT=0 ;;
	--dual-boot) DUALBOOT=1 ;;
	--size)
		shift
		case ${1:-} in
		esp) ESP_SIZE=$2 ;;
		root | linux) ROOT_SIZE=$2 ;;
		*) echo "--size {esp|root} BYTES" >&2; exit 2 ;;
		esac
		shift
		;;
	-h | --help) sed -n '2,36p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

# Resolve the boot loader / NVRAM label now that DUALBOOT is final.
if [ -z "$LOADER_REL" ]; then
	if [ "$DUALBOOT" -eq 1 ]; then
		LOADER_REL=EFI/BOOT/bootaa64.efi
	else
		LOADER_REL=$UKI_REL
	fi
fi
[ -n "$BOOT_LABEL" ] || {
	if [ "$DUALBOOT" -eq 1 ]; then BOOT_LABEL='rEFInd (nabu)'; else BOOT_LABEL='Debian (nabu)'; fi
}

log() { printf '\033[1;34m[nabu-img]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[nabu-img] error:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found ($2)"; }

# Compact FAT32 image size for the staged ESP content: the files plus ~25% and
# 4 MiB slack, rounded up to 1 MiB, never below ESP_MIN.  Unlike the ext4
# rootfs, FAT is not grown at boot, so the image is kept just big enough to fit
# its content and stays flashable to any esp partition.
compact_esp_size() {
	local root=$1 content size
	content=$(du -sb "$root" | cut -f1)
	size=$(( content + content / 4 + 4 * 1024 * 1024 ))
	size=$(( (size + 1048575) / 1048576 * 1048576 ))
	[ "$size" -lt "$ESP_MIN" ] && size=$ESP_MIN
	printf '%s\n' "$size"
}

# Build a compact ext4 image and report the minimum partition size it needs.
build_root() {
	local img=$OUT/linux.img tar stage min
	log "build rootfs image $img (compact)"
	need mkfs.ext4 "e2fsprogs >= 1.47 (mkfs.ext4 -d)"
	need tar "tar"
	need e2fsck "e2fsprogs"

	for f in "$OUT"/nabu-debian-rootfs.tar.zst "$OUT"/nabu-debian-rootfs.tar.gz \
		"$OUT"/nabu-debian-rootfs.tar; do
		[ -f "$f" ] && tar=$f && break
	done
	[ -n "${tar:-}" ] || die "no rootfs tarball in $OUT (run build.sh first)"

	stage=$HERE/work/root-stage
	mkdir -p "$OUT"
	rm -rf "$stage" "$img"
	mkdir -p "$stage"
	case $tar in
	*.zst) zstd -dc "$tar" | tar -C "$stage" --numeric-owner -xpf - ;;
	*.gz) tar -C "$stage" --numeric-owner -xzpf "$tar" ;;
	*.tar) tar -C "$stage" --numeric-owner -xpf "$tar" ;;
	esac
	# Guard against a corrupted rootfs tarball (non-root ownership silently
	# breaks setuid tools like sudo in the booted image).
	if [ -e "$stage/usr/bin/sudo" ]; then
		su=$(stat -c %u "$stage/usr/bin/sudo")
		[ "$su" = 0 ] ||
			die "rootfs tarball has /usr/bin/sudo owned by uid $su (expected 0); rebuild the rootfs"
	fi
	# du includes on-disk block padding; add 20% + 1 GiB headroom
	local used_kb headroom_kb
	used_kb=$(du -sk "$stage" | cut -f1)
	headroom_kb=$((used_kb / 5 + 1048576))
	min=$(((used_kb + headroom_kb) * 1024))
	# round up to a 64 MiB boundary
	min=$(((min + 67108864 - 1) / 67108864 * 67108864))
	if [ -n "$ROOT_SIZE" ] && [ "$ROOT_SIZE" -gt 0 ]; then
		min=$ROOT_SIZE
	fi
	# create the fs with the compact size, then populate directly from $stage
	truncate -s "$min" "$img"
	mkfs.ext4 -F -q -L "$ROOT_LABEL" -d "$stage" "$img"
	rm -rf "$stage"
	ROOT_SIZE=$min
	log "wrote $img (${min} bytes); it will be grown to the partition on flash"
}

stage_dualboot_boot() {
	# Lay down the rEFInd + Reboot2Android chain from the vendored payload.
	local root=$1
	[ -f "$BOOT_ZIP" ] ||
		die "dual-boot EFI payload not found: $BOOT_ZIP (run ./fetch-efi.sh)"
	need unzip "unzip"
	unzip -q -o "$BOOT_ZIP" -d "$root"
	# never carry a distro-specific kernel from the payload
	rm -rf "$root/EFI/fedora"
	[ -f "$root/EFI/BOOT/bootaa64.efi" ] ||
		die "payload is missing EFI/BOOT/bootaa64.efi"
	[ -f "$root/EFI/Android/Reboot2Android.efi" ] ||
		die "payload is missing EFI/Android/Reboot2Android.efi"
	# NOTE: FAT is case-insensitive, so the firmware resolves
	# \EFI\BOOT\BOOTAA64.EFI to the lowercase bootaa64.efi shipped above.
	# Do not add an uppercase copy: it would be the same directory entry and
	# mtools refuses to write the duplicate.
	# Reference refind.conf (auto-scan, no hand-written menuentry); the payload
	# already carries an identical copy, so this is only a refresh/override.
	if [ -f "$REFIND_CONF" ]; then
		install -m0644 "$REFIND_CONF" "$root/EFI/BOOT/refind.conf"
	fi
}

# Bundle the assembled EFI tree as a zip, so it can be extracted onto an
# existing ESP (e.g. over adb/TWRP: unzip onto the esp partition) instead of
# flashing the whole esp.img.  Entries start with EFI/, like the reference
# distribution's efi/EFI tree.
make_efi_zip() {
	local root=$1
	local zip=$OUT/EFI.zip
	rm -f "$zip"
	if command -v zip >/dev/null 2>&1; then
		(cd "$root" && zip -q -r "$zip" EFI)
	elif command -v python3 >/dev/null 2>&1; then
		(
			cd "$root" &&
				python3 - "$zip" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for base, _dirs, files in os.walk("EFI"):
        for name in files:
            p = os.path.join(base, name)
            z.write(p, p)
PY
		)
	else
		log "zip/python3 not found; skipping $zip"
		return 0
	fi
	log "wrote $zip"
}

build_esp() {
	local img=$OUT/esp.img root=$HERE/work/esp-root
	log "build ESP image $img"
	need mkfs.fat "dosfstools"
	[ -f "$OUT/nabu-debian.efi" ] || die "missing $OUT/nabu-debian.efi (run build.sh --uki-only)"

	rm -rf "$root"
	install -d -m0755 "$root/EFI/debian"

	if [ "$DUALBOOT" -eq 1 ]; then
		# Same boot chain as the other nabu distros: rEFInd owns the ESP's
		# default loader and offers Debian or "Reboot to Android".
		stage_dualboot_boot "$root"
		log "ESP: dual-boot rEFInd + Reboot2Android + Debian UKI"
	else
		# Only our own boot files: no old-Ubuntu content is copied in.
		install -d -m0755 "$root/EFI/BOOT"
		# fallback loader used when no NVRAM entry points at our UKI yet
		cp -a "$OUT/nabu-debian.efi" "$root/EFI/BOOT/BOOTAA64.EFI"
		log "ESP: Debian UKI only"
	fi

	cp -a "$OUT/nabu-debian.efi" "$root/$UKI_REL"

	if [ -n "$ESP_SIZE" ]; then
		log "ESP size: $ESP_SIZE bytes (ESP_SIZE)"
	else
		ESP_SIZE=$(compact_esp_size "$root")
		log "ESP size: $ESP_SIZE bytes (compact; content $(du -sb "$root" | cut -f1) bytes)"
	fi

	mkdir -p "$OUT"
	rm -f "$img"
	truncate -s "$ESP_SIZE" "$img"
	mkfs.fat -F 32 -n "$VOLID" "$img" >/dev/null

	local populated=0
	if command -v mcopy >/dev/null 2>&1; then
		export MTOOLS_SKIP_CHECK=1
		mcopy -s -i "$img" "$root/EFI" ::/
		populated=1
	else
		local mnt
		mnt=$(mktemp -d "${TMPDIR:-/tmp}/nabu-img.XXXXXX")
		if mount -o loop "$img" "$mnt" 2>/dev/null; then
			(cd "$root" && cp -a . "$mnt/")
			sync
			umount "$mnt"
			populated=1
		fi
		rmdir "$mnt" 2>/dev/null || true
	fi
	[ "$populated" -eq 1 ] ||
		die "cannot populate the FAT image; install mtools (mcopy) or allow loop mounts"

	if command -v mdir >/dev/null 2>&1; then
		mdir -i "$img" "::/$UKI_REL" >/dev/null 2>&1 || die "UKI missing from $img"
		if [ "$DUALBOOT" -eq 1 ]; then
			mdir -i "$img" "::/EFI/BOOT/bootaa64.efi" >/dev/null 2>&1 ||
				die "rEFInd missing from $img"
			mdir -i "$img" "::/EFI/Android/Reboot2Android.efi" >/dev/null 2>&1 ||
				die "Reboot2Android missing from $img"
		fi
	fi
	log "wrote $img"
	make_efi_zip "$root"
}

make_flash_script() {
	local s=$OUT/flash.sh
	cat >"$s" <<EOF
#!/bin/bash
# Generated by make-img.sh.  Run on the tablet that will boot Debian.
# Writes esp.img and linux.img, grows the root filesystem to its partition and
# creates the UEFI boot entry.  The current Ubuntu system is left untouched.
set -euo pipefail
HERE=\$(cd -- "\$(dirname -- "\$0")" && pwd)
ESP_PART=\${ESP_PART:-$ESP_PART}
ROOT_PART=\${ROOT_PART:-$ROOT_PART}
ROOT_DEV_ALT=\${ROOT_DEV_ALT:-$ROOT_DEV_ALT}
BOOT_LABEL=\${BOOT_LABEL:-$BOOT_LABEL}
UKI_REL=\${UKI_REL:-$UKI_REL}
LOADER_REL=\${LOADER_REL:-$LOADER_REL}

log() { printf '\\033[1;34m[flash]\\033[0m %s\\n' "\$*"; }
die() { printf '\\033[1;31m[flash] error:\\033[0m %s\\n' "\$*" >&2; exit 1; }
[ "\$(id -u)" -eq 0 ] || die "must run as root (sudo \$0)"

write_part() {
	local img=\$1 part=\$2 dev grow=\$3
	[ -f "\$img" ] || die "missing \$img"
	for d in "\$part" "\${4:-}"; do
		[ -n "\$d" ] || continue
		[ -b "\$d" ] && { dev=\$(readlink -f "\$d"); break; }
	done
	[ -n "\${dev:-}" ] && [ -b "\$dev" ] || die "partition not found: \$part"
	[ "\$(readlink -f "\$(findmnt -no SOURCE /)")" != "\$dev" ] ||
		die "\$dev is the mounted root"
	! findmnt -no TARGET "\$dev" >/dev/null 2>&1 || die "\$dev is mounted"
	log "dd \$img -> \$dev"
	dd if="\$img" of="\$dev" bs=4M status=progress conv=fsync
	if [ "\$grow" = 1 ]; then
		e2fsck -fy "\$dev" >/dev/null 2>&1 || true
		resize2fs "\$dev"
		e2fsck -fy "\$dev" >/dev/null 2>&1 || true
	fi
}
EOF
	if [ "$DO_ROOT" -eq 1 ]; then
		cat >>"$s" <<'EOF'
write_part "$HERE/linux.img" "$ROOT_PART" 1 "$ROOT_DEV_ALT"
EOF
	fi
	if [ "$DO_ESP" -eq 1 ]; then
		cat >>"$s" <<'EOF'
write_part "$HERE/esp.img" "$ESP_PART" 0
EOF
	fi
	cat >>"$s" <<'EOF'

# create the UEFI boot entry (NVRAM based, like all nabu distributions); in
# dual-boot mode this points at rEFInd, otherwise at the Debian UKI directly.
# The existing Ubuntu entry is left untouched.
if command -v efibootmgr >/dev/null 2>&1; then
	ESP_DEV=$(readlink -f "$ESP_PART")
	DISK=$(basename "$(readlink -f "/sys/class/block/$(basename "$ESP_DEV")/..")")
	PNUM=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")
	LOADER="\\$(echo "$LOADER_REL" | tr / '\\')"
	command -v mount >/dev/null
	m=$(mktemp -d "${TMPDIR:-/tmp}/esp.XXXXXX")
	mount "$ESP_DEV" "$m"
	[ -f "$m/$UKI_REL" ] || { umount "$m"; die "UKI not on the ESP after flash"; }
	[ -f "$m/$LOADER_REL" ] || { umount "$m"; die "boot loader $LOADER_REL not on the ESP after flash"; }
	umount "$m"; rmdir "$m"
	efibootmgr -c -d "/dev/$DISK" -p "$PNUM" -L "$BOOT_LABEL" -l "$LOADER"
	log "UEFI boot entry \"$BOOT_LABEL\" created (BootOrder unchanged)"
else
	log "efibootmgr missing; add the boot entry with: efibootmgr -c -d /dev/DISK -p PNUM -L '$BOOT_LABEL' -l '$LOADER'"
fi
log "done; reboot and pick \"$BOOT_LABEL\" in the boot menu"
EOF
	chmod +x "$s"
	log "wrote $s"
}

make_fastboot_script() {
	# PC-side counterpart of flash.sh: the reference nabu distributions are
	# installed with `fastboot flash esp/linux`, so provide the same flow.
	local s=$OUT/flash-fastboot.sh
	cat >"$s" <<EOF
#!/bin/bash
# Generated by make-img.sh.  Run on a PC with the tablet in fastboot mode:
#   fastboot boot <modded TWRP>   # optional, to repartition first
#   fastboot flash esp   esp.img
#   fastboot flash linux linux.img
#   fastboot reboot
#
# Prerequisite for the Android + Linux dual boot: rodriguezst's boot manager
# patch (installer_bootmanager_NOSB.zip) must have been flashed once via
# TWRP/Magisk so the firmware starts rEFInd from the ESP.  On its own this
# script only installs the Debian rootfs and the boot menu.
set -euo pipefail
HERE=\$(cd -- "\$(dirname -- "\$0")" && pwd)
FB=\${FASTBOOT:-fastboot}
ESP_PART=\${FB_ESP_PART:-$FB_ESP_PART}
ROOT_PART=\${FB_ROOT_PART:-$FB_ROOT_PART}

log() { printf '\\033[1;34m[fastboot]\\033[0m %s\\n' "\$*"; }
die() { printf '\\033[1;31m[fastboot] error:\\033[0m %s\\n' "\$*" >&2; exit 1; }
command -v "\$FB" >/dev/null 2>&1 || die "\$FB not found"
"\$FB" devices 2>/dev/null | grep -q . || die "no device in fastboot mode (fastboot devices)"

if [ "$DO_ESP" -eq 1 ]; then
	[ -f "\$HERE/esp.img" ] || die "missing \$HERE/esp.img"
	log "fastboot flash \$ESP_PART esp.img"
	"\$FB" flash "\$ESP_PART" "\$HERE/esp.img"
fi
if [ "$DO_ROOT" -eq 1 ]; then
	[ -f "\$HERE/linux.img" ] || die "missing \$HERE/linux.img"
	log "fastboot flash \$ROOT_PART linux.img"
	"\$FB" flash "\$ROOT_PART" "\$HERE/linux.img"
fi
log "done; run 'fastboot reboot' and pick the entry in rEFInd"
EOF
	chmod +x "$s"
	log "wrote $s"
}

mkdir -p "$OUT" "$HERE/work"
if [ "$DO_ESP" -eq 1 ]; then build_esp; fi
if [ "$DO_ROOT" -eq 1 ]; then build_root; fi
if [ "$MAKE_FLASH" -eq 1 ]; then make_flash_script; fi
if [ "$MAKE_FASTBOOT" -eq 1 ]; then make_fastboot_script; fi

(
	cd "$OUT" || exit 0
	for f in esp.img linux.img EFI.zip; do
		[ -f "$f" ] && sha256sum "$f"
	done >IMG-SHA256SUMS
) 2>/dev/null || true

log "done."
if [ "$DO_ROOT" -eq 1 ]; then log "  rootfs: out/linux.img ($ROOT_SIZE bytes, compact)"; fi
if [ "$DO_ESP" -eq 1 ]; then log "  esp:    out/esp.img ($ESP_SIZE bytes, dual-boot=$DUALBOOT)"; fi
if [ "$DO_ESP" -eq 1 ]; then log "  efi:    out/EFI.zip (extract EFI/ onto an existing ESP)"; fi
if [ "$MAKE_FLASH" -eq 1 ]; then log "  flash:  sudo out/flash.sh"; fi
if [ "$MAKE_FASTBOOT" -eq 1 ]; then log "  flash:  ./out/flash-fastboot.sh  (PC + fastboot)"; fi