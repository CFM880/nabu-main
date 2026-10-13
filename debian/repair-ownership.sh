#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# One-off repair for a rootfs whose ownership was corrupted by an accidental
# recursive chown (everything became uid 1000 and setuid bits were lost, which
# breaks sudo/passwd/su).  Instead of re-running debootstrap, reset the tree to
# root and restore owner+mode for every path it shares with a pristine
# reference rootfs of the same Debian family (e.g. a freshly debootstrapped
# one).
#
#   make debian-repair-ownership
#
# Environment: TARGET (default debian/work/rootfs), REF (default
# debian/work/rootfs-pristine; point it at any pristine same-family rootfs).
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET=${TARGET:-$HERE/work/rootfs}
REF=${REF:-$HERE/work/rootfs-pristine}

log() { printf '\033[1;34m[repair]\033[0m %s\n' "$*"; }
die() {
	printf '\033[1;31m[repair] error:\033[0m %s\n' "$*" >&2
	exit 1
}

[ -d "$TARGET/usr/bin" ] || die "no target rootfs at $TARGET (build it first, or set TARGET)"
[ -d "$REF/usr/bin" ] ||
	die "no reference rootfs at $REF (set REF); otherwise just re-debootstrap (make debian-clean && make debian-img)"

log "resetting $TARGET to root:root"
chown -R 0:0 "$TARGET"

log "restoring owner/mode from $REF for shared paths (this takes a minute)"
( cd "$REF" && find . -mindepth 1 -print0 ) |
	while IFS= read -r -d '' p; do
		t="$TARGET/$p"
		if [ -L "$t" ]; then
			chown -h --reference="$REF/$p" "$t" 2>/dev/null || true
		elif [ -e "$t" ]; then
			chown --reference="$REF/$p" "$t" 2>/dev/null || true
			chmod --reference="$REF/$p" "$t" 2>/dev/null || true
		fi
	done

su_file=$TARGET/usr/bin/sudo
[ -e "$su_file" ] || die "no /usr/bin/sudo in $TARGET"
u=$(stat -c %u "$su_file")
m=$(stat -c %a "$su_file")
log "/usr/bin/sudo uid=$u mode=$m"
[ "$u" = 0 ] || die "repair failed: sudo is not uid 0"
case $m in
4??? | 5??? | 6??? | 7???) ;;
*) log "warning: /usr/bin/sudo mode $m may lack the setuid bit" ;;
esac
log "done — rebuild the image with: make debian-img"
