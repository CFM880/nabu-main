#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main helper: make the kernel deb installable on the tablet.
#
# "make bindeb-pkg" produces a stock Debian kernel package, which assumes two
# things this device does not have:
#
#   * /boot writable and hard-link capable.  On the tablet /boot IS the ESP
#     (vfat, automounted), so dpkg fails with
#       unable to make backup link of './boot/System.map-...': Operation not permitted
#     and that file is useless anyway: the kernel boots from the UKI.
#   * initramfs-tools and update-grub, which the maintainer scripts call.
#
# So repack the image deb: drop /boot from the payload and replace the
# maintainer scripts with a postinst that just runs depmod.  The result installs
# with plain "dpkg -i" and registers in the dpkg database, so it can also be
# removed cleanly.
#
# Usage: scripts/deb-repack.sh <linux-image-*.deb> [...]
# Rewrites the packages in place (same filename).

set -eu

[ $# -gt 0 ] || { echo "usage: $0 <linux-image-*.deb>..." >&2; exit 1; }

for deb in "$@"; do
	case "$deb" in
	*-dbg_*) continue ;;	# debug symbols: nothing to change
	esac

	[ -f "$deb" ] || { echo "skip: $deb" >&2; continue; }

	release=$(basename "$deb" | sed 's/^linux-image-//; s/_.*$//')
	[ -n "$release" ] || { echo "cannot derive release from $deb" >&2; exit 1; }

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	dpkg-deb -R "$deb" "$tmp/root" >/dev/null
	rm -rf "$tmp/root/boot"

	# Stock scripts: preinst/prerm/postrm talk to initramfs-tools and the boot
	# loader; postinst does the same plus depmod.  Replace all of them.
	rm -f "$tmp/root/DEBIAN/preinst" "$tmp/root/DEBIAN/prerm" \
	      "$tmp/root/DEBIAN/postrm" "$tmp/root/DEBIAN/postinst"

	cat > "$tmp/root/DEBIAN/postinst" <<EOF
#!/bin/sh
# Nabu: modules only.  The kernel itself boots from the UKI on the ESP, so
# there is no /boot entry to update and no initramfs to rebuild.
set -e
if [ "\$1" = "configure" ]; then
	depmod -a $release || true
fi
exit 0
EOF
	chmod 0755 "$tmp/root/DEBIAN/postinst"

	# The stock package depends on initramfs-tools; we do not need it.
	sed -i 's/^Depends:.*/Depends: /' "$tmp/root/DEBIAN/control"

	dpkg-deb --build --root-owner-group "$tmp/root" "$tmp/out.deb" >/dev/null
	mv -f "$tmp/out.deb" "$deb"
	rm -rf "$tmp"; trap - EXIT INT TERM
	printf 'repacked %s (no /boot, depmod-only postinst)\n' "$(basename "$deb")"
done
