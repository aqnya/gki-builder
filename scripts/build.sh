#!/usr/bin/env bash
# gki-builder 编译主流程：
#   repo init/sync 拉源码 -> 打补丁 -> 生成 .config -> make Image -> 打包
#
# 源码走 Android 官方的 repo 工具（manifest 里已包含所需的 clang 与构建工具），
# 所有可调项都在 config.yml；本脚本只负责执行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

# repo sync 默认只拉 make 路线需要的项目（省磁盘/时间）。
# 要更多项目（如 virtual-device）在 config.yml 的 sync.projects 里加。
DEFAULT_SYNC_PROJECTS=(
  common
  build/kernel
  prebuilts/clang/host/linux-x86
  prebuilts/build-tools
  prebuilts/kernel-build-tools
  kernel/configs
)

die() { echo "::error::$*" >&2; exit 1; }
info() { echo "==> $*"; }
note() { echo "    $*"; }

command -v git   >/dev/null || die "缺少 git"
command -v make  >/dev/null || die "缺少 make"
command -v curl  >/dev/null || die "缺少 curl"
python3 -c "import yaml" 2>/dev/null || die "缺少 PyYAML（pip install pyyaml）"

# ---------------------------------------------------------------- 读配置
eval "$(python3 "$ROOT/scripts/parse_config.py" "$ROOT/config.yml" --shell)"
python3 "$ROOT/scripts/parse_config.py" "$ROOT/config.yml" --config-list > "$ROOT/.config.list.tmp" \
  || die "config.yml 校验失败"
CONFIG_LIST="$ROOT/.config.list.tmp"
trap 'rm -f "$CONFIG_LIST"' EXIT

if [[ -n "${SYNC_PROJECTS:-}" ]]; then
  read -r -a PROJECTS <<< "$SYNC_PROJECTS"
else
  PROJECTS=("${DEFAULT_SYNC_PROJECTS[@]}")
fi

WORK="$ROOT/.work"
SRC="$WORK/src"                 # repo 工作区
KERNEL_SRC="$SRC/common"        # kernel/common 在 manifest 里的 path
OUT="$WORK/out"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$DIST"

summary_lines=()

# ------------------------------------------------------------ 0. repo 工具
ensure_repo() {
  if command -v repo >/dev/null; then
    note "repo 已存在：$(command -v repo)"
    return
  fi
  info "安装 repo 工具"
  mkdir -p "$HOME/bin"
  curl -fsSL --retry 3 -o "$HOME/bin/repo" \
    https://storage.googleapis.com/git-repo-downloads/repo \
    || die "下载 repo 工具失败"
  chmod +x "$HOME/bin/repo"
  export PATH="$HOME/bin:$PATH"
  command -v repo >/dev/null || die "repo 安装后仍不可用"
}

