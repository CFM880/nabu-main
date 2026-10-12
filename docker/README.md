# nabu-main build image

English | [中文](README.zh.md)

A reproducible container that runs the whole [nabu-main](../README.md) pipeline
(apply → compose → config → build → collect → package → verify) and also carries
the tools needed by `make install` / `make rollback` (`ukify`, `efibootmgr`,
`kmod`, `systemd`, `util-linux`).

It is **multi-arch** and always produces **aarch64** kernel artifacts, natively
(no qemu emulation):

| Host | How it builds | Speed |
|---|---|---|
| `amd64` | native `x86_64` host tools + `aarch64-linux-gnu` cross toolchain | native |
| `arm64` | everything native | native |

The image ships no sources: the workspace (this `nabu-main` tree plus its
`linux-6.14` and `nabu-*` siblings) is bind-mounted at its original host path at
run time — the exact layout `scripts/nabu` expects (it derives `ROOT` from the
`nabu-main` location). Keeping the original path also matters because
`linux-6.14` is a git worktree whose `.git` file stores an absolute `gitdir`.
The image is based on Debian 13 (trixie), which provides a meson new enough for
the userspace stack and a unified amd64+arm64 archive, and uses the
`aarch64-linux-gnu-` toolchain
that `nabu-main` expects by default.

## Build the image

```sh
docker/build-image.sh
```

This builds for the host's own architecture, so kernel builds then run natively.
To build the arm64 image on an `x86_64` host instead (e.g. to copy onto the
tablet), use `NABU_PLATFORM`:

```sh
NABU_PLATFORM=linux/arm64 NABU_IMAGE=nabu-main-builder:arm64 docker/build-image.sh
```

That image's `RUN` steps (and any build you run in it on x86_64) go through
binfmt/qemu, so only use it on a real arm64 machine.

## Run the pipeline

```sh
docker/run.sh                       # make (full pipeline)
docker/run.sh build                 # a single stage: make build
docker/run.sh PRODUCT=audio-only build
docker/run.sh -j4 build             # extra make flags are forwarded
docker/run.sh clean
```

The workspace root is mounted read-write at its original host path (the `apply`
stage does `git reset --hard` in the kernel tree; the kernel worktree records an
absolute `gitdir`, so the path must match). Builds run as your host uid:gid so
that `out/` and `artifacts/` do not become root-owned.

Artifacts land in `nabu-main/artifacts/<product>/`, the UKI included.

Stages are independent: `build` uses whatever `out/` the last `config` produced,
so run `config` first (or the full pipeline, i.e. `run.sh` with no target) and
re-run it whenever you switch product. Concurrent runs are serialised with a
lock so two builds cannot corrupt the shared `out/`.

### Switching between host and container builds

`out/` is shared with host builds, but its **host** tools
(`out/scripts/kconfig/conf`, `out/tools/objtool`, `out/usr/gen_init_cpio`,
`out/certs/extract-cert`, …) are compiled for the build host's architecture. An
`out/` whose host tools were built by a different toolchain (e.g. an arm64 image
after an x86_64 host build) cannot run in the image (`cannot execute`, exit 127).
`run.sh` detects the mismatch against the image's architecture and removes
`out/{scripts,tools,usr,certs}` so `make` rebuilds them; the architecture-neutral
`.config` and the aarch64 target objects are kept, so incremental builds survive
(switching between the amd64 cross image and an arm64 native image keeps the
target objects, since both target aarch64). If in doubt, run
`docker/run.sh clean` for a full rebuild.

## Install / rollback

Install and rollback touch the host at absolute paths (`/lib/modules`,
`/etc/systemd/system`, the ESP, …), so they run privileged with the relevant
host directories bind-mounted at the same paths:

```sh
docker/run.sh install          # first build/package with docker/run.sh
docker/run.sh rollback
```

Run this **on the target device**. The module install hooks (nabu-iris,
nabu-accelerometer) talk to the running `systemd`, expect real hardware
(e.g. `/dev/fastrpc-sdsp`), and may `apt-get install` extra packages; if that is
not workable inside the container, build/package here and run
`sudo make install` directly on the host instead.

`docker/run.sh install-modules` installs modules only and leaves the ESP alone.

## Environment

| Variable | Meaning | Default |
|---|---|---|
| `NABU_IMAGE` | image tag | `nabu-main-builder:<host arch>` |
| `NABU_PLATFORM` | force a target platform (e.g. `linux/arm64` to run the arm64 image under qemu on x86_64) | host platform |
| `NABU_JOBS` | make parallelism | all CPUs |
| `INSTALL_MOD_PATH` | install root for `modules_install` | `/` |

Inside the image `NABU_CROSS_COMPILE=aarch64-linux-gnu-` is preset, matching the
`nabu-main` default.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | multi-arch Debian 13 image with the aarch64 toolchain |
| `build-image.sh` | build the image for the host architecture with `docker buildx` |
| `run.sh` | run `make` against the mounted workspace; privileged mode for install |
