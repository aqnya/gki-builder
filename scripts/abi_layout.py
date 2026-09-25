#!/usr/bin/env python3
"""ABI 布局比对：从 BTF 里挖出结构体的大小与成员偏移，做刷机前的布局验证。

为什么需要它
------------
`check_kmi` 只保证「符号还在」，`check_abi_pinned` 只挡住名单里的那几个开关。
但厂商模块是**二进制**，结构体字段偏移是编译期烤进 .ko 的：
符号一个不少、偏移变了，模块照样读到野指针 → 卡 logo，而且不是 panic、抓不到日志。
（2026-09-23 实测：SCHEDSTATS=n + TASK_XACCT=n + PAGE_OWNER=n 就是这么挂的。）

GKI 一定带 CONFIG_DEBUG_INFO_BTF=y，BTF 里存着每个结构体的大小和每个成员的位偏移，
所以「布局有没有变」是**刷机前就能验**的。设备上还能直接读能开机内核的 BTF：
    su -c 'cp /sys/kernel/btf/vmlinux /data/local/tmp/btf.ref'
拿它当参考，比对新编译的 Image（BTF 段是 Image 的一部分）即可。

用法
----
    abi_layout.py dump <btf|vmlinux|Image> [结构体名...]     # 不带名字=dump 全部
    abi_layout.py diff <参考> <待测> [--all] [结构体名...]    # 不带名字=只看重点结构体
    abi_layout.py focus                                      # 打印内置的重点结构体名单

输入可以是：裸 BTF（/sys/kernel/btf/vmlinux）、ELF（vmlinux）、arm64 裸 Image
（没有节表，就靠魔数扫描找 BTF 段）。
"""

from __future__ import annotations

import struct
import sys

BTF_MAGIC = 0xEB9F
HDR_LEN = 24

# BTF 的 kind 编号（include/uapi/linux/btf.h）
KIND_INT, KIND_PTR, KIND_ARRAY, KIND_STRUCT, KIND_UNION = 1, 2, 3, 4, 5
KIND_ENUM, KIND_FWD, KIND_TYPEDEF, KIND_VOLATILE, KIND_CONST = 6, 7, 8, 9, 10
KIND_RESTRICT, KIND_FUNC, KIND_FUNC_PROTO, KIND_VAR, KIND_DATASEC = 11, 12, 13, 14, 15
KIND_FLOAT, KIND_DECL_TAG, KIND_TYPE_TAG, KIND_ENUM64 = 16, 17, 18, 19

# 每个 kind 的类型条目里「名字+info+size/type」之后还有多少字节
_KIND_EXTRA = {
    KIND_INT: 4, KIND_PTR: 0, KIND_ARRAY: 12,
    KIND_STRUCT: None, KIND_UNION: None,          # vlen * 12
    KIND_ENUM: None, KIND_ENUM64: None,           # vlen * 8 / vlen * 12
    KIND_FWD: 0, KIND_TYPEDEF: 0, KIND_VOLATILE: 0, KIND_CONST: 0,
    KIND_RESTRICT: 0, KIND_FUNC: 0, KIND_FUNC_PROTO: None,  # vlen * 8
    KIND_VAR: 4, KIND_DATASEC: None,              # vlen * 12
    KIND_FLOAT: 0, KIND_DECL_TAG: 4, KIND_TYPE_TAG: 0,
}
_MEMBER_STRIDE = {KIND_STRUCT: 12, KIND_UNION: 12, KIND_ENUM: 8, KIND_ENUM64: 12,
                  KIND_FUNC_PROTO: 8, KIND_DATASEC: 12}

# 厂商模块会碰的「重点结构体」—— 布局变了大概率就是变砖
FOCUS = [
    "task_struct", "sched_entity", "sched_statistics", "sched_info", "signal_struct",
    "mm_struct", "vm_area_struct", "page", "cred", "pid", "nsproxy", "module",
    "file", "inode", "dentry", "super_block", "block_device", "gendisk",
    "request_queue", "bio", "page_ext",
    "sock", "socket", "sk_buff", "net_device", "proto_ops", "nf_hook_ops",
    "device", "class", "bus_type", "driver", "platform_device", "attribute_group",
    "clk", "clk_core", "regulator_dev", "dma_buf", "dma_buf_attachment",
    "gpio_desc", "gpio_chip", "i2c_client", "i2c_adapter", "spi_device",
    "spi_controller", "usb_device", "usb_interface", "scsi_device", "scsi_host",
    "work_struct", "delayed_work", "workqueue_struct", "timer_list", "tasklet_struct",
    "wait_queue_head", "completion", "mutex", "rw_semaphore", "spinlock", "kref",
    "list_head", "hlist_node", "rb_node", "atomic_t", "seq_file", "proc_dir_entry",
    "notifier_block", "dev_pm_ops", "file_operations", "vm_operations_struct",
]