# -------------------------------------------------------- 1. repo 同步源码
sync_source() {
  info "repo 同步：$KERNEL_REPO @ $KERNEL_BRANCH"
  mkdir -p "$SRC"

  # repo 会在很多子目录里跑 git，先放开所有权检查
  git config --global --add safe.directory '*' >/dev/null 2>&1 || true
  git config --global user.email  "gki-builder@localhost" >/dev/null 2>&1 || true
  git config --global user.name   "gki-builder"           >/dev/null 2>&1 || true

  (
    cd "$SRC"
    repo init -u "$KERNEL_REPO" -b "$KERNEL_BRANCH" \
      --no-clone-bundle --quiet --depth=1 \
      || die "repo init 失败（检查 kernel.repo / kernel.branch）"

    local pin="$SRC/.repo/local_manifests/pin-kernel-common.xml"
    mkdir -p "$SRC/.repo/local_manifests"
    if [[ -n "$KERNEL_COMMIT" ]]; then
      note "钉死 kernel/common -> $KERNEL_COMMIT"
      cat > "$pin" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="kernel/common"/>
  <project path="common" name="kernel/common" revision="$KERNEL_COMMIT"/>
</manifest>
XML
    else
      note "未指定 commit，使用 manifest 给出的 revision"
      rm -f "$pin"
    fi

    info "repo sync（${#PROJECTS[@]} 个项目）"
    repo sync --no-clone-bundle --prune -j"$(nproc)" "${PROJECTS[@]}" \
      || die "repo sync 失败"
  )

  [[ -d "$KERNEL_SRC" ]] || die "同步后找不到内核源码目录：$KERNEL_SRC"

  # 安全网：local manifest 的 revision 若没被 sync 取到，手动补一次
  if [[ -n "$KERNEL_COMMIT" ]]; then
    local head
    head="$(git -C "$KERNEL_SRC" rev-parse HEAD)"
    if [[ "$head" != "$KERNEL_COMMIT" ]]; then
      note "HEAD($head) 与目标不同，尝试直接 fetch"
      git -C "$KERNEL_SRC" fetch --depth=1 origin "$KERNEL_COMMIT" \
        || git -C "$KERNEL_SRC" fetch origin "$KERNEL_COMMIT" \
        || die "无法取得 commit $KERNEL_COMMIT"
      git -C "$KERNEL_SRC" checkout -q "$KERNEL_COMMIT" \
        || die "commit $KERNEL_COMMIT 无法 checkout"
    fi
  fi

  KERNEL_SHA="$(git -C "$KERNEL_SRC" rev-parse HEAD)"
  info "kernel/common HEAD = $KERNEL_SHA"
  summary_lines+=("| 内核 commit | \`$KERNEL_SHA\` |")
  summary_lines+=("| manifest 分支 | \`$KERNEL_BRANCH\` |")
}

# ------------------------------------------------------------ 2. 工具链
# 工具链由 manifest 的 prebuilts/clang/host/linux-x86 提供，这里只负责
# 把版本号读出来（用于 PATH、磁盘清理和日志）。
resolve_clang_version() {
  if [[ -n "$TOOLCHAIN_CLANG_VERSION" ]]; then
    CLANG_VERSION="$TOOLCHAIN_CLANG_VERSION"
    note "使用 config.yml 指定的 clang: $CLANG_VERSION"
  else
    local consts="$KERNEL_SRC/build.config.constants"
    [[ -f "$consts" ]] || die "内核树缺少 build.config.constants，无法推断 clang 版本"
    CLANG_VERSION="$(sed -n 's/^CLANG_VERSION=//p' "$consts" | head -1 | tr -d '[:space:]')"
    [[ -n "$CLANG_VERSION" ]] || die "build.config.constants 中未找到 CLANG_VERSION"
    note "从内核树读取 clang: $CLANG_VERSION"
  fi

  CLANG_BIN="$SRC/prebuilts/clang/host/linux-x86/clang-$CLANG_VERSION/bin"
  [[ -x "$CLANG_BIN/clang" ]] || die "找不到可执行的 clang：
期望路径: $CLANG_BIN/clang
请确认 sync.projects 包含 prebuilts/clang/host/linux-x86，
或在 config.yml 的 toolchain.clang_version 里填对版本。"

  # prebuilts/clang 仓库带很多历史版本，只留本次用的，省磁盘
  local base="$SRC/prebuilts/clang/host/linux-x86" d
  for d in "$base"/clang-*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" == "clang-$CLANG_VERSION" ]] && continue
    rm -rf "$d"
  done

  export CLANG_VERSION CLANG_BIN
  summary_lines+=("| clang | \`$CLANG_VERSION\` |")
}

