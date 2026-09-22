#!/usr/bin/env bash
# gki-builder 编译主流程：
#   clone 内核 -> 下载 AOSP clang -> 打补丁 -> 生成 .config -> make Image -> 打包
#
# 所有可调项都在 config.yml；本脚本只负责执行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export LC_ALL=C

# AOSP 预编译 clang 所在仓库；下载形如
#   $CLANG_REPO/+/refs/heads/<prebuilts分支>/clang-<版本>.tar.gz
CLANG_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"

die() { echo "::error::$*" >&2; exit 1; }
info() { echo "==> $*"; }
note() { echo "    $*"; }

command -v git >/dev/null || die "缺少 git"
command -v make >/dev/null || die "缺少 make"
command -v patch >/dev/null || die "缺少 patch"
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"
python3 -c "import yaml" 2>/dev/null || die "缺少 PyYAML（pip install pyyaml）"

# ---------------------------------------------------------------- 读配置
eval "$(python3 "$ROOT/scripts/parse_config.py" "$ROOT/config.yml" --shell)"
python3 "$ROOT/scripts/parse_config.py" "$ROOT/config.yml" --config-list > "$ROOT/.config.list.tmp" \
  || die "config.yml 校验失败"
CONFIG_LIST="$ROOT/.config.list.tmp"
trap 'rm -f "$CONFIG_LIST"' EXIT

WORK="$ROOT/.work"
KERNEL="$WORK/kernel"
OUT="$WORK/out"
DIST="$ROOT/dist"
TOOLCHAIN_ROOT="$ROOT/toolchain"
mkdir -p "$WORK" "$DIST" "$TOOLCHAIN_ROOT"

summary_lines=()

# ------------------------------------------------------------ 1. 拉源码
clone_kernel() {
  info "拉取内核源码：$KERNEL_REPO"
  rm -rf "$KERNEL"
  mkdir -p "$KERNEL"
  git -C "$KERNEL" init -q
  git -C "$KERNEL" remote add origin "$KERNEL_REPO"

  if [[ -n "$KERNEL_COMMIT" ]]; then
    note "钉死 commit: $KERNEL_COMMIT（分支 $KERNEL_BRANCH）"
    if git -C "$KERNEL" fetch -q --depth=1 origin "$KERNEL_COMMIT"; then
      git -C "$KERNEL" checkout -q FETCH_HEAD
    else
      note "按 SHA 直取失败，回退为拉分支再 checkout"
      git -C "$KERNEL" fetch -q --depth=1 origin "$KERNEL_BRANCH"
      git -C "$KERNEL" checkout -q FETCH_HEAD
      git -C "$KERNEL" fetch -q --unshallow origin 2>/dev/null \
        || note "unshallow 跳过（可能本就是完整仓库）"
      git -C "$KERNEL" checkout -q "$KERNEL_COMMIT" \
        || die "commit $KERNEL_COMMIT 不在分支 $KERNEL_BRANCH 上"
    fi
  else
    note "未指定 commit，编译分支最新：$KERNEL_BRANCH"
    git -C "$KERNEL" fetch -q --depth=1 origin "$KERNEL_BRANCH" \
      || die "拉取分支 $KERNEL_BRANCH 失败"
    git -C "$KERNEL" checkout -q FETCH_HEAD
  fi

  KERNEL_SHA="$(git -C "$KERNEL" rev-parse HEAD)"
  info "内核 HEAD = $KERNEL_SHA"
  summary_lines+=("| 内核 commit | \`$KERNEL_SHA\` |")
  summary_lines+=("| 分支 | \`$KERNEL_BRANCH\` |")
}

# ---------------------------------------------------------- 2. 工具链
resolve_clang_version() {
  if [[ -n "$TOOLCHAIN_CLANG_VERSION" ]]; then
    CLANG_VERSION="$TOOLCHAIN_CLANG_VERSION"
    note "使用 config.yml 指定的 clang: $CLANG_VERSION"
    return
  fi
  local consts="$KERNEL/build.config.constants"
  [[ -f "$consts" ]] || die "内核树缺少 build.config.constants，无法推断 clang 版本"
  CLANG_VERSION="$(sed -n 's/^CLANG_VERSION=//p' "$consts" | head -1 | tr -d '[:space:]')"
  [[ -n "$CLANG_VERSION" ]] || die "build.config.constants 中未找到 CLANG_VERSION"
  note "从内核树读取 clang: $CLANG_VERSION"
}

