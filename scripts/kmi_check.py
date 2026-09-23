#!/usr/bin/env python3
"""CI KMI 护栏：确认新内核仍然导出厂商模块需要的每一个符号。

背景：GKI 内核跑在厂商模块（/vendor/lib/modules/*.ko）之上。厂商模块是二进制，
它们 import 的内核符号必须由 GKI 内核导出 —— 少一个，模块就 insmod 失败，而
这些模块里有 qce50_dlkm（/data 的 FBE 解密）、msm_kgsl（GPU）、cfg80211/rmnet
（WiFi/数据网）…… 结果是**卡 logo 不开机**，而且因为不是 panic，抓不到崩溃日志。
CI 里没有 ABI 检查，所以必须在真正的 ABI 之外补上这道护栏。

用法：
    kmi_check.py <vmlinux> <kmi-required-symbols.txt>

导出符号从 vmlinux 的 __ksymtab_strings 段（EXPORT_SYMBOL 生成的 kstrtab 字符串）
以及符号表里的 __ksymtab_/__kstrtab_ 系列符号名两处取并集 —— 两处都读是刻意的：
单靠一处可能因为编译选项差异读不全，宁可多算（多算只会少报错，不会漏报）。
"""
import struct
import sys

PREFIXES = (
    b"__ksymtab_gpl_future_", b"__kstrtab_gpl_future_",
    b"__ksymtab_gpl_", b"__kstrtab_gpl_",
    b"__ksymtab_unused_", b"__kstrtab_unused_",
    b"__ksymtab_unused_gpl_", b"__kstrtab_unused_gpl_",
    b"__ksymtab_", b"__kstrtab_",
    b"__kstrtabns_",
)
IDENT = set(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$.")


def _sections(d):
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3a)
    sh = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, soff, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", d, off)
        sh.append({"name": name, "typ": typ, "off": soff, "size": size,
                   "link": link, "entsize": entsize})
    st = sh[e_shstrndx]
    stro = d[st["off"]:st["off"] + st["size"]]

    def nm_at(p):
        e = stro.find(b"\0", p)
        return stro[p:e]

    for s in sh:
        s["sname"] = nm_at(s["name"])
    return sh


def exported_symbols(path):
    """返回 vmlinux 里所有 EXPORT_SYMBOL 的名字集合。"""
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        raise SystemExit(f"!! 不是 64 位 ELF：{path}")
    sh = _sections(d)
    out = set()

    for s in sh:
        # 1) __ksymtab_strings（含 gpl 变体）里的 NUL 分隔字符串就是导出名
        if b"ksymtab_strings" in s["sname"]:
            for part in d[s["off"]:s["off"] + s["size"]].split(b"\0"):
                if part and all(c in IDENT for c in part):
                    out.add(part.decode())

        # 2) 符号表里的 __ksymtab_<name> / __kstrtab_<name>
        if s["typ"] in (2, 11):
            st = sh[s["link"]]
            stro = d[st["off"]:st["off"] + st["size"]]
            ent = s["entsize"] or 24
            for k in range(s["size"] // ent):
                nameoff, info, other, shndx, value, size = \
                    struct.unpack_from("<IBBHQQ", d, s["off"] + k * ent)
                if nameoff == 0:
                    continue
                e = stro.find(b"\0", nameoff)
                nm = stro[nameoff:e]
                for p in PREFIXES:
                    if nm.startswith(p):
                        rest = nm[len(p):]
                        if rest and all(c in IDENT for c in rest):
                            out.add(rest.decode())
                        break
    return out


def load_required(path):
    req = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                req.append(line)
    return req


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    vmlinux, reqfile = sys.argv[1], sys.argv[2]

    required = load_required(reqfile)
    exported = exported_symbols(vmlinux)
    missing = [s for s in required if s not in exported]

    print(f"护栏名单 {len(required)} 个符号；vmlinux 导出 {len(exported)} 个；缺失 {len(missing)} 个")

    if len(exported) < 5000:
        # 解析失败时全部符号都会“缺失”，这里再兜一层，避免解析逻辑坏掉后静默通过
        print("!! vmlinux 解析出的导出符号太少，护栏自身可能已失效", file=sys.stderr)
        return 2

    if missing:
        print("", file=sys.stderr)
        print(f"!! 有 {len(missing)} 个厂商模块依赖的内核符号在这次改动后消失了：", file=sys.stderr)
        for s in missing[:40]:
            print(f"   - {s}", file=sys.stderr)
        if len(missing) > 40:
            print(f"   … 另有 {len(missing) - 40} 个", file=sys.stderr)
        print("", file=sys.stderr)
        print("刷进去会有模块 insmod 失败 → 不开机。请找出是哪个 CONFIG_* 或补丁删掉了它们。",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
