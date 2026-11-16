"""Append satisfaction-source modifier definitions to the default modifier catalog.

The three authoring channels that can reach cohort satisfaction directly
(narrative events, political regimes, family effects) all apply a Modifier
definition.  Until this change the catalog only carried satisfaction terms
inside ideology card definitions, so an event or a regime had no definition to
apply.  This script appends the missing, reusable definitions.

Idempotent: re-running it is a no-op once every definition key exists.
"""

from __future__ import annotations

import sys
from pathlib import Path

CATALOG = Path(
    r"<repo>\Project\project-keynes\data\modifiers"
    r"\default_modifier_catalog.tres"
)

# (sub_resource id stem, definition key, display name, description, terms)
# terms: (profession id, ADD value in basis points)
DEFINITIONS: list[tuple[str, str, str, str, list[tuple[str, float]]]] = [
    (
        "NarrativeReliefAgrarianSatisfaction",
        "narrative.relief.agrarian_satisfaction",
        "叙事·赈济农户",
        "开仓赈济、平粜贷种：农耕各阶层的满意度在时效内上升。",
        [
            ("household_farmer", 350.0),
            ("tenant_farmer", 400.0),
            ("sharecropper", 400.0),
            ("serf", 400.0),
            ("subsistence_farmer", 350.0),
        ],
    ),
    (
        "NarrativeLevyLaborSatisfaction",
        "narrative.levy.labor_satisfaction",
        "叙事·征发民夫",
        "征发劳役：雇工与力役阶层的满意度在工期内下降。",
        [
            ("agricultural_worker", -400.0),
            ("worker", -400.0),
            ("miner", -400.0),
            ("construction_worker", -500.0),
            ("corvee_worker", -500.0),
        ],
    ),
    (
        "RegimeEarlyClanCohesion",
        "regime.early_clan.cohesion",
        "政体·氏族庇护",
        "早期氏族以血缘分配田土与庇护：佃农、农奴与小农的满意度大幅上升，商贾明显受损。",
        # 政体是唯一「无成本、全民、永久」的来源，核心阶层落在 ±450~750 bp
        # （100 bp = 满意度 1.0 点，满分 100 点）。旧值 100~200 bp 低于一张
        # 限时事件，玩家读到的只是舍入噪声；幅度梯见
        # docs/cpp-dots-runtime/satisfaction-runtime.md。
        [
            ("household_farmer", 450.0),
            ("subsistence_farmer", 450.0),
            ("tenant_farmer", 600.0),
            ("serf", 600.0),
            ("landlord", 300.0),
            ("merchant", -600.0),
        ],
    ),
    (
        "RegimeLocalCouncilCohesion",
        "regime.local_council.cohesion",
        "政体·议会共治",
        "地方议会让市镇与工场有发言权：商人、工场主与工匠显著满意，地主明显受损。",
        [
            ("merchant", 750.0),
            ("artisan", 450.0),
            ("journeyman", 450.0),
            ("industrialist", 600.0),
            ("worker", 300.0),
            ("landlord", -600.0),
        ],
    ),
    (
        "FamilyCountryPatronageSatisfaction",
        "family.country.patronage_satisfaction",
        "家族·门客供养",
        "名门养士、周济匠户：技艺与文教阶层的满意度上升。",
        [
            ("artisan", 150.0),
            ("scribe", 100.0),
            ("scholar", 150.0),
            ("worker", 100.0),
        ],
    ),
]


def term_block(definition_stem: str, index: int, profession: str, value: float) -> str:
    return (
        f'[sub_resource type="Resource" id="Term{definition_stem}{index}"]\n'
        f'script = ExtResource("4_term")\n'
        f'stat_key = &"economy.profession.{profession}.satisfaction_bp"\n'
        f'value = {value:g}\n'
    )


def definition_block(
    stem: str, key: str, display_name: str, description: str, term_count: int
) -> str:
    refs = ", ".join(
        f'SubResource("Term{stem}{index}")' for index in range(term_count)
    )
    return (
        f'[sub_resource type="Resource" id="Def{stem}"]\n'
        f'script = ExtResource("3_definition")\n'
        f'key = &"{key}"\n'
        f'display_name = "{display_name}"\n'
        f'description = "{description}"\n'
        f'domain = 1\n'
        f'stack_policy = 1\n'
        f'max_stacks = 1\n'
        f'default_duration_days = -1\n'
        f'terms = Array[Resource]([{refs}])\n'
    )


def main() -> int:
    text = CATALOG.read_text(encoding="utf-8")
    new_blocks: list[str] = []
    new_refs: list[str] = []
    for stem, key, display_name, description, terms in DEFINITIONS:
        # Only the definition key is authoritative for idempotence: a partial
        # earlier run must still be completed, but a complete one is skipped.
        if f'key = &"{key}"' in text:
            print(f"skip (already present): {key}")
            continue
        for index, (profession, value) in enumerate(terms):
            new_blocks.append(term_block(stem, index, profession, value))
        new_blocks.append(
            definition_block(stem, key, display_name, description, len(terms))
        )
        new_refs.append(f'SubResource("Def{stem}")')
        print(f"add: {key} ({len(terms)} terms)")

    if not new_refs:
        print("nothing to do")
        return 0

    marker = "\n[resource]\n"
    insert_at = text.find(marker)
    if insert_at < 0:
        print("ERROR: [resource] block not found", file=sys.stderr)
        return 1
    payload = "\n" + "\n".join(new_blocks)
    text = text[:insert_at] + payload + text[insert_at:]

    array_head = "definitions = Array[Resource](["
    array_at = text.find(array_head)
    if array_at < 0:
        print("ERROR: definitions array not found", file=sys.stderr)
        return 1
    close_at = text.find("])", array_at)
    if close_at < 0:
        print("ERROR: definitions array not closed", file=sys.stderr)
        return 1
    text = text[:close_at] + ", " + ", ".join(new_refs) + text[close_at:]

    CATALOG.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {CATALOG} (+{len(new_refs)} definitions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
