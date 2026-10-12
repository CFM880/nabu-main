#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Run the nabu-main builder image against this workspace.
#
#   docker/run.sh [make args...]
#
# By default it runs the image built for the host architecture, so the kernel
# is compiled natively (cross-compiled to aarch64 on amd64) at full speed.
#
# The workspace root (the parent of this nabu-main tree) is bind-mounted at its
# original host path, so `make` sees linux-6.14 and every nabu-* module next to
# it and any absolute path recorded in the git worktrees keeps resolving.
#
# Examples:
#   docker/run.sh                          # make            (full pipeline)
#   docker/run.sh build                    # make build
#   docker/run.sh PRODUCT=audio-only build # alternate product
#   docker/run.sh -j4 build                # extra make flags
#   docker/run.sh install                  # privileged; run on the target
#   docker/run.sh rollback
#   docker/run.sh debian-img               # build the Debian image (debian/)
#   docker/run.sh debian-rootfs            # rootfs tarball only
#   docker/run.sh debian-uki               # UKI only
#
# Environment:
#   NABU_IMAGE     image tag        (default: nabu-main-builder:<host arch>)
#   NABU_PLATFORM  force a platform, e.g. linux/arm64 to run the arm64 image
#                  under qemu on an x86_64 host
#   NABU_JOBS      make parallelism (default: all CPUs of the machine running it)
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
nabu_main_dir=$(dirname -- "$script_dir")
workspace_dir=$(dirname -- "$nabu_main_dir")

# Architecture of the image we are about to run: the host's, unless a platform
# is forced.
arch=$(uname -m)
case "$arch" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
esac
if [ -n "${NABU_PLATFORM:-}" ]; then
	case "$NABU_PLATFORM" in
	*arm64* | *aarch64*) arch=arm64 ;;
	*amd64* | *x86_64* | *x86-64*) arch=amd64 ;;
	esac
fi

image=${NABU_IMAGE:-nabu-main-builder:$arch}
jobs=${NABU_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
host_uid=$(id -u)
host_gid=$(id -g)

# install/rollback need root + host filesystem access, even when preceded by
# make variables, e.g. `run.sh PRODUCT=audio-only install`.
mode=build
for arg in "$@"; do
	case "$arg" in
	install | install-modules | rollback) mode=install ;;
	esac
done

# The Debian image build (debian/build.sh + debian/make-img.sh) runs inside a
# privileged container: mmdebstrap needs chroot/mount and, for the arm64 rootfs
# on an x86_64 host, the host qemu-binfmt.
debian_action=
for arg in "$@"; do
	case "$arg" in
	debian-img | debian-rootfs | debian-uki) debian_action=$arg ;;
	esac
done

# Serialise runs: two make invocations sharing out/ corrupt it.  The lock lives
# outside the repository (keyed by the workspace path) so it never shows up in git.
lock_file=${TMPDIR:-/tmp}/nabu-main-docker-$(printf '%s' "$workspace_dir" | md5sum | cut -d' ' -f 1).lock
exec 9>"$lock_file"
if ! flock -n 9; then
	echo "[docker/run.sh] another nabu-main run is already using $lock_file; wait for it to finish" >&2
	exit 1
fi

# out/ is shared between host and container builds, but its *host* tools
# (out/scripts/kconfig/conf, out/tools/objtool, out/usr/gen_init_cpio,
# out/certs/extract-cert, ...) are compiled for the build host's architecture.
# Drop them when they do not match the image we are about to run and let make
# rebuild them; the arch-neutral .config and the aarch64 target objects stay, so
# incremental builds survive.  (Not relevant for the Debian image build.)
out_dir=$nabu_main_dir/out
probe=$out_dir/scripts/kconfig/conf
if [ -z "$debian_action" ] && [ -f "$probe" ] && command -v file >/dev/null 2>&1; then
	case "$arch" in
	amd64) keep_re='x86-64' ;;
	arm64) keep_re='aarch64|ARM' ;;
	esac
	if ! file -b "$probe" | grep -qE "$keep_re"; then
		echo "[docker/run.sh] out/ host tools do not match the $arch image" >&2
		echo "[docker/run.sh] removing out/{scripts,tools,usr,certs} so make rebuilds them" >&2
		rm -rf -- "$out_dir/scripts" "$out_dir/tools" "$out_dir/usr" "$out_dir/certs"
	fi
