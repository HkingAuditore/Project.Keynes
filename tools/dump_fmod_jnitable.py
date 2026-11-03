#!/usr/bin/env python3
"""从 libfmod.so 里把 FMOD 的 `JNINativeMethod` 表挖出来。

背景：FMOD 的 Android 版要求 APK 里有 `org.fmod.FMOD` 这个 Java 类，它的
`JNI_OnLoad` 会 `FindClass` 然后 `RegisterNatives`。官方类在 `fmod.jar` 里（要登录
fmod.com 才能下），我们想先用一个自写的最小 stub 顶上，就必须知道**准确的方法名和
签名**，否则 RegisterNatives 会失败。

`JNINativeMethod { const char* name; const char* signature; void* fnPtr; }` 是 24 字节
的静态数组，放在 `.data.rel.ro`，三个字段都是 R_*_RELATIVE 重定位（x86_64 的 addend
在 `.rela.dyn` 里，槽位本身是 0）。所以：先算出方法名/签名字符串的虚拟地址，再在
`.rela.dyn` 里找 addend 指向它们的重定位，偏移相邻的三元组就是一张表。

用法：
    python tools/dump_fmod_jnitable.py Project/project-keynes/addons/FmodGodot/bin/android/x86_64/libfmodL.so
"""

from __future__ import annotations

import struct
import sys

R_X86_64_RELATIVE = 8
R_AARCH64_RELATIVE = 1027

METHOD_NAMES = (
    "SetInputEnumerationChanged",
    "SetOutputEnumerationChanged",
    "OutputAAudioHeadphonesChanged",
    "fmodGetSize",
    "fmodReadAt",
)


class Elf:
    def __init__(self, data: bytes) -> None:
        self.data = data
        if data[:4] != b"\x7fELF" or data[4] != 2:
            raise SystemExit("not an ELF64 file")
        self.little = data[5] == 1
        self.end = "<" if self.little else ">"
        (self.machine,) = struct.unpack_from(self.end + "H", data, 18)
        (e_shoff,) = struct.unpack_from(self.end + "Q", data, 40)
        (e_shentsize, e_shnum) = struct.unpack_from(self.end + "HH", data, 58)
        self.sections = []
        for i in range(e_shnum):
            base = e_shoff + i * e_shentsize
            name, sh_type, sh_flags, sh_addr, sh_offset, sh_size = struct.unpack_from(
                self.end + "IIQQQQ", data, base)
            self.sections.append({
                "name_off": name, "type": sh_type, "flags": sh_flags,
                "addr": sh_addr, "offset": sh_offset, "size": sh_size,
            })
        shstr = self.sections[self._u16(62)]
        self.shstr = data[shstr["offset"]:shstr["offset"] + shstr["size"]]

    def _u16(self, off: int) -> int:
        return struct.unpack_from(self.end + "H", self.data, off)[0]

    def section_name(self, section: dict) -> str:
        start = section["name_off"]
        stop = self.shstr.index(b"\x00", start)
        return self.shstr[start:stop].decode()

    def section(self, name: str) -> dict | None:
        for section in self.sections:
            if self.section_name(section) == name:
                return section
        return None

    def va_to_offset(self, va: int) -> int | None:
        for section in self.sections:
            if section["flags"] & 0x2 and section["addr"] <= va < section["addr"] + section["size"]:
                return section["offset"] + (va - section["addr"])
        return None

    def offset_to_va(self, offset: int) -> int | None:
        for section in self.sections:
            if section["flags"] & 0x2 and section["offset"] <= offset < section["offset"] + section["size"]:
                return section["addr"] + (offset - section["offset"])
        return None

    def read_cstr(self, va: int) -> str:
        offset = self.va_to_offset(va)
        if offset is None:
            return ""
        stop = self.data.index(b"\x00", offset)
        return self.data[offset:stop].decode("utf-8", "replace")

    def rela_relative(self) -> list[tuple[int, int]]:
        """[(slot_va, addend)] for R_*_RELATIVE entries."""
        rel_type = R_X86_64_RELATIVE if self.machine == 62 else R_AARCH64_RELATIVE
        out: list[tuple[int, int]] = []
        for section in self.sections:
            if self.section_name(section) not in ("rela.dyn", "rela.plt"):
                continue
            count = section["size"] // 24
            for i in range(count):
                off = section["offset"] + i * 24
                r_offset, r_info, r_addend = struct.unpack_from(self.end + "QQq", self.data, off)
                if (r_info & 0xFFFFFFFF) == rel_type:
                    out.append((r_offset, r_addend))
        return out

    def find_string_va(self, needle: str) -> int | None:
        raw = needle.encode() + b"\x00"
        start = 0
        while True:
            index = self.data.find(raw, start)
            if index < 0:
                return None
            va = self.offset_to_va(index)
            if va is not None:
                return va
            start = index + 1


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    data = open(argv[1], "rb").read()
    elf = Elf(data)
    relocs = elf.rela_relative()
    by_addend: dict[int, list[int]] = {}
    for slot, addend in relocs:
        by_addend.setdefault(addend, []).append(slot)

    print("[jnitable] %s machine=%d relocs=%d" % (argv[1], elf.machine, len(relocs)))
    for name in METHOD_NAMES:
        va = elf.find_string_va(name)
        if va is None:
            print("  %-32s <string not found>" % name)
            continue
        slots = by_addend.get(va, [])
        for slot in slots:
            # name at slot, signature at slot+8, fn at slot+16
            sig_slot = slot + 8
            fn_slot = slot + 16
            sig_va = next((addend for s, addend in relocs if s == sig_slot), None)
            fn_va = next((addend for s, addend in relocs if s == fn_slot), None)
            sig = elf.read_cstr(sig_va) if sig_va and sig_va > 0x1000 else "?"
            print("  %-32s slot=0x%x sig=%-12s fn=0x%s" % (
                name, slot, sig, ("%x" % fn_va) if fn_va else "?"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
