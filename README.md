# nabu-main

小米平板 5（nabu）Linux 内核的**统一构建 / 打包 / 安装**流水线。

main 自身不包含任何模块知识：它只读取各子仓根目录的 `nabu-module.toml`（契约），
据此完成叠加、配置合并、DTS 组合、编译、收集、打包 UKI、安装与回滚。
内核与所有模块都放在本目录的父目录中，通过 `repos.lock` 固定基线与 commit。

> 设计与动机见上一级的 [`nabu-main-design.md`](../nabu-main-design.md)。

## 快速开始

```sh
# 需要 arm64 交叉工具链（默认 aarch64-linux-gnu-）与 python3.11+
make                     # apply → compose → config → build → collect → package → verify
sudo make install        # 安装完整模块树 + UKI，并新建 UEFI 启动项
sudo make rollback       # 回滚到安装前状态
```

常用目标：

| 目标 | 说明 |
|---|---|
| `make apply` | 重置内核到基线并叠加各模块 overlay/patch |
| `make compose` | 由产品模块顺序生成组合 DTS，并注册到 `qcom/Makefile` |
| `make config` | 生成 `.config` 并合并内核/产品/模块配置片段 |
| `make build` | 编译 `Image`、模块、DTB，并执行模块 build hook |
| `make collect` | 按 `artifacts` 声明收集产物到 `artifacts/<product>/` |
| `make package` | 用 `ukify` 打包 UKI（Image + DTB + cmdline） |
| `make verify` | 校验各 `.ko` 的 vermagic 与 UKI 内容 |
| `make install` | 安装完整模块树、模块/用户态文件与 UKI |
| `make install-modules` | 只装模块与用户态，不动 ESP / 启动项 |
| `make rollback` | 按安装清单逆序恢复 |
| `make clean` / `distclean` | 删除 `out/` / 同时删除 `artifacts/` |

切换产品：`make PRODUCT=audio-only ...`。

## 目录结构

```
nabu-main/
├── Makefile              # 入口，逻辑全部在 scripts/nabu
├── repos.lock            # 内核路径/基线 commit + 各模块路径/commit
├── products/             # 产品定义（production.toml / audio-only.toml）
├── config/               # production.cmdline、uki.sbat
├── scripts/
│   ├── nabu              # Python 流水线（discover/apply/compose/...）
│   └── install-uki.sh    # 产品级 UKI 安装/rollback
├── out/                  # 唯一内核 O=（git 忽略）
└── artifacts/<product>/  # 收集产物 + install-manifest.tsv（git 忽略）
```

各子仓（与 `repos.lock` 同级的 `nabu-*`）根目录放一个 `nabu-module.toml`。

## 环境依赖

- `python3` ≥ 3.11（使用标准库 `tomllib`）
- arm64 交叉工具链，可用 `NABU_CROSS_COMPILE` 覆盖（默认 `aarch64-linux-gnu-`）
- 打包/安装：`ukify`（`/usr/bin/ukify`）、`efibootmgr`（缺失时自动安装）
- 可选环境变量：`NABU_JOBS`（并行度）、`NABU_UKI_STUB`（自定义 UKI stub）、
  `INSTALL_MOD_PATH`（安装根，默认 `/`）

## 模块契约：`nabu-module.toml`

每个模块通过契约回答四个问题，main 全程不出现模块名字面量。

```toml
schema = 1

[module]
name        = "nabu-iris"
description = "..."
requires    = []                       # 依赖模块，决定拓扑序

[provides]
overlay      = "kernel-overlay"        # 整体复制进内核树
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
# hook = "scripts/nabu-build.sh"        # 特殊构建（out-of-tree / 用户态）

[hooks]
# install = "scripts/nabu-install.sh"  # 复杂安装事务

[artifacts]                            # 对外名 → "out:<内核内路径>" | "module:<本仓路径>"
"qcom-iris.ko" = "out:drivers/media/platform/qcom/iris/qcom-iris.ko"

[install]                              # artifacts/模块文件 → 目标路径，@release@ 展开
"qcom-iris.ko" = "/lib/modules/@release@/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko"
```

- `requires` 保证拓扑序；同层按名字稳定排序，结果可复现。
- `artifacts` 前缀区分来源，main 无需了解模块内部布局。
- `install` 是纯路径映射；需要备份/事务时用 `[hooks].install`。
- 未声明的文件 main 不会碰。
- 支持按内核版本选择变体：`foo-6.18.patch` / `foo-6.18.dtsi` 优先，
  `foo-6.18.skip` 表示该分支跳过（逻辑已并入 overlay）。

### hook 协议

build/install hook 通过固定环境变量调用：

```
NABU_KERNEL_TREE  NABU_OUT  NABU_RELEASE  NABU_ARCH
NABU_CROSS_COMPILE  NABU_JOBS  NABU_MODULE_DIR  NABU_ARTIFACTS
```

hook 只负责产出本模块声明的产物，不得改动其它模块或全局状态。

## 产品定义：`products/*.toml`

```toml
[product]
name    = "production"
modules = ["nabu-iris", "nabu-camera", "nabu-audio", "nabu-accelerometer", "nabu-power"]
release = "6.14.11-nabu1"        # 所有模块共用，保证 vermagic 一致
image   = true
dtb     = "sm8150-xiaomi-nabu-production.dtb"
cmdline = "config/production.cmdline"
sbat    = "config/uki.sbat"
uki     = "nabu-production.efi"
# kernel_config = [...]           # 覆盖默认内核配置片段（可选）

[install]                          # 产品级 UKI 安装
esp        = "/dev/disk/by-partlabel/esp"
esp_mount  = "/boot/efi"
uki_target = "EFI/ubuntu/6.14.11-nabu1-build1.efi"
boot_label = "nabu-6.14.11-nabu1"
```

- `modules` 的顺序即组合 DTS 的 `#include` 顺序。
- `audio-only.toml` 为迭代用产品，复用同一 `out/`。

## 流水线

```text
discover  读 repos.lock → 解析各仓 nabu-module.toml
select    按 product 选取模块（顺序决定 DTS 与布局）
apply     reset 内核到基线 → 逐模块 git apply patch → 复制 overlay
compose   生成组合 DTS 并注册进 qcom/Makefile
config    defconfig + 内核片段 → 合并产品/模块 config → olddefconfig
build     编译 Image/模块/DTB，调用模块 build hook
collect   按 artifacts 收集到 artifacts/<product>/
package   ukify 打包 UKI
verify    校验 .ko vermagic 与 UKI 内容（release、cmdline）
install   安装完整模块树 + 各模块 install 映射 + UKI，写安装清单
rollback  按清单逆序恢复文件与模块树，撤销 UKI 启动项
```

## 安装与回滚

- `install` 需要 root；它会先执行 `modules_install` 安装**完整** `/lib/modules/<release>`，
  再按声明的 `install` 映射安装/覆盖，并写入 `artifacts/<product>/install-manifest.tsv`。
- 覆盖已有文件时先备份为 `*.nabu-backup`；回滚时恢复或删除。
- UKI 安装到 ESP 新文件并创建独立 UEFI 启动项，旧启动项保留作后备；
  状态记录在 `/var/lib/nabu-main/uki-state.env`。
- 建议流程：普通用户 `make`，然后 `sudo make install`。
