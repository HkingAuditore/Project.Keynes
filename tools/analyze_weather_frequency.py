#!/usr/bin/env python3
"""Save-side weather-frequency analysis for Project.Keynes.

计划 `docs/plans/weather-precipitation-frequency-plan.md` W1-3 的交付物：
从 `.pksv` 存档里解出 `CLM2` 气候段，算出与引擎侧探针
`tests/world/weather_frequency_probe.gd` 同一组指标，用于离线复核。

为什么需要这个工具：引擎侧探针只能跑「当前代码 + 新生成的测试图」，
而玩家反馈来自「已发布的代码 + 正在玩的那张图」。两边口径必须能对上，
否则修完只看探针会得出与玩家观感不一致的结论。

指标（与探针一致，定义见计划 §1）：
  M1 land_rain   陆地格中 target_type ∈ {RAIN,STORM,BLIZZARD,MONSOON} 的占比
  M2 conc        P̄_rainy / mean_P（同一 population）
  M3 五元组      ΣP / mean_P / P̄_rainy / conc / mean_P÷soft_cap 下界
  M4 hp_rain     ψ < −0.05 的格子中降水占比（只有存档侧有 ψ lane）
  M5 type_mix    8 种类型占比（display 与 target 各一份）
  M6 moist_sat   moisture==1.0 占比

恒等式 `area = 1/conc` 只在同一 population 内成立，所以 land / water / all 分开算。

用法::

    python tools/analyze_weather_frequency.py <save.pksv> [--json out.json] [--quiet]
    python tools/analyze_weather_frequency.py            # 取最新的 autosave

Windows 上存档在 ``%APPDATA%\\Godot\\app_userdata\\ProjectKeynes\\saves``。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

# CLM2 lane 顺序必须与 gdext/src/runtime_climate_authority.cpp 的
# CLIMATE_CELL_FLOAT_LANES / CLIMATE_U8_LANES / CLIMATE_I32_LANES 一致，
# 段 ABI 不匹配时直接报错，不猜。
CLIMATE_SECTION_ABI = 9
FLOAT_LANES = [
    "temperature", "temperature_30d_ema", "temperature_365d_ema",
    "temperature_baseline", "thermal_energy", "moisture",
    "plant_available_water", "water_balance_30d", "weather_precipitation",
    "weather_intensity", "vapor", "cloud_water", "cloud_cover", "convergence",
    "instability", "snow_cover", "snowpack", "sea_ice", "runoff", "groundwater",
    "river_storage", "river_discharge", "riparian_moisture", "vegetation_vitality",
    "vegetation_growth_pressure", "vegetation_heat_stress",
    "vegetation_drought_stress", "vegetation_cold_stress",
    "weather_transition_alpha", "synoptic_psi", "synoptic_psi_prev",
]
U8_LANES = [
    "weather_type", "weather_prev_type", "weather_target_type",
    "vegetation_succession_candidate", "vegetation", "base_vegetation",
    "terrain", "cover",
]
I32_LANES = ["vegetation_growth_streak", "vegetation_drought_streak"]

TYPE_NAMES = ["CLEAR", "RAIN", "STORM", "BLIZZARD", "DROUGHT", "FOG", "HEATWAVE", "MONSOON"]
PRECIP_TYPES = (1, 2, 3, 7)
# wf_is_water_terrain(): OCEAN=0, COAST=1, LAKE=18, RIVER?=19,20,21
WATER_TERRAIN = (0, 1, 18, 19, 20, 21)
SOFT_CAP_DEFAULT = 0.16
HP_PSI_THRESHOLD = -0.05


# ── zstd 解压 ────────────────────────────────────────────────────────────────
def _zstd_binary() -> str:
    env = os.environ.get("PK_ZSTD")
    if env and Path(env).exists():
        return env
    found = shutil.which("zstd")
    if found:
        return found
    for guess in (
        r"C:\ProgramData\anaconda3\Library\bin\zstd.exe",
        "/usr/bin/zstd",
        "/usr/local/bin/zstd",
    ):
        if Path(guess).exists():
            return guess
    raise SystemExit(
        "zstd not found. Install the `zstd` binary or the `zstandard` python module, "
        "or set PK_ZSTD=<path to zstd>."
    )


def _decompress(blob: bytes) -> bytes:
    if not blob:
        return b""
    try:
        import zstandard  # type: ignore

        return zstandard.ZstdDecompressor().decompress(blob)
    except ModuleNotFoundError:
        pass
    exe = _zstd_binary()
    fd, src = tempfile.mkstemp(suffix=".zst")
    os.close(fd)
    dst = src + ".raw"
    try:
        Path(src).write_bytes(blob)
        subprocess.run([exe, "-d", "-f", "-q", src, "-o", dst], check=True)
        return Path(dst).read_bytes()
    finally:
        for p in (src, dst):
            try:
                os.unlink(p)
            except OSError:
                pass


# ── 容器解析 ─────────────────────────────────────────────────────────────────
def load_pksv(path: Path) -> dict[str, bytes]:
    raw = path.read_bytes()
    if raw[:4] != b"PKSV":
        raise SystemExit(f"{path}: not a PKSV container (magic={raw[:4]!r})")
    header_len = struct.unpack_from("<I", raw, 8)[0]
    header = json.loads(raw[12:12 + header_len].decode("utf-8"))
    data = raw[12 + header_len:]
    out: dict[str, bytes] = {}
    for section in header["sections"]:
        blob = data[section["offset"]:section["offset"] + section["length"]]
        out[section["id"]] = _decompress(blob)
    return out


def find_climate(sections: dict[str, bytes]) -> tuple[str, bytes]:
    """PKSR 信封是 [marker][size][section bytes]，而 section bytes 自己也以 CLM2 开头。"""
    for sid, blob in sections.items():
        pos = blob.find(b"CLM2")
        while pos >= 0:
            size = struct.unpack_from("<I", blob, pos + 4)[0]
            inner = pos + 8
            if inner + 80 <= len(blob) and blob[inner:inner + 4] == b"CLM2":
                abi = struct.unpack_from("<I", blob, inner + 4)[0]
                if abi == CLIMATE_SECTION_ABI:
                    return sid, blob[inner:inner + size]
            pos = blob.find(b"CLM2", pos + 1)
    raise SystemExit(
        f"CLM2 section with ABI {CLIMATE_SECTION_ABI} not found; "
        "存档格式可能已升级，请同步 runtime_climate_authority.cpp 的 lane 列表"
    )


def parse_climate(section: bytes) -> tuple[dict, dict[str, np.ndarray]]:
    (_marker, abi, _rt_abi, cells, map_w, map_h, day, generation,
     _catalog_hash, _input_gen, _state_hash, payload_len, _checksum) = struct.unpack_from(
        "<IIIIIIqQQQQQQ", section, 0)
    payload = section[80:80 + payload_len]
    off = 0

    def u32() -> int:
        nonlocal off
        value = struct.unpack_from("<I", payload, off)[0]
        off += 4
        return value

    stored_cells = u32()
    if stored_cells != cells:
        raise SystemExit(f"cell count mismatch: header={cells} payload={stored_cells}")
    off += 8 + 8 + 8      # generation, climate_generation, committed_day
    off += 4 + 4          # climate_anomaly, annual_temperature_drift
    off += 8 + 8          # rng states
    history_cursor = u32()

    lanes: dict[str, np.ndarray] = {}
    for name in FLOAT_LANES:
        count = u32()
        lanes[name] = np.frombuffer(payload, dtype="<f4", count=count, offset=off).copy()
        off += 4 * count
    history_len = u32()
    off += 4 * history_len
    for name in U8_LANES:
        count = u32()
        lanes[name] = np.frombuffer(payload, dtype="u1", count=count, offset=off).copy()
        off += count
    for name in I32_LANES:
        count = u32()
        lanes[name] = np.frombuffer(payload, dtype="<i4", count=count, offset=off).copy()
        off += 4 * count

    meta = {
        "abi": abi, "cells": cells, "map": f"{map_w}x{map_h}", "day": day,
        "generation": generation, "history_cursor": history_cursor,
        "history_days": history_len // max(1, cells),
    }
    return meta, lanes


# ── 指标 ────────────────────────────────────────────────────────────────────
def _rates(precip: np.ndarray, raining: np.ndarray, soft_cap: float) -> dict:
    total = int(precip.size)
    rainy = int(raining.sum())
    sum_precip = float(precip.sum())
    mean_precip = sum_precip / max(1, total)
    mean_precip_rainy = (sum_precip / rainy) if rainy > 0 else 0.0
    conc = (mean_precip_rainy / mean_precip) if mean_precip > 0 else 0.0
    return {
        "cells": total,
        "rainy_cells": rainy,
        "area_pct": 100.0 * rainy / max(1, total),
        "sum_precip": sum_precip,
        "mean_precip": mean_precip,
        "mean_precip_rainy": mean_precip_rainy,
        "concentration": conc,
        "identity_area_pct": (100.0 * mean_precip / mean_precip_rainy) if mean_precip_rainy > 0 else 0.0,
        "lower_bound_pct": 100.0 * mean_precip / soft_cap if soft_cap > 0 else 0.0,
    }


def analyze(meta: dict, lanes: dict[str, np.ndarray], soft_cap: float) -> dict:
    precip = lanes["weather_precipitation"].astype(np.float64)
    target = lanes["weather_target_type"].astype(np.int32)
    display = lanes["weather_type"].astype(np.int32)
    terrain = lanes["terrain"].astype(np.int32)
    psi = lanes["synoptic_psi"].astype(np.float64)
    moisture = lanes["moisture"].astype(np.float64)

    land = ~np.isin(terrain, WATER_TERRAIN)
    raining = np.isin(target, PRECIP_TYPES)

    out: dict = {"meta": meta, "soft_cap": soft_cap}
    out["land"] = _rates(precip[land], raining[land], soft_cap)
    out["water"] = _rates(precip[~land], raining[~land], soft_cap)
    out["all"] = _rates(precip, raining, soft_cap)

    hist_target = {name: int((target == i).sum()) for i, name in enumerate(TYPE_NAMES)}
    hist_display = {name: int((display == i).sum()) for i, name in enumerate(TYPE_NAMES)}
    out["type_hist_target"] = hist_target
    out["type_hist_display"] = hist_display

    hp = psi < HP_PSI_THRESHOLD
    out["psi_high_pressure_cells"] = int(hp.sum())
    out["psi_high_pressure_rain_pct"] = (
        100.0 * float(raining[hp].mean()) if hp.any() else 0.0)
    out["psi_positive_cells"] = int((psi > 0.05).sum())
    out["psi_median"] = float(np.median(psi))
    out["convergence_median"] = float(np.median(lanes["convergence"]))
    out["moisture_sat_pct"] = 100.0 * float((moisture >= 0.99999).mean())
    out["land_moisture_median"] = float(np.median(moisture[land])) if land.any() else 0.0
    out["moisture_median"] = float(np.median(moisture))

    # 自洽性
    checks = []
    for name in ("land", "water", "all"):
        row = out[name]
        conc = row["concentration"]
        if conc <= 0:
            checks.append({"id": f"C1-{name}", "ok": False, "detail": "concentration=0"})
            continue
        expected = 100.0 / conc
        rel = abs(row["area_pct"] - expected) / max(expected, 1e-6)
        checks.append({"id": f"C1-{name}", "ok": rel < 0.05,
                       "detail": f"area={row['area_pct']:.2f}% 1/conc={expected:.2f}% rel={rel:.4f}"})
        checks.append({"id": f"C2-{name}", "ok": row["area_pct"] >= row["lower_bound_pct"] - 1e-6,
                       "detail": f"area={row['area_pct']:.2f}% lower={row['lower_bound_pct']:.2f}%"})
    out["checks"] = checks
    return out


# ── 输出 ────────────────────────────────────────────────────────────────────
def summarize(result: dict) -> str:
    meta = result["meta"]
    lines = [
        f"== day {meta['day']}  {meta['map']}  {meta['cells']} cells  ABI {meta['abi']} ==",
        f"  soft_cap={result['soft_cap']:.3f}  history={meta['history_days']}d",
    ]
    for name in ("land", "water", "all"):
        row = result[name]
        lines.append(
            f"  {name.upper():5s} cells={row['cells']:5d} rain={row['area_pct']:5.1f}% "
            f"mean_P={row['mean_precip']:.4f} P_bar={row['mean_precip_rainy']:.4f} "
            f"conc={row['concentration']:.3f} lower={row['lower_bound_pct']:.1f}%")
    lines.append(
        f"  hp_rain={result['psi_high_pressure_rain_pct']:.1f}% "
        f"(psi<{HP_PSI_THRESHOLD}, {result['psi_high_pressure_cells']} cells)  "
        f"psi_med={result['psi_median']:.3f}  conv_med={result['convergence_median']:.3f}")
    lines.append(
        f"  moist_sat={result['moisture_sat_pct']:.1f}%  land_moist_med={result['land_moisture_median']:.3f}")
    cells = max(1, result["all"]["cells"])
    mix = " ".join(f"{k}={100.0 * v / cells:.1f}%" for k, v in result["type_hist_target"].items())
    lines.append(f"  target type_mix {mix}")
    display_mix = " ".join(f"{k}={100.0 * v / cells:.1f}%" for k, v in result["type_hist_display"].items())
    lines.append(f"  display type_mix {display_mix}")
    for check in result["checks"]:
        if not check["ok"]:
            lines.append(f"  [FAIL] {check['id']}: {check['detail']}")
    failed = sum(1 for c in result["checks"] if not c["ok"])
    lines.append(f"  self-checks: {len(result['checks']) - failed}/{len(result['checks'])} passed")
    return "\n".join(lines)


def newest_autosave() -> Path | None:
    base = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "ProjectKeynes" / "saves"
    if not base.is_dir():
        return None
    candidates = sorted(base.glob("*.pksv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("save", nargs="?", help="path to .pksv (default: newest autosave)")
    parser.add_argument("--json", dest="json_out", help="write the full result as JSON here")
    parser.add_argument("--soft-cap", type=float, default=SOFT_CAP_DEFAULT,
                        help=f"weather_extreme_precip_soft_cap (default {SOFT_CAP_DEFAULT})")
    parser.add_argument("--quiet", action="store_true", help="only print (and optionally write) JSON")
    args = parser.parse_args(argv)

    path = Path(args.save) if args.save else newest_autosave()
    if path is None or not path.exists():
        raise SystemExit("no save given and no autosave found")

    sections = load_pksv(path)
    section_id, section = find_climate(sections)
    meta, lanes = parse_climate(section)
    meta["source"] = str(path)
    meta["section"] = section_id
    result = analyze(meta, lanes, args.soft_cap)

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    if args.quiet:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(summarize(result))
        if args.json_out:
            print(f"  wrote {args.json_out}")
    return 0 if all(c["ok"] for c in result["checks"]) else 1


if __name__ == "__main__":
    sys.exit(main())
