#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""world_ext.cpp 拆分工具。
默认 dry-run：只解析 + 分配 + 打印 helper 跨文件使用冲突报告，不写文件。
传入 'write' 参数才真正落盘。"""
import re, sys, os

WRITE = "write" in sys.argv
SRCDIR = r"d:/Godot/ProjectKeynes/Project.Keynes/gdext/src"
SRC = os.path.join(SRCDIR, "world_ext.cpp")

with open(SRC, "r", encoding="utf-8") as f:
    text = f.read()
lines = text.split("\n")            # 0-based
N = len(lines)

# ───────────────── 扫描结构字符（跳注释/字符串）─────────────────
def scan(s):
    events = []
    line_has_code = [False] * (s.count("\n") + 1)
    in_lc = in_bc = in_str = in_ch = False; esc = False
    i = 0; L = len(s); line = 0
    while i < L:
        c = s[i]; nxt = s[i+1] if i+1 < L else ""
        if c == "\n":
            line += 1; in_lc = False; i += 1; continue
        if in_lc: i += 1; continue
        if in_bc:
            if c == "*" and nxt == "/": in_bc = False; i += 2; continue
            i += 1; continue
        if in_str:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': in_str = False
            i += 1; continue
        if in_ch:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == "'": in_ch = False
            i += 1; continue
        if c == "/" and nxt == "/": in_lc = True; i += 2; continue
        if c == "/" and nxt == "*": in_bc = True; i += 2; continue
        if c == '"': in_str = True; line_has_code[line] = True; i += 1; continue
        if c == "'": in_ch = True; line_has_code[line] = True; i += 1; continue
        if not c.isspace():
            line_has_code[line] = True
            if c in "{}();":
                events.append((line, c))
        i += 1
    return events, line_has_code

events, line_has_code = scan(text)

# ───────────────── 找 namespace pk { ... } ─────────────────
pk_open = next(i for i in range(N) if lines[i].strip().startswith("namespace pk"))
depth = 0; pk_close = None; started = False
for (ln, ch) in events:
    if ln < pk_open: continue
    if ch == "{": depth += 1; started = True
    elif ch == "}":
        depth -= 1
        if started and depth == 0:
            pk_close = ln; break

body_events = [e for e in events if pk_open <= e[0] <= pk_close][1:-1]

# ───────────────── 分割顶层项（0-based 行号 start,end）─────────────────
items = []
cur = pk_open + 1; ei = 0
while ei < len(body_events):
    sl = None; l = cur
    while l < pk_close:
        if line_has_code[l]: sl = l; break
        l += 1
    if sl is None: break
    while ei < len(body_events) and body_events[ei][0] < sl: ei += 1
    bdepth = pdepth = 0; opened = False; end = None
    while ei < len(body_events):
        ln, ch = body_events[ei]; ei += 1
        if ch == "(": pdepth += 1
        elif ch == ")": pdepth -= 1
        elif ch == "{": bdepth += 1; opened = True
        elif ch == "}":
            bdepth -= 1
            if bdepth == 0 and opened: end = ln; break
        elif ch == ";":
            if bdepth == 0 and pdepth == 0 and not opened: end = ln; break
    if end is None: end = pk_close - 1
    items.append((sl, end))
    cur = end + 1

method_re = re.compile(r"\bDCWorldExt::\s*(~?\w+)")
# 安全断言：pk_close 必须落在 namespace pk 的闭合行；items 必须连续覆盖 pk body
print(f"[check] pk_open line={pk_open+1} {lines[pk_open]!r}")
print(f"[check] pk_close line={pk_close+1} {lines[pk_close]!r}")
assert lines[pk_close].strip().startswith("}"), "pk_close 未落在闭合花括号行!"
print(f"[check] item 数={len(items)} 末项={items[-1][0]+1}-{items[-1][1]+1} {lines[items[-1][0]]!r}")
# 覆盖性：相邻 item 之间不重叠，且末项 end 接近 pk_close
for k in range(1, len(items)):
    assert items[k][0] > items[k-1][1], f"item 重叠 @ {items[k-1]} vs {items[k]}"
def classify(a, b):
    head = "\n".join(lines[a:min(a+5, b+1)])
    m = method_re.search(head)
    f = lines[a].strip()
    if m: return ("METHOD", m.group(1))
    if f.startswith("namespace pk_async_climate"): return ("NS_ASYNC", f)
    if f.startswith("namespace"): return ("ANON_NS", f)
    if f.startswith("struct "): return ("STRUCT", f)
    if f.startswith("using "): return ("USING", f)
    return ("FREE", f)

# ───────────────── 文件分配 ─────────────────
CORE = {
  "DCWorldExt","~DCWorldExt","register_component","component_id","_ensure_slot_capacity",
  "create_entities","create_pool","pool_range","pool_id","pool_free_count",
  "view_f32","view_i32","view_u8","snapshot_f32","snapshot_i32","snapshot_u8",
  "read_f32","read_i32","read_u8","write_f32","write_i32","write_u8",
  "write_f32_range","write_i32_range","write_u8_range",
  "write_f32_indexed","write_i32_indexed","write_u8_indexed",
  "write_f32_scalar_indexed","write_i32_scalar_indexed","write_u8_scalar_indexed",
  "bind_map_data","configure_native_world","create_archetype","assign_archetype",
  "bind_dirty_world","_flush_slot_to_map","flush_pending_mark_dirty_all",
  "flush_slots_to_map","refresh_slots_from_map",
}
DAILY_SIM = {"run_native_daily_tick","run_native_sim_tick","get_native_daily_report",
  "get_native_shadow_diff_report","get_native_dirty_report"}
GENERATE = {"run_native_world_generate_pass","run_native_world_generate_full_pass",
  "start_native_generation","run_native_generation_slice","finish_native_generation",
  "run_temp_baseline_year_bake","run_native_world_generate_base_pass",
  "run_native_world_generate_post_base_pass","_run_native_generation_publish_pass",
  "run_season_refresh_stage","run_season_refresh_micro_pass","start_season_round",
  "run_season_round_slice","finish_season_round","abort_season_round"}
BAKE = {"encode_bake_height_tex_data","encode_bake_terrain_normal_tex_data",
  "encode_bake_r8_tex_data","encode_bake_flow_tex_data","encode_bake_enum_atlas_payload",
  "run_bake_volcano_field_pass","run_bake_latitude_field_pass","run_bake_river_sdf_pass",
  "run_bake_erosion_pass","run_bake_coast_sdf_pass","run_bake_geometry_fields_pass",
  "run_bake_terrain_index_pass","encode_bake_upwelling_tex_data"}
PHYSICAL = {"run_wind_field_pass","run_ocean_field_rasterize","run_wind_field_rasterize",
  "phys_field_nan_guard","run_physical_solve_pass","run_physical_circulation_pass",
  "run_slp_field_pass","run_psi_solver_pass"}
CLIMATE = {"run_climate_pass_a","run_climate_pass_a_thread","run_climate_pass_b",
  "run_climate_pass_b_simd","run_climate_pass_b_thread","run_ocean_water_pass",
  "run_ocean_water_pass_simd","run_ocean_water_pass_thread","run_ocean_land_pass",
  "run_ocean_land_pass_simd","run_ocean_land_pass_thread","run_sea_ice_daily_pass",
  "run_sea_ice_daily_pass_thread","run_transpiration_pass","run_runtime_hydrology_pass",
  "run_albedo_pass","run_albedo_pass_thread","run_vegetation_dynamics_pass",
  "run_vegetation_dynamics_pass_thread","run_climate_feedback_pass",
  "run_climate_feedback_pass_thread","run_stage_b_pass",
  "async_climate_register_task","async_climate_set_inputs","async_climate_request",
  "async_climate_poll","async_climate_stats","async_climate_shutdown_task",
  "async_climate_shutdown_all","async_climate_round_register",
  "async_climate_round_set_static_knobs","async_climate_round_kick",
  "async_climate_round_poll","async_climate_round_stats","async_climate_round_shutdown"}
WEATHER = {"get_native_fronts_snapshot","get_native_fronts_snapshot_packed",
  "run_synoptic_advance_pass","run_weather_field_solve_pass","run_weather_field_commit_pass",
  "run_wind_air_mass_pass","run_wind_surface_pass","run_weather_front_advect_pass",
  "run_weather_distribute_pass","run_weather_summary_fronts_pass","cyclone_wake_step",
  "get_cyclone_perturbations_dict","run_weather_refresh_daily_pass",
  "reset_weather_summary_state","snapshot_weather_summary_state","restore_weather_summary_state"}
ATLAS = {"run_sea_ice_atlas_prepare","patch_enum_atlas_axes","encode_dynamic_cell_atlas",
  "encode_ecology_visual_atlas","encode_dyn_smooth_atlas","encode_ice_state_atlas",
  "encode_overlay_atlas","invalidate_atlas_csr_cache","migrate_eco_persistent_from_gd",
  "encode_cell_luts","run_atlas_pipeline_step"}
DEMO = {"run_temp_drift_pass","run_thermal_gradient_pass","run_demo_complex_pass",
  "run_demo_complex_pass_archetyped","_spike_alias_v1_naive","_spike_alias_v2_release",
  "_spike_alias_v3_write_then_set","_debug_poke_f32","_debug_poke_f32_with_flush",
  "bench_pass_a_full_scalar","bench_pass_a_full_simd","bench_pass_a_full_thread",
  "bench_pass_a_indexed_scalar","bench_pass_a_indexed_simd","bench_pass_a_indexed_thread",
  "encode_tile_csv_rows","encode_detail_scatter"}

METHOD_FILE = {}
for s, fkey in [(CORE,"CORE"),(DAILY_SIM,"DAILY_SIM"),(GENERATE,"GENERATE"),
    (BAKE,"BAKE"),(PHYSICAL,"PHYSICAL"),(CLIMATE,"CLIMATE"),(WEATHER,"WEATHER"),
    (ATLAS,"ATLAS"),(DEMO,"DEMO")]:
    for nm in s: METHOD_FILE[nm] = fkey

# helper/struct/ns 块按起始行(1-based)分配
BLOCK_FILE = {
  59:"HEADER", 69:"HEADER", 99:"HEADER", 237:"HEADER",   # structs
  709:"DROP",                                            # BIND_TABLE anon ns -> internal.h
  3166:"DEMO",       # pass_a_* workers (被 bench 使用)
  3297:"HEADER",     # wf_* (被 climate 跨用 -> 头)
  6071:"HEADER",     # wind_belt_at (被 physical 跨用 -> 头)
  6127:"CLIMATE", 6501:"CLIMATE", 7029:"CLIMATE", 7366:"CLIMATE",
  7667:"CLIMATE", 7678:"CLIMATE", 7686:"CLIMATE",
  8877:"CLIMATE", 8883:"CLIMATE", 8900:"CLIMATE", 8917:"CLIMATE",
  11011:"WEATHER",
  12538:"PHYSICAL",  # NB_DIR_X 等
  13234:"HEADER",    # worldgen geo helpers（被 bake/physical/atlas 跨用 -> 头）
  18377:"GENERATE",  # pk_round_stage_to_cpp_stage
  21097:"ATLAS", 21107:"ATLAS", 21118:"ATLAS", 21957:"ATLAS",
  24892:"CLIMATE",   # async 状态 struct
  25376:"CLIMATE",   # pk_async_climate ns
  27944:"DEMO",
}
# dc_/pk_ 共享 helper 区 2090..2230 全部 -> HEADER
def assign_item(a1, b1, kind, name):
    if a1 in BLOCK_FILE: return BLOCK_FILE[a1]
    if kind == "METHOD":
        if name not in METHOD_FILE:
            raise SystemExit(f"未分配方法: {name} @ {a1}")
        return METHOD_FILE[name]
    if kind == "FREE" and 2089 <= a1 <= 2231:
        return "HEADER"
    if kind == "USING":
        return "WRAPPER"   # 不进 items 体
    raise SystemExit(f"未分配 helper 块: {kind} {name} @ {a1}-{b1}")

# 构建 item 记录
recs = []
for (a, b) in items:
    kind, name = classify(a, b)
    a1, b1 = a+1, b+1
    if kind == "USING":
        continue
    fkey = assign_item(a1, b1, kind, name)
    recs.append({"a":a, "b":b, "a1":a1, "b1":b1, "kind":kind, "name":name, "file":fkey})

# ───────────────── 行→文件 映射（含 gap 归属后一项）─────────────────
file_of_line = [None]*(pk_close+2)   # 1-based
prev_end = 52   # using 行；body 从 53 起
for r in recs:
    start_full = prev_end + 1
    for ln in range(start_full, r["b1"]+1):
        file_of_line[ln] = r["file"]
    prev_end = r["b1"]

def owner_file(ln):
    if 1 <= ln <= pk_close+1:
        return file_of_line[ln]
    return None

# ───────────────── helper 冲突检测 ─────────────────
CPP_KW = set("if for while switch return sizeof do else case const static inline "
    "void int float double bool char auto struct class enum namespace template "
    "typename using new delete this true false nullptr public private protected "
    "constexpr unsigned signed long short uint8_t int32_t uint32_t int64_t size_t "
    "float32 and or not catch try throw operator friend virtual override final".split())
def_fn_re = re.compile(r"^\s*(?:[A-Za-z_][\w:<>\*&]*\s+)+([A-Za-z_]\w*)\s*\(")
def_struct_re = re.compile(r"\bstruct\s+([A-Za-z_]\w*)")
def_const_re = re.compile(r"^\s*(?:static\s+|inline\s+)*(?:const|constexpr)\s+[\w:<>\*&\s]+?\b([A-Za-z_]\w*)\s*[=\[]")

CONTROL_KW = set("return if else for while do switch case goto throw delete new "
    "sizeof co_return co_await co_yield".split())
def line_defs(ln):
    # 只认顶层定义：本代码库里 namespace 直接成员一律顶格(0 缩进)，
    # 函数体内的局部变量都有缩进 -> 用顶格过滤掉所有局部噪声。
    names = set()
    if not ln or ln[0] in " \t":
        return names
    s = ln.strip()
    m = def_fn_re.match(ln)
    if m:
        first = s.split("(")[0].split()[0] if "(" in s and s.split("(")[0].split() else ""
        if (not s.endswith(";")) and first not in CONTROL_KW and m.group(1) not in CPP_KW:
            names.add(m.group(1))
    m = def_struct_re.match(ln)
    if m: names.add(m.group(1))
    m = def_const_re.match(ln)
    if m and m.group(1) not in CPP_KW: names.add(m.group(1))
    return names

def extract_defs(a, b):
    s = set()
    for i in range(a, b+1):
        s |= line_defs(lines[i])
    return s

# 全文件定义点：name -> set(files) where defined (含 method-local constexpr/struct)
def_files = {}
def_sites = {}
for i in range(N):
    of = owner_file(i+1)
    if not of or of == "WRAPPER": continue
    for nm in line_defs(lines[i]):
        def_files.setdefault(nm, set()).add(of)
        def_sites.setdefault(nm, []).append((i+1, of))

print("="*70)
print("HELPER 跨文件使用真冲突报告（已排除多处独立重定义）")
print("="*70)
conflicts = 0
real_bad = {}
for r in recs:
    if r["kind"] not in ("FREE","ANON_NS","NS_ASYNC","STRUCT"): continue
    if r["file"] in ("HEADER","DROP"): continue
    defs = extract_defs(r["a"], r["b"])
    for nm in sorted(defs):
        pat = re.compile(r"\b"+re.escape(nm)+r"\b")
        usefiles = {}
        for i in range(N):
            if r["a"] <= i <= r["b"]: continue
            if pat.search(lines[i]):
                of = owner_file(i+1)
                if of and of != "WRAPPER":
                    usefiles.setdefault(of, []).append(i+1)
        # 真冲突：使用文件 F 既不是定义块所在文件，且 F 内没有该名字的本地定义
        deff = def_files.get(nm, set())
        bad = {f: usefiles[f][:6] for f in usefiles
               if f != r["file"] and f not in deff}
        if bad:
            conflicts += 1
            real_bad[nm] = (r["a1"], r["b1"], r["file"], bad, def_sites.get(nm))
            print(f"[真冲突] {nm} 定义@{r['a1']}-{r['b1']}({r['file']})")
            print(f"         其他文件使用且无本地定义: {bad}")
            print(f"         全部定义点: {def_sites.get(nm)}")
print(f"\n真冲突名字数: {conflicts}")
print("需提升到 HEADER 的名字:", sorted(real_bad.keys()))

# HEADER 撞名检查：HEADER 块定义的名字若在非 HEADER 文件也有定义 -> 重复定义错误
print("\n" + "="*70)
print("HEADER 撞名检查（头里定义的名字是否与某 cpp 本地定义冲突）")
print("="*70)
header_names = set()
for r in recs:
    if r["file"] == "HEADER":
        header_names |= extract_defs(r["a"], r["b"])
header_collide = 0
for nm in sorted(header_names):
    other = sorted(f for f in def_files.get(nm, set()) if f not in ("HEADER",))
    if other:
        header_collide += 1
        print(f"[撞名] {nm} 在 HEADER 定义，但也在 {other} 定义: {def_sites.get(nm)}")
print(f"撞名数: {header_collide}")

# 统计各文件方法/块数
from collections import Counter
cnt = Counter(r["file"] for r in recs)
print("\n各文件项数:", dict(cnt))
mcnt = Counter(r["file"] for r in recs if r["kind"]=="METHOD")
print("各文件方法数:", dict(mcnt), " 合计", sum(mcnt.values()))

if not WRITE:
    print("\n[dry-run] 未写文件。确认无冲突后用 'write' 参数执行。")
    sys.exit(0)

# ───────────────── 写入前安全门 ─────────────────
KNOWN_FALSE_POS = {"fetch_world_soa"}   # 注释里提及，非真引用
bad_real = {nm for nm in real_bad if nm not in KNOWN_FALSE_POS}
if bad_real:
    raise SystemExit(f"存在未解决真冲突，拒绝写入: {bad_real}")
if header_collide:
    raise SystemExit("存在 HEADER 撞名，拒绝写入。")

# ───────────────── 每个 rec 的完整范围(含前导 gap) ─────────────────
prev = 52
for r in recs:
    r["fs"] = prev + 1     # full_start (1-based)
    prev = r["b1"]

# 行覆盖自检：body 行 53..最后一项 必须被 rec 连续无重叠覆盖
covered = [0]*(pk_close+2)
for r in recs:
    for ln in range(r["fs"], r["b1"]+1):
        covered[ln] += 1
for ln in range(53, recs[-1]["b1"]+1):
    assert covered[ln] == 1, f"行 {ln} 覆盖次数={covered[ln]} (期望1): {lines[ln-1]!r}"
print(f"[check] 行覆盖自检通过: 53..{recs[-1]['b1']} 每行恰好归属一个 item")

# 备份原 world_ext.cpp
import shutil
shutil.copy(SRC, os.path.join(r"d:/Godot/ProjectKeynes/Project.Keynes/tmp", "world_ext.cpp.bak"))
print("已备份 world_ext.cpp -> tmp/world_ext.cpp.bak")

FILE_NAMES = {
  "CORE":"world_ext.cpp", "GENERATE":"world_ext_generate.cpp",
  "BAKE":"world_ext_bake.cpp", "PHYSICAL":"world_ext_physical.cpp",
  "CLIMATE":"world_ext_climate.cpp", "WEATHER":"world_ext_weather.cpp",
  "ATLAS":"world_ext_atlas.cpp", "DAILY_SIM":"world_ext_daily_sim.cpp",
  "DEMO":"world_ext_demo.cpp",
}

preamble = "\n".join(lines[0:pk_open])   # 原文件 1..49（includes/宏），止于 namespace pk 之前

def emit_lines(lo, hi):
    # 1-based 闭区间 -> 原文行
    return "\n".join(lines[lo-1:hi])

WRAP_OPEN = "\n\n#include \"world_ext_internal.h\"\n\nnamespace pk {\n\nusing namespace godot;\n"
WRAP_CLOSE = "\n\n} // namespace pk\n"

# 写 cpp 文件
for fkey, fname in FILE_NAMES.items():
    parts = [preamble, WRAP_OPEN]
    for r in recs:
        if r["file"] != fkey: continue
        parts.append("\n" + emit_lines(r["fs"], r["b1"]))
    parts.append(WRAP_CLOSE)
    path = os.path.join(SRCDIR, fname)
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        fp.write("".join(parts))
    print(f"写出 {fname}")

# 写 world_ext_internal.h
HDR_INCLUDES = """#pragma once