class BtfError(RuntimeError):
    pass


def _btf_from_elf(data: bytes) -> bytes:
    """从 ELF（vmlinux）里取 .BTF 段。"""
    if len(data) < 64:
        raise BtfError("文件太小，不像 ELF")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    shnum = struct.unpack_from("<H", data, 0x3C)[0]
    shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    if not shoff or not shnum:
        raise BtfError("ELF 没有节表")

    def sh(i):
        return struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)

    strtab_off = sh(shstrndx)[4]
    for i in range(shnum):
        s = sh(i)
        end = data.index(b"\0", strtab_off + s[0])
        name = data[strtab_off + s[0]:end]
        if name == b".BTF":
            return data[s[4]:s[4] + s[5]]
    raise BtfError("ELF 里没有 .BTF 段（内核是不是没开 CONFIG_DEBUG_INFO_BTF？）")


def _btf_from_raw(data: bytes) -> bytes:
    """裸 Image：按 4 字节对齐扫 BTF 魔数，再校验头部自洽。"""
    # 只匹配头 8 字节（magic/version/flags/hdr_len），剩下的从命中的位置现读 ——
    # 别把 type_len 也写进模式里，那永远匹配不上。
    pat = struct.pack("<HBBI", BTF_MAGIC, 1, 0, HDR_LEN)
    start = 0
    while True:
        i = data.find(pat, start)
        if i < 0:
            raise BtfError("扫不到 BTF 魔数（不是 Image/vmlinux？）")
        start = i + 1
        if i % 4:
            continue
        hdr_len, type_off, type_len, str_off, str_len = struct.unpack_from("<IIIII", data, i + 4)
        if hdr_len != HDR_LEN or type_len == 0 or str_len == 0:
            continue
        tail = i + hdr_len + max(type_off + type_len, str_off + str_len)
        if tail > len(data):
            continue
        blob = data[i:tail]
        try:                       # 真正解一遍，能解通才算数
            _parse_types(blob)
        except (BtfError, struct.error):
            continue
        return blob


def load_btf(path: str) -> bytes:
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] == b"\x7fELF":
        return _btf_from_elf(data)
    if struct.unpack_from("<H", data, 0)[0] == BTF_MAGIC:
        return data
    return _btf_from_raw(data)


def _parse_types(blob: bytes) -> dict:
    """返回 {name: {"size": 字节数, "kind": kind, "members": [(成员名, 位偏移)]}}。"""
    hdr_len, type_off, type_len, str_off, str_len = struct.unpack_from("<IIIII", blob, 4)
    types = blob[hdr_len + type_off: hdr_len + type_off + type_len]
    strs = blob[hdr_len + str_off: hdr_len + str_off + str_len]

    def s(off: int) -> str:
        if off == 0:
            return ""
        end = strs.index(b"\0", off)
        return strs[off:end].decode("utf-8", "replace")

    recs: list = []
    pos = 0
    tid = 1
    while pos < len(types):
        if pos + 12 > len(types):
            raise BtfError("类型段长度对不上")
        name_off, info, size_or_type = struct.unpack_from("<III", types, pos)
        kind = (info >> 24) & 0x1F
        kind_flag = (info >> 31) & 1
        vlen = info & 0xFFFF
        pos += 12

        stride = _MEMBER_STRIDE.get(kind)
        if stride is not None:
            extra = vlen * stride
        else:
            extra = _KIND_EXTRA.get(kind)
            if extra is None:
                raise BtfError(f"未知 BTF kind {kind}")
        if pos + extra > len(types):
            raise BtfError("类型段长度对不上")

        rec = {"id": tid, "name": s(name_off), "kind": kind,
               "size": size_or_type, "members": []}
        if kind in (KIND_STRUCT, KIND_UNION):
            for m in range(vlen):
                m_name, m_type, m_off = struct.unpack_from("<III", types, pos + m * stride)
                bit_off = (m_off & 0xFFFFFF) if kind_flag else m_off
                bit_size = (m_off >> 24) if kind_flag else None
                rec["members"].append((s(m_name), bit_off, bit_size, m_type))
        recs.append(rec)
        pos += extra
        tid += 1

    by_id = {r["id"]: r for r in recs}

    def _wraps_kabi_reserve(type_id: int, seen: set) -> bool:
        """该匿名 struct/union 内部是否包裹了 ANDROID_KABI_RESERVE 字段。"""
        r = by_id.get(type_id)
        if not r or r["kind"] not in (KIND_STRUCT, KIND_UNION) or type_id in seen:
            return False
        seen.add(type_id)
        for nm, _bo, _bs, mt in r["members"]:
            if nm.startswith("android_kabi_reserved"):
                return True
            if _wraps_kabi_reserve(mt, seen):
                return True
        return False

    def _is_kabi_slot(nm: str, type_id: int) -> bool:
        # 顶层 reserve；或 ANDROID_KABI_USE()/REPLACE 生成的、包裹了 reserve
        # 的匿名 union/struct。二者二进制偏移与大小完全相同，视为同一 ABI 槽位。
        return nm.startswith("android_kabi_reserved") or \
            (nm == "" and _wraps_kabi_reserve(type_id, set()))

    out: dict = {}
    for r in recs:
        if r["kind"] not in (KIND_STRUCT, KIND_UNION):
            continue
        members = []
        for nm, bo, bs, mt in r["members"]:
            if _is_kabi_slot(nm, mt):
                continue
            members.append((nm, bo, bs))
        out.setdefault(r["name"], {"size": r["size"], "kind": r["kind"],
                                   "members": members, "id": r["id"]})
    return out


