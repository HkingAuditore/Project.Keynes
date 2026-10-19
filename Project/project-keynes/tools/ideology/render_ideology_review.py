"""Render the authored ideology card table into a readable review page.

This is a read-only report tool: it imports the generator, reads the live display
names out of the resource files, and writes one HTML page so the content can be
reviewed as prose instead of Python tuples. Running it never touches the .tres
catalogs.

Usage (from Project/project-keynes):
    python tools/ideology/render_ideology_review.py [output.html]
"""
from __future__ import annotations

import html
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = pathlib.Path(__file__).resolve().with_name("generate_ideology_catalog.py")

_spec = importlib.util.spec_from_file_location("gen", GENERATOR)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)

TERRAIN_CN: dict[str, str] = {}
LANDFORM_CN: dict[str, str] = {}
GOOD_CN: dict[str, str] = {}
BUILDING_CN: dict[str, str] = {}
PROFESSION_CN: dict[str, str] = {}
RESOURCE_CN: dict[str, str] = {}
SIGNAL_CN: dict[str, str] = {}
PROFILE_CN = {
    "dryland_crop": "旱作", "foraging_plants": "采集作物", "paddy_crop": "水田",
    "pasture_livestock": "畜牧", "phenology_observation": "物候观测",
    "plantation_crop": "种植园作物",
}
HAZARD_CN = {"drought": "旱", "flood": "涝", "cold_stress": "寒", "heat_stress": "热"}
SECTOR_CN = {"agriculture": "农业", "extractive": "采掘", "manufacturing": "制造",
             "energy": "能源", "knowledge": "知识"}
RARITY_CN = {1: "寻常", 2: "珍稀", 3: "传世"}
SCHOOL_ORDER = gen.SCHOOL_ORDER


def _load_display_names(directory: pathlib.Path, target: dict[str, str],
                        field: str = "display_name") -> None:
    for path in directory.glob("*.tres"):
        text = path.read_text(encoding="utf-8", errors="replace")
        match = re.search(rf'^{field} = "([^"]*)"', text, re.MULTILINE)
        if match:
            target[path.stem] = match.group(1)


def _load_static_names() -> None:
    for path in (ROOT / "data/terrain").glob("*.tres"):
        text = path.read_text(encoding="utf-8", errors="replace")
        match = re.search(r'^display_name_cn = "([^"]*)"', text, re.MULTILINE)
        if match:
            TERRAIN_CN[path.stem] = match.group(1)
    landform_src = (ROOT / "scripts/geography/landform_type.gd").read_text(
        encoding="utf-8")
    for member, name in re.findall(r'LF\.([A-Z_]+):\s*"([^"]+)"', landform_src):
        LANDFORM_CN[member.lower()] = name
    _load_display_names(ROOT / "data/goods", GOOD_CN)
    _load_display_names(ROOT / "data/economy/buildings", BUILDING_CN)
    _load_display_names(ROOT / "data/economy/professions", PROFESSION_CN)
    signal_src = (ROOT / "scripts/research/research_signal_catalog.gd").read_text(
        encoding="utf-8")
    for signal_id, name in re.findall(r'\[\s*"([a-z][a-z_]*\.[a-z0-9_.]+)"\s*,\s*"([^"]+)"',
                                      signal_src):
        SIGNAL_CN[signal_id] = name
        if signal_id.startswith("resource."):
            RESOURCE_CN[signal_id[len("resource."):]] = name


def _cn(mapping: dict[str, str], key: str) -> str:
    return mapping.get(key, key)


SCALAR_CN = {
    gen.AGRI: "全国农业产出", gen.EXTR: "全国采掘产出", gen.MANU: "全国制造产出",
    gen.ENER: "全国能源产出", gen.KNOW: "全国知识产出",
    gen.R_AGRI: "农业研究效率", gen.R_ENG: "工程研究效率",
    gen.R_SCI: "科学研究效率", gen.R_SOC: "社会研究效率",
    gen.R_COST: "研究成本", gen.R_INST: "研究机构产出",
    gen.INPUT: "全社会生产投入", gen.CONSUME: "全社会家庭消费",
    gen.RES_USE: "全社会自然资源耗用", gen.DEATH: "人口自然死亡率",
    gen.B_COST: "国家建设成本", gen.T_CAP: "国内贸易容量",
    gen.T_SPEED: "贸易速度", gen.DROUGHT: "旱灾损失", gen.FLOOD: "洪灾损失",
    gen.COLD: "寒害损失", gen.HEAT: "热害损失", gen.POINTS: "理念点获取",
}


