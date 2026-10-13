#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Fetch / refresh the dual-boot EFI payload used by make-img.sh.
#
# The payload is the same boot chain every nabu Linux distribution ships on
# its ESP: rEFInd (rodriguezst/rEFInd-nabu) plus Reboot2Android.efi
# (rodriguezst/Reboot2AndroidPkg), with the "refind-theme-regular" theme.
# It comes from the Fedora-for-nabu release bundle `efi-files-<ver>.zip`,
# which packages exactly those upstream binaries.
#
# make-img.sh only needs boot/nabu-dualboot-efi.zip, which is committed here,
# so a normal image build never downloads anything.  Run this script only to
# refresh to a newer payload.
#
#   ./fetch-efi.sh                 # fetch the pinned version, re-verify
#   ./fetch-efi.sh --version 43.0  # override the release version
#   EFI_URL=... ./fetch-efi.sh     # override the download URL entirely

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
BOOT=$HERE/boot
VERSION=43.0
# Pinned Fedora-for-nabu release that bundles rEFInd + Reboot2Android + theme.
RELEASE_TAG=${EFI_RELEASE_TAG:-release-20260417-1049}
EFI_URL=${EFI_URL:-https://github.com/jhuang6451/nabu_fedora/releases/download/$RELEASE_TAG/efi-files-$VERSION.zip}
# sha256 of the upstream efi-files-<version>.zip we vendor from
SOURCE_SHA256=${EFI_SHA256:-15361b7d1ccf1631308745a0cc73cc27a14de15de2c5191ceca8cd0989daa213}
OUT=$BOOT/nabu-dualboot-efi.zip

log() { printf '\033[1;34m[fetch-efi]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fetch-efi] error:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--version)
		VERSION=$2
		EFI_URL=${EFI_URL:-https://github.com/jhuang6451/nabu_fedora/releases/download/$RELEASE_TAG/efi-files-$VERSION.zip}
		shift
		;;
	-h | --help) sed -n '2,22p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found ($2)"; }
need curl "curl"
need unzip "unzip"
need zip "zip"
need sha256sum "coreutils"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fetch-efi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

log "downloading $EFI_URL"
curl -fL --retry 3 -o "$tmp/efi-files.zip" "$EFI_URL" || die "download failed"

got=$(sha256sum "$tmp/efi-files.zip" | cut -d' ' -f1)
if [ -n "$SOURCE_SHA256" ] && [ "$got" != "$SOURCE_SHA256" ]; then
	# A different version legitimately has a different hash; only hard-fail on
	# the pinned one.
	if [ "$VERSION" = 43.0 ]; then
		die "sha256 mismatch: expected $SOURCE_SHA256, got $got"
	fi
	log "note: $VERSION has sha256 $got (not the pinned $SOURCE_SHA256)"
fi

log "extracting EFI/ (dropping the distro-specific EFI/fedora kernel)"
unzip -q "$tmp/efi-files.zip" -d "$tmp/x" 'EFI/*' -x 'EFI/fedora/*'
rm -rf "$tmp/x/EFI/fedora"
[ -f "$tmp/x/EFI/BOOT/bootaa64.efi" ] || die "payload is missing EFI/BOOT/bootaa64.efi"
[ -f "$tmp/x/EFI/Android/Reboot2Android.efi" ] || die "payload is missing EFI/Android/Reboot2Android.efi"

mkdir -p "$BOOT"
rm -f "$OUT"
( cd "$tmp/x" && zip -q -r -X "$OUT" EFI )
log "wrote $OUT"
sha256sum "$OUT" | sed 's/^/  /'
