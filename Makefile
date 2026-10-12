# SPDX-License-Identifier: GPL-2.0-only
# nabu-main entry point.  All orchestration logic lives in scripts/nabu; this
# Makefile only forwards the product and the pipeline stage.
PRODUCT ?= production
NABU    := ./scripts/nabu

.PHONY: all discover apply compose config build collect package verify install install-modules rollback clean distclean debian-img debian-rootfs debian-uki debian-clean

all: apply compose config build collect package verify

discover:
	$(NABU) --product $(PRODUCT) discover

apply:
	$(NABU) --product $(PRODUCT) apply

compose:
	$(NABU) --product $(PRODUCT) compose

config:
	$(NABU) --product $(PRODUCT) config

build:
	$(NABU) --product $(PRODUCT) build

collect:
	$(NABU) --product $(PRODUCT) collect

package: collect
	$(NABU) --product $(PRODUCT) package

verify:
	$(NABU) --product $(PRODUCT) verify

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
	rm -rf debian/work debian/out
