# ak3/ —— 本项目实际使用的 AnyKernel3 模板

这份模板**跟着仓库走**：`scripts/build.sh` 打包时直接用它（`cp -a ak3/ .work/AnyKernel3` 再塞 `Image`），
不再去 clone 上游。改这里 = 改刷机包，改动命中 `ak3/**` 会自动触发编译。

- 上游：[osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- 基线 commit：`020dfeccf9d7e962a48400fc94d3e451df92eead`（2026-09-04，tools: update magisk utils to v31.0(31000) beta）

## 本仓库对模板的改动（同步上游时要保留的部分）

时间：2026-09-23，目标设备 **Redmi vermeer**（kalama / 5.15 GKI，A/B，Android 13+ 布局）。

| 项 | 上游示例 | 本项目 |
|---|---|---|
| `device.name1` | `maguro` 等 tuna 系列 | `vermeer`（devicecheck 比对 `ro.product.device`） |
| `BLOCK` | `/dev/block/platform/omap/omap_hsmmc.0/by-name/boot` | `boot`（A/B 自动加 `_a`/`_b`） |
| `IS_SLOT_DEVICE` | `0` | `1` |
| 安装动作 | `dump_boot` + 一堆 `replace_string`/`patch_fstab` + `write_boot` | `split_boot` + `flash_boot` |

最后一条是关键：本设备内核在 **boot**、ramdisk 在 **init_boot**，所以只拆包换 `Image`、
**不碰 ramdisk**（`split_boot` 只拆包不展开 ramdisk，`flash_boot` 用原 ramdisk 重新封包）。
用 `dump_boot`/`write_boot` 会把一个空的占位 ramdisk 写回 boot，属于变砖操作。
`vendor_boot` 里有厂商模块，同样不动 —— 这也是为什么 `do.modules=0`。

devicecheck 拿 `ro.product.device` / `ro.build.product` 之类的值比对 `device.name*`，
所以 device.name1 必须是设备代号（本机 `getprop ro.product.device` = `vermeer`）。

## kernel.string

刷入时 recovery 里打印的那行（也是 `AnyKernel3.zip` 里 `anykernel.sh` 的第 7 行）：

- `config.yml` 的 `ak3.kernel_string` 填了 → 每次构建都强制写成它；
- 留空（默认）→ 保留这里自己写的那串；只有还是上游示例（`ExampleKernel by osm0sis`）
  或压根没这行时，才自动填 `GKI <branch> (<sha12>)`。

也就是说：想固定成自己的名字，直接把这行改成你的（下面只是个例子）——构建不会覆盖它。

```sh
kernel.string=aqnya-gki-5.15
```

## 其它

- `README.md` 不会打进 `AnyKernel3.zip`（上游发版也不带 README），`LICENSE` 会带上。
- 构建时 `ak3/` 只读（复制到 `.work/` 后再改），所以这里的文件永远是你提交的那份。
- 上游模板的完整说明见其仓库 README；本项目侧的用法见根目录 [README.md](../README.md) 第 4 节。
