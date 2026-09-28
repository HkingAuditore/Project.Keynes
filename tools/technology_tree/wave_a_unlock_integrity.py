"""Wave A: every building is listed under the technology that actually makes it buildable.

For each building the complete gate (direct + required tags) is re-expressed as:

* ``D``: the defining technology, i.e. the latest-era technology of the gate
  (manual overrides win), which becomes the single ``technology_tags`` entry;
* ``R*``: the minimal subset of the remaining gate still needed for the
  operational closure (hard inputs, outputs, resources) that ``closure(D)``
  does not already provide.

Required tags that are neither implied by ``closure(D)`` nor needed for the
closure are hidden duplicates and are removed.  The building's effective era
therefore never changes, except for explicitly listed stray tags.

Usage: python wave_a_unlock_integrity.py [--apply]
"""
from __future__ import annotations

import sys
from collections import defaultdict

from techtree_lib import ERA_IDS, NETWORK_PATH, STARTERS, Model, dump_json, write_tres_array

# Required tags that are data errors: an intelligent-era collaboration method
# was stamped onto basic workshops that do not use any automation input.
STRAY_REQUIRED = {
    "coal_mine": {"tech.human_machine_collaboration"},
    "distillery": {"tech.human_machine_collaboration"},
    "method_stone_collector_r4": {"tech.human_machine_collaboration"},
    "method_wool_shed_r5": {"tech.human_machine_collaboration"},
    "method_timber_collector_r4": {"tech.human_machine_collaboration"},
    "method_lumber_plant_r4": {"tech.human_machine_collaboration"},
}

# Semantic defining technology.  Pacing markers left by the legacy generator keep
# the building era; these overrides replace a misleading marker with the
# technology whose name actually describes the facility (same era unless the
# comment states a historical correction).
DEFINING_OVERRIDES: dict[str, str] = {
    "batteries_plant": "tech.advanced_metallurgy",
    "cadastral_office": "tech.property_cadastre",          # correction: surveying office
    "learned_society": "tech.learned_societies",            # correction: 18th-c. society
    "precision_tool_workshop": "tech.precision_engineering",  # correction: pre-steam tools
    "steam_engine_works": "tech.steam_power",               # correction: steam era works
    "clay_collector": "tech.pottery",
    "method_timber_collector_r2": "tech.timber_sawing",
    "concrete_plant": "tech.reinforced_concrete",
    "fine_furniture_plant": "tech.mass_production",
    "glassware_factory": "tech.mass_production",
    "leather_goods_factory": "tech.mass_production",
    "metal_housewares_factory": "tech.mass_production",
    "glassware_manufactory": "tech.manufactory_system",
    "leather_goods_manufactory": "tech.manufactory_system",
    "metal_housewares_manufactory": "tech.manufactory_system",
    "hydropower_station": "tech.electric_generation",
    "method_printed_materials_plant_r7": "tech.electrification",
    "method_packaging_plant_r7": "tech.electrification",
    "lead_ore_collector": "tech.steam_pumping",
    "zinc_ore_collector": "tech.steam_pumping",
    "mechanized_farm": "tech.motorized_agriculture",
    "method_landed_estate_r6": "tech.motorized_agriculture",
    "method_cotton_collector_r6": "tech.motorized_agriculture",
    "ranching_station": "tech.modern_husbandry",
    "mechanized_slaughterhouse": "tech.mass_production",
    "method_potato_farm_r5": "tech.agricultural_improvement",
    "method_rice_collector_r5": "tech.agricultural_cooperatives",
    "method_edible_oil_plant_r6": "tech.mass_production",
    "method_agricultural_machinery_plant_r9": "tech.digital_control",
    "method_zinc_plant_r9": "tech.sensor_networks",
    "method_nuclear_fuel_plant_r10": "tech.robotic_manufacturing",
    "method_reactor_component_works_r10": "tech.robotic_manufacturing",
    "method_scientific_instrument_works_r10": "tech.scientific_agents",
    "method_smart_husbandry": "tech.automated_agriculture",
    "method_stone_age_hunting_camp_r4": "tech.market_institutions",
    "nuclear_power_plant": "tech.nuclear_energy",           # correction: 1954 reactor
    "nuclear_medicine_center": "tech.nuclear_fission",
    "reactor_component_works": "tech.nuclear_energy",
    "nuclear_fuel_plant": "tech.nuclear_fuel_cycle",
    "stainless_steel_plant": "tech.specialty_alloys",
    "rare_earth_collector": "tech.deep_geophysics",         # rare earths known by the 1940s
    "rare_earth_metals_plant": "tech.specialty_alloys",
    "rubber_tapping_camp": "tech.rubber_working",
    "spice_commercial_plantation": "tech.estate_plantation_management",
    "steel_plant": "tech.electrification",
    "tenant_potato_field": "tech.tenant_cereal_farming",
    "method_rice_collector_r3": "tech.tenant_paddy_management",
    "felt_making_tent": "tech.wool_husbandry",
    "coal_adit": "tech.coal_adit_mining",
    "electrical_equipment_plant": "tech.electronic_control",
    "electronic_components_plant": "tech.electronic_control",
    "radio_equipment_works": "tech.electronic_control",
    "household_appliances_plant": "tech.plastics_engineering",
    "insulated_cable_plant": "tech.plastics_engineering",
    "method_explosives_plant_r10": "tech.robotic_manufacturing",
    "staple_kitchen": "tech.grain_threshing",
    "steam_steel_works": "tech.coke_smelting",
    "improved_domestic_loom": "tech.textile_machinery",
    "distillery": "tech.guild_organization",               # correction: medieval spirits
    "method_wool_shed_r3": "tech.guild_organization",      # correction: wool guilds
    "method_wool_shed_r5": "tech.mechanical_workshops",    # correction: 1789 combing machine
    "method_flint_quarry_r1": "tech.ground_stone_tools",   # correction: Neolithic flint mines
}


