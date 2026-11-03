#!/usr/bin/env python3
"""把 libfmod.so 里被代码引用到的短字符串全部列出来（JNI 名字/签名即在此列）。

目的：FMOD 的 Android 版通过 JNI 反射找 `org.fmod.*` 的成员，缺一个就 abort。
逐个上设备撞太慢，这里先静态扫一遍：x86_64 的 `lea reg, [rip+disp32]` 覆盖了绝大多数
"取字符串地址"的写法（JNI 的 name/signature 都是字面量），把命中的 .rodata 字符串
按"像 Java 标识符 / 像 JNI 签名"过滤后输出，用来一次性补齐 stub。

用法：
    python tools/scan_fmod_jni_strings.py <libfmod.so> [--all]
"""

from __future__ import annotations

import re
import struct
import sys

IDENT = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$]{2,40}$")
SIGNATURE = re.compile(r"^\([\[\]A-Za-z0-9/;$.]*\)[\[\]A-Za-z0-9/;$.]+$")
CLASS_PATH = re.compile(r"^[a-z][A-Za-z0-9_/]*$")


class Elf:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.end = "<" if data[5] == 1 else ">"
        (self.machine,) = struct.unpack_from(self.end + "H", data, 18)
        (e_shoff,) = struct.unpack_from(self.end + "Q", data, 40)
        (e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from(self.end + "HHH", data, 58)
        self.sections = []
        for i in range(e_shnum):
            base = e_shoff + i * e_shentsize
            name, sh_type, sh_flags, sh_addr, sh_offset, sh_size = struct.unpack_from(
                self.end + "IIQQQQ", data, base)
            self.sections.append({"name": name, "type": sh_type, "flags": sh_flags,
                                  "addr": sh_addr, "offset": sh_offset, "size": sh_size})
        shstr = self.sections[e_shstrndx]
        self.shstr = data[shstr["offset"]:shstr["offset"] + shstr["size"]]

    def name(self, section: dict) -> str:
        start = section["name"]
        stop = self.shstr.index(b"\x00", start)
        return self.shstr[start:stop].decode()

    def find(self, name: str) -> dict | None:
        for section in self.sections:
            if self.name(section) == name:
                return section
        return None

    def read_cstr(self, va: int) -> str | None:
        for section in self.sections:
            if section["flags"] & 0x2 and section["addr"] <= va < section["addr"] + section["size"]:
                offset = section["offset"] + (va - section["addr"])
                try:
                    stop = self.data.index(b"\x00", offset, offset + 64)
                except ValueError:
                    return None
                raw = self.data[offset:stop]
                if not raw or any(byte < 0x20 or byte > 0x7E for byte in raw):
                    return None
                return raw.decode("ascii")
        return None


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    show_all = "--all" in argv
    data = open(argv[1], "rb").read()
    elf = Elf(data)
    text = elf.find(".text")
    if text is None:
        raise SystemExit("no .text section")

    refs: set[str] = set()
    code = data[text["offset"]:text["offset"] + text["size"]]
    base_va = text["addr"]
    for i in range(len(code) - 7):
        # REX.W lea r64, [rip+disp32]: 48 8D /r with mod=00 rm=101
        if code[i] != 0x48 or code[i + 1] != 0x8D:
            continue
        modrm = code[i + 2]
        if (modrm & 0xC7) != 0x05:
            continue
        (disp,) = struct.unpack_from("<i", code, i + 3)
        target = base_va + i + 7 + disp
        value = elf.read_cstr(target)
        if value is None:
            continue
        if show_all or IDENT.match(value) or SIGNATURE.match(value) or CLASS_PATH.match(value):
            refs.add(value)

    interesting = sorted(refs)
    print("[scan] %d referenced strings" % len(interesting))
    for value in interesting:
        print("  " + value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
