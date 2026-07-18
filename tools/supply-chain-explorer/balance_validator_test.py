import unittest

import numpy as np

from balance_validator import BalanceValidator


def fixture():
    model = {
        "schema": "project-keynes-economy-balance-model",
        "schema_version": 1,
        "scales": {"goods": 1000, "money": 10000, "ratio": 65536, "resource_quantity": 100},
        "economy_profile": {"market_cycle_days": 5, "merchant_market_making_days_q16": 30 * 65536},
        "eras": [{"id": "stone", "display_name": "石器时代", "order": 0, "tags": ["tech.hunting"]}],
        "goods": [{
            "id": "meat", "display_name": "肉", "default_price": 10000,
            "merchant_buy_price_factor_q16": 65536, "inventory_target_ratio_q16": 65536,
            "demand_price_elasticity_q16": 65536, "price_adjust_q16": 512,
            "min_price": 1, "max_price": 1000000, "eraPrimary": "stone", "eraOrder": 0,
            "substitutionCategories": ["food"], "production_quality_level": 0,
            "production_efficiency_q16": 65536, "trade_enabled": False,
        }],
        "resources": [{
            "id": "wild", "display_name": "野生动物", "eraPrimary": "stone", "eraOrder": 0,
            "temp_lo": 0, "temp_hi": 1, "climate_temp_opt": 0.5, "climate_temp_tol": 1,
            "climate_moisture_opt": 0.5, "climate_moisture_tol": 1,
            "runtime_climate_fit_weight": 0, "ecology_capacity": 100,
            "ecology_growth_rate": 0.02, "ecology_immigration": 0,
            "ecology_stress_mortality_rate": 0,
        }],
        "professions": [{
            "id": "hunter", "display_name": "猎人", "default_consumption_plan_id": "hunter_plan",
            "eraPrimary": "stone", "eraOrder": 0,
        }],
        "needs": [{"id": "food", "display_name": "食物", "living_cost_weight_q16": 65536}],
        "plans": [{
            "id": "hunter_plan", "needDetails": [{
                "id": "food", "baseQty": 1000, "variants": [{
                    "id": "meat", "preferenceQ16": 65536,
                    "components": [{"good": "meat", "qty": 1000}],
                }],
            }],
        }],
        "buildings": [{
            "id": "camp", "display_name": "营地", "eraPrimary": "stone", "eraOrder": 0,
            "upgrade_family_id": "hunt", "upgrade_tier": 1, "owner_profession_id": "hunter",
            "owner_slots_per_building": 1, "jobs": [{
                "profession": "hunter", "slots": 1, "role": "owner", "refWage": 0,
            }],
            "consumes": [], "produces": [{"good": "meat", "qty": 2000}],
            "extracts": [{"resource": "wild", "mode": "extract", "access": "local", "qty": 10}],
            "resource_generation_ids": [], "resource_generation_quantities_per_day": [],
            "resource_generation_floor_q16": 0, "target_operating_margin_q16": 6554,
        }],
    }
    scenario = {
        "era": "stone", "default_building_count": 1, "solve_utilization": False,
        "utilization": 0.5, "sell_through": 1.0,
        "resource_context": {"default": {"temperature": 0.5, "moisture": 0.5}, "wild": {"reserve": 5000}},
        "projection_days": [30],
    }
    return model, scenario


class BalanceValidatorTests(unittest.TestCase):
    def test_evaluates_building_household_and_local_resource(self):
        model, scenario = fixture()
        validator = BalanceValidator(model, scenario)
        evaluated = validator.evaluate(np.asarray([0.5]))
        self.assertEqual(evaluated["harvest"]["wild"], 5)
        self.assertEqual(evaluated["goods"][0]["supply"], 1000)
        self.assertEqual(evaluated["goods"][0]["household_demand"], 1000)
        self.assertFalse(any(x["code"] == "nonlocal_harvest" for x in validator.static_audit()))

    def test_detects_nonlocal_resource_access(self):
        model, scenario = fixture()
        model["buildings"][0]["extracts"][0]["access"] = "neighbor"
        audit = BalanceValidator(model, scenario).static_audit()
        self.assertTrue(any(x["code"] == "nonlocal_harvest" and x["severity"] == "fail" for x in audit))

    def test_resource_projection_and_stability_are_finite(self):
        model, scenario = fixture()
        report = BalanceValidator(model, scenario).run()
        resource = report["resources"][0]
        self.assertIn(resource["status"], {"pass", "warn", "fail"})
        self.assertTrue(np.isfinite(resource["projections"]["30"]["reserve"]))
        self.assertTrue(np.isfinite(report["market_stability"]["maximum_spectral_radius"]))
        self.assertFalse(report["method"]["godot_started"])


if __name__ == "__main__":
    unittest.main()
