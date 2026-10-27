# SPDX-License-Identifier: GPL-2.0-only
# nabu-main entry point.  All orchestration logic lives in scripts/nabu; this
# Makefile only forwards the product and the pipeline stage.
PRODUCT ?= production
NABU    := ./scripts/nabu

# Same default as docker/run.sh and docker/build-image.sh.
NABU_ARCH    ?= $(shell uname -m)
NABU_IMAGE   ?= nabu-main-builder:$(if $(filter x86_64,$(NABU_ARCH)),amd64,$(if $(filter aarch64,$(NABU_ARCH)),arm64,$(NABU_ARCH)))
.DEFAULT_GOAL := all

.PHONY: all discover apply compose config build collect package verify install install-modules rollback clean distclean deb-kernel debian-img debian-rootfs debian-uki debian-clean debian-repair-ownership debian-flash-esp deploy deploy-flash

# ---------------------------------------------------------------------------
# Pipeline stages (discover -> ... -> verify) always run inside the build
# container via docker/run.sh, which carries the cross toolchain and the
# userspace build dependencies (libsystemd/libva/glib/protoc/...).  docker/run.sh
# sets NABU_IN_CONTAINER=1, and the stages then call scripts/nabu directly,
# because docker is not available inside the container.
ifeq ($(NABU_IN_CONTAINER),1)
NABU_STAGE = $(NABU) --product $(PRODUCT)
else
NABU_STAGE = ./docker/run.sh PRODUCT=$(PRODUCT)
endif

discover:
	$(NABU_STAGE) discover

apply:
	$(NABU_STAGE) apply

compose:
	$(NABU_STAGE) compose

config:
	$(NABU_STAGE) config

build:
	$(NABU_STAGE) build

collect:
	$(NABU_STAGE) collect

package: collect
	$(NABU_STAGE) package

verify:
	$(NABU_STAGE) verify

all:
	$(NABU_STAGE) all

install:
	$(NABU) --product $(PRODUCT) install

# Install modules and userspace only; leave the ESP / boot entry untouched.
install-modules:
	$(NABU) --product $(PRODUCT) install --no-uki

rollback:
	$(NABU) --product $(PRODUCT) rollback

clean:
	rm -rf out

distclean: clean
	rm -rf artifacts

# ---------------------------------------------------------------------------
# Debian image (nabu-main/debian): rootfs + UKI + esp.img/linux.img.
# By default it runs inside the build container (privileged, with network);
# see docker/README.md and debian/README.md.  Set DEBIAN_DOCKER=0 to run the
# scripts directly on the host instead.
DEBIAN_DOCKER ?= 1

debian-img:
ifeq ($(DEBIAN_DOCKER),1)
	./docker/run.sh debian-img
else
	debian/build.sh
	debian/make-img.sh
endif

debian-rootfs:
ifeq ($(DEBIAN_DOCKER),1)
	./docker/run.sh debian-rootfs
else
	debian/build.sh --rootfs-only
endif

debian-uki:
ifeq ($(DEBIAN_DOCKER),1)
	./docker/run.sh debian-uki
else
	debian/build.sh --uki-only
endif

debian-clean:
ifeq ($(DEBIAN_DOCKER),1)
	./docker/run.sh debian-clean
else
	rm -rf debian/work debian/out
endif

# One-off, no-download repair of a rootfs whose ownership was corrupted (see
# debian/repair-ownership.sh).  Rebuild afterwards with `make debian-img`.
debian-repair-ownership:
ifeq ($(DEBIAN_DOCKER),1)
	./docker/run.sh debian-repair-ownership
else
	debian/repair-ownership.sh
endif

# ---------------------------------------------------------------------------
# Deploy the built Debian image (host-side; needs adb + fastboot and the
# tablet's USB).  fastboot-boots TWRP, copies out/EFI.zip onto the ESP,
# sideloads the boot-manager patch, then fastboot-flashes out/linux.img.
# See debian/README.md; override paths via TWRP_IMG / BOOTMANAGER_ZIP etc.
DEPLOY_ARGS ?=
deploy:
	debian/deploy.sh $(DEPLOY_ARGS)

# Flash only the rootfs (when the ESP / sideload work is already done) and
# reboot — no TWRP round trip.
FB_ROOT_PART ?= linux
deploy-flash:
	fastboot flash $(FB_ROOT_PART) debian/out/linux.img
	fastboot reboot

# Rebuild out/esp.img to the tablet's esp partition size, then flash it
# (host-side; needs fastboot and the tablet's USB, tablet in fastboot mode).
debian-flash-esp:
	debian/flash-esp.sh $(ESP_ARGS)

# ---------------------------------------------------------------------------
# Kernel .debs from the tree that is currently in out/: linux-image (kernel +
# every module), linux-headers (for out-of-tree modules), -dbg and libc-dev.
#
# These are for installing modules with dpkg and for building external modules;
# the boot image stays the UKI, because deb-pkg's vmlinuz carries neither the
# composed product DTB nor our command line.
#
# Three container quirks are handled here:
#   * debhelper/libssl-dev must be in the builder image (they are);
#   * the container has no /etc/passwd entry for the build user, and mkdebian
#     calls "id -nu", so KBUILD_BUILD_USER is set explicitly;
#   * with arm64 multiarch enabled dpkg-checkbuilddeps insists on the arm64
#     libssl-dev, hence DPKG_FLAGS=-d.
# Packages land in this directory (deb-pkg writes to $(objtree)/..).
deb-kernel:
	docker run --rm --privileged --user "$$(id -u):$$(id -g)" \
		-e KBUILD_BUILD_USER=$${KBUILD_BUILD_USER:-$(shell id -un)} \
		-e KBUILD_BUILD_HOST=$${KBUILD_BUILD_HOST:-nabu} \
		-e DEBFULLNAME=$${DEBFULLNAME:-$(shell id -un)} \
		-e DEBEMAIL=$${DEBEMAIL:-$(shell id -un)@nabu} \
		-v "$$(pwd)/..":"$$(pwd)/.." -w "$$(pwd)/.." \
		$(NABU_IMAGE) \
		sh -c 'make -C linux-6.14 O=$(CURDIR)/out ARCH=arm64 \
			CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
			-j$(shell nproc) DPKG_FLAGS=-d bindeb-pkg'
	@ls -lh *.deb | tail -n 5

