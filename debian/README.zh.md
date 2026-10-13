# nabu-main/debian — Debian 镜像构建与设备记录

> 从原独立仓库 `nabu-debian` 迁移而来；下方 `nabu-debian` 字样多为主机名/镜像名
> （`nabu-debian.efi`、`nabu-debian-rootfs.tar` 等），不是仓库路径。

为小米平板 5（nabu）构建并部署一套 **Debian trixie (13) arm64 + GNOME** 系统。

默认采用与其他 nabu Linux 发行版一致的 **`esp` + `linux` 分区布局**：

- Debian 根文件系统写入 `PARTLABEL=linux` 分区（内核命令行 `root=PARTLABEL=linux`）；
- 内核沿用 nabu-main 构建的 `7.2.7-nabu-full` UKI（同一个内核、同一份 `/lib/modules`）；
- ESP（`PARTLABEL=esp`）默认做成 **Android + Linux 双引导**：rEFInd + Reboot2Android
  + `EFI/nabu/nabu-debian.efi`，可用 `make-img.sh` 生成 `fastboot flash` 镜像；
- `deploy.sh` 是“单系统”路径：格式化 `linux`、解包 rootfs、装 UKI、建独立 UEFI 启动项。

> 分区名可用 `ROOT_PART` / `ESP_PART`（设备路径）与 `FB_ROOT_PART` / `FB_ESP_PART`
> （fastboot 名）覆盖；根分区 PARTLABEL 用 `NABU_LABEL` 覆盖。

## 核心思路：把设备相关内容做成 deb 输入

镜像里所有“只有平板上才有”的东西都被打成可分发、可追踪的 **deb 输入包**，
放在 `packages/`；镜像构建本身**不依赖平板**，可以在任意 arm64 Debian/Ubuntu 机器上完成。

| 输入包 | 内容 |
|---|---|
| `xiaomi-nabu-firmware_*.deb` | 专有固件：Adreno 640、Venus VPU、SLPI/ADSP/CDSP/modem、WLAN/BT（WCN3990）、Novatek 触控、Cirrus 功放、`hexagonfs`、`venus.mbn` 等 |
| `nabu-userspace_*.deb` | `/usr/local` 下的 SLPI/SSC 用户态：`libssc`、`ssccli`、打过补丁的 `iio-sensor-proxy-ssc`、`nabu-tablet-mode`、`nabu-sensors-*`、SensorProxy D-Bus 策略 |
| `nabu-linux-modules_*.deb` | 完整的 `/lib/modules/7.2.7-nabu-full` 模块树 |

镜像构建还会用到（不是 deb）：

- `nabu-main/artifacts/production-7.2/{Image,*.dtb}`（UKI 的内核与设备树）；
- `nabu-*` 各模块仓库里的 systemd/udev/alsa/libcamera 配置。

在缺少某个输入包、但本机恰好有对应文件时，`build.sh` 会**自动现场生成该 deb 并安装**，
所以在平板上第一次构建仍然是单条命令。

## 目录

```
debian/
├── build.sh              构建输入包 / rootfs / UKI（rootfs 需要 root）
├── deploy.sh             写入 linux + 安装输入包 + 装 UKI + 建启动项（需要 root）
├── make-img.sh           生成 esp.img / linux.img + flash 脚本（无需 root）
├── capture-serial.sh     在 PC 上持续抓取 USB 串口日志（断线自动重连）
├── fetch-efi.sh          拉取/刷新双引导 EFI 负载（正常构建不需要）
├── boot/
│   ├── nabu-dualboot-efi.zip  rEFInd + Reboot2Android + 主题（已内置）
│   └── SOURCE.md              负载来源与校验和
├── config/
│   ├── debian.cmdline    Debian UKI 的内核命令行模板（root=PARTLABEL 按 NABU_LABEL 改写）
│   ├── packages.list     Debian 包清单（GNOME + nabu 运行依赖）
│   ├── customize.sh      mmdebstrap 定制钩子（主机名/用户/服务/fstab）
│   ├── USB-CONSOLE.md    USB 串口调试说明（装进镜像 /usr/local/share/doc）
│   ├── refind.conf       双引导菜单（Debian + “Reboot to Android”）
│   └── debian-os-release UKI 内置 os-release（构建 rootfs 后改用其自身版本）
├── packages/             输入包（对其它机器分发这些即可）
│   ├── xiaomi-nabu-firmware_*_arm64.deb
│   ├── nabu-userspace_*_arm64.deb
│   ├── nabu-linux-modules_*_arm64.deb
│   └── SHA256SUMS
└── out/                  产物
    ├── nabu-debian-rootfs.tar.zst/gz
    ├── nabu-debian.efi
    ├── esp.img         FAT32，含 rEFInd + Reboot2Android + Debian UKI
    ├── linux.img       ext4，紧凑 rootfs（首次启动自动扩容）
    ├── flash.sh        在平板内 dd 刷写
    ├── flash-fastboot.sh  在 PC 上用 fastboot 刷写
    └── SHA256SUMS / IMG-SHA256SUMS
```

## 前置条件

构建可以在**平板自身**上做，也可以在**独立 arm64 构建机**上做：

- 独立构建机：只需在 nabu-main 里 `make`（会重跑 `config`），产物
  `nabu-main/artifacts/production-7.2/{Image,*.dtb}` 会被 `debian/build.sh`
  直接使用；模块/固件/用户态用 `packages/*.deb` 作为输入。
  **不需要（也用不上）`make install`**——那是「构建机就是平板」时把模块写进本机
  `/lib/modules`、UKI 写进 ESP 用的。
- 在平板自身构建时，才需要先 `nabu-main$ make && sudo make install`
  （提供 `/lib/modules/7.2.7-nabu-full` 与 `artifacts/production-7.2/{Image,*.dtb}`）。
- 工具：`mmdebstrap`、`ukify`（systemd-ukify）、`zstd`/`pigz`（可选）、`efibootmgr`（部署时）、
  `mtools`/`unzip`（生成镜像时；生成双引导 ESP 用）

```sh
sudo apt-get install -y mmdebstrap systemd-ukify zstd efibootmgr debian-archive-keyring mtools unzip
```

> `build.sh` 会在缺少 Debian 归档密钥环时自动安装 `debian-archive-keyring`；
> 也可用 `NABU_KEYRING=/path/to/keyring.gpg` 指定其它密钥环。

> 注意：opencode/agent 会话带有 `NoNewPrivs`，`sudo` 在其中不可用；请在平板的普通终端里执行。

## 步骤 1：生成输入包（在平板上）

```sh
cd ~/sources/nabu-linux/nabu-main/debian
./build.sh --make-packages          # 生成 packages/ 下三个 deb（不需要 root）
# 也可单独生成：
./build.sh --firmware-deb-only
./build.sh --userspace-deb-only
./build.sh --modules-deb-only
```

之前已经生成过：`packages/xiaomi-nabu-firmware_7.2.7-1_arm64.deb`、
`packages/nabu-userspace_7.2.7-1_arm64.deb`、`packages/nabu-linux-modules_7.2.7-nabu-full_arm64.deb`。

## 步骤 2：构建镜像

可以在**平板**上做（会自动补齐缺失输入包），也可以在**任意 arm64 机器**上做
（把 `packages/*.deb` 和 `nabu-main/artifacts/production-7.2/` 一起带过去）：

```sh
sudo ./build.sh                  # 构建 rootfs（约 2-4 GB 下载）+ UKI
# 可选：
sudo ./build.sh --rootfs-only     # 只做 rootfs
sudo ./build.sh --uki-only        # 只重建 UKI（不需要 root）
sudo ./build.sh --packages-dir DIR  # 指定输入包目录（默认 ./packages）
sudo ./build.sh --rebuild-rootfs  # 强制重新 debootstrap（默认复用 work/rootfs）
sudo ./build.sh --clean           # 清空 work/ 与 out/ 后重建
```

