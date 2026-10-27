#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main helper: install the kernel .debs and the product UKI on a running
# tablet, then reboot it.
#
# Why both: the .debs bring /lib/modules/<release> (and headers), while the
# kernel itself is booted from a UKI on the ESP - deb-pkg's vmlinuz has no
# composed product DTB and no command line, so it must not be used for booting.
#
# Only /lib/modules is extracted from the deb, by hand:
#   * `dpkg -i` runs the Debian kernel postinst, which wants initramfs-tools and
#     update-grub - this image has neither;
#   * `dpkg --unpack` fails here anyway, because /boot on this tablet IS the ESP
#     (vfat, automounted on /boot), and dpkg insists on hard-linking the old
#     /boot/System.map-<release> out of the way.  vfat has no hard links, so the
#     unpack aborts with "unable to make backup link ... Operation not permitted".
# The kernel does not boot from /boot either - it boots from the UKI - so the
# vmlinuz/System.map/config members are useless here.
#
# The ESP cannot be mounted on the tablet (4096-byte logical sectors vs FAT's
# 512: "can't read superblock"), and mtools refuses the partition directly
# ("Hidden (656) does not match sectors (63)"), so copy the partition to a
# file, edit the file with mcopy, and write it back.
#
# Usage:
#   scripts/deb-install.sh [options]
#
#   -H host       tablet address            (default 192.168.0.67)
#   -p product    product name             (default from PRODUCT or production)
#   -u uki        local UKI                (default artifacts/<product>/<uki>)
#   -d dest       UKI path inside the ESP   (default EFI/debian/<release>.efi,
#                                           e.g. EFI/debian/6.14.11-nabu-minimal.efi,
#                                           so the file name matches the modules)
#   -P part       ESP partition            (default /dev/disk/by-partlabel/esp)
#   -n            do not reboot
#
# The sudo password comes from NABU_PW (prompted for when stdin is a terminal).

set -eu

MAIN=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

HOST=192.168.0.67
PRODUCT=${PRODUCT:-production}
UKI=
DEST=
PART=/dev/disk/by-partlabel/esp
REBOOT=1

while getopts "H:p:u:d:P:n" opt; do
	case "$opt" in
	H) HOST=$OPTARG ;;
	p) PRODUCT=$OPTARG ;;
	u) UKI=$OPTARG ;;
	d) DEST=$OPTARG ;;
	P) PART=$OPTARG ;;
	n) REBOOT=0 ;;
	*) sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
	esac
done

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

artifacts=$MAIN/artifacts/$PRODUCT
[ -d "$artifacts" ] || die "no artifacts for product $PRODUCT; run 'make PRODUCT=$PRODUCT' first"

if [ -z "$UKI" ]; then
	uki_name=$(sed -n 's/^uki *= *"\(.*\)"/\1/p' "$MAIN/products/$PRODUCT.toml")
	[ -n "$uki_name" ] || die "cannot read the UKI name from products/$PRODUCT.toml"
	UKI=$artifacts/$uki_name
fi
[ -f "$UKI" ] || die "no such UKI: $UKI"

# newest first: deb-pkg bumps the Debian revision on every run, and older
# packages are left behind in the directory.
deb=$(ls -t "$MAIN"/linux-image-*"$PRODUCT"*.deb 2>/dev/null | grep -v -- '-dbg' | head -n 1 || true)
[ -n "$deb" ] || die "no linux-image deb for $PRODUCT; run 'make deb-kernel' first"

# The UKI is named after the kernel release so that the ESP entry and
# /lib/modules/<release> always refer to the same build:
#   linux-image-6.14.11-nabu-minimal_<version>_arm64.deb -> 6.14.11-nabu-minimal
release=$(basename "$deb" | sed 's/^linux-image-//; s/_.*$//')
[ -n "$release" ] || die "cannot derive the release from $(basename "$deb")"
# set -e would abort on the "no" branch of a bare && chain
if [ -z "$DEST" ]; then
	DEST=EFI/debian/$release.efi
fi

if [ -z "${NABU_PW:-}" ]; then
	if [ -t 0 ]; then
		printf 'sudo password for %s: ' "$HOST" >&2
		stty -echo; read -r NABU_PW; stty echo; echo >&2
	else
		die "NABU_PW is not set and stdin is not a terminal"
	fi
fi

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 cfm880@$HOST"
as_root() { { printf '%s\n' "$NABU_PW"; cat; } | $SSH 'sudo -S -p "" bash -s'; }

$SSH true >/dev/null 2>&1 || die "cannot reach $HOST over ssh"

log "== pushing $(basename "$deb") ($(stat -c %s "$deb") bytes)"
cat "$deb" | $SSH 'cat > /home/cfm880/.nabu-image.deb' || die "push failed"
local_md5=$(md5sum "$deb" | cut -d' ' -f1)
remote_md5=$($SSH 'md5sum /home/cfm880/.nabu-image.deb' | cut -d' ' -f1)
[ "$local_md5" = "$remote_md5" ] || die "md5 mismatch: $local_md5 != $remote_md5"
log "== md5 ok: $local_md5"

log "== installing /lib/modules/$release"
as_root <<EOS
set -e
dpkg-deb --fsys-tarfile /home/cfm880/.nabu-image.deb |
	tar -x -C / --wildcards './lib/modules/$release/*'
rm -f /home/cfm880/.nabu-image.deb
depmod $release
echo "  modules: \$(find /lib/modules/$release -name '*.ko*' | wc -l)"
EOS

log "== pushing $(basename "$UKI")"
cat "$UKI" | $SSH 'cat > /home/cfm880/.nabu-uki' || die "push failed"
uki_md5=$(md5sum "$UKI" | cut -d' ' -f1)
[ "$uki_md5" = "$($SSH 'md5sum /home/cfm880/.nabu-uki' | cut -d' ' -f1)" ] || die "UKI md5 mismatch"
log "== md5 ok: $uki_md5"

log "== writing the UKI to $DEST on the ESP"
as_root <<EOS
set -e
img=/tmp/esp-install-\$\$.img
dd if=$PART of=\$img bs=1M status=none
mcopy -o -i \$img /home/cfm880/.nabu-uki ::/$DEST
mdir -i \$img ::/\$(dirname $DEST) | tail -n 2
dd if=\$img of=$PART bs=1M conv=fsync status=none
sync
rm -f \$img /home/cfm880/.nabu-uki
echo "== installed $DEST"
EOS

if [ "$REBOOT" = 1 ]; then
	log "== rebooting"
	$SSH 'systemctl reboot' >/dev/null 2>&1 || true
	sleep 30
	for _ in $(seq 1 18); do
		if $SSH true >/dev/null 2>&1; then
			log "== back up: $($SSH 'cat /proc/cmdline')"
			exit 0
		fi
		sleep 10
	done
	log "== tablet did not come back"
fi
