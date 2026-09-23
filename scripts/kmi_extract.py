#!/usr/bin/env python3
"""从厂商模块 .ko 里提取「内核必须导出」的符号 —— 用来生成/更新 KMI 护栏名单。

厂商模块是二进制，它们 import 的内核符号必须由 GKI 内核导出；少一个就 insmod
失败，进而「卡 logo 不开机」（且不是 panic，抓不到崩溃日志）。

两步走：
  1) 解析每个 .ko 的未定义符号（.symtab/.dynsym 里 st_shndx==SHN_UNDEF）
     以及 __versions 段（开了 MODVERSIONS 时，有些导入只出现在那张 CRC 表里）
  2) 与 /proc/kallsyms 取交集，只保留「内核自带」的符号：
     模块之间互相提供的符号（如 cfg80211.ko 的 __cfg80211_*）不在 vmlinux 里，
     留在名单里会让 CI 误报。/proc/kallsyms 每行的第 4 列是模块名，非空即模块符号。

用法（设备上）：
    su -c 'cp /vendor/lib/modules/*.ko /data/local/tmp/mods/ && chmod -R a+rX /data/local/tmp/mods'
    su -c 'cat /proc/kallsyms' > /tmp/kallsyms.txt
    python3 scripts/kmi_extract.py /data/local/tmp/mods --kallsyms /tmp/kallsyms.txt \
        -o scripts/kmi-required-symbols.txt

不加 --kallsyms 时输出原始导入集合（含模块互相提供的符号），仅供查看。
"""
import argparse
import glob
import os
import struct
import sys

# struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; }
# MODULE_NAME_LEN = 64 - sizeof(unsigned long) = 56（64 位）
VERSIONS_ENT = 8 + 56


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
    for s in sh:
        e = stro.find(b"\0", s["name"])
        s["sname"] = stro[s["name"]:e]
    return sh


def module_imports(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF":
        return set()
    sh = _sections(d)
    out = set()

    for s in sh:
        if s["typ"] in (2, 11):                     # SYMTAB / DYNSYM
            st = sh[s["link"]]
            stro = d[st["off"]:st["off"] + st["size"]]
            ent = s["entsize"] or 24
            for k in range(s["size"] // ent):
                nameoff, info, other, shndx, value, size = \
                    struct.unpack_from("<IBBHQQ", d, s["off"] + k * ent)
                if shndx != 0 or nameoff == 0:      # 只取未定义（导入）的
                    continue
                e = stro.find(b"\0", nameoff)
                nm = stro[nameoff:e].decode("latin1")
                if nm and not nm.startswith("__crc_"):
                    out.add(nm)

        if s["sname"] == b"__versions":             # MODVERSIONS 的 CRC 表
            blob = d[s["off"]:s["off"] + s["size"]]
            for k in range(len(blob) // VERSIONS_ENT):
                rec = blob[k * VERSIONS_ENT:(k + 1) * VERSIONS_ENT]
                nm = rec[8:].split(b"\0")[0].decode("latin1").strip()
                if nm and not nm.startswith("__crc_"):
                    out.add(nm)
    return out


def kallsyms_builtin(path):
    """/proc/kallsyms 里「内核自带」（第 4 列无模块名）的符号名。"""
    builtin = set()
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) == 3:
                builtin.add(p[2])
    return builtin


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("modules", help="包含 *.ko 的目录")
    ap.add_argument("-o", "--output", help="输出文件（默认 stdout）")
    ap.add_argument("--kallsyms", help="设备 /proc/kallsyms，用于剔除模块互相提供的符号")
    args = ap.parse_args()

    mods = sorted(glob.glob(os.path.join(args.modules, "*.ko")))
    if not mods:
        raise SystemExit(f"!! {args.modules} 下没有 .ko")

    imported = set()
    for m in mods:
        imported |= module_imports(m)
    print(f"# 模块 {len(mods)} 个，原始导入符号 {len(imported)} 个", file=sys.stderr)

    if args.kallsyms:
        builtin = kallsyms_builtin(args.kallsyms)
        keep = imported & builtin
        print(f"# 与 kallsyms 交集后（只留内核自带）: {len(keep)} 个"
              f"（剔除 {len(imported) - len(keep)} 个：模块互相提供 + 解析噪声）",
              file=sys.stderr)
        imported = keep

    lines = sorted(imported)
    text = "\n".join(lines) + "\n"
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
