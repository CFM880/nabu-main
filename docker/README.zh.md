# nabu-main 编译镜像

[English](README.md) | 中文

一个可复现的容器,用于运行完整的 [nabu-main](../README.zh.md) 流水线
(apply → compose → config → build → collect → package → verify),同时内置
`make install` / `make rollback` 所需的工具(`ukify`、`efibootmgr`、`kmod`、
`systemd`、`util-linux`)。

镜像是**多架构**的,始终产出 **aarch64** 内核产物,且都在原生速度下完成
(不使用 qemu 模拟):

| 宿主机 | 编译方式 | 速度 |
|---|---|---|
| `amd64` | 原生 `x86_64` 宿主机工具 + `aarch64-linux-gnu` 交叉工具链 | 原生 |
| `arm64` | 全部原生 | 原生 |

镜像本身不含源码:运行时把工作区(本 `nabu-main` 目录及其同级的 `linux-6.14`
和各 `nabu-*` 模块)挂载到**宿主机上的原始路径**——这正是 `scripts/nabu` 期望的
布局(它从 `nabu-main` 位置推导 `ROOT`)。保持原始路径很重要,因为 `linux-6.14`
是一个 git worktree,其 `.git` 文件里记录的是绝对 `gitdir`。基础镜像是
镜像是基于 Debian 13(trixie)的:它提供足够新的 meson 来构建用户空间栈,且 amd64/arm64
在同一个主仓库中(无需 ports),并使用 `nabu-main` 默认的 `aarch64-linux-gnu-` 工具链。

## 构建镜像

```sh
docker/build-image.sh
```

默认按宿主机自身架构构建,这样之后的内核编译都是原生的。若要在 `x86_64` 主机上
构建 arm64 镜像(例如拷到平板上跑),用 `NABU_PLATFORM`:

```sh
NABU_PLATFORM=linux/arm64 NABU_IMAGE=nabu-main-builder:arm64 docker/build-image.sh
```

该镜像的 `RUN` 步骤(以及在 x86_64 上用它做的编译)会走 binfmt/qemu,所以只建议在
真正的 arm64 机器上使用。

## 运行流水线

```sh
docker/run.sh                       # make(完整流水线)
docker/run.sh build                 # 单个阶段:make build
docker/run.sh PRODUCT=audio-only build
docker/run.sh -j4 build             # 其余参数原样转发给 make
docker/run.sh clean
```

工作区根目录以读写方式挂载到宿主机原始路径(`apply` 阶段会在内核树里做
`git reset --hard`;内核是 worktree,记录的是绝对 `gitdir`,路径必须一致)。
编译以宿主机的 uid:gid 运行,避免 `out/`、`artifacts/` 变成 root 所有。

产物输出到 `nabu-main/artifacts/<product>/`,包含 UKI。

各阶段相互独立:`build` 使用上一次 `config` 生成的那个 `out/`,
所以要先跑 `config`(或直接跑不带目标的完整流水线),切换产品后也要重新跑。
并发的多次运行会用锁串行化,避免两个构建同时破坏共用的 `out/`。

### 宿主机 / 容器构建切换

`out/` 是和宿主机构建共用的,但里面的**宿主机工具**
(`out/scripts/kconfig/conf`、`out/tools/objtool`、`out/usr/gen_init_cpio`、
`out/certs/extract-cert` 等)是按构建主机架构编译的。若这些工具与要运行的镜像架构
不一致(例如 arm64 镜像配上 x86_64 宿主机产生的 `out/`),就无法运行
(`cannot execute`,退出码 127)。`run.sh` 会按镜像架构检测并删除
`out/{scripts,tools,usr,certs}`,让 `make` 重新编译;与架构无关的 `.config` 和
aarch64 目标文件会保留,增量构建不受影响(在 amd64 交叉镜像和 arm64 原生镜像之间
切换时目标文件可复用,因为两者都面向 aarch64)。若不确定,执行
`docker/run.sh clean` 做一次全量重建。

## 安装 / 回滚

安装和回滚会写入宿主机的绝对路径(`/lib/modules`、`/etc/systemd/system`、ESP 等),
因此以特权方式运行,并把相关宿主机目录绑定到容器内相同路径:

```sh
docker/run.sh install          # 先用 docker/run.sh 完成 build/package
docker/run.sh rollback
```

请在**目标设备上**运行。模块的安装钩子(nabu-iris、nabu-accelerometer)要访问正在
运行的 `systemd`,依赖真实硬件(如 `/dev/fastrpc-sdsp`),并可能 `apt-get install`
额外软件包;如果容器内不可行,也可以在这里只做 build/package,再到宿主机上直接执行
`sudo make install`。

`docker/run.sh install-modules` 只安装模块,不动 ESP。

## 环境变量

| 变量 | 含义 | 默认值 |
|---|---|---|
| `NABU_IMAGE` | 镜像 tag | `nabu-main-builder:<宿主架构>` |
| `NABU_PLATFORM` | 强制目标平台(例如在 x86_64 上用 `linux/arm64` 经 qemu 运行 arm64 镜像) | 宿主机平台 |
| `NABU_JOBS` | make 并行度 | 全部 CPU |
| `INSTALL_MOD_PATH` | `modules_install` 的安装根 | `/` |

镜像内已预设 `NABU_CROSS_COMPILE=aarch64-linux-gnu-`,与 `nabu-main` 默认一致。

## 文件

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 带 aarch64 工具链的多架构 Debian 13 镜像 |
| `build-image.sh` | 用 `docker buildx` 按宿主架构构建镜像 |
| `run.sh` | 对挂载的工作区运行 `make`;install 走特权模式 |
