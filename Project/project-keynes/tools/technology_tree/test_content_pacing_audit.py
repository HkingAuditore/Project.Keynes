#!/usr/bin/env python3
"""Small catalog counterexamples for the production-pacing audit.

Run from any directory: python path/to/test_content_pacing_audit.py
The tests write temporary .tres fixtures and call the real offline auditor.
They do not modify the installed catalog or launch the simulation.
"""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rebalance_content_pacing import Profile, audit


class ContentPacingAuditTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="keynes-pacing-audit-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.network = {
            "eras": [{"id": era} for era in ("stone", "agrarian", "kingdom")],
            "nodes": [
                {
                    "id": f"tech.{era}",
                    "era_id": era,
                    "hard_prerequisite_ids": [],
                    "expected_bindings": [],
                }
                for era in ("stone", "agrarian", "kingdom")
            ],
            "application_intersections": [],
        }
        self.buildings = {}
        self.goods = {}
        self.resources = {}

    def profile(self, kind, id, technology, **fields):
        """Build actual resource text so parsing is exercised as well as audit."""
        fields = {"id": id, "display_name": id, "technology_tags": [technology], **fields}
        lines = ['[gd_resource type="Resource" format=3]', "", "[resource]"]
        for key, value in fields.items():
            if isinstance(value, list):
                packed = "PackedStringArray" if not value or isinstance(value[0], str) else "PackedInt64Array"
                serialized = packed + "(" + ", ".join(json.dumps(v) for v in value) + ")"
            else:
                serialized = json.dumps(value)
            lines.append(f"{key} = {serialized}")
        path = self.root / f"{kind}_{id}.tres"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        profile = Profile(path)
        table, binding_kind = (self.goods, 1) if kind == "good" else (self.buildings, 2)
        table[id] = profile
        node = next(n for n in self.network["nodes"] if n["id"] == technology)
        node["expected_bindings"].append({"kind": binding_kind, "id": id})
        return profile

    def good(self, id, technology, **fields):
        return self.profile("good", id, technology, **fields)

    def building(self, id, technology, **fields):
        return self.profile("building", id, technology, **fields)

    def result(self):
        return audit(self.network, self.buildings, self.goods, self.resources)

    def test_jewelry_license_before_any_workshop_is_rejected(self):
        # The actual regression: early jewelry permission, first producer later.
        self.good("jewelry", "tech.stone")
        self.building("jewelry_workshop", "tech.kingdom", output_good_ids=["jewelry"])
        errors, _, building_era, supply_era = self.result()
        self.assertIn("good_before_supply jewelry: 0 -> 2", errors)
        self.assertEqual(building_era["jewelry_workshop"], 2)
        self.assertEqual(supply_era["jewelry"], 2)

    def test_jewelry_permission_at_its_first_workshop_is_valid(self):
        self.good("jewelry", "tech.kingdom")
        self.building("jewelry_workshop", "tech.kingdom", output_good_ids=["jewelry"])
        self.assertEqual(self.result()[0], [])

    def test_high_step_before_its_lower_step_is_rejected(self):
        # Reproduces late-method predecessors installed on earlier base plants.
        self.good("raw_stone", "tech.stone")
        self.building(
            "quarry", "tech.agrarian", output_good_ids=["raw_stone"],
            industry_chain_id="production.raw_stone", progression_step=1,
            predecessor_building_ids=[],
        )
        self.building(
            "organized_quarry", "tech.stone", output_good_ids=["raw_stone"],
            industry_chain_id="production.raw_stone", progression_step=2,
            predecessor_building_ids=["quarry"],
        )
        errors = self.result()[0]
        self.assertTrue(
            any(e.startswith("progression_era_inversion ") and "organized_quarry" in e and "quarry" in e for e in errors),
            errors,
        )

    def install_delayed_input(self, required_q16):
        self.good("tools", "tech.agrarian")
        self.good("gathered_plants", "tech.stone")
        self.building("tool_workshop", "tech.agrarian", output_good_ids=["tools"])
        self.building(
            "gathering_camp", "tech.stone", input_good_ids=["tools"],
            input_required_q16=[required_q16], output_good_ids=["gathered_plants"],
        )

    def test_required_input_one_era_late_delays_real_supply(self):
        self.install_delayed_input(65536)
        errors, _, _, supply_era = self.result()
        self.assertIn("building_supply_delay gathering_camp: 0 -> 1", errors)
        self.assertIn("good_before_supply gathered_plants: 0 -> 1", errors)
        self.assertEqual(supply_era["gathered_plants"], 1)

    def test_soft_input_one_era_late_does_not_block_operation(self):
        self.install_delayed_input(32768)
        errors, _, _, supply_era = self.result()
        self.assertEqual(errors, [])
        self.assertEqual(supply_era["gathered_plants"], 0)

    def install_construction_materials(self):
        self.good("timber", "tech.stone", substitution_category_ids=["construction"], production_quality_level=0)
        self.good("steel", "tech.kingdom", substitution_category_ids=["construction"], production_quality_level=2)
        self.good("construction_components", "tech.stone")
        self.building("wood_camp", "tech.stone", output_good_ids=["timber"])
        self.building("steel_works", "tech.kingdom", output_good_ids=["steel"])

    def test_construction_bom_is_one_pool_not_all_materials_required(self):
        self.install_construction_materials()
        self.building(
            "building_yard", "tech.stone", construction_good_ids=["steel", "timber"],
            construction_quantities=[1000, 1000], output_good_ids=["construction_components"],
        )
        errors, _, _, supply_era = self.result()
        self.assertEqual(errors, [])
        self.assertEqual(supply_era["construction_components"], 0)

    def test_explicit_construction_substitute_prevents_false_delay(self):
        self.install_construction_materials()
        self.building(
            "building_yard", "tech.stone", construction_good_ids=["steel"],
            construction_quantities=[1000], construction_candidate_offsets=[0, 2],
            construction_candidate_good_ids=["steel", "timber"],
            output_good_ids=["construction_components"],
        )
        self.assertEqual(self.result()[0], [])

    def test_construction_category_substitute_prevents_false_delay(self):
        self.install_construction_materials()
        self.building(
            "building_yard", "tech.stone", construction_good_ids=["steel"],
            construction_quantities=[1000], construction_category_ids=["construction"],
            construction_min_quality_levels=[0], output_good_ids=["construction_components"],
        )
        self.assertEqual(self.result()[0], [])

    def test_category_quality_floor_still_rejects_inferior_early_material(self):
        self.install_construction_materials()
        self.building(
            "building_yard", "tech.stone", construction_good_ids=["steel"],
            construction_quantities=[1000], construction_category_ids=["construction"],
            construction_min_quality_levels=[2], output_good_ids=["construction_components"],
        )
        errors, _, _, supply_era = self.result()
        self.assertIn("building_supply_delay building_yard: 0 -> 2", errors)
        self.assertEqual(supply_era["construction_components"], 2)


if __name__ == "__main__":
    unittest.main()
