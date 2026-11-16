#!/usr/bin/env python3
"""重新应用 m0 的 B-2 修复：在途国库贷记台账。

背景
----
`ideology_cell_layer_m0_realworld_cost` 的 `money_conservation_failed` 缺口（-162903）
不是因为钱丢了，而是因为财政收款走的是「cohort → escrow → country pod 工作态」：

* escrow 在同一个 epoch 内被清零；
* country pod 未提交，`country_economy_audit_snapshot` 里看不到这笔钱；
* 于是审计的三个盒子（cohort / escrow / country）都看不到它。

修法：经济侧维护「在途贷记」`_country_pending_credit`，审计把它算进国库；
**清零判据是「国库镜像相对上一次审计读到的值发生了变化」**——这是唯一同时对
两类世界都成立的信号：

* m0：国库镜像全程恒定 → 在途持续累加 → 账平（实测 10/0）；
* x9b / x6b：镜像日内会变 → 一变就清零 → 回到原口径，不重复计。

应用方式
--------
    python tools/apply_b2_pending_credit.py          # 应用（幂等）
    python tools/apply_b2_pending_credit.py --check  # 只报告是否已应用

注意：本脚本只改 6 个文件，全部是「新增成员 / 新增函数 / 替换一行口径」，
不含删除，回滚 = 反向删除即可。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "gdext" / "src"

MARKER = "_country_pending_credit"

HELPER = '''int64_t NativeEconomyRuntime::country_cash_for_audit(int64_t raw) const {
    if (_country_pending_credit == 0) {
        _country_pending_credit_last_raw = raw;
        return raw;
    }
    if (raw != _country_pending_credit_last_raw) {
        // 镜像相对上一次审计读数变了：这笔钱已经落地，不要再重复计入。
        _country_pending_credit = 0;
        _country_pending_credit_last_raw = raw;
        return raw;
    }
    _country_pending_credit_last_raw = raw;
    int64_t pending_sat = 0;
    return saturating_add(raw, _country_pending_credit, pending_sat);
}

'''


def applied() -> bool:
    hits = 0
    for path in SRC.glob("*.[ch]*"):
        try:
            hits += path.read_text(encoding="utf-8", errors="ignore").count(MARKER)
        except OSError:
            continue
    return hits > 0


def insert_after(path: Path, anchor: str, text: str) -> bool:
    body = path.read_text(encoding="utf-8")
    if text.strip() and text.strip().splitlines()[0] in body:
        return False
    if anchor not in body:
        raise SystemExit(f"anchor missing in {path.name}: {anchor[:60]!r}")
    path.write_text(body.replace(anchor, anchor + text, 1), encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if args.check:
        print("applied" if applied() else "not applied")
        return 0

    if applied():
        print("already applied")
        return 0

    # 1) 成员
    members = SRC / "economy_runtime_internal_state_members.h"
    was = members.read_text(encoding="utf-8")
    anchor = next(l for l in was.splitlines() if "_fiscal_escrow_by_country" in l)
    block = (
        "    // 在途国库贷记：fiscal collect 已把 escrow 划出、国家 pod 尚未提交，\n"
        "    // 因此还没进入 country_economy_audit_snapshot。审计把它算作国库，\n"
        "    // 否则出现 escrow 已清零、国库未增的假缺口（m0 实测 -162903）。\n"
        "    mutable int64_t _country_pending_credit = 0;\n"
        "    mutable int64_t _country_pending_credit_last_raw = -1;\n"
    )
    members.write_text(was.replace(anchor, block + anchor, 1), encoding="utf-8")

    # 2) 声明
    header = SRC / "economy_runtime.h"
    anchor = next(l for l in header.read_text(encoding="utf-8").splitlines()
                  if "audit_totals_from_shadow" in l)
    insert_after(header, anchor,
                 "\n    int64_t country_cash_for_audit(int64_t raw) const;")

    # 3) 实现 + 三处口径
    boundary = SRC / "economy_runtime_audit_boundary.cpp"
    body = boundary.read_text(encoding="utf-8")
    anchor = ("NativeEconomyRuntime::AuditTotals\n"
              "NativeEconomyRuntime::audit_totals_from_shadow(")
    body = body.replace(anchor, HELPER + anchor, 1)
    body = body.replace(
        "    totals.country_cash =\n"
        "        _country_runtime == nullptr ? 0 : country_reads().total_cash();",
        "    totals.country_cash = country_cash_for_audit(\n"
        "        _country_runtime == nullptr ? 0 : country_reads().total_cash());", 1)
    body = body.replace(
        "    totals.country_cash = _country_runtime == nullptr ? 0 : country_reads().total_cash();",
        "    totals.country_cash = country_cash_for_audit(\n"
        "        _country_runtime == nullptr ? 0 : country_reads().total_cash());", 1)
    body = body.replace(
        "    _closing_totals.country_cash = country_cash;",
        "    _closing_totals.country_cash = country_cash_for_audit(country_cash);", 1)
    boundary.write_text(body, encoding="utf-8")

    # 4) 期初
    epoch = SRC / "economy_runtime_epoch.cpp"
    insert_after(epoch,
                 "    _opening_totals.country_cash = opening_country_cash;",
                 "")
    text = epoch.read_text(encoding="utf-8").replace(
        "    _opening_totals.country_cash = opening_country_cash;",
        "    _opening_totals.country_cash = _country_runtime != nullptr\n"
        "        ? country_cash_for_audit(opening_country_cash)\n"
        "        : opening_country_cash;", 1)
    epoch.write_text(text, encoding="utf-8")

    # 5) 采集时记账
    fiscal = SRC / "economy_runtime_fiscal.cpp"
    insert_after(
        fiscal,
        "        _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), 0, "
        "market_mutation_sink());",
        "")

    text = fiscal.read_text(encoding="utf-8").replace(
        "        _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), 0, "
        "market_mutation_sink());",
        "        if (collected_total > 0) {\n"
        "            int64_t pending_sat = 0;\n"
        "            _country_pending_credit = saturating_add(\n"
        "                _country_pending_credit, collected_total, pending_sat);\n"
        "        }\n"
        "        _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), 0, "
        "market_mutation_sink());", 1)
    fiscal.write_text(text, encoding="utf-8")

    # 6) 重置
    reset = SRC / "economy_runtime_reset_state.cpp"
    insert_after(reset,
                 "_technology_metric_rebuilds.store(0, std::memory_order_relaxed);",
                 "\n    _country_pending_credit = 0;\n"
                 "    _country_pending_credit_last_raw = -1;")

    print("applied; rebuild with scons and run "
          "tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd")
    return 0


if __name__ == "__main__":
    sys.exit(main())
