# gki-builder

在 GitHub Actions 上编译 Android GKI 内核。全部可调项集中在两个地方：

| 你想做的事 | 改哪里 |
|---|---|
| 开关内核 config | [`config.yml`](config.yml) 的 `config:` |
| 指定编译哪个 commit | [`config.yml`](config.yml) 的 `kernel.commit` |
| 加补丁 | 丢进 [`patches/`](patches/) |

改完推到 `main`（且改动命中 `config.yml` 或 `patches/**`）会自动编译，
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
  branch: android13-5.15
  commit: ""            # 留空 = 分支最新
  # commit: "e6654bf2f6c2c3c7b6af8897baa2a86991d3b5ac"   # 精确钉死
```

`commit` 是唯一的 commit 来源（40 位 SHA，或留空用分支 tip）。填 SHA 能保证可复现，
也避免分支 tip 漂移导致刷入后 vermagic 对不上、vendor 模块加载失败。

查 SHA：

```bash
git ls-remote https://android.googlesource.com/kernel/common refs/heads/android13-5.15
```

> ⚠️ 分支名是 `android13-5.15`，**没有 `common-` 前缀**。
> `common-android13-5.15` 是 `kernel/manifest` 的分支名，拿来 clone `kernel/common` 会 404。

### 3. 放补丁

见 [`patches/README.md`](patches/README.md)。零填充文件名控制顺序，`fuzz` 默认 0（严格）。

## 支持的分支

`config.yml` 里 `kernel.branch` 可换（`kernel/common` 仓库的真实分支）：

| 分支 | 内核 | clang |
|---|---|---|
| `android13-5.15` | 5.15 | `r450784e` |
| `android14-5.15` | 5.15 | `r487747c` |
| `android14-6.1` | 6.1 | `r487747c` |
| `android15-6.6` | 6.6 | `r510928` |
| `android16-6.12` | 6.12 | `r536225` |

clang 版本默认从内核树的 `build.config.constants` 自动读取，一般不用管。
换分支后如果工具链下载失败，多半是该版本不在候选的 prebuilts 分支里，
在 `toolchain.clang_branch` 填上它所在的分支即可（例如 `master-kernel-build-2022`）。

## 产物

构建成功后 artifact 里有：

- `Image` —— 原始内核镜像（若存在还会带 `Image.gz` / `dtb` / `dtbo`）
- `AnyKernel3.zip` —— 可在 recovery / KernelSU 里直接刷的包
- `kernel.config` —— 实际生效的完整 `.config`，便于复查

## 本地跑

```bash
python3 scripts/parse_config.py config.yml --shell         # 校验 + 看解析结果
python3 scripts/parse_config.py config.yml --config-list   # 看会被写进 .config 的项
bash -n scripts/build.sh                                   # 语法检查
```

`scripts/build.sh` 也可以在本地跑完整流程，但需要 git / make / patch / curl / PyYAML，
且要拉得动 `android.googlesource.com`。

## 工作原理

```
config.yml ──► parse_config.py ──► 校验 ──► build.sh
                                                │
   1. clone kernel/common @ commit/branch ◄─────┘
   2. 下载 AOSP clang（按 CLANG_VERSION，空包防线）
   3. patches/*.patch 按序 dry-run 后应用
   4. gki_defconfig → scripts/config → olddefconfig → 回读校验
   5. make Image
   6. 打包 Image + AnyKernel3.zip → upload-artifact
```

CI 侧还会先回收 runner 磁盘（只保证 14GB，不够）并加 16GB swap（防链接阶段 OOM），
clang 用 `actions/cache` 缓存。

## 许可

内核源码遵循其自身的 GPL-2.0；本仓库的脚本与配置可自由使用。
