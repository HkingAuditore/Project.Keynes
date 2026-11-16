"""Append the first family effect that moves cohort satisfaction.

`family_official_buffs.json` is the official source for family effects; the .tres
is only a thin wrapper that `FamilyOfficialCatalog.hydrate_effect_catalog()`
fills from this file. The new effect mirrors `trade_nation` (the only COUNTRY
domain effect) but uses ADD on `family.country.patronage_satisfaction`, whose
terms are already basis points on `economy.profession.<pid>.satisfaction_bp`.

Idempotent: re-running does nothing once the key exists.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

JSON_PATH = Path(
    r"<repo>\Project\project-keynes"
    r"\data\economy\family_official_buffs.json"
)

# Q16 magnitudes for prestige 0 (unranked) then I..V. Multiplied into the
# definition's authored basis points: 0.6x .. 1.1x.
MAGNITUDES = [39322, 45875, 52429, 58982, 65536, 72090]

EFFECT = {
    "key": "patronage_house",
    "display_name": "门客之家",
    "description": (
        "威望Ⅰ：该家族所在国全部地块的匠户与学者满意度 +1.1，书吏与雇工 +0.7。\n"
        "威望Ⅱ：该家族所在国全部地块的匠户与学者满意度 +1.2，书吏与雇工 +0.8。\n"
        "威望Ⅲ：该家族所在国全部地块的匠户与学者满意度 +1.4，书吏与雇工 +0.9。\n"
        "威望Ⅳ：该家族所在国全部地块的匠户与学者满意度 +1.5，书吏与雇工 +1.0。\n"
        "威望Ⅴ：该家族所在国全部地块的匠户与学者满意度 +1.7，书吏与雇工 +1.1。"
    ),
    "weight": 100,
    "source_kind": 1,
    "target_domain": 3,
    "operation": 0,
    "lifecycle": 0,
    "duration_days": -1,
    "stack_policy": 0,
    "max_stacks": 1,
    "target_selector_kind": 3,
    "target_selector_id": "",
    "exclusion_keys": [],
    "magnitude_by_prestige_q16": MAGNITUDES,
    "commands": [
        {
            "action": 1,
            "domain": 1,
            "opcode": 1,
            "target_resolver": 1,
            "command_key": "family.country.patronage_satisfaction",
            "definition_key": "family.country.patronage_satisfaction",
            "duration_days": -1,
            "stacks": 1,
            "value_mode": 1,
        }
    ],
    "instructions": [
        {"op": 2, "arg0": 0, "value_q16": 0},
        {"op": 11, "arg0": 0, "value_q16": 0},
        {"op": 12, "arg0": 0, "value_q16": 0},
    ],
    "trigger_definition_keys_by_tier": [],
    "trigger_reward_target": 0,
    "cadence_days": 1,
    "prestige_descriptions": [
        "威望Ⅰ：该家族所在国全部地块的匠户与学者满意度 +1.1，书吏与雇工 +0.7。",
        "威望Ⅱ：该家族所在国全部地块的匠户与学者满意度 +1.2，书吏与雇工 +0.8。",
        "威望Ⅲ：该家族所在国全部地块的匠户与学者满意度 +1.4，书吏与雇工 +0.9。",
        "威望Ⅳ：该家族所在国全部地块的匠户与学者满意度 +1.5，书吏与雇工 +1.0。",
        "威望Ⅴ：该家族所在国全部地块的匠户与学者满意度 +1.7，书吏与雇工 +1.1。",
    ],
    "appearance_condition": "该家族定居一年以上，且当地已有作坊、学堂或书吏",
    "target_copy": "该家族所在国的全部地块",
    "prerequisite_technology_any": False,
    "prerequisite_technology_keys": [],
    "random_pool_eligible": True,
}


def main() -> int:
    raw = JSON_PATH.read_text(encoding="utf-8-sig")
    document = json.loads(raw)
    effects = document.get("effects")
    if not isinstance(effects, list):
        print("ERROR: effects array missing", file=sys.stderr)
        return 1
    if any(row.get("key") == EFFECT["key"] for row in effects):
        print("nothing to do: %s already present" % EFFECT["key"])
        return 0
    # Insert after `trade_nation` so the two COUNTRY-domain effects stay
    # adjacent in the file, which makes the country-scope pair easy to audit.
    insert_at = len(effects)
    for index, row in enumerate(effects):
        if row.get("key") == "trade_nation":
            insert_at = index + 1
            break
    effects.insert(insert_at, EFFECT)
    JSON_PATH.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8-sig",
        newline="\n",
    )
    print("inserted %s at index %d (effects=%d)" % (
        EFFECT["key"], insert_at, len(effects)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
