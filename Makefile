# SPDX-License-Identifier: GPL-2.0-only
# nabu-main entry point.  All orchestration logic lives in scripts/nabu; this
# Makefile only forwards the product and the pipeline stage.
PRODUCT ?= production
NABU    := ./scripts/nabu

.PHONY: all discover apply compose config build collect package verify install rollback clean distclean

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

package:
	$(NABU) --product $(PRODUCT) package

verify:
	$(NABU) --product $(PRODUCT) verify

install:
	$(NABU) --product $(PRODUCT) install

rollback:
	$(NABU) --product $(PRODUCT) rollback

clean:
	rm -rf out

distclean: clean
	rm -rf artifacts
