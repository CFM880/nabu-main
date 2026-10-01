# SPDX-License-Identifier: GPL-2.0-only
# nabu-main entry point.  All orchestration logic lives in scripts/nabu; this
# Makefile only forwards the product and the pipeline stage.
PRODUCT ?= production-7.2
NABU    := ./scripts/nabu
# `make` runs the stages sequentially: a parallel top-level make would launch
# the heavy kernel builds side by side and can exhaust memory.  Parallelism
# inside each stage comes from NABU_JOBS.
MAKEFLAGS += --no-print-directory
.NOTPARALLEL:

.PHONY: all bootstrap discover apply compose config build collect package verify install install-modules rollback clean distclean

all: apply compose config build collect package verify

# Fetch the kernel base and every module at the commits in repos.lock, then
# build.  Use this on a fresh clone whose sibling directories are still empty.
bootstrap:
	$(NABU) bootstrap
	$(MAKE) all

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
