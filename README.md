# gki-builder

在 GitHub Actions 上用 Android 官方的 **`repo`** 工具同步并编译 GKI 内核。
全部可调项集中在两个地方：

| 你想做的事 | 改哪里 |
|---|---|
| 开关内核 config | [`config.yml`](config.yml) 的 `config:` |
| 换自己维护的 kernel/common | [`config.yml`](config.yml) 的 `kernel:` |
| 指定编译哪个 commit | [`config.yml`](config.yml) 的 `kernel.commit` |
| 加补丁 | 丢进 [`patches/`](patches/) |
| 改刷机包（设备名 / BLOCK / 打包内容） | [`ak3/`](ak3/) 里的 AnyKernel3 模板 |

改完推到 `main`（且改动命中 `config.yml`、`patches/**` 或 `ak3/**`）会自动编译，
也可以在 **Actions → Build GKI → Run workflow** 手动触发。

## 快速开始

### 1. 开关 config

```yaml
# config.yml
config:
  CONFIG_LOCALVERSION: "-mybuild"
  CONFIG_KSU: y          # 打开
  CONFIG_DEBUG_INFO: n   # 关闭
  CONFIG_SOME_MODULE: m  # 编成模块
  CONFIG_CMDLINE: "androidboot.console=ttyMSM0"
```

取值语义：`y`/`n`/`m` 对应启用/禁用/模块，整数直接写成 `CONFIG_X=1234`，
其它字符串会加引号写入。YAML 里写 `true`/`false` 等价于 `y`/`n`。

流程是 `gki_defconfig` → 逐条 `scripts/config` → `make olddefconfig` → **回读校验**。
因为 Kconfig 会静默丢弃依赖不满足的符号，最后一步会把「想要的」和「实际得到的」
逐条比对，**有差异就让构建失败并列出差清单**，不会悄悄降级。

### 2. 指定 kernel/common 与编译 commit

`kernel/common` 由自己维护（你的 fork），不再从 Google 拉：

```yaml
kernel:
  repo: https://github.com/aqnya/android13-5.15-vermeer
  branch: main
  commit: ""            # 留空 = branch 的 tip
  # commit: "77804d3596695c7b85fe038c81d9580283ffd2ca"   # 精确钉死
```

prebuilts（clang、build-tools）仍从 Google 的 manifest 拉，单独配置：

```yaml
manifest:
  repo: https://android.googlesource.com/kernel/manifest
  branch: common-android17-6.18   # 注意带 common- 前缀；决定 clang 工具链版本
toolchain:
  clang_version: r584948c         # Android17-6.18 的 clang
```

> 内核树自身的 `build.config.constants` 里写的还是 5.15 的 `r450784e`，而 Android17-6.18
> 的 prebuilts 里没有这个版本，所以 `toolchain.clang_version` 必须显式指定，不能留空自动读。

`commit` 是唯一的 commit 来源（40 位 SHA，或留空）。钉住的是**你这个 fork 的 SHA**。

实现方式是 `repo init` 之后写一个 local manifest，先
`<remove-project name="kernel/common"/>`，再把自己仓库挂到 `path=common`，然后 `repo sync`；
同步后还会校验一次 `git rev-parse HEAD` 是否吻合。

填 SHA 能保证可复现，也避免分支 tip 漂移导致 vermagic 对不上、vendor 模块加载失败。
查你自己 fork 的 tip：

```bash
git ls-remote https://github.com/aqnya/android13-5.15-vermeer refs/heads/main
```

> ⚠️ **两套分支名，前缀规则相反，别搞混：**
>
> | 配置项 | 分支名 | 例 |
> |---|---|---|
> | `kernel.branch`（你自己的 fork） | 通常**不带**前缀 | `main` |
> | `manifest.branch`（Google manifest） | **带** `common-` 前缀 | `common-android17-6.18` |

### 3. 放补丁

见 [`patches/README.md`](patches/README.md)。零填充文件名控制顺序，补丁打在 `common/` 目录上，
用 `git apply` 严格匹配（无 fuzz，上下文必须逐行命中）。

### 4. 改刷机包（AK3）

打包用的 AnyKernel3 模板就在仓库的 [`ak3/`](ak3/) 里，**构建时不再去 clone 上游**——
`ak3/anykernel.sh` 就是你改的那份，直接编辑并提交即可（改动会命中 `ak3/**`，自动触发编译）。

现在已经按目标设备 **Redmi vermeer**（kalama / 5.15 GKI，A/B）配好了：

```sh
# ak3/anykernel.sh
properties() { '
do.devicecheck=1             # 1 = 校验设备名，对不上就直接拒绝安装
device.name1=vermeer         # devicecheck 比对 ro.product.device
'; }

BLOCK=boot;                  # 内核在 boot；A/B 会自己接 _a/_b
IS_SLOT_DEVICE=1;
split_boot; flash_boot;      # ramdisk 在 init_boot：只换 Image，绝不碰 ramdisk
```

**换设备/换模块时要注意的点**（细节记在 [`ak3/README.md`](ak3/README.md)）：

- `device.name1` 填设备代号（设备上 `getprop ro.product.device` 的值），否则刷机时被 devicecheck 拒掉。
- `BLOCK` 写分区名（`boot` / `init_boot` / `vendor_boot`）而不是路径，A/B 由 `IS_SLOT_DEVICE=1` 处理。
- Android 13+ 的 GKI 设备，内核在 `boot`、ramdisk 在 `init_boot`：用 `split_boot` + `flash_boot`
  （只换内核）。写成 `dump_boot` + `write_boot` 会把空的占位 ramdisk 写回 boot，**会变砖**。
