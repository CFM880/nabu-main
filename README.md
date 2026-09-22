# nabu-main

**English** | [中文](README.zh.md)

The unified **build / package / install** pipeline for the Xiaomi Pad 5 (nabu) Linux kernel.

`main` itself contains no module knowledge: it only reads the `nabu-module.toml` contract in each
sub-repository's root and uses it to perform overlay application, config merging, DTS composition,
compilation, collection, UKI packaging, installation, and rollback. The kernel and all modules live
in the parent directory of this directory, and `repos.lock` pins the baseline and commits.

> See [`nabu-main-design.md`](../nabu-main-design.md) one level up for the design and rationale.

## Quick start

```sh
# Requires an arm64 cross toolchain (default aarch64-linux-gnu-) and python3.11+
make                     # apply → compose → config → build → collect → package → verify
sudo make install        # install the full module tree + UKI and create a UEFI boot entry
sudo make rollback       # roll back to the pre-install state
```

Common targets:

| Target | Description |
|---|---|
| `make apply` | Reset the kernel to the baseline and apply each module's overlay/patch |
| `make compose` | Generate the combined DTS from the product module order and register it in `qcom/Makefile` |
| `make config` | Generate `.config` and merge the kernel/product/module config fragments |
| `make build` | Build `Image`, modules, and DTB, and run module build hooks |
| `make collect` | Collect artifacts into `artifacts/<product>/` per the `artifacts` declarations |
| `make package` | Package the UKI (Image + DTB + cmdline) with `ukify` |
| `make verify` | Verify the vermagic of each `.ko` and the UKI contents |
| `make install` | Install the full module tree, module/userspace files, and the UKI |
| `make install-modules` | Install only modules and userspace, without touching the ESP / boot entries |
| `make rollback` | Restore in reverse order per the install manifest |
| `make clean` / `distclean` | Delete `out/` / also delete `artifacts/` |

Switch product: `make PRODUCT=audio-only ...`.

## Directory layout

```
nabu-main/
├── Makefile              # entry point; all logic lives in scripts/nabu
├── repos.lock            # kernel path/baseline commit + module paths/commits
├── products/             # product definitions (production.toml / audio-only.toml)
├── config/               # production.cmdline, uki.sbat
├── scripts/
│   ├── nabu              # Python pipeline (discover/apply/compose/...)
│   └── install-uki.sh    # product-level UKI install/rollback
├── out/                  # the single kernel O= (git-ignored)
└── artifacts/<product>/  # collected artifacts + install-manifest.tsv (git-ignored)
```

Each sub-repository (the `nabu-*` siblings of `repos.lock`) has a `nabu-module.toml` in its root.

## Environment requirements

- `python3` ≥ 3.11 (uses the standard library `tomllib`)
- arm64 cross toolchain, overridable with `NABU_CROSS_COMPILE` (default `aarch64-linux-gnu-`)
- Packaging/install: `ukify` (`/usr/bin/ukify`), `efibootmgr` (auto-installed when missing)
- Optional environment variables: `NABU_JOBS` (parallelism), `NABU_UKI_STUB` (custom UKI stub),
  `INSTALL_MOD_PATH` (install root, default `/`)

## Module contract: `nabu-module.toml`

Each module answers four questions through the contract; `main` never contains a module name literal.

```toml
schema = 1

[module]
name        = "nabu-iris"
description = "..."
requires    = []                       # dependency modules; determines topological order

[provides]
overlay      = "kernel-overlay"        # copied wholesale into the kernel tree
patches      = ["patches/0001-....patch"]
dtsi         = ["arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu-iris.dtsi"]
config       = ["config/nabu-iris.config"]
systemd      = ["system/qcom-iris-autoload.service"]
modules_load = ["system/qcom-iris.conf"]
firmware     = ["firmware/venus.mbn"]
userspace    = ["camera-tuning/ov13b10.yaml"]
rules        = ["config/90-nabu-ssc-accelerometer.rules"]

[build]
kernel_targets = ["drivers/media/platform/qcom/iris/qcom-iris.ko"]
# hook = "scripts/nabu-build.sh"        # special builds (out-of-tree / userspace)

[hooks]
# install = "scripts/nabu-install.sh"  # complex install transactions

[artifacts]                            # public name → "out:<path in kernel>" | "module:<path in repo>"
"qcom-iris.ko" = "out:drivers/media/platform/qcom/iris/qcom-iris.ko"

[install]                              # artifacts/module files → target paths, @release@ expanded
"qcom-iris.ko" = "/lib/modules/@release@/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko"
```