> 若某次在 overlay 阶段失败，`work/rootfs` 已经装好，直接重跑 `sudo ./build.sh`
> 会**复用现有 rootfs**并重放 overlay，不必重新下载 GNOME；只有换 `SUITE`/`MIRROR`/
> 用户等影响 debootstrap 的参数时才需要 `--rebuild-rootfs` 或 `--clean`。

可用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SUITE` | `trixie` | Debian 版本 |
| `MIRROR` | USTC | Debian 镜像 |
| `KERNEL_RELEASE` | `7.2.7-nabu-full` | 模块目录/UKI uname |
| `NABU_PACKAGES_DIR` | `./packages` | 输入包目录 |
| `PKG_BASE_VERSION` | `7.2.7-1` | 固件/用户态包版本 |
| `FIRMWARE_VERSION` / `USERSPACE_VERSION` / `MODULES_VERSION` | 见上 | 各输入包版本 |
| `NABU_HOSTNAME` | `nabu-debian` | 主机名 |
| `NABU_USER` | `nabu` | 第一个用户（uid 1000，加入 sudo） |
| `NABU_PASSWORD` | `nabu` | 初始密码（**首次登录后请修改**） |
| `NABU_LABEL` | `linux` | 根分区 PARTLABEL |

镜像构建流程：

1. `mmdebstrap` 安装 Debian trixie（含 `task-gnome-desktop`）；
2. 用 `dpkg -i --force-overwrite` 安装 `packages/*.deb`（固件/用户态/模块，均被 dpkg 追踪）；
3. 缺失的输入包在本机有源时自动现做并安装；
4. 叠加 `nabu-*` 仓库里的 systemd 单元与 drop-in
   （`qcom-iris-autoload`、`ln8000-autoload`、`nabu-tablet-mode`、
   `nabu-sensors-suspend/resume`、`hexagonrpcd.service.d`、`iio-sensor-proxy.service.d`）、
   `modprobe.d` / `modules-load.d` / udev rules / ALSA / libcamera tuning，
   并启用 USB 串口登录 `serial-getty@ttyGS0`（串口 gadget 由内核内建，不依赖服务）；
5. 屏蔽 `pd-mapper.service`（由内核 `qcom_pd_mapper` 负责域表）；
6. 打包 rootfs，并用 `ukify` 生成 `out/nabu-debian.efi`（Image + DTB + `root=PARTLABEL=linux`）。

## 输入包说明

```sh
dpkg-deb -I packages/xiaomi-nabu-firmware_*.deb      # 控制信息
dpkg-deb -c packages/nabu-userspace_*.deb            # 内容
# 在任意 nabu Debian 上单独安装：
sudo dpkg -i packages/nabu-linux-modules_*.deb packages/xiaomi-nabu-firmware_*.deb packages/nabu-userspace_*.deb
```

- 固件包控制字段含 `Replaces: firmware-atheros, firmware-qcom-soc, wireless-regdb`，
  用 `--force-overwrite` 覆盖 Debian 固件包 / alternatives 的悬空链接。
- 用户态二进制 GLIBC 需求 ≤ 2.38，trixie 满足；若在原系统重装过传感器栈，
  重新 `--make-packages` 即可。

## 部署

```sh
sudo ./deploy.sh          # 会要求输入 yes 确认格式化 linux
sudo ./deploy.sh --yes    # 免确认
```

1. 安全检查：拒绝格式化当前根分区或已挂载分区；
2. `mkfs.ext4 -L nabu-debian` 格式化 `linux`；
3. 解包 rootfs 到该分区（`--numeric-owner` 保留权限），创建 tqftpserv 目录；
4. 在 rootfs 里安装 `packages/*.deb`（旧 tar 也能补上 dpkg 追踪，新 tar 幂等重装）；
5. 将 `out/nabu-debian.efi` 安装到 ESP 的 `EFI/nabu/nabu-debian.efi`；
6. `efibootmgr` 创建名为 `Debian (nabu)` 的启动项。

常用参数：`--no-format`（保留现有文件系统）、`--no-boot`（只写 rootfs）、
`--no-rootfs`（只装 UKI）、`--no-input-debs`（不装输入包）、`--rootfs FILE`。

## 生成可刷写镜像（esp.img / linux.img）

采用与其他 nabu Linux 发行版（TheMojoMan / rodriguezst / Fedora / postmarketOS）相同的做法：
**两个独立分区镜像**——`esp`（引导+双引导菜单）与 `linux`（rootfs）。`make-img.sh` 不需要 root：
它会自动用 `fakeroot` 重建，以保留 root 属主（否则非 root 解包会把所有文件变成当前用户，
`/usr/bin/sudo` 的 setuid 失效、`/etc/sudo.conf` 属主不对，导致用不了 sudo）；机器上没有
`fakeroot` 时改用 `sudo ./make-img.sh`。

```sh
./make-img.sh                    # 生成 out/linux.img、out/esp.img、两个 flash 脚本
./make-img.sh --esp-only
./make-img.sh --linux-only
./make-img.sh --no-dualboot      # ESP 只放 Debian UKI（不做 Android 双引导）
ESP_SIZE=1073741824 ./make-img.sh --esp-only   # 覆盖 esp 镜像大小（字节）
```

- `out/esp.img`：FAT32、卷标 `ESPNABU`（若能看到平板 `esp` 分区则用其实际大小，
  否则沿用上一次 `out/esp.img` 的大小）。**默认做成双引导**，内容与其他 nabu 发行版一致：
  - `EFI/BOOT/bootaa64.efi`：rEFInd（菜单由 `config/refind.conf` 定义）；
  - `EFI/BOOT/drivers_aa64/`、`icons/`、`themes/`、`vars/`；
  - `EFI/Android/Reboot2Android.efi`：菜单里的 “Reboot to Android”；
  - `EFI/nabu/nabu-debian.efi`：Debian UKI。

  这些 EFI 负载已内置在 `boot/nabu-dualboot-efi.zip`（来源与校验和见 `boot/SOURCE.md`），
  构建时**不需要联网**；要升级负载可运行 `./fetch-efi.sh`。
- `out/linux.img`：ext4、卷标 `linux`，**紧凑镜像**（只含实际数据，约 6 GiB），
  用 `mkfs.ext4 -d` 直接填充（e2fsprogs ≥ 1.47），无需 root/挂载。
  **不是**整个分区大小；写入分区后由 fstab 里的 `x-systemd.growfs` 在首次启动时自动扩容，
  `flash.sh` 也会先做一次 `resize2fs`。
- `out/flash-fastboot.sh`：在 **PC** 上运行，`fastboot flash esp/linux` + 重启，
  与参考发行版的安装方式一致。
- `out/flash.sh`：在**平板内**运行，dd 两个镜像、扩容、并建立 UEFI 启动项。

### 用 fastboot 刷写（PC，推荐）

```sh
# 平板进入 fastboot（关机后按住音量减 + 插 USB）
fastboot devices
./out/flash-fastboot.sh
# 等价的单条命令：
#   fastboot flash esp   out/esp.img
#   fastboot flash linux out/linux.img
fastboot reboot
```

> 分区名可用 `FB_ESP_PART` / `FB_ROOT_PART` 覆盖；两者默认都跟随构建时的 `NABU_LABEL`
> （未设置时为 `linux`），这样 `root=PARTLABEL=$NABU_LABEL`（cmdline/fstab）与
> `fastboot flash` 的目标始终是同一个分区，不会写错。**本机当前按 `NABU_LABEL=debian`
> 构建**，所以默认刷的就是 `debian` 分区，Ubuntu 的 `linux` 分区永远不会被碰到。

### 在平板内 dd 刷写

```sh
sudo out/flash.sh
```

或手动：

```sh
sudo dd if=out/linux.img of=/dev/disk/by-partlabel/linux bs=4M status=progress conv=fsync
sudo e2fsck -fy /dev/disk/by-partlabel/linux && sudo resize2fs /dev/disk/by-partlabel/linux
sudo dd if=out/esp.img   of=/dev/disk/by-partlabel/esp  bs=4M status=progress conv=fsync
```

> **启动机制 / Android 双引导**：`esp.img` 内的 rEFInd 是 ESP 的默认引导器
> （`\EFI\BOOT\BOOTAA64.EFI`）。要让固件开机进入 rEFInd（从而在 Debian 与 Android 间选择），
> 需先用 TWRP/Magisk 刷一次 rodriguezst 的引导补丁
> （`installer_bootmanager_NOSB.zip`，即 TheMojoMan / Fedora 教程里的 DualBootKernelPatcher）：
> 冷启动进入 UEFI→rEFInd；选 “Reboot to Android” 时 `Reboot2Android.efi` 写入标记并热重启回到
> Android 内核。`linux.img` 只含根分区内容，不含引导链（`xbl/abl`）；**不要整盘 dd**，
> 否则会破坏设备的 Android 引导链。刷写 `esp.img` 会替换 ESP 上原有的 rEFInd/引导文件，请先备份。

## 本机实际分区布局（从 linux 切出的 debian 分区）

设备 GPT：`sda` 474.5 GiB，**逻辑扇区 4096**，64 条表项，**表头在 LBA 1**（LBA 0 全零、
没有保护式 MBR），主表在 LBA 2–3，备份表在盘尾。

| # | 分区 | 大小 | 内容 |
|---|------|------|------|
| 31 | `esp` | 333.9 MiB | FAT32 + rEFInd（`\EFI\BOOT\bootaa64.efi`） |
| 32 | `linux` | 329.15 GiB | 原 Ubuntu，`EFI/ubuntu/6.14.11.efi`，`root=PARTLABEL=linux` |
| 34 | `debian` | **100 GiB** | 我们的系统，`root=PARTLABEL=debian` |
| 33 | `userdata` | 34.9 GiB | Android 用户数据（**未动**） |

`debian` = 26,214,400 × 4096 = 正好 100 GiB，从 `linux` 尾部切出（`linux` 原 429.15 GiB）。

### 为什么要离线缩容再切分

Ubuntu 的 ext4 **原先铺满整个 429 GiB 分区**（112,500,000 个 4096 块 = 分区大小）。
直接从尾部切 100 GiB 会让「文件系统 > 分区」，Ubuntu 挂载时读越界组的位图直接 `-EIO`。
所以顺序必须是**先缩 fs，再缩分区**，且必须在 Ubuntu 未挂载时做：

```sh
fastboot boot ~/Downloads/nabu-ubuntu/V4-MODDED-TWRP-LINUX.img   # 只从内存启动，不写盘
adb shell umount /linux                                          # TWRP 默认会把它挂上，先卸掉
# 1) 缩文件系统（337024M 需为 128 MiB 组边界整数倍，且 < 新分区 337053 MiB）
#    resize2fs /dev/block/sda32 337024M      # → 86,278,144 块
# 2) 改分区表（4096 扇区单位）
sgdisk --delete=32 \
       --new=32:2739747:89025346   --typecode=32:8300 --change-name=32:linux \
       --new=34:89025347:115239746 --typecode=34:8300 --change-name=34:debian \
       /dev/block/sda
# 3) 把 linux 的分区 GUID 改回原值（Ubuntu 虽用 PARTLABEL，但保持 GUID 不变更稳妥）
sgdisk --partition-guid=32:27ac3b42-cbef-41a4-b7f8-c9b570c79241 /dev/block/sda
```

> ⚠️ **TWRP 自带的 e2fsprogs 1.45.4 用不了**：Ubuntu 的文件系统开了
> `metadata_csum_seed`，老 e2fsck 报 `unsupported feature(s): FEATURE_C12` 直接退出。
> 解决办法是从 Alpine 取 aarch64 的 e2fsprogs 1.47.4
> （`e2fsprogs`、`e2fsprogs-libs`、`e2fsprogs-extra`、`musl`、`libblkid`、`libuuid`、
> `libcom_err`、`libeconf`），解包后 `adb push` 进 TWRP，用 musl loader 显式调用：
>
> ```sh
> /tmp/e2/lib/ld-musl-aarch64.so.1 --library-path /tmp/e2/lib:/tmp/e2/usr/lib \
>     /tmp/e2/sbin/e2fsck -f -y /dev/block/sda32
> /tmp/e2/lib/ld-musl-aarch64.so.1 --library-path /tmp/e2/lib:/tmp/e2/usr/lib \
>     /tmp/e2/usr/sbin/resize2fs /dev/block/sda32 337024M
> ```
>
> 注意 `adb push <dir> <已存在的目录>` 会多套一层目录，且不保留可执行位（记得 `chmod 755`）。

改表前后都留了原始 GPT（`dd` 拉头尾各 64/8 扇区 + `sgdisk --backup`），
存放在 `work/gptdump/`；改完必须校验**主表与备份表逐条一致**、`linux` 的 GUID 未变。

### ESP 侧新增引导（只增文件，不改配置）

```
/esp/EFI/debian/nabu-debian.efi   # 我们的 UKI（与 out/ 的 md5 一致）
/esp/EFI/BOOT/refind.conf         # 原样未动（3233 B，md5 e95934e05b4ae2d8cf6dd1c08355ba71）
/esp/EFI/ubuntu/6.14.11.efi       # Ubuntu 的 UKI，原样未动
/esp/EFI/android/…                # 原样未动
```

**不手写 `menuentry`**：原版 `refind.conf` 本来就是「零 menuentry、全靠自动扫描」
（只有 `timeout 5` 和 `hideui`，没有一条 `menuentry`），所以只要把 UKI 放进
`\EFI\debian\`，rEFInd 就自己扫出条目；`themes/refind-theme-regular/theme.conf` 的
`icons_dir` 指向 `…/icons/256-96/`，里面就有 `os_debian.png`，图标由它自己挑。
ESP 上因此**只多一个文件夹和一个文件**，`timeout` / `default_selection` 保持原值。

> 2026-10-08 曾在 `refind.conf` 末尾追加过手写 `menuentry`（带 `icon` 行 + 一条
> `dont_scan_files`），现象是**条目在、图标空白**，已回退成原版改用自动扫描。
> 回退前后的文件都留了：`work/refind.conf.on-device`（我们改的 3998 B）、
> `work/refind.conf.orig`（原版 3233 B，与设备 md5 一致）。
>
> **已实测（2026-10-08 重启验证）**：去掉手写 `menuentry` 后，自动扫描出的 Debian
> 条目**图标正常**（主题 `os_debian.png`）。所以空白图标的根因就是手写条目的
> `icon` 相对路径没被 rEFInd 解析 —— 以后别再手写 menuentry，放文件即可。

更新用 `deploy-uki-twrp.sh`（主机侧、走 adb，带 md5 双向校验）：

```sh
fastboot boot ~/Downloads/nabu-ubuntu/V4-MODDED-TWRP-LINUX.img   # RAM 启动，不写盘
./deploy-uki-twrp.sh              # 加 --no-reboot 可先核对再重启
```

它做的事：确认 ESP 挂在 `/esp`（TWRP 会自动挂）→ 备份当前 `refind.conf` → 推
`out/nabu-debian.efi` 到 `\EFI\debian\` → 把 `refind.conf` 覆盖回 `work/refind.conf.orig`
→ 双文件 md5 校验 → 删掉我们留的 `refind.conf.bak` → `sync` / `umount` / `reboot`。

> ⚠️ 千万不要 `fastboot flash esp out/esp.img`：`make-img.sh` 的 `esp.img` 是**从零重建**
> 的，会抹掉 ESP 上 Ubuntu 自己的引导文件。
>
> 系统已经起来时也可以只换 UKI（ESP 在 Debian 里**挂不上**：分区逻辑扇区 4096 vs
> FAT 512，就是 `boot.mount` 那个错），用镜像自带的 `mtools` 写裸分区：
>
> ```sh
> scp out/nabu-debian.efi nabu@<ip>:/tmp/
> ssh nabu@<ip> 'sudo mcopy -o -i /dev/sda31 /tmp/nabu-debian.efi ::/EFI/debian/nabu-debian.efi && sync'
> # 回读校验（应当与 out/nabu-debian.efi 一致）：
> ssh nabu@<ip> 'rm -f /tmp/verify.efi && sudo mcopy -i /dev/sda31 ::/EFI/debian/nabu-debian.efi /tmp/verify.efi && md5sum /tmp/verify.efi'
> ```

### 每次迭代只刷 debian

```sh
./out/flash-fastboot.sh          # FB_ROOT_PART 已默认 debian
# 等价： fastboot flash debian out/linux.img   （6.6 GB 紧凑镜像，约 100 s）
```

Ubuntu 的 `linux` 分区和 ESP 引导链全程不动；回退只需在 rEFInd 里选 Ubuntu 条目。

## 启动 Debian / 切回 Android

- 开机进入 rEFInd 菜单，用音量键选择、电源键确认：`Debian GNU/Linux (nabu)` 或 `Reboot to Android`；
- rEFInd 默认 5 秒后启动第一项（Debian），可在 `config/refind.conf` 调整 `timeout` / 顺序；
- 若引导补丁尚未安装（或想用 NVRAM 直接启动），`flash.sh` 会建立一条指向 rEFInd
  （`\EFI\BOOT\bootaa64.efi`）的独立启动项，不改动其它启动项。

## USB 串口调试（抓启动错误）

采用**内核内建 gadget**，不依赖任何用户态服务：只要 USB-C 枚举成功，PC 侧就能登录，
登录后 `dmesg` 可取完整早期日志。（**默认不实时推送内核日志**，见下条；要实时看把
`console=ttyGS0` 加回 cmdline。）

- `nabu-main` 的 product 内建 legacy CDC-ACM gadget
  （`config/nabu-usb-console.config` 里的 `CONFIG_USB_G_SERIAL=y`，经
  `products/production.toml` 的 `kernel_config` 合入）。内核在 UDC 可用时自己创建
  `ttyGS0`，**没有 configfs、没有 gadget 服务**；
- **UKI 命令行不再带 `console=ttyGS0` 与 `ignore_loglevel`**（2026-10-08 去掉，见
  `config/debian.cmdline`，现在只剩 `console=tty0`）。原因：`ignore_loglevel` 让 printk
  全量往串口灌，叠上 `ath10k_snoc: chan info: invalid frequency 0 (idx 41 out of
  bounds)` 一开机刷 189 条，把 `serial_cmd.py` 的首次登录直接挤掉。因为还留着
  `console=tty0`，`register_console()` 的 `preferred_console ≥ 0`，ttyGS console 匹配不到
  `console=` 条目就不会启用——内核日志只进 ring buffer，不往串口写；
- `serial-getty@ttyGS0.service` 打开 `/dev/ttyGS0` 提供串口登录：它由 `build.sh` 显式
  `ln -sf` 进 `getty.target.wants`，**不依赖 `console=`**，所以关掉内核串口 console
  之后登录照常可用；登录后 `dmesg` 仍能看到完整早期日志（`console=` 只决定往哪输出，
  ring buffer 是无条件记录的）。

想要**实时**串口日志（含 USB 起来之前就发生的错误）时，把 `console=ttyGS0` 加回
`config/debian.cmdline` 重建 UKI 即可：ttyGS console 带 `CON_PRINTBUFFER`，gadget 一绑上
就回放整个 ring buffer。gadget 默认 `use_acm=1`，PC 侧看到标准 `/dev/ttyACM*`，USB ID
为 NetChip `0525:a4a7`（Gadget Serial v2.4）。

> **已实测（2026-10-08 重启验证）**：`/proc/consoles` 只剩 `tty0` + `ramoops-1`（无
> `ttyGS0`）、`gs_close` 的 `u_serial.c:696` WARN 由 3 次归零、`serial-getty@ttyGS0`
> 仍 active/enabled；`ath10k_snoc: chan info: invalid frequency 0` 从 189 条降到 13 条。
> 同时**启动从 1min17s 降到 12.5s**（`graphical.target` 10.7s）—— 早期 userspace 那
> 64s 卡顿很可能就是往 g_serial console 全量灌日志拖住的，待再重启复测确认。

PC 侧（USB 数据线连平板 USB-C）：

```sh
dmesg | tail                     # cdc_acm ... ttyACM0: USB ACM device
ls /dev/ttyACM*
sudo chmod a+rw /dev/ttyACM0     # 或把自己加进 dialout 组
picocom -b 115200 /dev/ttyACM0   # 或 screen /dev/ttyACM0 115200
```

仓库里的 `capture-serial.sh` 更适合长时间抓取：自动识别 gadget（`0525:a4a7` 或
`1d6b:0104`）、断线/重启后自动重连、持续追加到同一个日志文件，直到 Ctrl-C
（**默认 cmdline 下抓到的是登录/交互会话，不是启动日志**）：

```sh
./capture-serial.sh -t -o nabu-boot.log   # 逐行加时间戳
./capture-serial.sh -q                    # 只写文件，不在终端回显
# 可选：-d /dev/ttyACM0  -b 115200  -o FILE
# 后台常驻：nohup ./capture-serial.sh -q -o ~/nabu-boot.log &
```

登录用户 `nabu` / 密码 `nabu`；进去后 `dmesg` 可取完整早期日志。

枚举前提：Type-C 端口必须处于 **device 角色**。默认的 `dr_mode="otg"` 下，PM8150B
Type-C 同时被主线的 `pm8150b_typec`（TCPM）和 `nabu-power` 带的下游
`qcom_pmi8998_charger` 驱动，两者都写同一个 power-role 寄存器，会把端口钉在 host，
gadget 就永远枚举不出来。所以 **debug 版把 `&usb_1_dwc3` 改成 `dr_mode = "peripheral"`**
（见 `nabu-platform/.../sm8150-xiaomi-nabu.dts`），彻底绕开 role-switch，USB-C 恒为 device。
代价是 **USB-C 不能再当 OTG host**（键盘/鼠标）；调试完把它改回
`dr_mode = "otg"; usb-role-switch;` 重编即可。

这样无论 `nabu-debian` 还是主系统重编后，插 PC 都应当枚举出 `/dev/ttyACM*`。

还有第二个、更直接的冲突：SMB5 充电驱动 `qcom_pmi8998_charger` 会用
`dpdm-supply = <&usb_1_hsphy>` 把 **USB HS PHY 的 D+/D-** 抢去跑 APSD/QC 充电器识别
（识别不成功时每 2s 重抢一次，PHY overlay 里有个 `dpdm` regulator 就是干这个的），
所以 gadget 根本拿不到 D+/D-。debug 版已在
`nabu-power/config/nabu-power.config` 关掉 `CONFIG_CHARGER_QCOM_SMB2`，并去掉 FG 的
`power-supplies` 链接以免电量计永久 `-EPROBE_DEFER`（电池/电量计仍在，充电退回
PM8150B 的 ABL 默认值，可能很慢）。要恢复充电就把这两个改动改回去重编。

因为 gadget 已在内核里，改 `config/debian.cmdline` 只需重做 UKI：

```sh
sudo ./build.sh --uki-only
sudo ./deploy.sh --no-rootfs        # 或重新生成 esp.img
```

> **前提是内核本身带了 `CONFIG_USB_G_SERIAL=y`。** 改的是 `nabu-main`，先在那边
> `make`（会重跑 `config`，按新 fragment 编出内核并收集到
> `nabu-main/artifacts/production-7.2/`）。`make install` 是「构建机就是平板」时用的
> （把模块装进本机 `/lib/modules`、UKI 装进 ESP），**独立构建机上不需要**
> ——`debian/build.sh` 直接从 `nabu-main/artifacts/production-7.2/` 取
> `Image`/DTB 重建 UKI。之后在本目录 `sudo ./build.sh`（复用 `work/rootfs`，清掉旧的 configfs 服务与
> ttyGS0 getty），再 `./make-img.sh`，或把产物拿到
> 平板上 `sudo ./deploy.sh`。
>
> 模块包不用重做：内建 gadget 不改变任何模块，`nabu-linux-modules_7.2.7-nabu-full`
> 的 vermagic 与现内核一致，继续用即可。

**现在默认就是「内核不往串口打印」**（`config/debian.cmdline` 只剩 `console=tty0`）。
反过来要恢复实时串口日志：把 `console=ttyGS0 ignore_loglevel` 加回 `config/debian.cmdline`
→ `./build.sh --uki-only` → 把新的 `out/nabu-debian.efi` 覆盖到 ESP 的
`\EFI\debian\nabu-debian.efi`（**不要整盘 `fastboot flash esp`**）。连串口登录也不想要：
`sudo systemctl disable --now serial-getty@ttyGS0.service`；彻底关掉 gadget 则从
`nabu-main/config/nabu-usb-console.config` 移除 `CONFIG_USB_G_SERIAL=y` 重编内核。

## 已知事项 / 注意

- **`linux` 分区会被清空**（刷写/部署时），其中若仍有数据请先备份。
- Debian 初次开机使用 GDM；默认用户 `nabu` / 密码 `nabu`（务必修改）。
- 无 initramfs：内核直接以 `root=PARTLABEL=linux` 挂载；紧凑 `linux.img` 由
  fstab 的 `x-systemd.growfs` 在首次启动时扩展到分区实际大小。
- 双引导需要 rodriguezst 的引导补丁（`installer_bootmanager_NOSB.zip`）；没有它时
  开机仍进入原系统，Debian 可通过 `flash.sh` 建的 NVRAM 启动项进入。
- GPU/显示/触控依赖内核内建驱动 + 输入包里的固件；桌面为 GNOME（Mesa freedreno）。
- 相机/视频硬件解码依赖 `libcamera`/`iris-vaapi` 用户态，Debian 侧目前只提供基础依赖。
- 内核升级后（`KERNEL_RELEASE` 变化）需重新 `--modules-deb-only` 与构建/部署；
  UKI 的 `.uname` 必须与模块目录、模块包版本一致。
- 该工具假定分区布局为 `PARTLABEL=esp` + `PARTLABEL=linux`。
  其它布局可用 `ROOT_PART` / `ESP_PART` / `UKI_REL` / `NABU_LABEL` 覆盖；
  fastboot 分区名用 `FB_ESP_PART` / `FB_ROOT_PART` 覆盖，`DUALBOOT=0` 可生成单系统 ESP。
- **WiFi（WCN3990）依赖 modem/WPSS（`remoteproc_mpss`）**：WLAN 固件 `wlanmdsp.mbn`
  由 modem 里的 `wlan_pd` 子域加载（`modemuw.jsn` 确认 `domain=modem`、
  `subdomain=wlan_pd`）。modem 启动后要**经 QRTR TFTP 从 AP 侧拉
  `/readonly/firmware/image/wlanmdsp.mbn`**（`modem.mbn` 里有 `tftp_client.c`、
  `tftp_socket_ipcr_modem.c`、`fs_qmi_service.c`、`ELF_LOADER CAN SPWAN User PD:%s`，
  以及 `Attempting APSS Service Locator Server connection`）。所以 **AP 侧必须运行
  `tqftpserv`**（Debian/Ubuntu 包，QRTR TFTP 服务端，`/usr/bin/tqftpserv` 的字符串里
  就有 `/readonly/firmware/image/`）——这是 2026-10-08 定位到的真正根因：
  **没装 `tqftpserv` → `wlan_pd` 从不加载 → QRTR 名字服务里没有 `wlfw`(0x45) →
  `ath10k_snoc` probe 永久阻塞在 QMI 等待 → 没有 `wlan0`**。`build.sh` 现在会安装并
  `systemctl enable tqftpserv.service`（与 `rmtfs` 一起），`nabu-start-modem.service`
  加了 `After=tqftpserv.service rmtfs.service`。依赖只有 `libc6` + `libqrtr1`。
  **排查方法**：把 `nabu-audio/scripts/qrtr-services.py` 推到设备跑一遍，和服务正常的
  系统（`nabu-audio/diagnostics/qrtr-after-boot.txt`）逐条对比——正常系统 node0 有
  `0x0045`，node1(AP) 有 `0x1000`（= `tqftpserv` 注册的）和两个 `0x0040`（内核
  `qcom_pd_mapper` + 用户态 `pd-mapper`）。
  **已验证（2026-10-08，`6.14.11-nabu-full` + `tqftpserv 1.1-4`）**：`wlan0` 正常出现，
  `nmcli dev wifi list` 扫到 16 个 AP（含 `SPAX-office` 两个频段、`ZYSD`、`vivo` 等），
  `wlan0` 已连上 `SPAX-office` 并拿到 `192.168.0.67/24`（`con show --active` = activated）。
  该构建**刻意没装** `protection-domain-mapper`（`pd-mapper.service` 仍 mask），说明内核
  `qcom_pd_mapper` 已经够用——WiFi 修复只需要 `tqftpserv` 这一个变量。
  nabu 没有 WWAN，`ModemManager.service` 与 `qcom-modem-setup.service` 会去戳这块 modem
  导致固件 fatal-error 循环崩溃——镜像里已 mask 掉，并装了 `rmtfs`/`qrtr-tools`（modem EFS）。
  （注意：运行中 `echo stop > /sys/class/remoteproc/remoteproc1/state` 会硬挂机，勿做。）
- **WiFi MAC 每次开机随机 → IP 跟着漂（2026-10-08 修复）**：这块 WCN3990 **没有烧录 MAC**，
  `ath10k_snoc` 每次开机打 `invalid MAC address; choosing random`（设备树里 0 个
  `local-mac-address` 节点、`/persist` 为空、蓝牙 `BD Address` 同样是本地管理位=1 的假地址）。
  路由器按 MAC 发 DHCP 租约，于是**每重启一次 = 换一个 MAC = 换一条租约 = 换一个 IP**
  （实测 `.67 ↔ .68`）。两个容易误判的点：① 单次开机内 IP **不会**变——`boot -2` 连开 6 个月、
  跨多次重连始终 `.67`，漂移只发生在**重启**那一刻；② NM 日志里
  `set MAC address to XX (scanning)` 是**每次扫描换一个**的临时地址，扫完立刻
  `reset ... (preserve)` 还原，**不参与 DHCP**，别把它当成根因。修在**全局**（不然换个 SSID
  就得再改一次 profile）：
  - `/etc/NetworkManager/conf.d/10-nabu-fixed-mac.conf`
    `[connection] wifi.cloned-mac-address=02:00:0C:79:07:42`（所有 WiFi 连接档案的默认值，
    含以后新建的）+ `[device] wifi.scan-rand-mac-address=no`（扫描阶段也不换 MAC）。
    这两个键都在 `NetworkManager.conf(5)` 的 Supported Properties / `[device]` 清单里。
  - `/etc/udev/rules.d/99-nabu-fixed-wlan-mac.rules`：网卡 `add` 时就
    `/usr/bin/ip link set dev %k address 02:00:0c:79:07:42`，不依赖 NetworkManager 是否接管
    （注意 `ip` 装在 **`/usr/bin/ip`**，规则里写 `/usr/sbin/ip` 会找不到）。
  - `SPAX-office` 与 `vivo` 两个 profile 的 `cloned-mac-address` 都**留空**，全靠全局默认。
  改 `conf.d` 要 `sudo systemctl restart NetworkManager` 才生效（日志 `Read config:` 里能看到）。
  **已验证（2026-10-08 11:08 重启）**：驱动照旧打 `choosing random`，但落盘 MAC 恒为
  `02:00:0c:79:07:42`，租约 2/2 = `192.168.0.67`，NTP 已同步、失败单元 0 个、启动 10.7 s。
  **随机性与种子质量都已实锤**：三次开机三个不同值——`02:00:0C:79:07:42`(08:05)、
  `A6:D8:E0:1A:1A:92`(10:26)、`ea:f6:2e:de:12:97`(11:39)，最后一个取自
  `/sys/class/ieee80211/phy0/macaddress`（= `SET_IEEE80211_PERM_ADDR` 写进 phy 的驱动
  原始值，`netdev` 上看到的只是我们覆盖后的地址）。这平台**没有硬件随机源**
  （`rng_current=none`、CPU 无 RDRAND/FEAT_RNG、`trust_cpu=0`，种子全靠时序抖动），
  但每次开机 `random: crng init done` 都比 `choosing random` **早 9~40 秒**
  （08:05:52→08:06:01、10:26:55→10:27:28、11:39:33→11:40:14），日志无 unseeded 警告 →
  MAC 出自已播种的 CSPRNG。**别拿「IP 一直没变」倒推「MAC 没变」**：路由器是发第一个
  空闲地址，不同 MAC 照样可能都拿到 `.67`。
- `boot.mount`（systemd `gpt-auto-generator` 自动生成的 ESP 挂载）必然失败并重试刷日志：
  `sda31`(ESP) 的逻辑扇区是 **4096**，而 `make-img.sh` 用 `mkfs.fat -F 32` 生成的是 512，
  于是 `fs/fat/inode.c` 判 `logical_sector_size < s_blocksize` 直接 `-EIO`。改 4096 扇区
  又可能让 UEFI/rEFInd 读不了，故保持现状（不影响引导，原厂 Ubuntu 镜像同样挂不上）。
- `/etc/sudoers` 有时是空的（即使 `nabu` 在 `sudo` 组里也不能 sudo）；`build.sh` 每次会把它写回
  标准 Debian 策略（`%sudo ALL=(ALL:ALL) ALL` + `@includedir /etc/sudoers.d`）。
- 若重新启用 USB console，`console=ttyGS0` 必须接在 `console=tty0` **之后**（保留 tty0
  为主 console），否则无主机连接时会影响启动；**当前默认配置已去掉 `console=ttyGS0`**
  （串口只用于登录 + `dmesg`，不再接收内核 printk，见「USB 串口调试」）。
- **默认内核为 6.14.11**（`PRODUCT=production`、`KERNEL_RELEASE=6.14.11-nabu-full`）。
  切回 7.2.7 用 `PRODUCT=production-7.2 KERNEL_RELEASE=7.2.7-nabu-full`。
  USB 串口 console 现在两个内核都有：`config/nabu-usb-console.config`
  （`CONFIG_USB_G_SERIAL=y`）已并入 `products/production.toml` 的 `kernel_config`。
  早先「7.2.7 上 `wlan_pd` 不加载、6.14.11 上正常」的说法已作废——真正变量是
  **`tqftpserv` 有没有装**（见上面 WiFi 条目），与内核版本无关；
  `0001-remoteproc-pas-autoboot-mpss.patch` 两个构建其实都没打（好系统日志里 modem 同样
  是开机 2 秒后由 `nabu-start-modem.service` 拉起的），不是决定因素。
- **RTC：已关掉 `CONFIG_RTC_DRV_EFI`（2026-10-08 修复）**：efi RTC 在这台机器上是坏的
  （开机必现 `hctosys: unable to read the hardware clock`，`timedatectl` 直接报
  `Failed to read RTC: Input/output error`），而它**抢在 `rtc-pm8xxx` 前面**注册占住了 `rtc0`，
  `CONFIG_RTC_HCTOSYS_DEVICE="rtc0"` 配上 `drivers/rtc/class.c:436` 的
  `strcmp(dev_name, "rtc0")` 就永远轮不到 PMIC RTC 去设系统时钟。正规修法是 fragment
  `nabu-main/config/nabu-rtc.config`（`# CONFIG_RTC_DRV_EFI is not set`，已挂进
  `products/production.toml` 与 `production-7.2.toml` 的 `kernel_config`），**不用**
  `initcall_blacklist=` 这种临时手段（该参数已弃用）。rtc-efi 导出 0 个符号 →
  `Module.symvers` 逐字节不变 → 平板上现成 `.ko` 不用重装、内核仍为
  `6.14.11-nabu-full`。**已验证**：`/sys/class/rtc/` 只剩 `rtc0 = rtc-pm8xxx`，开机 4.37 s
  `setting system clock to 2026-10-08T… UTC`，`unable to read` 计数 0，`timedatectl`
  恢复可用（NTP 随后自动同步）。
- **挂起后恢复必崩，但按决策保留电源键挂起（2026-10-08 实测）**：2026-10-08 11:23:50
  被 `systemd-logind` 挂起（日志 `The system will suspend now!` → `PM: suspend entry
  (s2idle)`；入口是**电源键**，GNOME `power-button-action='suspend'`），睡了 16 分钟
  （期间网络与 USB gadget 全消失，SSH 连不上）；11:39:33 再按电源键恢复时**立刻崩**：
  ```
  Internal error: synchronous external abort: 0000000096000010 [#1] PREEMPT SMP
  CPU: 2 PID: 1059 Comm: KMS thread   6.14.11-nabu-full #41
  dpu_reg_read+0x8/0x10 (P)
  dpu_encoder_trigger_kickoff_pending → dpu_crtc_atomic_begin → drm_mode_atomic_ioctl
  ```
  即**恢复路径的 DPU 驱动读显示寄存器时总线不应答**（显示电源域没被正确还原），
  oops 后系统重启（`journalctl --list-boots`：boot -1 终点 = boot 0 起点 = 11:39:33）。
  这坐实了体检清单「D. suspend 故意不测、有硬挂机风险」——**一睡一起必崩，只能重启**。
  **处置（2026-10-08 拍板）：保留电源键挂起**，即 `power-button-action='suspend'` 不动、
  `sleep.target`/`suspend.target` 保持 `static` **不 mask**；同时已确认**没有自动挂起
  路径**（不会自己睡过去）：GNOME `sleep-inactive-battery/ac-type='nothing'`、
  `session idle-delay=0`（连熄屏都关了）、logind `IdleAction=ignore`（默认）、
  **无 `SW_LID` 盖子开关**（合上键盘皮套不触发）。⚠️ 后果要认账：**按了电源键 = 睡，
  再按 = 必崩重启**，介意就别按；想根治得修 DPU 恢复路径（体检清单 D 项）。
- **扬声器无声：缺 ALSA UCM（2026-10-09 修复并经用户听感确认）**：声卡本身一直是好的
  （`0 [X5]: sm8150 - Xiaomi Pad 5`，驱动 `snd-sm8150`，`snd_soc_wcd934x` /
  `soundwire_qcom` / `snd_soc_cs35l41` 全部加载，4 颗 CS35L41 在 I2C `2-0040`~`2-0043`，
  `q6afe`/`q6routing`/`q6asm` 正常，DAPM 路由 1347 个控件齐全）。缺的只是**用例配置**：
  `alsa-ucm-conf` 没有 nabu 的 UCM，`ucm2/conf.d/` 下只有 `sm8250`/`sm8550`/`sm8650`
  等，**没有 `X5`/`sm8150`/`Xiaomi`**，于是 PipeWire 只能造一个 `Dummy Output`
  ——GNOME 里音量条能动，但不出声。
  **修法**：按 `ucm2/ucm.conf` 的探测顺序，hw 卡会试
  `ucm2/conf.d/${Driver}/${Driver}.conf`（`${Driver}` 取自 `0 [X5]: sm8150` 的
  驱动名，即 `sm8150`），所以装两个文件（已进 `nabu-audio/config/ucm2/`，由
  `debian/build.sh` 的 `overlay_nabu_userspace` 安装）：
  ```
  usr/share/alsa/ucm2/conf.d/sm8150/sm8150.conf   # 入口：Syntax 3 + SectionUseCase."HiFi"
  usr/share/alsa/ucm2/Xiaomi/nabu/HiFi.conf      # verb（File 路径相对 ucm2 根）
  ```
  **验证**：`alsaucm -c hw:X5 list _verbs` → `0: HiFi`（注意必须带 `hw:` 前缀，
  否则 alsaucm 走 no-hw 分支找不到卡，报 `failed to import X5 ... -2`）；
  PipeWire 出现 `Built-in Audio Speaker playback` + `Internal Microphones` 两个节点
  取代 `Dummy Output`；UCM 的 `EnableSequence` 全部生效（`BR Digital PCM Volume=817`、
  `ADC1/ADC3 Volume=8`、`QUAT_TDM_RX_0 Audio Mixer MultiMedia1=on`、
  `CDC_IF TX6 MUX=DEC6`、`AMIC4_5 SEL=AMIC4` 等枚举值逐项核对无误）；用户实测**四路扬声器出声**。
  内核侧无需改动——`sm8150.c` 把 `QUATERNARY_TDM_RX_0` 功放 DAI 从 `DSP_A` 改成
  `I2S`（`nabu-audio` overlay，治 BR 扬声器无声）本来就在树里。
- **麦克风只在开机后第一次开流时出真实数据（2026-10-10 定位；已加可用 workaround，
  根因未修）**：播放修好后麦克风仍录不到声音，但问题比"全 0"精确得多——**每次开机
  只有第一次打开采集 PCM 能拿到真实音频，之后所有打开都返回常量**（S16 是恒定直流值，
  如 `L=-26/R=-44` 或 `+20`；S24 是 4~5 个固定值高频交替）。4 次重启**每次都稳定复现**。
  2026-10-10 又用**受控声学激励**（用户敲击平板 + 人声）终审：重启后第 1 段 8~20 s
  一次不落地录到敲击脉冲（峰值打满 `32768`）与人声爆发，第 2/3/4 段则是常量；且失败段
  缓冲区开头与第 1 段**逐样本相同**（残留的固定头 + 常量），即 DSP 不再往缓冲里写。
  判定必须看**唯一值数 + 变化率**，常量也 100% 非零，光看非零数会误判。
  **已确证的事实**：
  - **与 PipeWire 无关**：开机后立刻 `systemctl --user stop wireplumber pipewire`、
    改用 `arecord -D hw:X5,1` 直采，仍是第 1 次真实、第 2/3/4 次常量。
  - **内核侧在"工作态"与"故障态"逐字节相同**（插桩对比第 1 次与第 2 次开流）：
    - codec 寄存器（采集中读 `regmap/217:250:1:0/registers`，格式 `060e: a8`）：
      `060e=a8 0610=a8 0625=50 0626=50 0a81=24 0a91=24` 两次完全一样
      （ADC1/ADC3 使能、MICB3/4 偏置使能、TX5/TX6 通路使能都正常）。
    - `wcd934x_trigger` 返回 `prepare=0 enable=0 port_mask=0x60`，两次一样。
    - 通道映射链 `set_channel_map tx5=133 tx6=134` → `get_channel_map
      port5/ch133 port6/ch134` → `afe_set_channel_map slots=[133,134]`，两次一样。
    - `q6routing_stream_open`：`port_id=3 path=2 rate=48000 ch=2` 与
      `matrix_map` 返回值，两次一样。
    - `q6asm_dai_prepare`：`phys/size/periods/sid/ret/state`，两次一样。
  - **模拟前端贡献的确实是字面 0**：差分测试让 `CDC_IF TX6 MUX` 在 `ZERO`
    （断开 ADC）与 `DEC6`（接上 ADC）两个位置，输出**完全相同**；再扫
    `ADC MUX6`（AMIC/DMIC/ANC_FB_TUNE1）与 `AMIC MUX6`（ADC1~4/ZERO）
    也全一样 —— 读到的 `-26/-44` 直流偏置来自 TX/SLIM 数字路径，不是 ADC 输出。
  - **无法靠不重启的操作恢复**：换采样率（16k）、换 PCM（MultiMedia1）、
    换格式（S24）、先播放再采集、静置 90 秒，**全部无效**。
  - PipeWire 开机探测会 `hw_params` 却不 `TRG START`，**不消耗**有效配额
    （配额按**真正 RUN** 计）。
  - **⚠️ workaround 尝试（2026-10-10，部分有效但不可靠，尚未定稿）**：思路是让 PipeWire
    **第一次打开后就一直持有**那个有效的第一次会话。实测：
    - **只设 `session.suspend-timeout-seconds=0` 不够**：节点仍会变 `idle`、ALSA 设备随之
      被关闭（空闲 ~20 s 后 `fuser` 为空、下次录音又是常量）。
    - **常驻一个客户端**（`nabu-mic-keepalive.service`，跑 `pw-record … /dev/null`）能把它
      钉住，但**时序很敏感**：若在 codec/UCM 就绪前开流，只录到**全 0**（比常量更糟）；
      若 `user@1000`/PipeWire 重启（keepalive 被 systemd 拉起、PipeWire 重开设备），又拿回
      坏会话。多次实测**时好时坏**。
    - **系统级 `snd-aloop` 桥接**（屏蔽真实麦 + 系统服务把 `hw:X5,1` 常开到 `hw:Loopback`）
      在 **ALSA 层稳定 live**（`arecord -D hw:Loopback,1,0` 始终有数据、且不受用户会话影响），
      但**没能让 PipeWire 稳定暴露 loopback 源**（实测源时有时无，可能与本机
      GDM/WirePlumber 会话反复重启有关）。
    - 该 workaround **已移除**（2026-10-13）：`nabu-mic-keepalive.service` 与
      `wireplumber/51-nabu-mic-keepalive.conf` 已从本目录删除，`build.sh` 也会从复用
      rootfs 里清掉——它可能让麦克风比"只能用一次"更糟（全 0）。真正可靠的方案要么修固件，
      要么把 snd-aloop 桥接做扎实（含屏蔽真实麦、固定 loopback 源、先跑 `alsaucm` 应用 UCM）。
    - 关键坑：**别**用 `node.always-process=true`（开机太早开流 → 全 0）；PipeWire **开机
      就会打开麦克风**（`fuser` 可见 wireplumber 持有），这常吃掉"第一次"配额。
  **结论与排除**：断点收敛到 **ADSP 固件的采集图重开路径**——内核每次做的事
  完全相同，但 DSP 只在会话首次 RUN 时投递数据；内核日志零输出（ADSP 日志读不到，
  `CONFIG_DYNAMIC_DEBUG`/`FTRACE` 未开）。已排除：声道数、采样率、格式、
  PipeWire/UCM、DAPM 上电、mic bias、通道映射、SLIM 端口、AFE 端口重启、
  `q6routing` 路由、`q6asm` 会话参数、`port_disabled` 标志位、`CMD_CLOSE` 漏发
  （`Q6ASM_STREAM_IDLE=0/STOPPED=1/RUNNING=2`，停止后 `state=1` 仍为真，
  `q6asm_dai_close()` 的 `if (prtd->state)` 会正常发 `CMD_CLOSE`，此前怀疑的
  采集会话泄漏不成立）。
  **顺带纠正两个假阳性**：(1) 9 月"验证通过"的样本其实分两类——`mic-direct`/
  `capture24-listen`/`capture-0` 等 L/R 完全相同且能量挤在 5.9 Hz（慢漂移驻波），
  `mic-current`/`mic-default-repeat` L/R 相关≈0 且能量铺满到 Nyquist
  （未初始化缓冲区垃圾），只有 `capture-1`/`capture-2` 像真实底噪；
  (2) 曾据周期为 8 的伪信号怀疑「S24 字节错位」，方向作废。
  判定麦克风务必查**唯一值数 + 变化率 + L/R 相关性 + 频谱**，别只看非零数/峰值。
  2026-10-10 又做了**内核可见态全量对比**（重启后停 PipeWire，dump 全 `regmap` 与
  整个 `asoc` DAPM 树，第 1 段工作态 vs 第 2 段故障态）：`asoc` DAPM 树**逐字节相同**；
  `regmap/217:250:1:0`（`wcd934x-slim`，非缓存）**只有一个寄存器**不同——`0x800` 即
  `WCD934X_SEL_REGISTER`（窗口选择器，读全表后的残留值，属**伪影**）；
  `regmap/217:250:0:0`（MFD，`REGCACHE_MAPLE` 缓存）里 `0x55/0x56`
  （`WCD934X_SLIM_PGD_TX_PORT_CFG(5/6)`）等差异也多为窗口/缓存伪影。
  **结论不变：内核侧几乎无差异，断点在 ADSP 固件的采集图重开路径**。要根治仍需能看到
  ADSP 侧日志（当前 `CONFIG_DYNAMIC_DEBUG`/`FTRACE` 均未开），或对照 Android/vendor 的
  AFE/ASM 关流序列。本轮插桩此前已全部回退，源码 `NABUDBG` 清零、`wcd934x.c` 恢复 `+46`、
  `q6asm-dai.c` 恢复 `+81`、`q6routing.c`/`q6afe-dai.c` 恢复无 diff，
  设备上四个模块已换回干净版并验证播放正常。
  **再补两条 2026-10-10 实证**：(1) 失败段缓冲**开头是一个完整的 WAV 文件头**
  （`52 49 46 46 24 dc 05 00 57 41 56 45 66 6d 74 20 …`，即 `RIFF…WAVEfmt …data`，
  48 kHz 立体声 S16、data 384000 字节）→ **第二次会话 DSP 根本没往缓冲写**，读到的是
  缓冲分配时的原始（未初始化）内容；(2) 用插桩模块（`q6afe` 打端口启停、`wcd934x` 打
  抽取器/trigger、`q6asm` 打映射与首个 READ）对比两次会话：`afe_start/stop port=0x4001
  token=3 ret=0`、`decimator tx_port=5/6 mux_sel=2 dec=5/6 rate_val=4`、`asm_map dir=1
  phys=0x1ffc00000 …` **逐条相同**；且关流命令换 `CMD_PAUSE` / `CMD_PAUSE+
  CMD_OUT_FLUSH`(=`ASM_STREAM_CMD_FLUSH_READBUFS`) / `CMD_EOS` 三种都**不能**让第二次
  会话恢复 → 进一步坐实是 DSP 固件层、非内核命令序列问题（插桩源码已全部回退）。
  **2026-10-10 还验证了 `nabu-audio` main（6.14）分支**：把全部 `nabu-*` 仓库切到 main、
  按 main overlay 全量重编（Image `#42` + 全量模块）并整机部署——**麦克风行为完全一样**：
  直采第 1 次 live、第 2 次起常量；PipeWire 背靠背连录会 live，但只要空闲 >5 s（`fuser`
  显示设备已释放）下一次录音立刻变常量/全 0。所以 **main 的 `q6asm-dai.c` overlay 并没有
  修好"关流后重开"**；main README 里"three default PipeWire recordings reopened …
  non-zero data"是**假阳性**（背靠背录音共用同一个有效会话，且"non-zero"满足不了判据）。
  顺带把 main 的 `products/production.toml` 补上 `kernel_config = [... "config/nabu-rtc.config"]`
  （关掉坏 EFI RTC），并修了 main 的 `scripts/nabu`（`run_capture` 过滤 make 的"进入/离开
  目录"串扰、`kernel_release_base` 取最后一行）。
- **ALSA 枚举 SoundWire 设备要加 `hw:` 前缀**：`alsaucm -c X5 ...` 会报
  `failed to import X5 use case configuration -2` 并 `expected 1 arguments`，
  容易误判成 UCM 没装；正确写法是 `alsaucm -c hw:X5 list _verbs`。
- ⚠️ **UCM 路径 `ucm2/Xiaomi/nabu/` 的大小写是硬的，改成小写会静默失效**：
  入口 `conf.d/sm8150/sm8150.conf` 里写的是 `File "/Xiaomi/nabu/HiFi.conf"`，
  而 alsa-lib 对 `File` 指令就是**大小写敏感的普通 `open()`**（拼 ucm2 根目录后直接
  打开，无任何大小写折叠）。2026-10-09 实测：目录一旦改成 `xiaomi/`，
  ALSA 立刻报 `could not open configuration file .../Xiaomi/nabu/HiFi.conf`，
  UCM 整体加载失败，PipeWire 退回没有 `Speaker playback` / `Internal Microphones`
  的裸状态（扬声器重新变哑，但**不报任何错**，很容易被当成别的问题）。
  这个 `Xiaomi/nabu` 布局沿用上游 map220v 的原始 UCM，**不要"顺手改成小写"**。
  改完 UCM 后一律用 `alsaucm -c hw:X5 list _verbs` 复核，应看到 `0: HiFi`。
- **声卡起来前要等 SLIM 枚举（本机 5 s ~ 5.5 min 波动）**：`qcom,slim-ngd-ctrl`
  只打 `Adding to iommu group` 时 codec 还没注册（`/proc/asound/cards` 为空或
  `no soundcards`），此时 PipeWire 只有 `Dummy Output`。等
  `journalctl -k -b | grep 'WCD934X Minor'` 出现再判定音频问题——
  2026-10-09 有一次 codec 迟迟不就绪被误当成插桩把声卡搞挂了。

## 故障排查

- 构建报 `no modules input ... and no /lib/modules/...`：把
  `nabu-linux-modules_*.deb` 放进 `packages/`；或在平板本机执行
  `nabu-main$ sudo make install` 让本机能现场生成（独立构建机走 `packages/` 输入）。
- `mmdebstrap` 报镜像/密钥错误：换 `MIRROR`（如 `https://deb.debian.org/debian`）。
- 固件 deb 覆盖冲突：脚本已用 `--force-overwrite`；如仍失败，确认 `wireless-regdb`
  未处于异常状态。
- `make-img.sh` 报 `dual-boot EFI payload not found`：确认 `boot/nabu-dualboot-efi.zip`
  存在，或运行 `./fetch-efi.sh`，或用 `--no-dualboot` 生成单系统 ESP。
- `fastboot flash esp` 失败 / 报分区太小：`out/esp.img` 比设备 `esp` 分区大。用
  `ESP_SIZE=<esp分区字节> ./make-img.sh --esp-only` 重新生成。
- 启动项创建失败：确认 `efibootmgr` 可用且 ESP 为 `PARTLABEL=esp`；也可在 rEFInd 里
  直接启动，或在 UEFI Shell 里手动 `fs0:` → `\EFI\BOOT\bootaa64.efi`。
- `--uki-only` 报 `ModuleNotFoundError: No module named 'pefile'`：当前 PATH 的 `python3`
  缺少 `pefile`（例如 conda/venv 抢在系统 Python 前面）。`build.sh` 现在会自动挑一个能
  `import pefile` 的解释器（本机 `python3` → `/usr/bin/python3`），一般无需处理；实在没有
  可用解释器时用 `PATH=/usr/bin:$PATH ./build.sh --uki-only` 或 `pip install pefile`。
- 想重建 UKI 而不动 rootfs：`./build.sh --uki-only && sudo ./deploy.sh --no-rootfs`。