- 其它可改的：`do.modules`、`do.systemless`、`do.cleanup`、`ramdisk/`、`patch/`。

`kernel.string`（刷机时打印的那行）默认保留 `ak3/anykernel.sh` 里自己写的那串，
只有它还是上游示例时才自动填成 `GKI <branch> (<sha12>)`；想每次强制成固定文案，
在 `config.yml` 里填 `ak3.kernel_string`。

> 构建时会 `cp -a ak3/ .work/AnyKernel3` 再往里塞 `Image`，所以仓库里的 `ak3/` 一直是干净的。

## 源码怎么来的

用 `repo` 而不是裸 `git clone`：Google manifest 负责把 prebuilts 拉到位，
`kernel/common` 则由 local manifest 指向你自己维护的 fork：

```bash
repo init -u https://android.googlesource.com/kernel/manifest -b common-android17-6.18
# .repo/local_manifests/kernel-common.xml:
#   <remove-project name="kernel/common"/>
#   <project path="common" name="android13-5.15-vermeer" remote="self" revision="main"/>
repo sync common build/kernel prebuilts/clang/host/linux-x86 ...
```

这样 clang、build-tools 等工具链会跟着 manifest 一起到位。**注意 manifest 决定 clang 版本**：
Android17-6.18 用的是 `r584948c`，而 5.15 内核树里写的 `r450784e` 在新 prebuilts 里已不存在，
所以 `toolchain.clang_version` 要显式填 `r584948c`。默认只 sync make 路线需要的项目来省磁盘，
需要更多项目（比如 `common-modules/virtual-device`）就在 `config.yml` 的 `sync.projects` 里加：

```yaml
sync:
  projects:
    - common
    - build/kernel
    - prebuilts/clang/host/linux-x86
    - prebuilts/build-tools
    - prebuilts/kernel-build-tools
    - common-modules/virtual-device
```

留空 = 用内置默认集合（`common` / `build/kernel` / 三个 `prebuilts`）。

## 支持的 manifest 分支

`config.yml` 里 `manifest.branch` 可换（Google `kernel/manifest` 的真实分支），
换它就用对应版本的 prebuilts；`kernel.repo` / `kernel.branch` 指向你自己维护的对应内核：

| manifest 分支 | 内核 | 自带 clang |
|---|---|---|
| `common-android13-5.15` | 5.15 | `r450784e` |
| `common-android14-5.15` | 5.15 | — |
| `common-android14-6.1` | 6.1 | — |
| `common-android15-6.6` | 6.6 | — |
| `common-android16-6.12` | 6.12 | — |
| **`common-android17-6.18`**（当前） | 6.18 | `r584948c` |

换 manifest 时记得同步改 `toolchain.clang_version`（走 prebuilts 里实际存在的版本）。

还有带日期的快照分支（`common-android13-5.15-2023-01` 这类），manifest 里每个 project
都钉了 SHA，适合要和某个时间点完全对齐的场景。

## 产物

构建成功后 artifact 里有：

- `Image` —— 原始内核镜像（若存在还会带 `Image.gz` / `dtb` / `dtbo`）
- `AnyKernel3.zip` —— 可在 recovery / KernelSU 里直接刷的包，模板取自仓库的 [`ak3/`](ak3/)
- `kernel.config` —— 实际生效的完整 `.config`，便于复查

## 本地跑

```bash
python3 scripts/parse_config.py config.yml --shell         # 校验 + 看解析结果
python3 scripts/parse_config.py config.yml --config-list   # 看会被写进 .config 的项
bash -n scripts/build.sh                                   # 语法检查
```

`scripts/build.sh` 也可以在本地跑完整流程，需要 git / make / curl / python3(PyYAML)
以及 `bison` / `flex` / `pahole`（kconfig 与 BTF 用），会自动下载 `repo` 工具，
并且要拉得动 `android.googlesource.com`（prebuilts）和你自己 `kernel.repo` 指向的仓库。
pahole 会优先用 repo 同步下来的 `prebuilts/kernel-build-tools/linux_musl-x86/bin/pahole`。

## 工作原理

```
config.yml ──► parse_config.py ──► 校验 ──► build.sh
                                                │
   1. 装 repo 工具                              │
   2. repo init -u <manifest.repo> -b <manifest.branch> ◄─┘
      ├─ 写 local_manifests/kernel-common.xml：common 换成自己的 fork
      └─ repo sync（只拉需要的项目）
   3. 读 CLANG_VERSION，清掉用不到的历史 clang 版本省磁盘
   4. patches/*.patch 按序 git apply --check 后应用到 common/
   5. gki_defconfig → scripts/config → olddefconfig → 回读校验
   6. make Image
   7. 用仓库自带的 ak3/ 打包 Image → dist/AnyKernel3.zip → upload-artifact
```

CI 侧还会先回收 runner 磁盘（只保证 14GB，不够）并加 16GB swap（防链接阶段 OOM），
`.repo/project-objects` 用 `actions/cache` 缓存以加速后续 sync。

## 许可

内核源码遵循其自身的 GPL-2.0；本仓库的脚本与配置可自由使用。
