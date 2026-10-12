# syntax=docker/dockerfile:1
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main build / packaging image (multi-arch).
#
# Produces aarch64 kernel artifacts on both host architectures, at full native
# speed (no qemu emulation):
#   * amd64  -> native x86_64 host tools + aarch64-linux-gnu cross toolchain
#   * arm64  -> everything native
#
# It runs the whole nabu-main pipeline (apply -> compose -> config -> build ->
# collect -> package -> verify) and carries the tools needed by `make install` /
# `make rollback` (ukify, efibootmgr, kmod, systemd, util-linux).
#
# The image contains no sources.  At run time the workspace (this nabu-main
# tree plus its linux-6.14 and nabu-* siblings) is bind-mounted at its original
# host path, the layout scripts/nabu expects (ROOT = parent of nabu-main).
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

# Kernel toolchain + build dependencies.  On arm64, gcc-aarch64-linux-gnu is the
# native-compiler prefix nabu-main expects; on amd64 it is a cross compiler and
# the native gcc (build-essential) builds the x86_64 host tools.  The amd64
# build also needs arm64 libc/uapi headers and an arm64 libsystemd (for the
# nabu-tablet-mode helper), which come from the Ubuntu ports archive.
RUN set -eux; \
	if [ "$TARGETARCH" = "amd64" ]; then \
		sed -i 's/^Types: deb/Architectures: amd64\nTypes: deb/' \
			/etc/apt/sources.list.d/ubuntu.sources; \
		dpkg --add-architecture arm64; \
		{ \
			echo 'Types: deb'; \
			echo 'URIs: http://ports.ubuntu.com/ubuntu-ports/'; \
			echo 'Suites: noble noble-updates'; \
			echo 'Components: main universe'; \
			echo 'Architectures: arm64'; \
			echo 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'; \
		} > /etc/apt/sources.list.d/ubuntu-ports.sources; \
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
		pahole \
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
			libsystemd-dev:arm64; \
	fi; \
	rm -rf /var/lib/apt/lists/*

# ukify needs the target EFI stub linuxaa64.efi.stub (from systemd-boot-efi).
# The native package provides the host's own stub; on amd64 the aarch64 stub
# comes from systemd-boot-efi:arm64 (from the ports archive).  Kept in a
# separate layer so tuning it does not invalidate the large toolchain layer.
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends systemd-boot-efi; \
	if [ "$TARGETARCH" = "amd64" ]; then \
		apt-get install -y --no-install-recommends systemd-boot-efi:arm64; \
	fi; \
	rm -rf /var/lib/apt/lists/*

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
