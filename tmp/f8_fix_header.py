# -*- coding: utf-8 -*-
from pathlib import Path

p = Path("docs/cpp-dots-runtime/authority-migration.md")
lines = p.read_text(encoding="utf-8").splitlines(True)
new = (
    "更新时间：2026-09-12（Effect F8 已放行：`implemented` 与生产 request 均为 `0x866`；Climate /\n"
    "Country / Modifier 仍 ACTIVE；G8/H8 未做）\n"
    "\n"
    "**一句话现状**：十二个 domain 里 Climate、Country、Modifier 与 Effect 已是生产默认权威（`implemented_domain_mask =\n"
    "CLIMATE|COUNTRY|MODIFIER|EFFECT|COMMIT = 0x866`；Climate 滞后一日回灌，Country 经 Host read-view 回写，\n"
    "Modifier/Effect snapshot 回灌 legacy runtime）。`runtime_climate_authority_enabled` 为真时生产\n"
    "请求 `authoritative_domain_mask=0x866`。关掉该开关则退回 SHADOW：同步 Country / 主线程\n"
    "modifier·effect daily / Climate 回主线程。整图 ACTIVE 仍禁止，放行仍是 **逐域**的。Country D1–D12、\n"
    "Modifier E2–E8 与 Effect F8 完成。\n"
    "\n"
)
i = 1
while i < len(lines) and not lines[i].startswith("Ideology G2"):
    i += 1
out = [lines[0], new] + lines[i:]
p.write_text("".join(out), encoding="utf-8", newline="\n")
print("header fixed, ideology at", i)