_PRODUCERS: dict = {}


def closure_groups(model: Model, building_id: str, defining: str | None = None):
    """Operational groups.  With a defining technology, an output group requires
    prior knowledge of that good from another producer of the same or an earlier
    era; without one (or for the first producer) output groups are skipped."""
    if not _PRODUCERS:
        _PRODUCERS.update(model.producers_by_good())
    groups = []
    for kind, dep, acceptable in model.dependency_groups(building_id, False):
        if kind == "output_good":
            # Starter-core buildings are prebuilt from the starter technology set only.
            if defining is None or defining in STARTERS:
                continue
            others = set()
            for producer in _PRODUCERS.get(dep, []):
                if producer != building_id:
                    others |= {t for t in model.direct(producer)
                               if model.era(t) < model.era(defining)}
            if not others:
                continue
            acceptable = others
        groups.append((kind, dep, acceptable))
    return groups


def minimal_required(model: Model, building_id: str, defining: str, pool: list[str]) -> list[str]:
    covered = set(model.closure(defining))
    family = model.node[defining]["branch_family_id"]
    authored = set(model.full_gate(building_id))
    missing = [acc for _k, _d, acc in closure_groups(model, building_id, defining)
               if not acc & covered]
    chosen: list[str] = []
    pool = [t for t in pool if t not in covered]
    while missing:
        best = None
        best_score = None
        for tech in pool:
            if tech in chosen:
                continue
            hits = sum(1 for acc in missing if tech in acc)
            if hits == 0:
                continue
            same_family = model.node[tech]["branch_family_id"] == family
            score = (-model.era(tech), tech in authored, same_family, hits, -model.order[tech])
            if best_score is None or score > best_score:
                best, best_score = tech, score
        if best is None:
            return None
        chosen.append(best)
        missing = [acc for acc in missing if best not in acc]
    return sorted(chosen, key=lambda t: (model.era(t), model.order[t]))


def classify(model: Model, building_id: str, tech: str) -> str:
    """operational | construction | knowledge"""
    operational = any(tech in acc for _k, _d, acc in model.dependency_groups(building_id, False))
    if operational:
        return "operational"
    construction = any(tech in acc for kind, _d, acc in model.dependency_groups(building_id, True)
                       if kind == "construction_good")
    return "construction" if construction else "knowledge"