- `requires` guarantees topological order; peers at the same level are sorted stably by name, so
  results are reproducible.
- The `artifacts` prefix distinguishes the source; `main` doesn't need to know a module's internal
  layout.
- `install` is a pure path mapping; use `[hooks].install` when backup/transactions are needed.
- `main` never touches files that aren't declared.
- Kernel-version-specific variants are supported: `foo-6.18.patch` / `foo-6.18.dtsi` take
  precedence, and `foo-6.18.skip` means that branch is skipped (the logic has already been merged
  into the overlay).

### Hook protocol

Build/install hooks are invoked with fixed environment variables:

```
NABU_KERNEL_TREE  NABU_OUT  NABU_RELEASE  NABU_ARCH
NABU_CROSS_COMPILE  NABU_JOBS  NABU_MODULE_DIR  NABU_ARTIFACTS
```

A hook is only responsible for producing the artifacts declared by its own module and must not
modify other modules or global state.

## Product definition: `products/*.toml`

```toml
[product]
name    = "production"
modules = ["nabu-iris", "nabu-camera", "nabu-audio", "nabu-accelerometer", "nabu-power"]
release = "6.14.11-nabu1"        # shared by all modules to keep vermagic consistent
image   = true
dtb     = "sm8150-xiaomi-nabu-production.dtb"
cmdline = "config/production.cmdline"
sbat    = "config/uki.sbat"
uki     = "nabu-production.efi"
# kernel_config = [...]           # override the default kernel config fragments (optional)

[install]                          # product-level UKI install
esp        = "/dev/disk/by-partlabel/esp"
esp_mount  = "/boot/efi"
uki_target = "EFI/ubuntu/6.14.11-nabu1-build1.efi"
boot_label = "nabu-6.14.11-nabu1"
```

- The order of `modules` is the `#include` order of the combined DTS.
- `audio-only.toml` is a product for iteration and reuses the same `out/`.

## USB recovery console (not used)

A CDC-ACM kernel console on USB-C was prototyped but is **not part of the product**. It never
completed a real end-to-end capture here: the gadget has to claim USB-C in device mode, and this
tablet keeps the port in host mode with an attached HID, so the port never enumerated on a host.
It also risks early-boot hangs, because a cmdline `console=ttyGS0` only becomes a console once the
gadget is registered, and registering it needs an attached host.

If it is ever revisited, the requirements are: force the Type-C role so the gadget can bind, add
`console=ttyGS0` *after* `console=tty0` on the cmdline, and keep `tty0` as the console device. No
files for it remain in this repository.

## Pipeline

```text
discover  read repos.lock → parse each repo's nabu-module.toml
select    select modules by product (order determines DTS and layout)
apply     reset kernel to baseline → git apply each module's patch → copy overlay
compose   generate the combined DTS and register it in qcom/Makefile
config    defconfig + kernel fragments → merge product/module config → olddefconfig
build     build Image/modules/DTB, invoke module build hooks
collect   collect into artifacts/<product>/ per artifacts
package   package the UKI with ukify
verify    verify .ko vermagic and UKI contents (release, cmdline)
install   install the full module tree + each module's install mappings + UKI, write the install manifest
rollback  restore files and the module tree in reverse order per the manifest, remove the UKI boot entry
```

## Install and rollback

- `install` requires root; it first runs `modules_install` to install the **complete**
  `/lib/modules/<release>`, then installs/overwrites per the declared `install` mappings and writes
  `artifacts/<product>/install-manifest.tsv`.
- When overwriting existing files, they are first backed up as `*.nabu-backup`; rollback restores or
  deletes them.
- The UKI is installed to a new file on the ESP and a separate UEFI boot entry is created; the old
  boot entry is kept as a fallback. State is recorded in `/var/lib/nabu-main/uki-state.env`.
- Recommended flow: `make` as a normal user, then `sudo make install`.
