# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main build / packaging image (multi-arch), based on Debian 13 (trixie).
#
# Produces aarch64 kernel artifacts on both host architectures, at full native
# speed (no qemu emulation):
#   * amd64  -> native x86_64 host tools + aarch64-linux-gnu cross toolchain
#   * arm64  -> everything native
#
# Runs the whole nabu-main pipeline (apply -> compose -> config -> build ->
# collect -> package -> verify), builds the nabu-accelerometer userspace stack
# (libssc / iio-sensor-proxy) and carries the tools needed by `make install` /
# `make rollback` (ukify, efibootmgr, kmod, systemd, util-linux).
#
# Debian 13 provides meson >= 1.4 (needed by libssc 0.4.4) and a unified
# amd64+arm64 archive, so cross builds need no extra ports repository.
#
# The image contains no sources.  At run time the workspace (this nabu-main
# tree plus its linux-6.14 and nabu-* siblings) is bind-mounted at its original
# host path, the layout scripts/nabu expects (ROOT = parent of nabu-main).
FROM debian:13

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
# Debian mirror host for apt; override with
#   --build-arg DEBIAN_MIRROR_HOST=<host>
# (deb.debian.org is slow from CN, so default to USTC).
ARG DEBIAN_MIRROR_HOST=mirrors.ustc.edu.cn

# Point apt at the mirror before the first update.  Debian 13 ships the deb822
# sources in /etc/apt/sources.list.d/debian.sources; rewrite the host there
# (and in the legacy sources.list, if present) so both the host architecture
# and the arm64 architecture added below come from the same mirror.
RUN set -eux; \
	sed -i "s|deb.debian.org|$DEBIAN_MIRROR_HOST|g" \
		/etc/apt/sources.list.d/debian.sources; \
	if [ -s /etc/apt/sources.list ]; then \
		sed -i "s|deb.debian.org|$DEBIAN_MIRROR_HOST|g" /etc/apt/sources.list; \
	fi; \
	cat /etc/apt/sources.list.d/debian.sources

# Kernel toolchain + build dependencies.  On arm64, gcc-aarch64-linux-gnu is the
# native-compiler prefix nabu-main expects; on amd64 it is a cross compiler and
# the native gcc (build-essential) builds the x86_64 host tools.  The amd64
# build also needs arm64 libc/uapi headers, an arm64 libsystemd (for the
# nabu-tablet-mode helper) and the aarch64 EFI stub (for the UKI).
RUN set -eux; \
	if [ "$TARGETARCH" = "amd64" ]; then \
		dpkg --add-architecture arm64; \
	fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		bc \
		binutils-aarch64-linux-gnu \
		bison \
		build-essential \
		bzip2 \
		ca-certificates \
		cpio \
		device-tree-compiler \
		dwarves \
		efibootmgr \
		file \
		flex \
		gcc-aarch64-linux-gnu \
		git \
		kmod \
		libdw-dev \
		libelf-dev \
		libncurses-dev \
		libssl-dev \
		libsystemd-dev \
		libudev-dev \
		lz4 \
		lzop \
		make \
		openssl \
		perl \
		pkg-config \
		python3 \
		rsync \
		systemd \
		systemd-ukify \
		util-linux \
		uuid-dev \
		xz-utils \
		zlib1g-dev \
		zstd; \
	if [ "$TARGETARCH" = "amd64" ]; then \
		apt-get install -y --no-install-recommends \
			libc6-dev-arm64-cross \
			linux-libc-dev-arm64-cross \
			libsystemd-dev:arm64 \
			systemd-boot-efi:arm64; \
	fi; \
	if [ "$TARGETARCH" = "arm64" ]; then \
		apt-get install -y --no-install-recommends systemd-boot-efi; \
	fi; \
	rm -rf /var/lib/apt/lists/*

# Userspace built by the nabu-accelerometer build hook: libssc and
# iio-sensor-proxy are meson projects needing GLib/QMI/protobuf/GUdev/polkit
# development files for the target architecture, plus native build tools
# (protoc, protoc-gen-c, glib-compile-resources).
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		meson \
		ninja-build \
		pkg-config \
		protobuf-compiler \
		protobuf-c-compiler \
		libglib2.0-dev-bin; \
	if [ "$TARGETARCH" = "amd64" ]; then \
		apt-get install -y --no-install-recommends \
			libglib2.0-dev:arm64 \
			libqmi-glib-dev:arm64 \
			libprotobuf-c-dev:arm64 \
			libgudev-1.0-dev:arm64 \
			libpolkit-gobject-1-dev:arm64 \
			libva-dev:arm64 \
			libdrm-dev:arm64; \
	else \
		apt-get install -y --no-install-recommends \
			libglib2.0-dev \
			libqmi-glib-dev \
			libprotobuf-c-dev \
			libgudev-1.0-dev \
			libpolkit-gobject-1-dev \
			libva-dev \
			libdrm-dev; \
	fi; \
	rm -rf /var/lib/apt/lists/*

# Debian image build (make debian-img, see nabu-main/debian): mmdebstrap builds
# the arm64 rootfs (via the host qemu-binfmt), ukify assembles the UKI, and
# make-img.sh needs mtools/dosfstools/e2fsprogs to write the esp/linux images.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		mmdebstrap \
		arch-test \
		debian-archive-keyring \
		gnupg \
		mtools \
		dosfstools \
		e2fsprogs \
		fakeroot \
		unzip \
		pigz \
		python3-pefile \
	&& rm -rf /var/lib/apt/lists/*

# The source trees are bind-mounted from the host and are normally owned by a
# different uid than the container user, which makes git reject them as
# "dubious ownership".  Trust all repositories through a system gitconfig that
# lives outside /etc, because install mode overmounts /etc and would otherwise
# shadow it.
RUN install -d /opt/nabu \
	&& printf '[safe]\n\tdirectory = *\n' > /opt/nabu/gitconfig

ENV NABU_CROSS_COMPILE=aarch64-linux-gnu- \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    GIT_CONFIG_SYSTEM=/opt/nabu/gitconfig

# The workspace is bind-mounted at run time (see run.sh) at its original host
# path, so absolute paths recorded in the kernel git worktrees keep resolving.
WORKDIR /work

# Default command mirrors the plain `make` entry point; override with e.g.
#   docker run ... <image> make build
CMD ["make"]
