# nabu-main/debian — Debian image build

Migrated from the standalone `nabu-debian` repository. This directory builds
the Xiaomi Pad 5 (nabu) **Debian trixie arm64 + GNOME** system: the rootfs, the
UKI and the flashable partition images.

```sh
make debian-img        # rootfs + UKI + out/esp.img + out/linux.img + out/EFI.zip
make debian-rootfs     # rootfs tarball only
make debian-uki        # rebuild out/nabu-debian.efi only (fast)
make debian-clean      # remove debian/work and debian/out
```

By default these run inside the build container (`docker/run.sh debian-*`):
privileged (mmdebstrap needs chroot/mount) and with network access. The arm64
rootfs is built on an x86_64 host through the host's qemu-binfmt (the
`arch-test` package is installed in the image; register the handler with
`docker run --privileged --rm tonistiigi/binfmt --install arm64` if missing).
Set `DEBIAN_DOCKER=0` to run the scripts directly on the host instead (needs
root):

```sh
make debian-img DEBIAN_DOCKER=0
```

When you run it from a terminal the container is given a TTY, so apt and
mmdebstrap print their progress; `NABU_DEBIAN_VERBOSE=1` adds more detail.

## Caching and interrupts

A **completed** rootfs is kept in `debian/work/rootfs` and reused on the next
run, skipping the multi-GB `mmdebstrap` download. Reuse is gated on
`/var/lib/nabu-debian/rootfs-complete`, which `config/customize.sh` writes when
`mmdebstrap` finishes — a rootfs interrupted mid-debootstrap is **not** reused
(it has `dpkg`, but no marker). `mmdebstrap` keeps no reusable package download
cache, so an interrupted debootstrap downloads again; the container image layer
and `debian/out` are reused. Force a fresh build with `make debian-clean` or
`debian/build.sh --rebuild-rootfs`.

## Layout

| Path | Purpose |
|---|---|
| `build.sh` | rootfs (mmdebstrap) + optional input debs + `out/nabu-debian.efi` |
| `make-img.sh` | `out/esp.img` / `out/linux.img` / `out/EFI.zip` + `flash*.sh` (uses fakeroot) |
| `config/` | `packages.list`, `customize.sh`, `debian.cmdline`, `refind.conf`, … |
| `boot/` | `nabu-dualboot-efi.zip` (rEFInd + Reboot2Android), `SOURCE.md` |
| `packages/` | input debs (firmware/userspace/modules); `*.deb` is git-ignored |
| `work/`, `out/` | build trees and outputs (git-ignored) |

## Inputs

The **kernel modules** always come from the current nabu-main build: in the
container `build.sh` runs `make modules_install` on `out/` and packages the
result, so the image never ships a stale prebuilt modules deb. Set
`NABU_MODULES_FROM_BUILD=0` to fall back to an input deb or `/lib/modules`
instead.

The **userspace** (`libssc`, `ssccli`, `iio-sensor-proxy-ssc`, the tablet-mode
and sensors-sleep helpers, the D-Bus policy and the doc) is likewise packaged
from the current collected artifacts (`artifacts/$PRODUCT`) plus the
`nabu-accelerometer` module, so it matches the modules built here. Set
`NABU_USERSPACE_FROM_BUILD=0` to use an input deb or the host `/usr/local`.

`build.sh` takes the device-specific pieces as input debs in `packages/`
(firmware, `/usr/local` userspace, `/lib/modules`). When `packages/` is empty it
falls back to a sibling `../nabu-debian/packages` (the original repository keeps
those in place), and finally to files already present on the host
(`/lib/firmware`, `/lib/modules`, `/usr/local`) when not running in the
container. Override the directory with `NABU_PACKAGES_DIR`.

The kernel `Image` and DTB come from `nabu-main`'s collected artifacts
(`artifacts/$PRODUCT`, default `production` = `6.14.11-nabu-full`). Run
`make package` first.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `SUITE` | `trixie` | Debian suite |
| `MIRROR` | USTC | Debian mirror |
| `PRODUCT` | `production` | nabu-main product (artifact dir + DTB) |
| `KERNEL_RELEASE` | `6.14.11-nabu-full` | module dir / UKI uname |
| `NABU_HOSTNAME` / `NABU_USER` / `NABU_PASSWORD` | `nabu-debian` / `nabu` / `nabu` | identity |
| `NABU_LABEL` | `linux` | root partition PARTLABEL |
| `NABU_WIFI_MAC` | `02:00:0c:79:07:42` | fixed WiFi MAC (the WCN3990 has none; keeps DHCP/IPs stable) |

The full device/deploy documentation (partitioning, flashing, WiFi/audio/RTC
notes, USB serial console) lives in the `nabu-debian` repository's `README.md`.