def describe_stat(stat: str) -> str:
    """Turn one stat key into the Chinese effect line a player would read."""
    # Exact scalar keys win first: `country.resource.use_factor` is the
    # society-wide one and has no per-resource segment, so the selector branches
    # below would mis-parse it.
    if stat in SCALAR_CN:
        return SCALAR_CN[stat]
    if ".terrain." in stat:
        _, _, _, terrain, tail = stat.split(".", 4)
        sector = tail.replace("_factor", "")
        return f"{_cn(TERRAIN_CN, terrain)}地形上的{SECTOR_CN.get(sector, sector)}产出"
    if ".landform." in stat:
        _, _, _, landform, tail = stat.split(".", 4)
        sector = tail.replace("_factor", "")
        return f"{_cn(LANDFORM_CN, landform)}地貌上的{SECTOR_CN.get(sector, sector)}产出"
    if ".climate.profile." in stat:
        parts = stat.split(".")
        profile, hazard = parts[3], parts[4].replace("_loss_factor", "")
        return f"{_cn(PROFILE_CN, profile)}的{HAZARD_CN.get(hazard, hazard)}灾损失"
    if ".good." in stat:
        parts = stat.split(".")
        good = _cn(GOOD_CN, parts[3].replace("_factor", ""))
        return {"output": f"全国{good}产出", "input": f"{good}生产投入",
                "consumption": f"{good}家庭消费"}.get(parts[1], f"{good}")
    if ".resource." in stat:
        parts = stat.split(".")
        if len(parts) < 4:
            return stat
        resource = _cn(RESOURCE_CN, parts[2])
        if parts[3] == "use_factor":
            return f"{resource}开采耗用"
        return f"{resource}管护再生"
    if ".building." in stat:
        parts = stat.split(".")
        return f"{_cn(BUILDING_CN, parts[3].replace('_factor', ''))}产出"
    if ".tax." in stat:
        parts = stat.split(".")
        return f"{_cn(PROFESSION_CN, parts[3])}所得税率"
    return stat


