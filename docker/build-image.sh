#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the nabu-main builder image for the host's native architecture, so the
# kernel compiles at full speed (aarch64 cross toolchain on amd64, native on
# arm64) instead of under qemu emulation.
#
#   docker/build-image.sh
#
# Environment:
#   NABU_PLATFORM  target platform (default: the host's, e.g. linux/amd64)
#   NABU_IMAGE     image tag        (default: nabu-main-builder:<host arch>)
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

host_arch=$(uname -m)
case "$host_arch" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
	echo "unsupported host architecture: $host_arch" >&2
	exit 1
	;;
esac

platform=${NABU_PLATFORM:-linux/$arch}
image=${NABU_IMAGE:-nabu-main-builder:$arch}

exec docker buildx build \
	--platform "$platform" \
	--load \
	--tag "$image" \
	--file "$script_dir/Dockerfile" \
	"$script_dir"