# 把 repo 工作区里的工具放进 PATH（版本来自 build.config.common 的约定）
setup_path() {
  local p
  for p in \
    "$CLANG_BIN" \
    "$SRC/build/kernel/build-tools/path/linux-x86" \
    "$SRC/prebuilts/build-tools/path/linux-x86" \
    "$SRC/prebuilts/kernel-build-tools"
  do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
  done
  command -v clang >/dev/null || die "PATH 中没有 clang（$CLANG_BIN）"
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

  info "应用 ${#files[@]} 个补丁到 common/"
  local p name
  for p in "${files[@]}"; do
    name="$(basename "$p")"
    # 先 --check 试打，避免留下半打补丁的树；git apply 默认 -p1，上下文严格匹配
    if git -C "$KERNEL_SRC" apply --check "$p" >/dev/null 2>&1; then
      git -C "$KERNEL_SRC" apply "$p" >/dev/null
      note "已应用 $name"
      count=$((count + 1))
    elif git -C "$KERNEL_SRC" apply -R --check "$p" >/dev/null 2>&1; then
      note "跳过 $name（已应用过）"
    else
      echo "::group::补丁失败详情：$name"
      git -C "$KERNEL_SRC" apply --check "$p" 2>&1 | tail -40 || true
      echo "::endgroup::"
      die "补丁 $name 无法应用。已回滚（--check 失败，源码树未被改动）。"
    fi
  done
  git -C "$KERNEL_SRC" add .
  git -C "$KERNEL_SRC" commit -m "no-dirty "
  summary_lines+=("| 补丁 | $count |")
}

# ------------------------------------------------------ 4. 生成并校验 .config
MAKE_ARGS=(ARCH="$ARCH" LLVM=1 LLVM_IAS=1 O="$OUT")