# AOSP 有些分支目录存在但内容是 ~165 字节占位空包（HTTP 200），
# 所以必须用 bin/clang 可执行来判定，而不是只看 HTTP 码。
fetch_clang() {
  local branch="$1" dest="$2" url tarball
  url="$CLANG_REPO/+/refs/heads/$branch/clang-$CLANG_VERSION.tar.gz"
  tarball="$WORK/clang.tar.gz"
  rm -rf "$dest"; mkdir -p "$dest"

  info "下载工具链：$branch / clang-$CLANG_VERSION"
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tarball" "$url"; then
    note "下载失败（分支 $branch 上无此版本）"
    return 1
  fi
  local size
  size="$(wc -c < "$tarball" | tr -d ' ')"
  if (( size < 1000000 )); then
    note "包只有 ${size} 字节 —— 是 AOSP 占位空包，跳过"
    rm -f "$tarball"; return 1
  fi
  tar -xzf "$tarball" -C "$dest"
  rm -f "$tarball"
  if [[ ! -x "$dest/bin/clang" ]]; then
    note "解压后没有可执行的 bin/clang —— 视为无效包"
    rm -rf "$dest"; return 1
  fi
  note "工具链就绪：$dest ($("$dest/bin/clang" --version | head -1))"
  return 0
}

setup_toolchain() {
  resolve_clang_version
  CLANG_BRANCH_USED=""
  CLANG_DIR="$TOOLCHAIN_ROOT/clang-$CLANG_VERSION"
  export CLANG_DIR CLANG_VERSION
  summary_lines+=("| clang | \`$CLANG_VERSION\` |")

  if [[ -x "$CLANG_DIR/bin/clang" ]]; then
    info "复用已缓存的工具链：$CLANG_DIR"
    return
  fi

  local candidates=()
  if [[ -n "$TOOLCHAIN_CLANG_BRANCH" ]]; then
    candidates=("$TOOLCHAIN_CLANG_BRANCH")
  else
    candidates=(
      master-kernel-build-2022
      main-kernel-build-2023
      main-kernel-build-2024
      main-kernel-build-2025
      main
    )
  fi

  local b
  for b in "${candidates[@]}"; do
    fetch_clang "$b" "$CLANG_DIR" && { CLANG_BRANCH_USED="$b"; break; }
  done

  [[ -x "$CLANG_DIR/bin/clang" ]] || die "未能获得可用的 clang-$CLANG_VERSION。
候选分支：${candidates[*]}
请在 config.yml 的 toolchain.clang_branch 里指定该版本所在的 AOSP prebuilts 分支。"

  summary_lines+=("| 工具链分支 | \`$CLANG_BRANCH_USED\` |")
}

