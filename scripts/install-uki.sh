#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Product-level UKI installer (nabu-main).
#
# Installs the product UKI to a new file on the ESP and creates a new UEFI
# boot entry for it, leaving the previously booted entry in place as a
# fallback.  This device has no bootloader manager, so the firmware boots an
# ESP file directly through an NVRAM Boot#### variable; efibootmgr is used to
# create it.  All state needed for rollback is stored under NABU_BACKUP_DIR.
#
# Environment (set by nabu-main):
#   NABU_ARTIFACTS   collected artifact directory (contains $NABU_UKI)
#   NABU_UKI         product UKI file name
#   NABU_RELEASE     product kernel release
#   NABU_UKI_TARGET  ESP-relative install path, e.g. EFI/ubuntu/foo.efi
#   NABU_ESP         ESP block device
#   NABU_ESP_MOUNT   ESP mount point
#   NABU_BOOT_LABEL  UEFI boot entry label
#   NABU_BACKUP_DIR  state/backup directory

set -eu

mode=${1:-}
case $mode in
"") ;;
--rollback) ;;
*)
	echo "usage: $0 [--rollback]" >&2
	exit 2
	;;
esac

esp=${NABU_ESP:-/dev/disk/by-partlabel/esp}
esp_mount=${NABU_ESP_MOUNT:-/boot/efi}
release=${NABU_RELEASE:?}
artifact_dir=${NABU_ARTIFACTS:?}
uki=${NABU_UKI:?}
target_rel=${NABU_UKI_TARGET:?}
boot_label=${NABU_BOOT_LABEL:-nabu-$release}
backup_dir=${NABU_BACKUP_DIR:-/var/lib/nabu-main}
state=$backup_dir/uki-state.env

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

mounted_here=false
cleanup()
{
	if [ "$mounted_here" = true ]; then
		sync
		umount "$esp_mount"
	fi
}

mount_esp()
{
	command -v findmnt >/dev/null 2>&1 || {
		echo "missing findmnt" >&2
		exit 1
	}
	if findmnt -rn -M "$esp_mount" >/dev/null 2>&1; then
		mounted_source=$(findmnt -rn -o SOURCE -M "$esp_mount")
		[ "$(readlink -f -- "$mounted_source")" = "$(readlink -f -- "$esp")" ] || {
			echo "$esp_mount is mounted from unexpected device: $mounted_source" >&2
			exit 1
		}
	else
		[ -b "$esp" ] || {
			echo "missing ESP device: $esp" >&2
			exit 1
		}
		install -d -m 0755 -- "$esp_mount"
		mount -t vfat "$esp" "$esp_mount"
		mounted_here=true
	fi
}

if [ "$mode" = "--rollback" ]; then
	[ -f "$state" ] || {
		echo "no product UKI install state: $state" >&2
		exit 1
	}
	# shellcheck disable=SC1090
	. "$state"
	mount_esp
	trap cleanup EXIT HUP INT TERM

	if [ -n "${BOOTENTRY:-}" ] && command -v efibootmgr >/dev/null 2>&1; then
		efibootmgr -b "$BOOTENTRY" -B >/dev/null || true
	fi
	if [ -n "${OLD_ORDER:-}" ] && command -v efibootmgr >/dev/null 2>&1; then
		efibootmgr -o "$OLD_ORDER" >/dev/null || true
	fi
	if [ -n "${BACKUP:-}" ] && [ -f "$BACKUP" ]; then
		install -m 0644 -- "$BACKUP" "$esp_mount/$target_rel"
		rm -f -- "$BACKUP"
	elif [ -f "$esp_mount/$target_rel" ]; then
		rm -f -- "$esp_mount/$target_rel"
	fi
	rm -f -- "$state"
	echo "rolled back product UKI: $target_rel"
	exit 0
fi

source_uki=$artifact_dir/$uki
[ -s "$source_uki" ] || {
	echo "missing product UKI: $source_uki" >&2
	exit 1
}
strings "$source_uki" | grep -Fq "$release" || {
	echo "product UKI does not contain release $release" >&2
	exit 1
}
strings "$source_uki" | grep -Fq 'root=PARTLABEL=linux' || {
	echo "product UKI does not contain the expected command line" >&2
	exit 1
}

command -v efibootmgr >/dev/null 2>&1 || {
	echo "installing efibootmgr"
	apt-get install --no-install-recommends -y efibootmgr
}

mount_esp
trap cleanup EXIT HUP INT TERM

dest=$esp_mount/$target_rel
install -d -m 0755 -- "$(dirname -- "$dest")"

backup=
if [ -e "$dest" ]; then
	install -d -m 0700 -- "$backup_dir"
	backup=$backup_dir/$(basename -- "$target_rel").pre-nabu-main
	if [ ! -f "$backup" ]; then
		install -m 0644 -- "$dest" "$backup"
	fi
fi

temporary=$dest.new
rm -f -- "$temporary"
install -m 0644 -- "$source_uki" "$temporary"
sync "$temporary"
[ "$(sha256sum "$temporary" | cut -d ' ' -f 1)" = "$(sha256sum "$source_uki" | cut -d ' ' -f 1)" ] || {
	rm -f -- "$temporary"
	echo "copy verification failed" >&2
	exit 1
}
mv -f -- "$temporary" "$dest"
sync "$dest"

disk=$(lsblk -no PKNAME "$esp" | head -1)
part=$(lsblk -no PARTN "$esp" | head -1)
[ -n "$disk" ] && [ -n "$part" ] || {
	echo "cannot derive ESP disk/partition from $esp" >&2
	exit 1
}

loader="\\$(printf '%s' "$target_rel" | tr '/' '\\')"
old_order=$(efibootmgr | sed -n 's/^BootOrder: //p' | tr -d ' ')
entry=$(efibootmgr |
	sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)[* ].*$boot_label.*/\1/p" | head -1)
if [ -n "$entry" ]; then
	echo "reusing existing UEFI boot entry: Boot$entry ($boot_label)"
else
	create_out=$(efibootmgr -c -d "/dev/$disk" -p "$part" -L "$boot_label" -l "$loader")
	entry=$(printf '%s\n' "$create_out" |
		sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)[* ].*$boot_label.*/\1/p" | head -1)
	[ -n "$entry" ] || {
		echo "failed to create UEFI boot entry; efibootmgr output:" >&2
		printf '%s\n' "$create_out" >&2
		exit 1
	}
fi

new_order=$(printf '%s' "$old_order" | tr ',' '\n' | grep -v "^$entry$" | paste -sd, -)
if [ -n "$new_order" ]; then
	new_order=$entry,$new_order
else
	new_order=$entry
fi
efibootmgr -o "$new_order" >/dev/null

install -d -m 0700 -- "$backup_dir"
{
	echo "BOOTENTRY=$entry"
	echo "OLD_ORDER=$old_order"
	echo "TARGET_REL=$target_rel"
	echo "BACKUP=$backup"
	echo "LABEL=$boot_label"
} > "$state"
chmod 600 "$state"

echo "installed product UKI: $dest"
echo "UEFI boot entry: Boot$entry ($boot_label)"
echo "boot order: $new_order"
[ -n "$backup" ] && echo "previous UKI backed up: $backup"
echo "rollback: sudo $(dirname -- "$0")/nabu --product ${NABU_PRODUCT:-production} rollback"
echo "reboot to start $release"