def solve_required(model: Model, building_id: str, defining: str, gate: list, old_primary: str):
    pool = [t for t in gate if t != defining]
    extended = pool + sorted(model.closure(old_primary) - set(pool) - {defining},
                             key=lambda t: (model.era(t), model.order[t]))
    fallback = set()
    for _k, _d, acc in closure_groups(model, building_id, defining):
        fallback |= acc
    extended = extended + sorted(fallback - set(extended) - {defining},
                                 key=lambda t: (model.era(t), model.order[t]))
    return minimal_required(model, building_id, defining, extended)


def plan(model: Model) -> dict:
    result = {}
    for building_id in sorted(model.buildings):
        direct = model.direct(building_id)
        if len(direct) != 1:
            raise SystemExit("building must have one direct tag: %s" % building_id)
        old_primary = direct[0]
        old_required = model.required(building_id)
        strays = STRAY_REQUIRED.get(building_id, set())
        gate = [old_primary] + [t for t in old_required if t not in strays]
        # A required tag that only stands for one acceptable producer of an input or
        # a construction material is not the building's knowledge; pacing markers
        # (pure knowledge tags) and the primary tag are.
        markers = [t for t in gate[1:] if classify(model, building_id, t) == "knowledge"]
        if building_id in DEFINING_OVERRIDES:
            defining = DEFINING_OVERRIDES[building_id]
        else:
            semantic = [old_primary] + markers
            max_era = max(model.era(t) for t in semantic)
            tied = [t for t in semantic if model.era(t) == max_era]
            defining = old_primary if old_primary in tied else max(tied, key=lambda t: model.order[t])
        required = solve_required(model, building_id, defining, gate, old_primary)
        if required is None:
            raise SystemExit("no closure-preserving gate for %s" % building_id)
        # An input only producible later makes that producer the real gate.
        for _ in range(3):
            if not required or max(model.era(t) for t in required) <= model.era(defining):
                break
            defining = max(required, key=lambda t: (model.era(t), model.order[t]))
            required = solve_required(model, building_id, defining, gate, old_primary)
            if required is None:
                raise SystemExit("no closure-preserving gate for %s" % building_id)
        result[building_id] = {
            "old_primary": old_primary,
            "old_required": old_required,
            "defining": defining,
            "required": required,
        }
    return result


def recompute_goods(model: Model) -> dict:
    """Good technology tags == union of the direct technologies of its producers."""
    producers = model.producers_by_good()
    changes = {}
    for good_id, row in model.goods.items():
        old_tags = list(row.get("technology_tags", []))
        wanted = set()
        for building_id in producers.get(good_id, []):
            wanted |= set(model.direct(building_id))
        if not wanted:
            continue
        kept = [t for t in old_tags if not t.startswith("tech.") or t in wanted]
        present = set(kept)
        for tech in sorted(wanted - present, key=lambda t: (model.era(t), model.order[t])):
            kept.append(tech)
        if kept != old_tags:
            changes[good_id] = (old_tags, kept)
            row["technology_tags"] = kept
    return changes


def _effect(kind: str, item_id: str, display_name: str) -> dict:
    if kind == "building":
        return {"kind": "building", "id": item_id, "binding_kind": 2,
                "subject": "building." + item_id,
                "attribute": "construction_and_production_access", "operation": "unlock",
                "value": 1, "implementation": "BuildingProfile.technology_tags",
                "status": "catalog_rebind", "display_name": display_name}
    if kind == "good":
        return {"kind": "good", "id": item_id, "binding_kind": 1, "subject": "good." + item_id,
                "attribute": "production_access", "operation": "unlock", "value": 1,
                "implementation": "GoodProfile.technology_tags", "status": "catalog_rebind",
                "display_name": display_name}
    return {"kind": "resource", "id": item_id, "binding_kind": 3,
            "subject": "resource." + item_id, "attribute": "local_resource_access",
            "operation": "unlock", "value": 1,
            "implementation": "ResourceProfile.discovery_technology_tags",
            "status": "existing_binding", "display_name": display_name}


KIND_NAME = {1: "good", 2: "building", 3: "resource"}


