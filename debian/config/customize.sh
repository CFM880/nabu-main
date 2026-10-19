#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# mmdebstrap --customize-hook for the Debian nabu image.
#
# mmdebstrap runs "normal" customize hooks on the host (not inside the
# chroot), with $1 set to the rootfs directory.  Everything that must happen
# inside the target is wrapped in "chroot $1 ..." explicitly.
#
# Tunables come from the environment (same values build.sh used):
#   NABU_HOSTNAME (default nabu-debian)
#   NABU_USER     (default nabu, first user -> uid 1000)
#   NABU_PASSWORD (default nabu; change after the first login)
#   NABU_LABEL    (root partition label, default linux)

set -eu

root=$1
hostname=${NABU_HOSTNAME:-nabu-debian}
user=${NABU_USER:-nabu}
password=${NABU_PASSWORD:-nabu}
label=${NABU_LABEL:-linux}
# 1 = no user is pre-created; GDM runs gnome-initial-setup on first boot.
initial_setup=${NABU_INITIAL_SETUP:-1}

[ -d "$root/etc" ] || {
	echo "customize-hook: $root does not look like a rootfs" >&2
	exit 1
}

# --- identity -------------------------------------------------------------
echo "$hostname" >"$root/etc/hostname"
cat >"$root/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$hostname

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

# --- fstab ----------------------------------------------------------------
# root= is on the UKI command line; fstab only records the root entry so
# systemd-remount-fs and x-systemd.growfs (btrfs/ext4 online grow) work.
cat >"$root/etc/fstab" <<EOF
# <file system>	<mount point>	<type>	<options>	<dump>	<pass>
PARTLABEL=$label	/	ext4	errors=remount-ro,x-systemd.growfs	0	1
EOF

# --- locales --------------------------------------------------------------
if [ -f "$root/etc/locale.gen" ]; then
	if ! grep -q '^en_US.UTF-8' "$root/etc/locale.gen"; then
		echo 'en_US.UTF-8 UTF-8' >>"$root/etc/locale.gen"
	fi
	if ! grep -q '^zh_CN.UTF-8' "$root/etc/locale.gen"; then
		echo 'zh_CN.UTF-8 UTF-8' >>"$root/etc/locale.gen"
	fi
	chroot "$root" locale-gen
	chroot "$root" update-locale LANG=en_US.UTF-8
fi

# --- user -----------------------------------------------------------------
# adduser.conf drives the account gnome-initial-setup creates: the tablet
# needs these groups for GPU (render/video), sound (audio) and touch/input.
{
	echo '# nabu: groups the first (wizard-created) user needs.'
	echo 'ADD_EXTRA_GROUPS=1'
	echo 'EXTRA_GROUPS="video render audio input plugdev netdev"'
} >>"$root/etc/adduser.conf"

# By default no account is pre-created, so GDM runs gnome-initial-setup and the
# owner picks their own name/password.  Set NABU_INITIAL_SETUP=0 to pre-create
# the NABU_USER/NABU_PASSWORD account instead (headless/automation).
if [ "$initial_setup" = 0 ] || [ "$initial_setup" = no ]; then
	if ! chroot "$root" id "$user" >/dev/null 2>&1; then
		chroot "$root" useradd --create-home --shell /bin/bash --groups sudo "$user"
		# add whichever supplementary groups this suite actually defines
		for group in adm cdrom video render audio input plugdev netdev; do
			if chroot "$root" getent group "$group" >/dev/null 2>&1; then
				chroot "$root" usermod --append --groups "$group" "$user"
			fi
		done
		echo "$user:$password" | chroot "$root" chpasswd
	fi
fi

# --- services -------------------------------------------------------------
# systemctl enable works offline (it only creates symlinks).
chroot "$root" systemctl enable gdm3.service >/dev/null 2>&1 || true
chroot "$root" systemctl enable NetworkManager.service >/dev/null 2>&1 || true
chroot "$root" systemctl enable hexagonrpcd.service >/dev/null 2>&1 || true
chroot "$root" systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
chroot "$root" systemctl enable ssh.service >/dev/null 2>&1 || true
if [ ! -L "$root/etc/resolv.conf" ]; then
	rm -f "$root/etc/resolv.conf"
	ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
fi
# The kernel qcom_pd_mapper carries the SM8150 domain table; the userspace
# pd-mapper would answer with empty domain lists and break SLPI discovery.
chroot "$root" systemctl mask pd-mapper.service >/dev/null 2>&1 || true
# The BT stack keeps the c8c000.serial UART busy, and that UART's system
# suspend then takes ~127 ms and sometimes never completes, wedging the whole
# suspend.  The tablet has no usable BT adapter anyway (no hci device), so mask
# the service.
chroot "$root" systemctl mask bluetooth.service >/dev/null 2>&1 || true

# --- machine identity -----------------------------------------------------
if command -v systemd-machine-id-setup >/dev/null 2>&1; then
	chroot "$root" systemd-machine-id-setup
else
	: >"$root/etc/machine-id"
	chmod 0644 "$root/etc/machine-id"
fi

# Completion marker: build.sh only reuses a rootfs, skipping debootstrap, when
# this marker exists (i.e. mmdebstrap finished), never for a partial rootfs.
install -d -m0755 "$root/var/lib/nabu-debian"
: >"$root/var/lib/nabu-debian/rootfs-complete"

echo "customize-hook: $hostname ready (user $user)" >&2