// ─────────────────────────────────────────────────────────────────────────
// world_ext_internal.h — DCWorldExt 拆分后的共享内部头。
// 内容：① 持久状态结构体（WeatherSummaryState/AtlasPipelineState/...）；
//       ② BIND_TABLE 别名；③ 跨翻译单元复用的 file-local 无状态 helper
//       （dc_/pk_ 气候、wf_ 天气场、wind_belt_at、worldgen 几何）。
// 这些 helper 原为 world_ext.cpp 内的 static/匿名命名空间符号；移到本头后
// 仍保持 internal linkage（每个 TU 各一份），零行为变化。仅供 world_ext*.cpp
// 包含，不对外暴露。
// ─────────────────────────────────────────────────────────────────────────

#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include "world_ext.h"
#include "component_bind_table.gen.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace pk {

using namespace godot;
"""

BIND_TABLE_BLOCK = """
// ─── BIND_TABLE — autogenerated single source（原 world_ext.cpp 匿名 ns）─────
// 提到共享头：bind_map_data / _flush_slot_to_map（CORE）与 _debug_poke_f32_with_flush
// （DEMO）分处不同 TU，需都能见到该别名。匿名 ns -> 每 TU 各一份 internal linkage。
namespace {
[[maybe_unused]] constexpr auto &BIND_TABLE      = BIND_TABLE_AUTOGEN;
[[maybe_unused]] constexpr int   BIND_TABLE_SIZE = BIND_TABLE_AUTOGEN_SIZE;
} // namespace
"""

hdr_parts = [HDR_INCLUDES]
for r in recs:
    if r["file"] != "HEADER": continue
    hdr_parts.append("\n" + emit_lines(r["fs"], r["b1"]))
    if r["a1"] == 237:   # SeasonRoundState 后注入 BIND_TABLE
        hdr_parts.append(BIND_TABLE_BLOCK)
hdr_parts.append("\n} // namespace pk\n")
with open(os.path.join(SRCDIR, "world_ext_internal.h"), "w", encoding="utf-8", newline="\n") as fp:
    fp.write("".join(hdr_parts))
print("写出 world_ext_internal.h")
print("\n完成。")
