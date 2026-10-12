#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build a Debian trixie (arm64, GNOME) rootfs together with a nabu UKI.
#
# Entry point from nabu-main: `make debian-img`, which runs this and
# make-img.sh inside the build container (privileged, with network).  Run this
# script directly when building on the host instead (needs root).
#
# Everything device-specific is an explicit, distributable input so the image
# can be produced on ANY arm64 Debian/Ubuntu host:
#
#   packages/xiaomi-nabu-firmware_*_arm64.deb   proprietary firmware
#   packages/nabu-userspace_*_arm64.deb         SLPI/SSC userspace (/usr/local)
#   packages/nabu-linux-modules_*_arm64.deb     /lib/modules/$KERNEL_RELEASE
#
# Build those inputs once on the tablet with `sudo ./build.sh --make-packages`
# (or copy them from a previous run), then run the image build anywhere with the
# same kernel artifacts.  When an input is missing and the local host happens to
# have the corresponding files, build.sh falls back to them and builds the .deb
# on the fly.
#
# Requirements:
#   * run as root for the rootfs build (chroot, dpkg)
#   * mmdebstrap, debian-archive-keyring, ukify
#   * nabu-main artifacts: Image + DTB (or --uki-only can build the UKI alone)
#   * the nabu-* module repositories (configs/units/rules)
#
# Outputs:
#   packages/*.deb                          inputs (firmware/userspace/modules)
#   out/nabu-debian-rootfs.tar.gz / .tar.zst
#   out/nabu-debian.efi
#   out/SHA256SUMS, packages/SHA256SUMS

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)       # nabu-main/debian
MAIN=$(dirname -- "$HERE")                       # nabu-main
NABU_ROOT=$(dirname -- "$MAIN")                  # .../nabu-linux
WORK=${NABU_WORK:-$HERE/work}
ROOTFS=$WORK/rootfs
OUT=$HERE/out
PACKAGES_DIR=${NABU_PACKAGES_DIR:-$HERE/packages}
# Keep working when the input debs still live in a sibling nabu-debian checkout
# (the migration left that repository in place): fall back to it unless the
# caller pinned NABU_PACKAGES_DIR explicitly.
if [ -z "${NABU_PACKAGES_DIR:-}" ] && ! ls "$PACKAGES_DIR"/*.deb >/dev/null 2>&1 &&
	[ -d "$NABU_ROOT/nabu-debian/packages" ]; then
	PACKAGES_DIR=$NABU_ROOT/nabu-debian/packages
fi

SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-https://mirrors.ustc.edu.cn/debian}
ARCH=arm64

PRODUCT=${PRODUCT:-production}
KERNEL_RELEASE=${KERNEL_RELEASE:-6.14.11-nabu-full}
KEYRING=${NABU_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}

PKG_BASE_VERSION=${PKG_BASE_VERSION:-7.2.7-1}
FIRMWARE_PKG=${FIRMWARE_PKG:-xiaomi-nabu-firmware}
FIRMWARE_VERSION=${FIRMWARE_VERSION:-$PKG_BASE_VERSION}
USERSPACE_PKG=${USERSPACE_PKG:-nabu-userspace}
USERSPACE_VERSION=${USERSPACE_VERSION:-$PKG_BASE_VERSION}
MODULES_PKG=${MODULES_PKG:-nabu-linux-modules}
MODULES_VERSION=${MODULES_VERSION:-$KERNEL_RELEASE}
MODULES_SRC=${NABU_MODULES_SRC:-/lib/modules/$KERNEL_RELEASE}
# When set, stage /lib/modules from the current nabu-main build (make
# modules_install) instead of using a prebuilt modules deb or /lib/modules.
MODULES_FROM_BUILD=${NABU_MODULES_FROM_BUILD:-0}
# Likewise, build the /usr/local userspace deb from the current nabu-main
# collected artifacts instead of a prebuilt deb or the host /usr/local tree.
USERSYS_FROM_BUILD=${NABU_USERSPACE_FROM_BUILD:-0}
FIRMWARE_DEB=$PACKAGES_DIR/${FIRMWARE_PKG}_${FIRMWARE_VERSION}_arm64.deb
USERSPACE_DEB=$PACKAGES_DIR/${USERSPACE_PKG}_${USERSPACE_VERSION}_arm64.deb
MODULES_DEB=$PACKAGES_DIR/${MODULES_PKG}_${MODULES_VERSION}_arm64.deb

HOSTNAME=${NABU_HOSTNAME:-nabu-debian}
USERNAME=${NABU_USER:-nabu}
PASSWORD=${NABU_PASSWORD:-nabu}
LABEL=${NABU_LABEL:-linux}

ART=$MAIN/artifacts/$PRODUCT
case $PRODUCT in
production-7.2) DTB_NAME=${DTB_NAME:-sm8150-xiaomi-nabu-production-7.2.dtb} ;;
*) DTB_NAME=${DTB_NAME:-sm8150-xiaomi-nabu-production.dtb} ;;
esac

MODULES="nabu-platform nabu-display nabu-touchscreen nabu-iris nabu-camera nabu-audio nabu-accelerometer nabu-power"

log() { printf '\033[1;34m[nabu-debian]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[nabu-debian] error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
usage: sudo $0 [options]

image build:
  --rootfs-only        build/customize the rootfs and its tarball only
  --uki-only           rebuild only out/nabu-debian.efi (no root needed)
  --rebuild-rootfs     force a fresh mmdebstrap run (default: reuse work/rootfs)
  --clean              remove work/ and out/ first
  --packages-dir DIR   input package directory (default $PACKAGES_DIR)

package inputs (run on the tablet to (re)generate packages/*.deb):
  --make-packages      build firmware + userspace + modules .deb inputs
  --firmware-deb-only  build only the firmware .deb
  --userspace-deb-only build only the userspace .deb
  --modules-deb-only   build only the modules .deb

environment:
  SUITE, MIRROR, PRODUCT, KERNEL_RELEASE, NABU_HOSTNAME, NABU_USER,
  NABU_PASSWORD, NABU_LABEL, PKG_BASE_VERSION, FIRMWARE_VERSION,
  USERSPACE_VERSION, MODULES_VERSION, NABU_PACKAGES_DIR
EOF
}

ROOTFS_ONLY=0
UKI_ONLY=0
FIRMWARE_DEB_ONLY=0
USERSPACE_DEB_ONLY=0
MODULES_DEB_ONLY=0
MAKE_PACKAGES=0
CLEAN=0
REBUILD_ROOTFS=0
while [ $# -gt 0 ]; do
	case $1 in
	--rootfs-only) ROOTFS_ONLY=1 ;;
	--uki-only) UKI_ONLY=1 ;;
	--firmware-deb-only) FIRMWARE_DEB_ONLY=1 ;;
	--userspace-deb-only) USERSPACE_DEB_ONLY=1 ;;
	--modules-deb-only) MODULES_DEB_ONLY=1 ;;
	--make-packages) MAKE_PACKAGES=1 ;;
	--rebuild-rootfs) REBUILD_ROOTFS=1 ;;
	--packages-dir)
		PACKAGES_DIR=$2
		FIRMWARE_DEB=$PACKAGES_DIR/${FIRMWARE_PKG}_${FIRMWARE_VERSION}_arm64.deb
		USERSPACE_DEB=$PACKAGES_DIR/${USERSPACE_PKG}_${USERSPACE_VERSION}_arm64.deb
		MODULES_DEB=$PACKAGES_DIR/${MODULES_PKG}_${MODULES_VERSION}_arm64.deb
		shift
		;;
	--clean)
		CLEAN=1
		REBUILD_ROOTFS=1
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done

PKG_ONLY=0
if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$FIRMWARE_DEB_ONLY" -eq 1 ] ||
	[ "$USERSPACE_DEB_ONLY" -eq 1 ] || [ "$MODULES_DEB_ONLY" -eq 1 ]; then
	PKG_ONLY=1
fi

pkg_input_present() {
	local pat=$1 f
	for f in "$PACKAGES_DIR"/$pat; do
		[ -f "$f" ] && return 0
	done
	return 1
}

preflight() {
	command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (dpkg)"

	if [ "$PKG_ONLY" -eq 1 ]; then
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$FIRMWARE_DEB_ONLY" -eq 1 ]; then
			[ -d /lib/firmware/qcom/sm8150/xiaomi/nabu ] ||
				die "missing nabu firmware in /lib/firmware; run nabu-main install first"
		fi
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$USERSPACE_DEB_ONLY" -eq 1 ]; then
			[ -x /usr/local/libexec/iio-sensor-proxy-ssc ] ||
				die "missing /usr/local nabu userspace; run nabu-accelerometer install first"
		fi
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$MODULES_DEB_ONLY" -eq 1 ]; then
			[ -d "$MODULES_SRC" ] ||
				die "missing $MODULES_SRC; run nabu-main install (or set NABU_MODULES_SRC)"
		fi
		return 0
	fi

	# A UKI-only rebuild just runs ukify on existing artifacts; no root needed.
	if [ "$UKI_ONLY" -eq 0 ]; then
		[ "$(id -u)" -eq 0 ] || die "must run as root (use: sudo $0)"
	fi

	if [ "$UKI_ONLY" -eq 0 ]; then
		command -v mmdebstrap >/dev/null 2>&1 ||
			die "mmdebstrap not found; install it with: apt-get install -y mmdebstrap"
		if [ ! -e "$KEYRING" ]; then
			log "installing Debian archive keyring (debian-archive-keyring)"
			apt-get install -y debian-archive-keyring >/dev/null 2>&1 ||
				die "install debian-archive-keyring (or set NABU_KEYRING to a Debian keyring)"
		fi
		[ -e "$KEYRING" ] || die "missing Debian keyring: $KEYRING"
		local m
		for m in $MODULES; do
			[ -f "$NABU_ROOT/$m/nabu-module.toml" ] || die "missing module repo $NABU_ROOT/$m"
		done
		# missing inputs are only a problem when the host cannot provide them
		if [ "$MODULES_FROM_BUILD" = 1 ]; then
			[ -d "$MAIN/out" ] ||
				die "NABU_MODULES_FROM_BUILD=1 but $MAIN/out is missing; run 'make' in nabu-main first"
		else
			pkg_input_present "nabu-linux-modules_*.deb" ||
				[ -d "/lib/modules/$KERNEL_RELEASE" ] ||
				die "no modules input in $PACKAGES_DIR and no /lib/modules/$KERNEL_RELEASE"
		fi
		pkg_input_present "xiaomi-nabu-firmware_*.deb" ||
			[ -d /lib/firmware/qcom/sm8150/xiaomi/nabu ] ||
			die "no firmware input in $PACKAGES_DIR and no local firmware"
		if [ "$USERSYS_FROM_BUILD" = 1 ]; then
			{ [ -f "$ART/ssccli" ] && [ -f "$ART/iio-sensor-proxy-ssc" ]; } ||
				die "NABU_USERSPACE_FROM_BUILD=1 but userspace artifacts are missing; run 'make package' first"
		else
			pkg_input_present "nabu-userspace_*.deb" ||
				[ -x /usr/local/libexec/iio-sensor-proxy-ssc ] ||
				die "no userspace input in $PACKAGES_DIR and no local userspace"
		fi
	fi

	if [ "$ROOTFS_ONLY" -eq 0 ]; then
		command -v ukify >/dev/null 2>&1 ||
			die "ukify not found; install systemd-ukify (or systemd-boot-efi)"
		[ -f "$ART/Image" ] || die "missing $ART/Image; run 'make package' in nabu-main first"
		[ -f "$ART/$DTB_NAME" ] || die "missing $ART/$DTB_NAME; run 'make package' in nabu-main first"
	fi
}

# --------------------------------------------------------------------------
# input packages
# --------------------------------------------------------------------------

dpkg_build() {
	local stage=$1 deb=$2
	mkdir -p "$(dirname -- "$deb")"
	rm -f "$deb"
	# --root-owner-group makes the archive root:root even when built unprivileged
	dpkg-deb --root-owner-group --build "$stage" "$deb"
	log "wrote $deb"
}

stage_firmware_tree() {
	local stage=$1
	local fw=$stage/usr/lib/firmware
	rm -rf "$stage"
	install -d -m0755 "$fw"

	local d f
	for d in \
		qcom/sm8150/xiaomi/nabu \
		hexagonfs \
		novatek \
		qca \
		ath10k/WCN3990 \
		cirrus; do
		[ -e "/lib/firmware/$d" ] || continue
		install -d -m0755 "$fw/$(dirname "$d")"
		rm -rf "$fw/$d"
		cp -a "/lib/firmware/$d" "$fw/$d"
	done
	for f in qcom/a630_sqe.fw qcom/a640_gmu.bin regulatory.db regulatory.db.p7s; do
		[ -e "/lib/firmware/$f" ] || continue
		install -d -m0755 "$fw/$(dirname "$f")"
		rm -f "$fw/$f"
		cp -a "/lib/firmware/$f" "$fw/$f"
	done
	if [ -f "$NABU_ROOT/nabu-iris/firmware/venus.mbn" ]; then
		install -d -m0755 "$fw/qcom/sm8150/xiaomi/nabu"
		rm -f "$fw/qcom/sm8150/xiaomi/nabu/venus.mbn"
		cp -a "$NABU_ROOT/nabu-iris/firmware/venus.mbn" \
			"$fw/qcom/sm8150/xiaomi/nabu/venus.mbn"
	fi
}

build_firmware_deb() {
	local stage=$WORK/firmware-pkg
	local isize
	log "build firmware package $FIRMWARE_PKG $FIRMWARE_VERSION"
	stage_firmware_tree "$stage"
	isize=$(du -sk "$stage/usr" | cut -f1)
	mkdir -p "$stage/DEBIAN"
	cat >"$stage/DEBIAN/control" <<EOF
Package: $FIRMWARE_PKG
Version: $FIRMWARE_VERSION
Architecture: arm64
Maintainer: nabu-debian <nabu@localhost>
Section: non-free-firmware/kernel
Priority: optional
Installed-Size: $isize
Replaces: firmware-atheros, firmware-qcom-soc, wireless-regdb
Description: Proprietary firmware for the Xiaomi Pad 5 (nabu)
 Adreno 640 GPU, Venus VPU, SLPI/ADSP/CDSP/modem, WLAN/BT, Novatek touch
 controller and Cirrus speaker amplifier firmware for the nabu Linux port.
EOF
	dpkg_build "$stage" "$FIRMWARE_DEB"
}

stage_userspace_tree() {
	local stage=$1
	rm -rf "$stage"
	install -d -m0755 "$stage/usr/local/bin" "$stage/usr/local/lib" \
		"$stage/usr/local/libexec" "$stage/usr/share/dbus-1/system.d" \
		"$stage/usr/local/share/doc/nabu-accelerometer"

	if [ -f "$ART/ssccli" ] && [ -f "$ART/iio-sensor-proxy-ssc" ]; then
		# From the current nabu-main build (collected artifacts).
		install -m0755 "$ART/ssccli" "$stage/usr/local/bin/ssccli"
		install -m0644 "$ART/libssc.so.2" "$stage/usr/local/lib/libssc.so.2"
		install -m0755 "$ART/iio-sensor-proxy-ssc" \
			"$stage/usr/local/libexec/iio-sensor-proxy-ssc"
		install -m0755 "$ART/nabu-tablet-mode" \
			"$stage/usr/local/libexec/nabu-tablet-mode"
		[ -f "$ART/net.hadess.SensorProxy.conf" ] &&
			install -m0644 "$ART/net.hadess.SensorProxy.conf" \
				"$stage/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf"
	else
		# Fall back to the host's installed /usr/local userspace.
		install -d -m0755 "$stage/usr/local/lib/aarch64-linux-gnu"
		cp -a /usr/local/libexec/iio-sensor-proxy-ssc \
			/usr/local/libexec/nabu-tablet-mode "$stage/usr/local/libexec/" 2>/dev/null || true
		cp -a /usr/local/bin/ssccli "$stage/usr/local/bin/" 2>/dev/null || true
		local src
		for src in /usr/local/lib/libssc.so* /usr/local/lib/aarch64-linux-gnu/libssc.so*; do
			[ -e "$src" ] || continue
			cp -a "$src" "$stage/usr/local/lib/"
		done
		[ -f /usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf ] &&
			cp -a /usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf \
				"$stage/usr/share/dbus-1/system.d/"
	fi

	# The suspend/resume helper and the doc come from the module repository.
	local mod=$NABU_ROOT/nabu-accelerometer
	if [ -f "$mod/libexec/nabu-sensors-sleep" ]; then
		install -m0755 "$mod/libexec/nabu-sensors-sleep" \
			"$stage/usr/local/libexec/nabu-sensors-sleep"
	fi
	if [ -f "$mod/DEVELOPMENT.md" ]; then
		install -m0644 "$mod/DEVELOPMENT.md" \
			"$stage/usr/local/share/doc/nabu-accelerometer/DEVELOPMENT.md"
	fi
}

build_userspace_deb() {
	local deb=${1:-$USERSPACE_DEB}
	local stage=$WORK/userspace-pkg
	local isize
	log "build userspace package $USERSPACE_PKG $USERSPACE_VERSION -> $deb"
	stage_userspace_tree "$stage"
	isize=$(du -sk "$stage/usr" | cut -f1)
	mkdir -p "$stage/DEBIAN"
	cat >"$stage/DEBIAN/control" <<EOF
Package: $USERSPACE_PKG
Version: $USERSPACE_VERSION
Architecture: arm64
Maintainer: nabu-debian <nabu@localhost>
Section: admin
Priority: optional
Installed-Size: $isize
Description: Nabu SLPI/SSC userspace (libssc, ssccli, sensor proxy)
 Patched iio-sensor-proxy-ssc, libssc, ssccli, the tablet-mode helper, the
 sensors-sleep helper and the SensorProxy D-Bus policy for the nabu port.
EOF
	dpkg_build "$stage" "$deb"
}

stage_modules_tree() {
	local stage=$1
	rm -rf "$stage"
	install -d -m0755 "$stage/usr/lib/modules"
	cp -a "$MODULES_SRC" "$stage/usr/lib/modules/"
}

build_modules_deb() {
	local deb=${1:-$MODULES_DEB}
	local stage=$WORK/modules-pkg
	local isize
	log "build modules package $MODULES_PKG $MODULES_VERSION -> $deb"
	stage_modules_tree "$stage"
	isize=$(du -sk "$stage/usr" | cut -f1)
	mkdir -p "$stage/DEBIAN"
	cat >"$stage/DEBIAN/control" <<EOF
Package: $MODULES_PKG
Version: $MODULES_VERSION
Architecture: arm64
Maintainer: nabu-debian <nabu@localhost>
Section: kernel
Priority: optional
Installed-Size: $isize
Description: Nabu kernel modules for $KERNEL_RELEASE
 The complete /lib/modules/$KERNEL_RELEASE tree built by nabu-main, matching
 the $KERNEL_RELEASE UKI.
EOF
	dpkg_build "$stage" "$deb"
}

# --------------------------------------------------------------------------
# rootfs
# --------------------------------------------------------------------------

build_rootfs() {
	local pkgs
	pkgs=$(grep -v '^[[:space:]]*#' "$HERE/config/packages.list" | grep -v '^[[:space:]]*$' | paste -sd, -)

	log "debootstrap $SUITE/$ARCH -> $ROOTFS"
	log "mirror: $MIRROR"
	log "installing the GNOME desktop; downloads a few GB and can take a while"
	rm -rf "$ROOTFS"
	mkdir -p "$WORK"

	local verbose=
	if [ -n "${NABU_DEBIAN_VERBOSE:-}" ]; then
		verbose=--verbose
	fi

	export NABU_HOSTNAME=$HOSTNAME NABU_USER=$USERNAME
	export NABU_PASSWORD=$PASSWORD NABU_LABEL=$LABEL

	mmdebstrap \
		$verbose \
		--arch="$ARCH" \
		--variant=important \
		--components=main,contrib,non-free,non-free-firmware \
		--keyring="$KEYRING" \
		--include="$pkgs" \
		--aptopt='APT::Install-Recommends "true";' \
		--customize-hook="$HERE/config/customize.sh \"\$1\"" \
		"$SUITE" "$ROOTFS" "$MIRROR"
}

# Install every .deb placed in $PACKAGES_DIR (the explicit inputs).
install_input_packages() {
	local names=() f
	for f in "$PACKAGES_DIR"/*.deb; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		if [ "$MODULES_FROM_BUILD" = 1 ]; then
			case $base in
			nabu-linux-modules_*.deb) continue ;;
			esac
		fi
		if [ "$USERSYS_FROM_BUILD" = 1 ]; then
			case $base in
			nabu-userspace_*.deb) continue ;;
			esac
		fi
		install -D -m0644 "$f" "$ROOTFS/tmp/nabu-pkgs/$base"
		names+=("/tmp/nabu-pkgs/$base")
	done
	if [ ${#names[@]} -eq 0 ]; then
		log "no input packages in $PACKAGES_DIR"
		return 0
	fi
	log "installing ${#names[@]} input package(s) from $PACKAGES_DIR"
	chroot "$ROOTFS" dpkg -i --force-overwrite "${names[@]}"
	rm -rf "$ROOTFS/tmp/nabu-pkgs"
}

install_one_deb() {
	local deb=$1 base
	base=$(basename "$deb")
	install -D -m0644 "$deb" "$ROOTFS/tmp/$base"
	chroot "$ROOTFS" dpkg -i --force-overwrite "/tmp/$base"
	rm -f "$ROOTFS/tmp/$base"
}

host_copy_modules() {
	log "no modules package; copying $MODULES_SRC"
	install -d -m0755 "$ROOTFS/usr/lib/modules"
	rm -rf "$ROOTFS/usr/lib/modules/$KERNEL_RELEASE"
	cp -a "$MODULES_SRC" "$ROOTFS/usr/lib/modules/"
}

# Stage /lib/modules/<release> from the current nabu-main build so the image
# ships the modules we just compiled, not a prebuilt input deb.
stage_modules_from_kernel() {
	local kernel=${NABU_KERNEL_TREE:-} rel
	if [ -z "$kernel" ]; then
		rel=$(sed -n '/^\[kernel\]/,/^\[/p' "$MAIN/repos.lock" |
			sed -n 's/^path *= *"\(.*\)"/\1/p' | head -1)
		[ -n "$rel" ] || die "cannot determine the kernel path from $MAIN/repos.lock"
		kernel=$NABU_ROOT/$rel
	fi
	[ -f "$kernel/Makefile" ] || die "kernel tree not found: $kernel (set NABU_KERNEL_TREE)"
	[ -d "$MAIN/out" ] || die "missing $MAIN/out; run 'make' in nabu-main first"
	log "staging /lib/modules/$KERNEL_RELEASE from the current nabu-main build"
	rm -rf "$WORK/modules-root"
	install -d -m0755 "$WORK/modules-root"
	make -C "$kernel" O="$MAIN/out" ARCH="$ARCH" \
		CROSS_COMPILE="${NABU_CROSS_COMPILE:-aarch64-linux-gnu-}" LOCALVERSION= \
		-j"${NABU_JOBS:-$(nproc)}" \
		INSTALL_MOD_PATH="$WORK/modules-root" modules_install
	MODULES_SRC=$WORK/modules-root/lib/modules/$KERNEL_RELEASE
	[ -d "$MODULES_SRC" ] || die "modules_install produced no $MODULES_SRC"
	# drop the build/source links the kernel points back at the build host
	rm -f "$MODULES_SRC/build" "$MODULES_SRC/source"
}

host_copy_userspace() {
	log "no userspace package; copying the current userspace into the image"
	local stage=$WORK/userspace-copy
	stage_userspace_tree "$stage"
	install -d -m0755 "$ROOTFS/usr/local" "$ROOTFS/usr/share"
	cp -a "$stage/usr/." "$ROOTFS/usr/"
}

# Fill in any input that was not supplied as a .deb from the local host.
install_missing_inputs() {
	if ! pkg_input_present "xiaomi-nabu-firmware_*.deb"; then
		[ -d /lib/firmware/qcom/sm8150/xiaomi/nabu ] ||
			die "no firmware input and no local firmware to build one from"
		build_firmware_deb
		install_one_deb "$FIRMWARE_DEB"
	fi
	if [ "$MODULES_FROM_BUILD" = 1 ]; then
		stage_modules_from_kernel
		build_modules_deb "$WORK/nabu-linux-modules_${MODULES_VERSION}_arm64.deb"
		install_one_deb "$WORK/nabu-linux-modules_${MODULES_VERSION}_arm64.deb"
	elif ! pkg_input_present "nabu-linux-modules_*.deb"; then
		host_copy_modules
	fi
	if [ "$USERSYS_FROM_BUILD" = 1 ]; then
		build_userspace_deb "$WORK/nabu-userspace_${USERSPACE_VERSION}_arm64.deb"
		install_one_deb "$WORK/nabu-userspace_${USERSPACE_VERSION}_arm64.deb"
	elif ! pkg_input_present "nabu-userspace_*.deb"; then
		host_copy_userspace
	fi
}

overlay_nabu_userspace() {
	local m=$NABU_ROOT
	local etc=$ROOTFS/etc
	log "overlay nabu systemd/udev/alsa config"

	install -d -m0755 "$etc/systemd/system" "$etc/modprobe.d" \
		"$etc/modules-load.d" "$etc/udev/rules.d" "$etc/alsa/conf.d" \
		"$ROOTFS/usr/share/libcamera/ipa/simple"

	install -m0644 "$m/nabu-iris/system/qcom-iris-autoload.service" "$etc/systemd/system/"
	install -m0644 "$m/nabu-power/system/ln8000-autoload.service" "$etc/systemd/system/"
	install -m0644 "$m/nabu-accelerometer/config/nabu-tablet-mode.service" "$etc/systemd/system/"
	install -m0644 "$m/nabu-accelerometer/config/nabu-sensors-suspend.service" "$etc/systemd/system/"
	install -m0644 "$m/nabu-accelerometer/config/nabu-sensors-resume.service" "$etc/systemd/system/"

	install -d -m0755 "$etc/systemd/system/hexagonrpcd.service.d"
	install -m0644 "$m/nabu-accelerometer/config/nabu-slpi-hexagonrpcd.conf" \
		"$etc/systemd/system/hexagonrpcd.service.d/nabu-slpi.conf"
	install -d -m0755 "$etc/systemd/system/iio-sensor-proxy.service.d"
	install -m0644 "$m/nabu-accelerometer/config/nabu-ssc-iio-sensor-proxy.conf" \
		"$etc/systemd/system/iio-sensor-proxy.service.d/nabu-ssc.conf"

	local w
	for w in multi-user.target graphical.target suspend.target; do
		install -d -m0755 "$etc/systemd/system/$w.wants"
	done
	ln -sf ../qcom-iris-autoload.service "$etc/systemd/system/multi-user.target.wants/"
	ln -sf ../ln8000-autoload.service "$etc/systemd/system/multi-user.target.wants/"
	ln -sf ../nabu-tablet-mode.service "$etc/systemd/system/graphical.target.wants/"
	ln -sf ../nabu-sensors-suspend.service "$etc/systemd/system/suspend.target.wants/"
	ln -sf ../nabu-sensors-resume.service "$etc/systemd/system/suspend.target.wants/"

	install -m0644 "$m/nabu-iris/system/qcom-iris.conf" "$etc/modprobe.d/qcom-iris.conf"
	install -m0644 "$m/nabu-audio/config/nabu-audio.conf" "$etc/modules-load.d/nabu-audio.conf"

	install -m0644 "$m/nabu-accelerometer/config/90-nabu-ssc-accelerometer.rules" "$etc/udev/rules.d/"
	install -m0644 "$m/nabu-platform/config/99-nabu-serial-wakeup.rules" "$etc/udev/rules.d/"

	# --- USB serial debug console (kernel built-in gadget) ----------------
	# ttyGS0 is created by the kernel itself (CONFIG_USB_G_SERIAL=y in the
	# 7.2 production product); no userspace gadget service is needed.  Only
	# install the doc and a serial getty so the console also offers a login.
	# Drop the superseded configfs gadget helper if a reused rootfs has it.
	rm -f "$etc/systemd/system/nabu-usb-console.service" \
		"$etc/systemd/system/multi-user.target.wants/nabu-usb-console.service" \
		"$etc/udev/rules.d/99-nabu-usb-console.rules" \
		"$ROOTFS/usr/local/lib/nabu/nabu-usb-console.sh"
	rmdir "$ROOTFS/usr/local/lib/nabu" 2>/dev/null || true
	install -d -m0755 "$ROOTFS/usr/local/share/doc/nabu-debian"
	install -m0644 "$HERE/config/USB-CONSOLE.md" "$ROOTFS/usr/local/share/doc/nabu-debian/"
	install -d -m0755 "$etc/systemd/system/getty.target.wants"
	ln -sf /usr/lib/systemd/system/serial-getty@.service \
		"$etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"

	# --- modem/WPSS remoteproc: needed for the WCN3990 WiFi firmware --------
	# qcom_q6v5_pas keeps the mpss rproc auto_boot=false, so start it at boot;
	# without it the ath10k WLAN firmware is never loaded and there is no WiFi.
	install -d -m0755 "$ROOTFS/usr/local/lib/nabu"
	install -m0755 "$HERE/config/nabu-start-modem.sh" "$ROOTFS/usr/local/lib/nabu/"
	install -m0644 "$HERE/config/nabu-start-modem.service" "$etc/systemd/system/"
	ln -sf ../nabu-start-modem.service "$etc/systemd/system/multi-user.target.wants/"

	# --- sudo: the rootfs can ship an empty /etc/sudoers, which makes "sudo"
	# fail even though the first user is in the sudo group.  Restore the
	# standard Debian policy (env_reset + %sudo + includedir).
	cat >"$ROOTFS/etc/sudoers" <<'EOF'
Defaults	env_reset
Defaults	mail_badpass
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

root	ALL=(ALL:ALL) ALL
%sudo	ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d
EOF
	chmod 0440 "$ROOTFS/etc/sudoers"
	chown 0:0 "$ROOTFS/etc/sudoers"

	# --- WiFi-only: stop ModemManager poking the modem into a crash loop ----
	# nabu has no WWAN.  The modem/WPSS only loads the WCN3990 WLAN firmware,
	# and Debian's ModemManager + qcom-modem-setup keep probing it, which
	# sends it into a fatal-error crash loop before WiFi can come up.  Mask
	# them, and provide rmtfs (the modem's EFS / remote filesystem) whose
	# absence also makes the firmware crash.
	rm -f "$etc/systemd/system/ModemManager.service.wants/qcom-modem-setup.service"
	rmdir "$etc/systemd/system/ModemManager.service.wants" 2>/dev/null || true
	ln -sf /dev/null "$etc/systemd/system/ModemManager.service"
	ln -sf /dev/null "$etc/systemd/system/qcom-modem-setup.service"
	# rmtfs serves the modem's EFS/remote filesystem; tqftpserv is the QRTR
	# TFTP daemon the modem fetches wlanmdsp.mbn from (/readonly/firmware/
	# image/) so that its ELF loader can spawn the WLAN PD.  Without tqftpserv
	# that fetch fails, wlan_pd never boots, ath10k never sees the wlfw QMI
	# service (0x45) and probe blocks forever.
	need_pkgs=
	for pkg in rmtfs tqftpserv; do
		chroot "$ROOTFS" dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
			grep -q 'install ok installed' || need_pkgs=1
	done
	if [ -n "$need_pkgs" ]; then
		log "installing rmtfs/qrtr-tools/tqftpserv (modem EFS + WLAN PD)"
		if [ -e "$ROOTFS/etc/resolv.conf" ] || [ -L "$ROOTFS/etc/resolv.conf" ]; then
			mv "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.nabu-save"
		fi
		cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
		chroot "$ROOTFS" apt-get update -qq >/dev/null 2>&1 || true
		chroot "$ROOTFS" apt-get install -y --no-install-recommends \
			rmtfs qrtr-tools tqftpserv \
			>/dev/null 2>&1 ||
			log "warning: could not install rmtfs/tqftpserv (use --rebuild-rootfs)"
		rm -f "$ROOTFS/etc/resolv.conf"
		[ -e "$ROOTFS/etc/resolv.conf.nabu-save" ] &&
			mv "$ROOTFS/etc/resolv.conf.nabu-save" "$ROOTFS/etc/resolv.conf"
	fi
	chroot "$ROOTFS" systemctl enable qrtr-ns.service rmtfs.service \
		tqftpserv.service >/dev/null 2>&1 || true

	# --- WCN3990 WLAN DSP image: also expose it under the ath10k tree --------
	# The image ships qcom/sm8150/xiaomi/nabu/wlanmdsp.mbn; some WCN3990
	# firmware loaders look for it as ath10k/WCN3990/hw1.0/wlanmdsp.mbn too.
	if [ -f "$ROOTFS/lib/firmware/qcom/sm8150/xiaomi/nabu/wlanmdsp.mbn" ] &&
		[ ! -e "$ROOTFS/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn" ]; then
		install -d -m0755 "$ROOTFS/lib/firmware/ath10k/WCN3990/hw1.0"
		cp -f "$ROOTFS/lib/firmware/qcom/sm8150/xiaomi/nabu/wlanmdsp.mbn" \
			"$ROOTFS/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn"
	fi

	install -m0644 "$m/nabu-audio/config/51-nabu-mic-s16.conf" "$etc/alsa/conf.d/"

	# --- WirePlumber: keep the mic capture session alive ----------------------
	# The ADSP capture graph only works on the first RUN after boot, so let
	# PipeWire open the source once and never suspend it.  The rule lives
	# under wireplumber.conf.d (WirePlumber 0.5); /etc/alsa/conf.d is the
	# ALSA-lib directory and is not read by WirePlumber.
	install -d -m0755 "$etc/wireplumber/wireplumber.conf.d"
	install -m0644 "$HERE/config/wireplumber/51-nabu-mic-keepalive.conf" \
		"$etc/wireplumber/wireplumber.conf.d/51-nabu-mic-keepalive.conf"

	# --- hold the one working mic capture session open ------------------------
	# The ADSP capture graph only works on the first RUN after boot, so run a
	# client on the internal mic source for the whole session; PipeWire then
	# keeps that working ALSA session open for every other client.
	install -d -m0755 "$ROOTFS/etc/systemd/user"
	install -m0644 "$HERE/config/nabu-mic-keepalive.service" \
		"$ROOTFS/etc/systemd/user/nabu-mic-keepalive.service"
	local uhome=$ROOTFS/home/$USERNAME
	install -d -m0755 "$uhome/.config/systemd/user/default.target.wants"
	ln -sf /etc/systemd/user/nabu-mic-keepalive.service \
		"$uhome/.config/systemd/user/default.target.wants/nabu-mic-keepalive.service"
	# The first user is always uid/gid 1000 in the image (see customize.sh).
	chown -R 1000:1000 "$uhome/.config" 2>/dev/null || true

	# --- ALSA UCM for the sm8150 sound card -----------------------------------
	# Without a UCM, PipeWire finds no profile for card X5 and falls back to
	# "Dummy Output", so the speakers stay silent even though the codec, the
	# CS35L41 amplifiers and every DAPM route are working.
	#
	# ucm2/ucm.conf probes a hw card as
	#   ucm2/conf.d/${Driver}/${CardLongName}.conf
	#   ucm2/conf.d/${Driver}/${Driver}.conf
	# with ${Driver} taken from the card driver, i.e. "sm8150" for
	# "0 [X5]: sm8150 - Xiaomi Pad 5".  The second form is used here because
	# it does not depend on the long name.  Its File reference is resolved
	# against the ucm2 root, which is why the verb lives in
	# ucm2/Xiaomi/nabu/.
	local ucm=$ROOTFS/usr/share/alsa/ucm2
	install -d -m0755 "$ucm/conf.d/sm8150" "$ucm/Xiaomi/nabu"
	install -m0644 "$m/nabu-audio/config/ucm2/conf.d/sm8150/sm8150.conf" \
		"$ucm/conf.d/sm8150/sm8150.conf"
	install -m0644 "$m/nabu-audio/config/ucm2/Xiaomi/nabu/HiFi.conf" \
		"$ucm/Xiaomi/nabu/HiFi.conf"

	install -m0644 "$m/nabu-camera/camera-tuning/ov13b10.yaml" \
		"$ROOTFS/usr/share/libcamera/ipa/simple/"
	install -m0644 "$m/nabu-camera/camera-tuning/ov8856.yaml" \
		"$ROOTFS/usr/share/libcamera/ipa/simple/"

	install -d -m0700 "$ROOTFS/var/lib/tqftpserv/sensors/registry"
}

finalize_rootfs() {
	log "finalize rootfs"
	# A reused work/rootfs may carry state from an earlier/different base:
	#  * /etc/fstab can name the wrong root partition label (e.g. userdata while
	#    the UKI cmdline says root=PARTLABEL=linux), which makes
	#    systemd-remount-fs fail;
	#  * Droidian/Mobian leftovers such as droid-juicer.service run before
	#    display-manager, hang, and then reboot the device.
	# Re-assert the fstab and drop them so a reused rootfs boots cleanly.
	cat >"$ROOTFS/etc/fstab" <<EOF
# <file system>	<mount point>	<type>	<options>	<dump>	<pass>
PARTLABEL=$LABEL	/	ext4	errors=remount-ro,x-systemd.growfs	0	1
EOF
	if chroot "$ROOTFS" dpkg-query -W -f='${Status}' droid-juicer 2>/dev/null |
		grep -q 'install ok installed'; then
		log "purging stale droid-juicer"
		chroot "$ROOTFS" dpkg --purge --force-all droid-juicer >/dev/null 2>&1 || true
	fi
	rm -f "$ROOTFS/usr/bin/droid-juicer" \
		"$ROOTFS/usr/lib/systemd/system/droid-juicer.service" \
		"$ROOTFS/lib/systemd/system/droid-juicer.service" \
		"$ROOTFS/etc/systemd/system/basic.target.wants/droid-juicer.service" \
		"$ROOTFS/etc/systemd/system/sysinit.target.wants/droid-juicer.service"
	rm -rf "$ROOTFS/etc/droid-juicer" "$ROOTFS/usr/share/droid-juicer" \
		"$ROOTFS/var/lib/droid-juicer"
	install -d -m0755 "$ROOTFS/var/lib" "$ROOTFS/var/cache/apt/archives/partial" \
		"$ROOTFS/var/lib/apt/lists/partial" "$ROOTFS/tmp"
	chmod 1777 "$ROOTFS/tmp"
	chroot "$ROOTFS" apt-get -y purge 'linux-image-*' 'linux-headers-*' \
		>/dev/null 2>&1 || true
	chroot "$ROOTFS" ldconfig
	chroot "$ROOTFS" apt-get clean
	rm -f "$ROOTFS/var/cache/apt/archives/"*.deb 2>/dev/null || true
	rm -rf "$ROOTFS/var/lib/apt/lists/"* 2>/dev/null || true
	mkdir -p "$ROOTFS/var/lib/apt/lists/partial"
}

package_rootfs() {
	local name=nabu-debian-rootfs.tar
	log "packing rootfs"
	rm -f "$OUT/nabu-debian-rootfs.tar" "$OUT/nabu-debian-rootfs.tar.gz" \
		"$OUT/nabu-debian-rootfs.tar.zst"
	mkdir -p "$OUT"
	tar -C "$ROOTFS" \
		--numeric-owner --xattrs --acls \
		--exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
		--exclude='./run/*' --exclude='./tmp/*' --exclude='./mnt/*' \
		-cf "$OUT/$name" .
	if command -v zstd >/dev/null 2>&1; then
		zstd -T0 -6 -f "$OUT/$name" -o "$OUT/$name.zst"
		rm -f "$OUT/$name"
		log "wrote $OUT/$name.zst"
	elif command -v pigz >/dev/null 2>&1; then
		pigz -f "$OUT/$name"
		log "wrote $OUT/$name.gz"
	else
		gzip -f "$OUT/$name"
		log "wrote $OUT/$name.gz"
	fi
}

# ukify imports pefile; a conda/venv "python3" that shadows the distro one may
# lack it, so pick the first interpreter that can import pefile.
find_ukify_python() {
	local py
	for py in "$(command -v python3 2>/dev/null)" /usr/bin/python3; do
		[ -n "$py" ] && [ -x "$py" ] || continue
		if "$py" -c 'import pefile' >/dev/null 2>&1; then
			printf '%s\n' "$py"
			return 0
		fi
	done
	printf 'python3\n'
}

build_uki() {
	local os_release=$HERE/config/debian-os-release
	[ -f "$ROOTFS/usr/lib/os-release" ] && os_release=$ROOTFS/usr/lib/os-release
	local ukify_bin ukify_py
	ukify_bin=$(command -v ukify) || die "ukify not found (install systemd-ukify)"
	ukify_py=$(find_ukify_python)
	# The template hardcodes root=PARTLABEL=linux; rewrite it so the UKI and
	# /etc/fstab (NABU_LABEL) always agree on the root partition.
	local cmdline=$HERE/work/ukify.cmdline
	mkdir -p "$HERE/work"
	sed "s|root=PARTLABEL=[^ 	]*|root=PARTLABEL=$LABEL|" \
		"$HERE/config/debian.cmdline" >"$cmdline"
	log "package UKI -> $OUT/nabu-debian.efi (root=PARTLABEL=$LABEL)"
	mkdir -p "$OUT"
	"$ukify_py" "$ukify_bin" build \
		--linux "$ART/Image" \
		--devicetree "$ART/$DTB_NAME" \
		--cmdline "@$cmdline" \
		--os-release "@$os_release" \
		--uname "$KERNEL_RELEASE" \
		--sbat "@$MAIN/config/uki.sbat" \
		--efi-arch aa64 \
		--output "$OUT/nabu-debian.efi"
}

write_checksums() {
	(
		cd "$OUT" || exit 0
		for f in nabu-debian.efi nabu-debian-rootfs.tar.zst \
			nabu-debian-rootfs.tar.gz nabu-debian-rootfs.tar; do
			[ -f "$f" ] && sha256sum "$f"
		done >SHA256SUMS
	) || true
}

write_pkg_checksums() {
	(
		cd "$PACKAGES_DIR" || exit 0
		for f in *.deb; do
			[ -f "$f" ] && sha256sum "$f"
		done >SHA256SUMS
	) || true
}

main() {
	if [ "$CLEAN" -eq 1 ]; then
		rm -rf "$WORK" "$OUT"
	fi

	if [ "$PKG_ONLY" -eq 1 ]; then
		preflight
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$FIRMWARE_DEB_ONLY" -eq 1 ]; then
			build_firmware_deb
		fi
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$USERSPACE_DEB_ONLY" -eq 1 ]; then
			build_userspace_deb
		fi
		if [ "$MAKE_PACKAGES" -eq 1 ] || [ "$MODULES_DEB_ONLY" -eq 1 ]; then
			build_modules_deb
		fi
		write_pkg_checksums
		exit 0
	fi

	if [ "$UKI_ONLY" -eq 1 ]; then
		preflight
		build_uki
		write_checksums
		exit 0
	fi

	preflight
	if [ "$REBUILD_ROOTFS" -eq 0 ] && [ -x "$ROOTFS/usr/bin/dpkg" ]; then
		log "reusing existing rootfs at $ROOTFS (--rebuild-rootfs or --clean to rebuild)"
	else
		build_rootfs
	fi
	install_input_packages
	install_missing_inputs
	overlay_nabu_userspace
	finalize_rootfs
	package_rootfs

	if [ "$ROOTFS_ONLY" -eq 0 ]; then
		build_uki
	fi
	write_checksums
	log "done. Inputs: $PACKAGES_DIR  Outputs: $OUT"
}

main "$@"