def parse(path: str) -> dict:
    return _parse_types(load_btf(path))


def cmd_dump(argv: list) -> int:
    if not argv:
        print(__doc__.strip().splitlines()[0])
        print("用法: abi_layout.py dump <文件> [结构体名...]", file=sys.stderr)
        return 2
    types = parse(argv[0])
    names = argv[1:] or sorted(n for n, t in types.items() if t["kind"] == KIND_STRUCT)
    for n in names:
        t = types.get(n)
        if not t:
            print(f"# {n}: 这个内核的 BTF 里没有")
            continue
        print(f"struct {n} size={t['size']}")
        for m_name, bit_off, bit_size in t["members"]:
            bf = f" bits={bit_size}" if bit_size else ""   # 0 = 普通成员，不打印
            print(f"    +{bit_off // 8:<7} (bit {bit_off:<6}) {m_name}{bf}")
    return 0


def cmd_diff(argv: list) -> int:
    args = [a for a in argv if not a.startswith("--")]
    show_all = "--all" in argv
    if len(args) < 2:
        print("用法: abi_layout.py diff <参考> <待测> [--all] [结构体名...]", file=sys.stderr)
        return 2
    ref, new = parse(args[0]), parse(args[1])
    names = args[2:] or (sorted(set(ref) | set(new)) if show_all else FOCUS)

    changed, only_ref, only_new = [], [], []
    for n in names:
        a, b = ref.get(n), new.get(n)
        if a and not b:
            only_ref.append(n)
            continue
        if b and not a:
            only_new.append(n)
            continue
        if not a:
            continue
        diffs = []
        if a["size"] != b["size"]:
            diffs.append(f"大小 {a['size']} -> {b['size']}（{b['size'] - a['size']:+d} 字节）")
        ma = {m[0]: m for m in a["members"]}
        mb = {m[0]: m for m in b["members"]}
        for m in ma:
            if m not in mb:
                diffs.append(f"成员 {m} 没了（原本偏移 {ma[m][1] // 8}）")
            elif ma[m][1] != mb[m][1]:
                diffs.append(f"成员 {m} 偏移 {ma[m][1] // 8} -> {mb[m][1] // 8}"
                             f"（{(mb[m][1] - ma[m][1]) // 8:+d} 字节）")
        for m in mb:
            if m not in ma:
                diffs.append(f"新增成员 {m}（偏移 {mb[m][1] // 8}）")
        if diffs:
            changed.append((n, a["size"], b["size"], diffs))

    if not changed and not only_ref and not only_new:
        print(f"✅ 布局一致：比对了 {len(names)} 个结构体，大小与成员偏移完全相同")
        return 0

    print(f"⚠️ 布局有差异（比对 {len(names)} 个结构体）")
    for n, sa, sb, diffs in changed:
        print(f"\n  {n}: size {sa} -> {sb}")
        for d in diffs[:12]:
            print(f"      {d}")
        if len(diffs) > 12:
            print(f"      …还有 {len(diffs) - 12} 处")
    for n in only_ref:
        print(f"\n  {n}: 只存在于参考内核")
    for n in only_new:
        print(f"\n  {n}: 只存在于待测内核")
    return 1


def main(argv: list) -> int:
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "dump":
        return cmd_dump(rest)
    if cmd == "diff":
        return cmd_diff(rest)
    if cmd == "focus":
        print("\n".join(FOCUS))
        return 0
    print(f"未知子命令 {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