def render() -> str:
    _load_static_names()
    by_era: dict[int, list] = {}
    for row in gen.CARDS:
        by_era.setdefault(row[4], []).append(row)
    total = len(gen.CARDS)
    gated = sum(1 for row in gen.CARDS if row[7])

    parts: list[str] = []
    parts.append(
        "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
        "<title>理念卡表审阅</title><style>"
        ":root{--bg:#12141a;--panel:#1a1d26;--line:#2b3040;--ink:#e8eaf0;"
        "--dim:#9aa3b8;--good:#7fd18b;--bad:#e08a7a;--accent:#c8a45c;}"
        "*{box-sizing:border-box}"
        "body{margin:0;background:var(--bg);color:var(--ink);"
        "font:15px/1.7 -apple-system,'Segoe UI','Microsoft YaHei',sans-serif;}"
        ".wrap{max-width:1080px;margin:0 auto;padding:40px 24px 80px}"
        "h1{font-size:26px;margin:0 0 6px;font-weight:650}"
        ".lede{color:var(--dim);margin:0 0 28px;font-size:14px}"
        "h2{font-size:17px;margin:44px 0 14px;padding-bottom:8px;"
        "border-bottom:1px solid var(--line);color:var(--accent);font-weight:600}"
        ".card{background:var(--panel);border:1px solid var(--line);border-radius:10px;"
        "padding:14px 16px;margin:0 0 10px}"
        ".head{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}"
        ".name{font-size:16px;font-weight:650}"
        ".tag{font-size:11px;padding:1px 7px;border-radius:99px;border:1px solid var(--line);"
        "color:var(--dim);white-space:nowrap}"
        ".detail{color:var(--dim);font-size:13.5px;margin:6px 0 10px}"
        ".row{display:flex;gap:8px;font-size:13.5px;margin:3px 0;align-items:baseline}"
        ".label{color:var(--dim);min-width:42px;flex:0 0 auto}"
        ".cond{color:var(--accent)}"
        ".good{color:var(--good)}.bad{color:var(--bad)}"
        ".stat{display:inline-block;margin-right:14px;white-space:nowrap}"
        "</style></head><body><div class=\"wrap\">")
    parts.append("<h1>理念卡表 · 条件 / 对象 / 代价</h1>")
    parts.append(
        f"<p class=\"lede\">共 {total} 张，其中 {gated} 张带地理信号硬门槛"
        f"（{gated * 100 // total}%）。每张卡的绿灯是收益、红灯是代价；"
        "灰色标签是学派 / 稀有度 / 互斥组。</p>")

    for era in sorted(by_era):
        rows = by_era[era]
        parts.append(f"<h2>{gen.ERA_NAMES[era]} · {len(rows)} 张</h2>")
        for key, name, school, rarity, _era, exclusion, tech, signals, detail, terms in rows:
            tags = [f"{gen.SCHOOL_NAMES[school]}", RARITY_CN[rarity]]
            if exclusion:
                tags.append(f"互斥 {exclusion}")
            if tech:
                tags.append(tech.replace("tech.", ""))
            parts.append("<div class=\"card\">")
            parts.append(
                "<div class=\"head\"><span class=\"name\">%s</span>%s</div>"
                % (html.escape(name),
                   "".join(f"<span class=\"tag\">{html.escape(t)}</span>" for t in tags)))
            parts.append(f"<div class=\"detail\">{html.escape(detail)}</div>")
            if signals:
                cond = " · ".join(_cn(SIGNAL_CN, s) for s in signals)
                parts.append(
                    "<div class=\"row\"><span class=\"label\">条件</span>"
                    f"<span class=\"cond\">国土上须已发现：{html.escape(cond)}</span></div>")
            else:
                parts.append(
                    "<div class=\"row\"><span class=\"label\">条件</span>"
                    "<span class=\"cond\">无地理门槛</span></div>")
            buffs, costs = [], []
            for stat, value in terms:
                pct = int(round((value - 1.0) * 100))
                if pct == 0:
                    continue
                down = gen._is_downside(stat, value)
                line = (f"<span class=\"{'bad' if down else 'good'} stat\">{pct:+d}% "
                        f"{html.escape(describe_stat(stat))}</span>")
                (costs if down else buffs).append(line)
            parts.append(
                "<div class=\"row\"><span class=\"label\">收益</span><span>%s</span></div>"
                % ("".join(buffs) or "—"))
            parts.append(
                "<div class=\"row\"><span class=\"label\">代价</span><span>%s</span></div>"
                % ("".join(costs) or "—"))
            parts.append("</div>")

    parts.append("<h2>联动组合</h2>")
    for key, name, cards, terms in gen.NAMED_SYNERGIES:
        names = " + ".join(
            next((row[1] for row in gen.CARDS if row[0] == c), c) for c in cards)
        lines = []
        for stat, value in terms:
            pct = int(round((value - 1.0) * 100))
            down = gen._is_downside(stat, value)
            lines.append(f"<span class=\"{'bad' if down else 'good'} stat\">{pct:+d}% "
                         f"{html.escape(describe_stat(stat))}</span>")
        parts.append(
            f"<div class=\"card\"><div class=\"head\"><span class=\"name\">"
            f"{html.escape(name)}</span><span class=\"tag\">{html.escape(names)}</span>"
            f"</div><div class=\"row\"><span class=\"label\">联动</span>"
            f"<span>{''.join(lines)}</span></div></div>")

    parts.append("</div></body></html>")
    return "\n".join(parts)


def main() -> None:
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else \
        ROOT / "tmp/ideology_card_review.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(), encoding="utf-8", newline="\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