generate_config() {
  info "生成 $DEFCONFIG"
  make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" "$DEFCONFIG" >/dev/null

  if [[ -s "$CONFIG_LIST" ]]; then
    info "应用 config.yml 中的 $(wc -l < "$CONFIG_LIST" | tr -d ' ') 项开关"
    local sym val
    while IFS=$'\t' read -r sym val; do
      [[ -n "$sym" ]] || continue
      case "$val" in
        y) bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --enable  "$sym" ;;
        n) bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --disable "$sym" ;;
        m) bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --module  "$sym" ;;
        *)
          if [[ "$val" =~ ^-?[0-9]+$ || "$val" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
            bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --set-val "$sym" "$val"
          else
            bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --set-str "$sym" "$val"
          fi
          ;;
      esac
    done < "$CONFIG_LIST"
  else
    info "config.yml 未指定任何开关"
  fi

  # scripts/config 不校验 Kconfig —— 依赖不满足的符号会被 olddefconfig 静默丢弃。
  info "make olddefconfig 消解依赖"
  make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" olddefconfig >/dev/null
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
    actual="$(bash "$KERNEL_SRC/scripts/config" --file "$OUT/.config" --state "$sym" 2>/dev/null || echo undef)"

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

# ------------------------------------------------- 4.5 ABI 布局护栏（第二类变砖）
# check_kmi 只看「符号还在不在」。但厂商模块是拿 gki_defconfig（一批看着像调试的项
# 全是 =y）的头文件编译的，struct 里的字段偏移已经被烤进 .ko。关掉这些 CONFIG 会
# 删掉结构体成员 → 后面所有字段偏移前移 → 模块读野指针 → 卡 logo 且无 panic、无日志，
# 而符号一个没少，所以 KMI 护栏会全绿放行（2026-09-23 第三次卡 logo 就是这么来的）。
# 这一步在**编译之前**跑（省 30 分钟），要求名单里的项与 gki_defconfig 取值一致。
check_abi_pinned() {
  local list="$ROOT/scripts/abi-pinned-configs.txt"
  local defconfig="$KERNEL_SRC/arch/$ARCH/configs/$DEFCONFIG"
  [[ -f "$list" ]] || die "找不到 ABI 布局名单 $list"
  [[ -f "$defconfig" ]] || die "找不到 defconfig $defconfig"
  [[ -s "$CONFIG_LIST" ]] || { summary_lines+=("| ABI 布局护栏 | ✅ config.yml 未改任何开关 |"); return 0; }

  info "ABI 布局护栏：检查有没有动到模块可见结构体里的 CONFIG"
  local sym _rest want base checked=0
  local -a bad=()
  while read -r sym _rest; do
    [[ -z "$sym" || "$sym" == \#* ]] && continue
    # config.yml 没提这一项 -> 没动它，安全
    want="$(awk -F'\t' -v s="$sym" '$1 == s { print $2 }' "$CONFIG_LIST")"
    [[ -n "$want" ]] || continue
    base="$(bash "$KERNEL_SRC/scripts/config" --file "$defconfig" --state "$sym" 2>/dev/null || echo undef)"
    checked=$((checked + 1))
    [[ "$want" == "$base" ]] || bad+=("$sym：gki_defconfig=$base，config.yml=$want")
  done < "$list"

  if (( ${#bad[@]} > 0 )); then
    {
      echo "::error::config.yml 改了 ABI 布局红线名单里的开关，刷进去会卡 logo："
      printf '  - %s\n' "${bad[@]}"
      echo
      echo "原因：这些 CONFIG 出现在 include/ 里模块可见结构体（task_struct 等）的定义内部，"
      echo "      关掉会删掉结构体成员、把后面所有字段的偏移整体前移，"
      echo "      而厂商模块的偏移是编译期烤进 .ko 的 —— 符号一个不少，但读出来的是野指针。"
      echo "      名单与判定方法见 scripts/abi-pinned-configs.txt。"
    } >&2
    exit 1
  fi

  note "ABI 布局护栏：config.yml 动了 $checked 项，全部不在红线名单内"
  summary_lines+=("| ABI 布局护栏 | ✅ 未触碰模块可见结构体的布局（名单 $checked 项已核对） |")
}

# ------------------------------------------------------------ 5. 编译
build_image() {
  info "编译 Image（$(nproc) 线程）"
  export KBUILD_BUILD_USER="gki-builder" KBUILD_BUILD_HOST="ci"
  make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" -j"$(nproc)" Image
  [[ -f "$OUT/arch/$ARCH/boot/Image" ]] || die "编译结束但找不到 Image"
}

# ------------------------------------------------- 5.5 KMI 护栏（防刷机变砖）
# 设备上 293 个厂商模块一共 import 了 2329 个内核符号（名单见
# scripts/kmi-required-symbols.txt）。少任何一个，对应模块就会 insmod 失败：
# qce50_dlkm 起不来 /data 就解不开密，msm_kgsl 起不来就没有显示 ——
# 表现是「卡 logo 不开机」，而且不是 panic，抓不到崩溃日志，只能靠二分。
# 这一步把「刷了才知道炸」提前成「构建就报错」。
# 紧急绕过（不推荐）：SKIP_KMI_CHECK=1
check_kmi() {
  if [[ "${SKIP_KMI_CHECK:-}" == "1" ]]; then
    echo "::warning::SKIP_KMI_CHECK=1，已跳过 KMI 护栏（若删了厂商模块依赖的符号，会不开机）"
    summary_lines+=("| KMI 护栏 | ⚠️ 被 SKIP_KMI_CHECK 跳过 |")
    return 0
  fi

  local vmlinux="$OUT/vmlinux" list="$ROOT/scripts/kmi-required-symbols.txt"
  [[ -f "$vmlinux" ]] || die "找不到 $vmlinux，无法做 KMI 校验"
  [[ -f "$list" ]]    || die "找不到 KMI 护栏名单 $list"

  info "KMI 护栏：校验厂商模块依赖的符号是否都还在"
  local out rc=0
  out="$(python3 "$ROOT/scripts/kmi_check.py" "$vmlinux" "$list" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" >&2
    die "KMI 护栏未通过 —— 本次改动删掉了厂商模块依赖的内核符号，刷进去会不开机"
  fi

  note "$(printf '%s\n' "$out" | head -1)"
  summary_lines+=("| KMI 护栏 | ✅ $(grep -cv '^[[:space:]]*#' "$list") 个厂商依赖符号齐全 |")
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
  ensure_repo
  sync_source
  resolve_clang_version
  setup_path
  apply_patches
  generate_config
  verify_config
  check_abi_pinned
  build_image
  check_kmi
  package
  write_summary
  info "完成，产物在 $DIST"
}

main "$@"
