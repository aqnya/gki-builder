# gki-builder

在 GitHub Actions 上用 Android 官方的 **`repo`** 工具同步并编译 GKI 内核。
全部可调项集中在两个地方：

| 你想做的事 | 改哪里 |
|---|---|
| 开关内核 config | [`config.yml`](config.yml) 的 `config:` |
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

### 2. 指定编译的 commit

```yaml
kernel:
  branch: common-android13-5.15
  commit: ""            # 留空 = manifest 给出的 revision（分支 tip）
  # commit: "77804d3596695c7b85fe038c81d9580283ffd2ca"   # 精确钉死
```

`commit` 是唯一的 commit 来源（40 位 SHA，或留空）。钉住的是 **`kernel/common` 的 SHA**。

实现方式是 `repo init` 之后写一个 local manifest，把 `kernel/common` 的 revision
换成你给的 SHA，再 `repo sync`；同步后还会校验一次 `git rev-parse HEAD` 是否吻合。

填 SHA 能保证可复现，也避免分支 tip 漂移导致 vermagic 对不上、vendor 模块加载失败。
查当前 tip：

```bash
git ls-remote https://android.googlesource.com/kernel/common refs/heads/android13-5.15
```

> ⚠️ **两套分支名，前缀规则相反，别搞混：**
>
> | 用在哪 | 分支名 | 例 |
> |---|---|---|
> | `repo init -b`（`kernel/manifest`） | **带** `common-` 前缀 | `common-android13-5.15` |
> | `kernel/common` 的 project revision | **不带**前缀 | `android13-5.15` |
>
> `config.yml` 里 `kernel.repo` / `kernel.branch` 填的是 **manifest** 那一套。

### 3. 放补丁

见 [`patches/README.md`](patches/README.md)。零填充文件名控制顺序，补丁打在 `common/` 目录上，
用 `git apply` 严格匹配（无 fuzz，上下文必须逐行命中）。

### 4. 改刷机包（AK3）

打包用的 AnyKernel3 模板就在仓库的 [`ak3/`](ak3/) 里，**构建时不再去 clone 上游**——
`ak3/anykernel.sh` 就是你改的那份，直接编辑并提交即可（改动会命中 `ak3/**`，自动触发编译）。

至少要改这两处，否则刷到真机上会被 devicecheck 拦下：

```sh
# ak3/anykernel.sh
properties() { '
kernel.string=...            # 每次构建会被自动覆盖成 GKI <branch> (<sha12>)
do.devicecheck=1             # 1 = 校验设备名，填错就直接拒绝安装
device.name1=你的设备代号      # 上游示例是 maguro/toro/toroplus/tuna
'; }

BLOCK=/dev/block/by-name/boot;   # 上游示例是 omap 的路径，GKI 设备一般是 by-name
```

其它可改的：`do.modules`（要不要刷 modules）、`do.systemless`、`do.cleanup`、
`ramdisk/`（overlay.d 里要放的文件）、`patch/`（要打进 ramdisk 的补丁）。
详细说明见上游仓库 [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)。

> 构建时会 `cp -a ak3/ .work/AnyKernel3` 再往里塞 `Image`，所以仓库里的 `ak3/` 一直是干净的。

## 源码怎么来的

用 `repo` 而不是裸 `git clone`：

```bash
repo init -u https://android.googlesource.com/kernel/manifest -b common-android13-5.15
repo sync common build/kernel prebuilts/clang/host/linux-x86 ...
```

这样 clang、build-tools 等工具链会跟着 manifest 一起到位，版本也和内核树配套
（`common/build.config.constants` 里的 `CLANG_VERSION`）。默认只 sync make 路线需要的项目来省磁盘，
需要更多项目（比如 `common-modules/virtual-device`）就在 `config.yml` 的 `sync.projects` 里加：

```yaml
sync:
  projects:
    - common
    - build/kernel
    - prebuilts/clang/host/linux-x86
    - prebuilts/build-tools
    - prebuilts/kernel-build-tools
    - kernel/configs
    - common-modules/virtual-device
```

留空 = 用内置默认集合。

## 支持的 manifest 分支

`config.yml` 里 `kernel.branch` 可换（`kernel/manifest` 的真实分支）：

| manifest 分支 | 内核 | kernel/common 分支 |
|---|---|---|
| `common-android13-5.15` | 5.15 | `android13-5.15` |
| `common-android14-5.15` | 5.15 | `android14-5.15` |
| `common-android14-6.1` | 6.1 | `android14-6.1` |
| `common-android15-6.6` | 6.6 | `android15-6.6` |

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

`scripts/build.sh` 也可以在本地跑完整流程，需要 git / make / curl / python3(PyYAML)，
会自动下载 `repo` 工具，并且要拉得动 `android.googlesource.com`。

## 工作原理

```
config.yml ──► parse_config.py ──► 校验 ──► build.sh
                                                │
   1. 装 repo 工具                              │
   2. repo init -u <manifest> -b <branch> ◄─────┘
      ├─ 有 commit 就写 local_manifests/pin-kernel-common.xml
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
