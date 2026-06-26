#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""校验拆分结果：方法守恒 + 各文件花括号/namespace 平衡。"""
import os, re

SRCDIR = r"d:/Godot/ProjectKeynes/Project.Keynes/gdext/src"
BAK = r"d:/Godot/ProjectKeynes/Project.Keynes/tmp/world_ext.cpp.bak"
GEN = ["world_ext.cpp","world_ext_generate.cpp","world_ext_bake.cpp",
  "world_ext_physical.cpp","world_ext_climate.cpp","world_ext_weather.cpp",
  "world_ext_atlas.cpp","world_ext_daily_sim.cpp","world_ext_demo.cpp"]

defre = re.compile(r"^[A-Za-z_][\w:<>\*&,\s]*?\bDCWorldExt::\s*(~?\w+)\s*\(")
# 方法定义起始行：行首(0缩进)即返回类型...DCWorldExt::name(
def method_defs(path):
    names = []
    for ln in open(path, encoding="utf-8").read().split("\n"):
        if ln[:1] in (" ", "\t"): continue
        m = defre.match(ln)
        if m: names.append(m.group(1))
    return names

def brace_scan(s):
    in_lc=in_bc=in_str=in_ch=False; esc=False
    i=0; n=len(s); depth=0; ns_open=0
    # 统计 namespace pk { 次数与 } 收尾
    while i<n:
        c=s[i]; nx=s[i+1] if i+1<n else ""
        if c=="\n": in_lc=False; i+=1; continue
        if in_lc: i+=1; continue
        if in_bc:
            if c=="*" and nx=="/": in_bc=False; i+=2; continue
            i+=1; continue
        if in_str:
            if esc: esc=False
            elif c=="\\": esc=True
            elif c=='"': in_str=False
            i+=1; continue
        if in_ch:
            if esc: esc=False
            elif c=="\\": esc=True
            elif c=="'": in_ch=False
            i+=1; continue
        if c=="/" and nx=="/": in_lc=True; i+=2; continue
        if c=="/" and nx=="*": in_bc=True; i+=2; continue
        if c=='"': in_str=True; i+=1; continue
        if c=="'": in_ch=True; i+=1; continue
        if c=="{": depth+=1
        elif c=="}": depth-=1
        i+=1
    return depth

# 原始方法集
orig = method_defs(BAK)
from collections import Counter
orig_c = Counter(orig)
print(f"原始 world_ext.cpp 方法定义数: {len(orig)} (唯一 {len(orig_c)})")
dups_orig = {k:v for k,v in orig_c.items() if v>1}
if dups_orig: print("  原始重复(重载/同名):", dups_orig)

# 生成方法集
gen_all = []
per_file = {}
for f in GEN:
    p = os.path.join(SRCDIR, f)
    nm = method_defs(p)
    per_file[f] = nm
    gen_all += nm
gen_c = Counter(gen_all)
print(f"生成全部 cpp 方法定义数: {len(gen_all)} (唯一 {len(gen_c)})")

# 守恒比较
missing = orig_c - gen_c
extra = gen_c - orig_c
print("缺失(原有生成无):", dict(missing) if missing else "无")
print("多出(生成有原无):", dict(extra) if extra else "无")

# 跨文件重复(同名方法出现在多个文件)
cross = {k:v for k,v in gen_c.items() if v>1 and orig_c.get(k,0)<v}
print("疑似跨文件重复:", dict(cross) if cross else "无")

# 花括号平衡 + namespace
print("\n各文件花括号净值(应为0):")
for f in GEN + ["world_ext_internal.h"]:
    p = os.path.join(SRCDIR, f)
    s = open(p, encoding="utf-8").read()
    d = brace_scan(s)
    npk = s.count("namespace pk {")
    nclose = s.count("} // namespace pk")
    flag = "OK" if d==0 else "!!! 不平衡"
    print(f"  {f:30} brace_net={d:>3} {flag}  'namespace pk {{'×{npk} '}} // namespace pk'×{nclose}")

# 每文件方法数
print("\n各文件方法数:")
for f in GEN:
    print(f"  {f:30} {len(per_file[f])}")