fi

run_platform=()
if [ -n "${NABU_PLATFORM:-}" ]; then
	run_platform=(--platform "$NABU_PLATFORM")
fi

if [ -n "$debian_action" ]; then
	# Drop the action word; anything left is forwarded to the debian scripts.
	shift
	case "$debian_action" in
	debian-img) inner='./build.sh "$@" && ./make-img.sh' ;;
	debian-rootfs) inner='./build.sh --rootfs-only "$@"' ;;
	debian-uki) inner='./build.sh --uki-only "$@"' ;;
	esac
	docker run \
		--rm \
		"${run_platform[@]}" \
		--privileged \
		--workdir "$nabu_main_dir/debian" \
		--volume "$workspace_dir":"$workspace_dir" \
		--env "SUITE=${SUITE:-}" \
		--env "MIRROR=${MIRROR:-}" \
		--env "PRODUCT=${PRODUCT:-}" \
		--env "KERNEL_RELEASE=${KERNEL_RELEASE:-}" \
		--env "DTB_NAME=${DTB_NAME:-}" \
		--env "PKG_BASE_VERSION=${PKG_BASE_VERSION:-}" \
		--env "FIRMWARE_VERSION=${FIRMWARE_VERSION:-}" \
		--env "USERSPACE_VERSION=${USERSPACE_VERSION:-}" \
		--env "MODULES_VERSION=${MODULES_VERSION:-}" \
		--env "NABU_HOSTNAME=${NABU_HOSTNAME:-}" \
		--env "NABU_USER=${NABU_USER:-}" \
		--env "NABU_PASSWORD=${NABU_PASSWORD:-}" \
		--env "NABU_LABEL=${NABU_LABEL:-}" \
		--env "NABU_PACKAGES_DIR=${NABU_PACKAGES_DIR:-}" \
		"$image" \
		bash -c "cd '$nabu_main_dir/debian' && $inner; rc=\$?; chown -R '$host_uid:$host_gid' '$nabu_main_dir/debian/work' '$nabu_main_dir/debian/out' 2>/dev/null || true; exit \$rc" debian "$@"
	exit 0
fi

common=(
	--rm
	"${run_platform[@]}"
	--workdir "$nabu_main_dir"
	--volume "$workspace_dir":"$workspace_dir"
	--env NABU_JOBS="$jobs"
	--env INSTALL_MOD_PATH="${INSTALL_MOD_PATH:-/}"
)

case "$mode" in
install)
	# Privileged install/rollback: modules, systemd units, firmware and the UKI
	# are written to the host filesystem at their absolute paths and the real
	# ESP is touched through efibootmgr.  Run this on the target device.
	docker run \
		"${common[@]}" \
		--privileged \
		--pid=host \
		--env HOME=/root \
		--volume /etc:/etc \
		--volume /lib/modules:/lib/modules \
		--volume /lib/firmware:/lib/firmware \
		--volume /usr/local:/usr/local \
		--volume /usr/share/libcamera:/usr/share/libcamera \
		--volume /boot:/boot \
		--volume /dev:/dev \
		--volume /run:/run \
		--volume /sys:/sys \
		--volume /var/lib/nabu-main:/var/lib/nabu-main \
		--volume /var/lib/tqftpserv:/var/lib/tqftpserv \
		"$image" \
		make "$@"
	;;
build)
	# Build/package as the invoking user so the generated files under out/ and
	# artifacts/ keep the host ownership instead of becoming root-owned.
	docker run \
		"${common[@]}" \
		--user "$(id -u):$(id -g)" \
		--env HOME=/tmp \
		"$image" \
		make "$@"
	;;
esac