def rebuild_node_bindings(model: Model) -> None:
    bindings = defaultdict(set)
    for building_id in model.buildings:
        for tech in model.direct(building_id):
            bindings[tech].add((2, building_id))
    for good_id in model.goods:
        for tech in model.good_tags(good_id):
            bindings[tech].add((1, good_id))
    for resource_id in model.resources:
        for tech in model.resource_tags(resource_id):
            bindings[tech].add((3, resource_id))
    names = {}
    for building_id, row in model.buildings.items():
        names[(2, building_id)] = row.get("display_name", building_id)
    for good_id, row in model.goods.items():
        names[(1, good_id)] = row.get("display_name", good_id)
    for resource_id, row in model.resources.items():
        names[(3, resource_id)] = row.get("display_name", resource_id)
    support = defaultdict(list)
    for building_id in sorted(model.buildings):
        for tech in model.required(building_id):
            support[tech].append({"id": building_id,
                                  "name": model.buildings[building_id].get("display_name", building_id)})
    for node in model.nodes:
        tech = node["id"]
        wanted = bindings.get(tech, set())
        node["expected_bindings"] = [
            {"kind": kind, "id": item_id}
            for kind, item_id in sorted(wanted, key=lambda b: ({2: 0, 1: 1, 3: 2}[b[0]], b[1]))]
        old_effects = {}
        runtime_effects = []
        for effect in node.get("content_effects", []):
            binding_kind = int(effect.get("binding_kind", 0))
            if binding_kind <= 0:
                runtime_effects.append(effect)
            else:
                old_effects[(binding_kind, effect["id"])] = effect
        effects = list(runtime_effects)
        for kind, item_id in sorted(wanted, key=lambda b: ({2: 0, 1: 1, 3: 2}[b[0]], b[1])):
            effect = old_effects.get((kind, item_id))
            if effect is None:
                effect = _effect(KIND_NAME[kind], item_id, names[(kind, item_id)])
            effects.append(effect)
        node["content_effects"] = effects
        node["support_buildings"] = support.get(tech, [])
        building_count = sum(1 for kind, _ in wanted if kind == 2)
        review = node.get("building_unlock_review") or {}
        if review.get("policy") != "none":
            if building_count == 0:
                policy = "support_only"
                rationale = "本科技不直接开放新建筑，它作为后续生产方式的可见知识前提或以数值效果体现。"
            elif building_count == 1:
                policy = "single"
                rationale = "本科技直接开放一种与其名称对应、完成即可建设的生产设施。"
            else:
                policy = "paired"
                rationale = "本科技开放一组共享同一核心知识、完成即可建设的生产设施。"
            if review.get("policy") != policy:
                node["building_unlock_review"] = {"policy": policy, "rationale": rationale}


def rebuild_applications(model: Model) -> None:
    old = {row["building_ids"][0]: row for row in model.network["application_intersections"]}
    rows = []
    for building_id in model.buildings:
        gate = model.full_gate(building_id)
        if len(gate) < 2:
            continue
        defining = model.direct(building_id)[0]
        node = model.node[defining]
        latest = max(gate, key=lambda t: (model.era(t), model.order[t]))
        ordered = [defining] + sorted((t for t in gate if t != defining),
                                      key=lambda t: (model.era(t), model.order[t]))
        name = model.buildings[building_id].get("display_name", building_id)
        row = dict(old.get(building_id, {}))
        row.update({
            "id": "app." + building_id,
            "display_name": name,
            "description": "%s由%d项已掌握知识自动形成，不消耗研究点。" % (name, len(ordered)),
            "era_id": model.node[latest]["era_id"],
            "domain_id": node["domain_id"],
            "industry_chain_id": node["branch_family_id"],
            "layout_order": round(float(node.get("layout_order", 0.0)) + 0.01, 4),
            "required_technology_ids": ordered,
            "building_ids": [building_id],
        })
        rows.append(row)
    rows.sort(key=lambda r: (ERA_IDS.index(r["era_id"]), float(r["layout_order"]), r["id"]))
    model.network["application_intersections"] = rows