# ------------------------------------------------------------ 3. 打补丁
apply_patches() {
  local dir="$ROOT/patches" count=0
  # glob 而非 find：少一个外部依赖，且 LC_ALL=C 下 glob 本身就是字典序
  # （0001- 会在 0002- 之前），正好是补丁需要的顺序。
  local files=()
  shopt -s nullglob
  files=("$dir"/*.patch)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    info "patches/ 下没有 .patch 文件，跳过"
    summary_lines+=("| 补丁 | 0 |")
    return
  fi

  info "应用 ${#files[@]} 个补丁（fuzz=$PATCH_FUZZ）"
  local p name
  for p in "${files[@]}"; do
    name="$(basename "$p")"
    # 先 dry-run，避免留下半打补丁的树
    if patch -d "$KERNEL" -p1 --fuzz="$PATCH_FUZZ" --dry-run --silent < "$p" >/dev/null 2>&1; then
      patch -d "$KERNEL" -p1 --fuzz="$PATCH_FUZZ" --silent < "$p" >/dev/null
      note "已应用 $name"
      count=$((count + 1))
    elif patch -d "$KERNEL" -p1 -R --fuzz="$PATCH_FUZZ" --dry-run --silent < "$p" >/dev/null 2>&1; then
      note "跳过 $name（已应用过）"
    else
      echo "::group::补丁失败详情：$name"
      patch -d "$KERNEL" -p1 --fuzz="$PATCH_FUZZ" --dry-run < "$p" 2>&1 | tail -40 || true
      echo "::endgroup::"
      die "补丁 $name 无法应用。已回滚（dry-run 失败，源码树未被改动）。"
    fi
  done
  summary_lines+=("| 补丁 | $count |")
}

# ------------------------------------------------------ 4. 生成并校验 .config
MAKE_ARGS=(ARCH="$ARCH" LLVM=1 LLVM_IAS=1 O="$OUT")

generate_config() {
  info "生成 $DEFCONFIG"
  make -C "$KERNEL" "${MAKE_ARGS[@]}" "$DEFCONFIG" >/dev/null

  if [[ -s "$CONFIG_LIST" ]]; then
    info "应用 config.yml 中的 $(wc -l < "$CONFIG_LIST" | tr -d ' ') 项开关"
    local sym val
    while IFS=$'\t' read -r sym val; do
      [[ -n "$sym" ]] || continue
      case "$val" in
        y) bash "$KERNEL/scripts/config" --file "$OUT/.config" --enable  "$sym" ;;
        n) bash "$KERNEL/scripts/config" --file "$OUT/.config" --disable "$sym" ;;
        m) bash "$KERNEL/scripts/config" --file "$OUT/.config" --module  "$sym" ;;
        *)
          if [[ "$val" =~ ^-?[0-9]+$ || "$val" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
            bash "$KERNEL/scripts/config" --file "$OUT/.config" --set-val "$sym" "$val"
          else
            bash "$KERNEL/scripts/config" --file "$OUT/.config" --set-str "$sym" "$val"
          fi
          ;;
      esac
    done < "$CONFIG_LIST"
  else
    info "config.yml 未指定任何开关"
  fi

  # scripts/config 不校验 Kconfig —— 依赖不满足的符号会被 olddefconfig 静默丢弃。
  info "make olddefconfig 消解依赖"
  make -C "$KERNEL" "${MAKE_ARGS[@]}" olddefconfig >/dev/null
}

# 逐条回读，把「想要的」和「实际得到的」比对；有差异就明确报错。
verify_config() {
  [[ -s "$CONFIG_LIST" ]] || { summary_lines+=("| config 开关 | 0（全部按 defconfig） |"); return; }

  local sym val actual failures=() ok=0
  local -a details=()
  while IFS=$'\t' read -r sym val; do
    [[ -n "$sym" ]] || continue
    # 直接复用内核自己的 --state 解析，别自己再剥一遍引号：
    #   "# X is not set" -> n ;  "X=value" -> 去引号的 value ;  不存在 -> undef
    actual="$(bash "$KERNEL/scripts/config" --file "$OUT/.config" --state "$sym" 2>/dev/null || echo undef)"

    if [[ "$actual" == "$val" ]]; then
      ok=$((ok + 1))
      details+=("  ✅ $sym = $actual")
    else
      failures+=("$sym：期望 $val，实际 $actual")
      details+=("  ❌ $sym：期望 $val，实际 $actual")
    fi
  done < "$CONFIG_LIST"

  echo "::group::config 回读校验"
  printf '%s\n' "${details[@]}"
  echo "::endgroup::"

  summary_lines+=("| config 开关 | ${ok} 成功 / ${#failures[@]} 失败 |")

  if (( ${#failures[@]} > 0 )); then
    {
      echo "::error::以下 config 开关未能生效（多半是 Kconfig 依赖不满足，被 olddefconfig 丢弃，或符号名不存在）："
      printf '  - %s\n' "${failures[@]}"
    } >&2
    exit 1
  fi
}

# ------------------------------------------------------------ 5. 编译
build_image() {
  info "编译 Image（$(nproc) 线程）"
  export PATH="$CLANG_DIR/bin:$PATH"
  export KBUILD_BUILD_USER="gki-builder" KBUILD_BUILD_HOST="ci"
  make -C "$KERNEL" "${MAKE_ARGS[@]}" -j"$(nproc)" Image
  [[ -f "$OUT/arch/$ARCH/boot/Image" ]] || die "编译结束但找不到 Image"
}

# ------------------------------------------------------------ 6. 打包
package() {
  info "收集产物"
  local boot="$OUT/arch/$ARCH/boot"
  cp "$boot/Image" "$DIST/Image"
  local extra
  for extra in Image.gz Image.lz4 dtb dtbo.img; do
    [[ -f "$boot/$extra" ]] && cp "$boot/$extra" "$DIST/" || true
  done
  cp "$OUT/.config" "$DIST/kernel.config"

  info "打包 AnyKernel3"
  local ak3="$WORK/AnyKernel3"
  rm -rf "$ak3"
  git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$ak3" \
    || die "克隆 AnyKernel3 失败"
  cp "$DIST/Image" "$ak3/Image"
  sed -i "s/^kernel.string=.*/kernel.string=GKI ${KERNEL_BRANCH} (${KERNEL_SHA:0:12})/" \
    "$ak3/anykernel.sh" 2>/dev/null || true

  if ! command -v zip >/dev/null; then
    info "安装 zip"
    sudo apt-get update -qq && sudo apt-get install -y -qq zip
  fi
  ( cd "$ak3" && rm -f "$DIST/AnyKernel3.zip" && zip -qr9 "$DIST/AnyKernel3.zip" . -x '*.git*' )

  [[ -s "$DIST/AnyKernel3.zip" ]] || die "AnyKernel3.zip 生成失败"
  summary_lines+=("| 产物 | \`Image\` + \`AnyKernel3.zip\` |")
}

write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## GKI 构建结果"
    echo ""
    echo "| 项 | 值 |"
    echo "|---|---|"
    printf '%s\n' "${summary_lines[@]}"
    echo ""
    echo '```'
    ls -lh "$DIST"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
}

main() {
  clone_kernel
  setup_toolchain
  apply_patches
  generate_config
  verify_config
  build_image
  package
  write_summary
  info "完成，产物在 $DIST"
}

main "$@"
