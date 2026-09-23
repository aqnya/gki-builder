# ak3/ —— 本项目实际使用的 AnyKernel3 模板

这份模板**跟着仓库走**：`scripts/build.sh` 打包时直接用它（`cp -a ak3/ .work/AnyKernel3` 再塞 `Image`），
不再去 clone 上游。改这里 = 改刷机包，改动命中 `ak3/**` 会自动触发编译。

- 上游：[osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- 基线 commit：`020dfeccf9d7e962a48400fc94d3e451df92eead`（2026-09-04，tools: update magisk utils to v31.0(31000) beta）
- 相对上游做过哪些改动：**记录在下面**（方便以后想同步上游时知道要保留什么）

## 这个模板必须先改的地方

`device.name*` 和 `BLOCK` 还是上游示例（maguro / omap），不改的话 devicecheck 会拒绝安装。
构建时如果检测到还是示例值，会打一条 `::warning::`。

```sh
# anykernel.sh
properties() { '
kernel.string=...            # 每次构建会被覆盖成 GKI <branch> (<sha12>)
device.name1=你的设备代号
'; }
BLOCK=/dev/block/by-name/boot;
```

## 本仓库对模板的改动

- （还没有）上游基线是原样引入的，改了就在这一节记一笔。

## 其它

- `kernel.string` 由 `scripts/build.sh` 每次构建写入，本地改的会被覆盖。
- `README.md` 不会打进 `AnyKernel3.zip`（上游发版也不带 README），`LICENSE` 会带上。
- 上游模板的完整说明见其仓库 README；本项目侧的用法见根目录 [README.md](../README.md) 第 4 节。