def repair_closure(max_rounds: int = 6) -> int:
    """Fixed point: recompute R* against the recomputed good permits."""
    for _round in range(max_rounds):
        model = Model()
        _PRODUCERS.clear()
        for good_id, (_old, new) in recompute_goods(model).items():
            write_tres_array(model.good_paths[good_id], "technology_tags", new)
        failures = model.all_closure_failures(False)
        if not failures:
            rebuild_node_bindings(model)
            rebuild_applications(model)
            dump_json(NETWORK_PATH, model.network)
            return 0
        for building_id in failures:
            defining = model.direct(building_id)[0]
            gate = model.full_gate(building_id)
            required = solve_required(model, building_id, defining, gate, defining)
            if required is None:
                raise SystemExit("closure repair impossible: %s" % building_id)
            write_tres_array(model.building_paths[building_id], "required_technology_tags", required)
            model.buildings[building_id]["required_technology_tags"] = required
        for good_id, (_old, new) in recompute_goods(model).items():
            write_tres_array(model.good_paths[good_id], "technology_tags", new)
        rebuild_node_bindings(model)
        rebuild_applications(model)
        dump_json(NETWORK_PATH, model.network)
    return len(Model().all_closure_failures(False))


def minimize_all() -> int:
    """Re-solve every building's required tags as the minimal subset of its gate."""
    model = Model()
    _PRODUCERS.clear()
    changed = 0
    for building_id in sorted(model.buildings):
        defining = model.direct(building_id)[0]
        required = solve_required(model, building_id, defining, model.full_gate(building_id),
                                  defining)
        if required is None:
            raise SystemExit("minimize impossible: %s" % building_id)
        if required != model.required(building_id):
            write_tres_array(model.building_paths[building_id], "required_technology_tags", required)
            model.buildings[building_id]["required_technology_tags"] = required
            changed += 1
    return changed


def main() -> None:
    if "--minimize" in sys.argv:
        print("buildings minimized:", minimize_all())
    if "--repair" in sys.argv or "--minimize" in sys.argv:
        print("closure failures after repair:", repair_closure())
        return
    apply = "--apply" in sys.argv
    model = Model()
    decisions = plan(model)
    moved = {b: d for b, d in decisions.items() if d["defining"] != d["old_primary"]}
    pruned = sum(len(d["old_required"]) - len(d["required"]) for d in decisions.values())
    print("buildings %d | primary moved %d | required tags %d -> %d (removed %d)" % (
        len(decisions), len(moved),
        sum(len(d["old_required"]) for d in decisions.values()),
        sum(len(d["required"]) for d in decisions.values()), pruned))
    era_changes = 0
    for building_id, d in sorted(decisions.items(), key=lambda kv: kv[0]):
        old_era = max(model.era(t) for t in [d["old_primary"]] + d["old_required"])
        new_era = max(model.era(t) for t in [d["defining"]] + d["required"])
        if d["defining"] == d["old_primary"] and old_era == new_era:
            continue
        era_changes += old_era != new_era
        print("  %-38s %-10s %s(%s) -> %s(%s) req=[%s] era %s->%s%s" % (
            building_id, model.buildings[building_id].get("display_name", ""),
            model.node[d["old_primary"]]["display_name"], ERA_IDS[model.era(d["old_primary"])][:5],
            model.node[d["defining"]]["display_name"], ERA_IDS[model.era(d["defining"])][:5],
            ",".join(model.node[t]["display_name"] for t in d["required"]),
            ERA_IDS[old_era][:5], ERA_IDS[new_era][:5], "  <<ERA" if old_era != new_era else ""))
    print("era changes:", era_changes)
    if not apply:
        return
    for building_id, d in decisions.items():
        row = model.buildings[building_id]
        path = model.building_paths[building_id]
        other = [t for t in row.get("technology_tags", []) if not t.startswith("tech.")]
        direct = other + [d["defining"]]
        write_tres_array(path, "technology_tags", direct)
        write_tres_array(path, "required_technology_tags", d["required"])
        row["technology_tags"] = direct
        row["required_technology_tags"] = d["required"]
    good_changes = recompute_goods(model)
    for good_id, (_old, new) in good_changes.items():
        write_tres_array(model.good_paths[good_id], "technology_tags", new)
    print("goods retagged:", len(good_changes))
    rebuild_node_bindings(model)
    rebuild_applications(model)
    dump_json(NETWORK_PATH, model.network)
    failures = model.all_closure_failures(False)
    print("direct closure failures after apply:", len(failures))
    print("permit failures after apply:", model.permit_failures()[:5])


if __name__ == "__main__":
    main()
