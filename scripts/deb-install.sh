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
# "make deb-kernel" already repacked the image deb (scripts/deb-repack.sh):
# /boot is gone from the payload and the maintainer scripts only run depmod.
# That matters because /boot on this tablet IS the ESP (vfat, automounted), and
# the stock Debian scripts both fail there ("unable to make backup link of
# ./boot/System.map-...: Operation not permitted") and would try to rebuild an
# initramfs that this system does not use.
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

# Everything we push is safe to install here: the image deb was repacked (no
# /boot, depmod-only scripts) and the headers deb only writes /usr/src.
# linux-libc-dev is deliberately left out - it would replace the distribution's
# uapi headers, and the kernel does not need its own copy on the device.
debs=$deb
hdr=$(ls -t "$MAIN"/linux-headers-*"$PRODUCT"*.deb 2>/dev/null | head -n 1 || true)
if [ -n "$hdr" ]; then
	debs="$debs $hdr"
fi

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

for d in $debs; do
	log "== pushing $(basename "$d") ($(stat -c %s "$d") bytes)"
	cat "$d" | $SSH 'cat > /home/cfm880/.nabu-deb' || die "push failed"
	local_md5=$(md5sum "$d" | cut -d' ' -f1)
	remote_md5=$($SSH 'md5sum /home/cfm880/.nabu-deb' | cut -d' ' -f1)
	[ "$local_md5" = "$remote_md5" ] || die "md5 mismatch: $local_md5 != $remote_md5"
	log "== md5 ok: $local_md5"

	# One at a time, re-pushing into the same path.
	log "== installing $(basename "$d")"
	as_root <<'EOS'
set -e
dpkg -i /home/cfm880/.nabu-deb
rm -f /home/cfm880/.nabu-deb
EOS
done

as_root <<EOS
set -e
echo "  modules: \$(find /lib/modules/$release -name '*.ko*' | wc -l)"
EOS

# Publish the same .debs in a tiny local apt repository, so "apt search" and
# "apt install" know them by name.  Packages/ is generated here: the tablet has
# no dpkg-dev, and a compressed index is enough for apt.
repodir=/var/lib/nabu-debs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# dpkg-scanpackages needs the real <package>_<version>_<arch>.deb names
for d in $debs; do
	cp "$d" "$tmp/"
done
( cd "$tmp" && dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9c > Packages.gz )
[ -s "$tmp/Packages.gz" ] || die "dpkg-scanpackages produced nothing"

log "== publishing a local apt repository"
tar -C "$tmp" -cf - . | $SSH 'mkdir -p /home/cfm880/.nabu-repo && tar -C /home/cfm880/.nabu-repo -xf -'
as_root <<EOS
set -e
mkdir -p $repodir
mv /home/cfm880/.nabu-repo/*.deb $repodir/
mv /home/cfm880/.nabu-repo/Packages.gz $repodir/
rm -rf /home/cfm880/.nabu-repo
echo "deb [trusted=yes] file:$repodir ./" > /etc/apt/sources.list.d/nabu-local.list
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/nabu-local.list \
	-o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0 >/dev/null 2>&1 || \
	apt-get update >/dev/null 2>&1 || true
echo "  repo: $repodir (\$(ls $repodir/*.deb | wc -l) packages)"
EOS
rm -rf "$tmp"; trap - EXIT INT TERM

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
