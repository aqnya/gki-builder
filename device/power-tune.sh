#!/system/bin/sh
# gki-builder 设备侧省电工具（不动任何持久化设置，重启即恢复）
#
#   su -c 'sh power-tune.sh report'   只读诊断：谁在刷日志 + 当前旋钮状态
#   su -c 'sh power-tune.sh apply'    关掉纯观测/统计类开销（可 revert）
#   su -c 'sh power-tune.sh revert'   恢复 apply 之前的值
#
# 为什么重点看日志：内核 config 那些调试项合计也就 1~3% 的差别，而 SELinux
# 拒绝风暴（被拒 → 重试 → 再被拒）是**整夜唤醒 CPU + logd 落盘**，量级完全不同。
# 所以先 report 看来源，再决定 apply。

set -u

WATCHDOG=/proc/sys/kernel/watchdog
SCHEDSTATS=/proc/sys/kernel/sched_schedstats
KFENCE=/sys/module/kfence/parameters/sample_interval
CPUIDLE=/sys/devices/system/cpu/cpuidle/current_governor
BAK=/data/local/tmp/.power-tune.bak

cat_val() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "n/a"; }

set_val() {  # $1=路径 $2=值
  if [ ! -e "$1" ]; then echo "    跳过 $1（不存在）"; return 0; fi
  if echo "$2" > "$1" 2>/dev/null; then
    echo "    $1 = $(cat_val "$1")"
  else
    echo "    写入失败 $1（需要 root？）"
  fi
}

report_rate() {
  last=$(dmesg 2>/dev/null | tail -1 | sed -n 's/^\[ *\([0-9]*\)\..*/\1/p')
  total=$(dmesg 2>/dev/null | wc -l | tr -d ' ')
  recent=$(dmesg 2>/dev/null | sed -n 's/^\[ *\([0-9]*\)\..*/\1/p' \
           | awk -v t="${last:-0}" '$1 >= t-10' | wc -l | tr -d ' ')
  echo "  kmsg 缓冲 $total 行；最近 10 秒 $recent 行（≈ $((recent / 10)) 行/秒；一天 ≈ $((recent * 8640)) 行）"
}

report_denials() {
  echo "  按来源进程："
  dmesg 2>/dev/null | sed -n 's/.*avc:  denied.*comm="\([^"]*\)".*/\1/p' \
    | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
  echo "  按被拒目标："
  dmesg 2>/dev/null | sed -n 's/.*avc:  denied *{[^}]*}.*tcontext=\([^ :]*\):\([^ :]*\):\([^ ]*\).*/\2:\3/p' \
    | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
  echo "  按 来源域→目标:类别 {权限}（可直接据此写 dontaudit/allow）："
  dmesg 2>/dev/null \
    | sed -n 's/.*avc:  denied *{\([^}]*\)}.*scontext=\([^ ]*\) tcontext=\([^ ]*\) tclass=\([^ ]*\).*/\2 -> \3 :\4 {\1}/p' \
    | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
  echo "    （com.termux 多半是 su 工具自己在读 sysfs，不算真实负载）"
}

case "${1:-report}" in
  report)
    echo "== 日志活动 =="
    report_rate
    report_denials
    echo
    echo "== 统计/观测类旋钮 =="
    echo "  lockup 看门狗   $WATCHDOG      = $(cat_val "$WATCHDOG")   （1=开）"
    echo "  schedstats      $SCHEDSTATS    = $(cat_val "$SCHEDSTATS")"
    echo "  kfence 抽样     $KFENCE        = $(cat_val "$KFENCE")"
    echo
    echo "== 电源相关 =="
    echo "  cpuidle governor = $(cat_val "$CPUIDLE")   （本机是厂商的 qcom-cpu-lpm；若哪天变成 menu，可对比试 teo）"
    echo "  cpu0 governor    = $(cat_val /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
    echo "  mglru            = $(cat_val /sys/kernel/mm/lru_gen/enabled)  min_ttl_ms=$(cat_val /sys/kernel/mm/lru_gen/min_ttl_ms)"
    echo "  cmdline 相关项   = $(grep -oE 'kasan=[a-z]+|kfence[^ ]*|nowatchdog|init_on_[a-z]+=[01]' /proc/cmdline 2>/dev/null | tr '\n' ' ')"
    ;;

  apply)
    echo "== 记录原值到 $BAK =="
    { echo "WATCHDOG=$(cat_val "$WATCHDOG")"
      echo "SCHEDSTATS=$(cat_val "$SCHEDSTATS")"
      echo "KFENCE=$(cat_val "$KFENCE")"; } > "$BAK" 2>/dev/null
    cat "$BAK" 2>/dev/null | sed 's/^/    /'

    echo "== 关掉观测/统计开销 =="
    set_val "$WATCHDOG" 0      # 看门狗线程不再每 2s 醒来跑一遍
    set_val "$SCHEDSTATS" 0    # 不再每次调度记账
    set_val "$KFENCE" 0        # 不再抽样

    echo
    echo "已生效（重启后自动恢复；要立刻还原：revert）"
    echo "注意：看门狗关掉后，真卡死时就没有 lockup 报告了。"
    ;;

  revert)
    if [ ! -r "$BAK" ]; then echo "没有 $BAK，无法还原（可能没 apply 过）"; exit 1; fi
    echo "== 从 $BAK 还原 =="
    while IFS='=' read -r k v; do
      case "$k" in
        WATCHDOG)  set_val "$WATCHDOG" "$v" ;;
        SCHEDSTATS) set_val "$SCHEDSTATS" "$v" ;;
        KFENCE)    set_val "$KFENCE" "$v" ;;
      esac
    done < "$BAK"
    ;;

  *)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
