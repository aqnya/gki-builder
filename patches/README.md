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

- 格式是标准 unified diff，用 **`-p1`** 层级（也就是 `git diff` / `diff -u a b`
  生成的那种，路径以 `a/` `b/` 开头，或不带前缀的仓库相对路径）。
- fuzz 默认为 `0`（`config.yml` 里 `patches.fuzz` 可调）。它是 `patch --fuzz` 的含义：
  **允许忽略的上下文行数**。`0` = 上下文必须逐行命中；填 `1`/`2`/`3` = 容忍邻近几行
  因别的改动而变化。
  它**不**控制补丁整体的位置漂移——补丁落在第几行 patch 自己会去搜，fuzz 管不到那里。

## 失败时会发生什么

每个补丁都会先 `patch --dry-run` 试打一次：

- 试打成功 → 真正应用
- 反向试打成功 → 判定「已经打过了」，跳过
- 两者都失败 → **构建立即失败**，打印冲突上下文，源码树保持干净（不会有半打补丁的状态）

所以补丁冲突一定能在 CI 里看见，不会被悄悄吞掉。

## 生成补丁

在内核源码树里改完后：

```bash
git -C .work/src/common diff > patches/0001-my-change.patch
# 或者想保留提交信息：
git -C .work/src/common format-patch -1 -o patches/
```

## 注意

GKI 有 KMI / ABI 符号约束。改动导出符号、`EXPORT_SYMBOL` 列表或
`android/abi_gki_*` 相关内容时，可能触发 ABI 检查失败——这类补丁通常需要
连带更新 symbol list，而不只是一个 `.patch` 文件。
