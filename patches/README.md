# patches/

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
