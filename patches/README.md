# patches/

> **本目录默认已清空。** 内核改动现在直接提交到 `config.yml` 里 `kernel.repo`
> 指向的自己维护的 fork，不再以补丁形式放在这里；CI 遇到 0 个补丁会直接跳过
> （`scripts/build.sh` 的 `apply_patches`）。
>
> 下面保留原补丁工作流的说明，以及 KMI / ABI 布局护栏文档（护栏与补丁无关，仍然生效）。

把内核补丁放到这里，CI 会在编译前按**文件名字典序**依次应用到内核源码树的
**`common/`** 目录（也就是 `kernel/common`，repo 同步后的工作区路径）。

## 规则

- 只认 `*.patch`，其它文件（含本 README）会被忽略。
- 按文件名排序，所以用零填充前缀保证顺序：

  ```
  0001-enable-foo.patch
  0002-fix-bar.patch
  0010-optional-later.patch
  ```

- 格式是标准 unified diff，用 **`-p1`** 层级（也就是 `git diff` / `git format-patch`
  生成的那种，路径以 `a/` `b/` 开头，或不带前缀的仓库相对路径）。
- 用 `git apply` 打补丁：**没有 fuzz，上下文必须逐行命中**（最严格）。
  邻近几行有别的改动也会失败——保持补丁基于当前树重新生成即可。

## 失败时会发生什么

每个补丁都会先 `git apply --check` 试打一次：

- 试打成功 → `git apply` 真正应用
- 反向试打成功（`git apply -R --check`）→ 判定「已经打过了」，跳过
- 两者都失败 → **构建立即失败**，打印冲突上下文，源码树保持干净（不会有半打补丁的状态）

所以补丁冲突一定能在 CI 里看见，不会被悄悄吞掉。

## 生成补丁

在内核源码树里改完后：

```bash
git -C .work/src/common diff > patches/0001-my-change.patch
# 或者想保留提交信息：
git -C .work/src/common format-patch -1 -o patches/
```

## 注意：KMI 符号约束（真的会把机器刷成砖）

GKI 内核之上跑着一堆**二进制**厂商模块（本机 `/vendor/lib/modules/` 有 293 个），
它们 import 的内核符号必须由 GKI 内核导出。**少一个，对应模块就 insmod 失败**，
而失败的是 qce50_dlkm（/data 的 FBE 解密）、msm_kgsl（显示）、cfg80211/rmnet
（WiFi/数据网）这种要命的东西 —— 表现是**卡 logo 不开机**。而且它不是 panic，
所以崩溃日志、`/data` 里的 crashlog 都抓不到，只能靠二分定位。

这不是理论：2026-09 的两次刷机失败就是这么来的（`CONFIG_KASAN=n` 丢掉了
`kasan_flag_enabled`）。

所以本仓库加了一道护栏：`scripts/build.sh` 的 **`check_kmi`** 步骤会在编译后拿
`vmlinux` 的导出符号（`__ksymtab_strings`）和 **`scripts/kmi-required-symbols.txt`**
（本机 293 个厂商模块真实依赖的 2329 个内核符号）比对，缺任何一个就 **FAIL**。
名单的来历和重新生成方法写在该文件头部。

改 `CONFIG_*` 或补丁时，护栏报错就是"这一改会不开机"，别用
`SKIP_KMI_CHECK=1` 绕过去 —— 那等于直接刷砖。

## 注意 #2：不只是符号 —— **结构体布局**变了照样变砖

上面那道护栏只保证「**符号**还在」。但厂商模块是二进制，**结构体里的字段偏移是
编译期烤进 .ko 的**：关掉一个出现在模块可见结构体定义里的 `CONFIG_*`，会删掉结构体
成员，让它后面**所有**字段的偏移整体前移，模块通过野指针读内存 → 卡 logo，
一样没有 panic、一样抓不到日志；而符号一个都没少，所以 KMI 护栏会全绿放行。

2026-09-23 实测（第三次卡 logo，护栏 0 缺失）：

| 关掉的项 | 后果 |
|---|---|
| `CONFIG_SCHEDSTATS` | `struct sched_statistics` 里 29 个 u64 全被 `#ifdef` 掉，而 `sched_entity` 里那个字段是无条件保留的 → `se` 之后每个字段前移约 **232 字节** |
| `CONFIG_TASK_XACCT` | `task_struct` 少 `acct_rss_mem1/acct_vm_mem1/acct_timexpd` → 前移 24 字节 |
| `CONFIG_PAGE_OWNER` | `task_struct` 少 `in_page_owner:1` 位域（位域共享存储单元，会影响同单元后续位域） |

所以有两条防线：

1. **`scripts/abi-pinned-configs.txt` + `build.sh` 的 `check_abi_pinned`**：
   在**编译之前**把 `config.yml` 里动过的项和 `gki_defconfig` 的取值比对，
   动了红线项立即 FAIL（省 30 分钟）。判定方法写在文件头：
   `grep -rn 'CONFIG_<该项>' include/` —— 只要它出现在某个 struct 定义内部，就不能动。
2. **`scripts/abi_layout.py`**：刷机前的深度验证，用 BTF 直接看结构体大小和成员偏移。
   设备上能开机的内核就有现成的参考：

   ```bash
   su -c 'cp /sys/kernel/btf/vmlinux /data/local/tmp/btf.ref'      # 参考：能开机的布局
   python3 scripts/abi_layout.py diff /data/local/tmp/btf.ref dist/Image   # 差异非空就别刷
   python3 scripts/abi_layout.py dump  /data/local/tmp/btf.ref task_struct # 看具体偏移
   ```

   这条比护栏更通用：名单只能挡已知的几个，BTF 比对能挡住**任何**布局改动。
