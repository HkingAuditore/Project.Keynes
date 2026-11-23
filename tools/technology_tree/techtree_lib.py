"""Offline model of the Project.Keynes technology network and its content bindings.

Mirrors the Godot-side rules used by the technology catalog tests so that a
redesign can be validated before running the engine:

* building dependency groups (EconomyCatalog._compile_building_dependency_columns)
* direct / construction unlock closure (technology_unlock_closure_audit_test)
* good production permits (EconomyCatalog good_technology_producer_missing)
* application intersections == complete multi-technology building gate
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROJECT = REPO / "Project" / "project-keynes"
NETWORK_PATH = PROJECT / "data" / "technology" / "technology_network.json"
BUILDINGS_DIR = PROJECT / "data" / "economy" / "buildings"
GOODS_DIR = PROJECT / "data" / "goods"
RESOURCES_DIR = PROJECT / "data" / "resources"

ERA_IDS = [
    "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
    "steam", "electrical", "atomic", "information", "intelligent",
]
ERA_INDEX = {era: index for index, era in enumerate(ERA_IDS)}
STARTERS = [
    "tech.gathering", "tech.hunting", "tech.early_trade", "tech.gold_panning",
    "tech.surface_silver_collection", "tech.hide_scraping", "tech.deadwood_collection",
]

_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*) = (.*)$")
_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _parse_value(raw: str):
    raw = raw.strip()
    if raw.startswith("PackedStringArray("):
        return _STRING.findall(raw)
    if raw.startswith(("PackedInt32Array(", "PackedInt64Array(", "PackedFloat32Array(",
                       "PackedFloat64Array(", "PackedByteArray(")):
        inner = raw[raw.index("(") + 1:raw.rindex(")")].strip()
        if not inner:
            return []
        return [float(x) if "." in x else int(x) for x in (p.strip() for p in inner.split(","))]
    if raw.startswith('&"') or raw.startswith('"'):
        match = _STRING.search(raw)
        return match.group(1) if match else ""
    return raw


def read_tres(path: Path) -> dict:
    fields: dict = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = _LINE.match(line)
        if match:
            fields[match.group(1)] = _parse_value(match.group(2))
    return fields


def write_tres_array(path: Path, key: str, values: list[str]) -> bool:
    """Replace one PackedStringArray line; returns True when the file changed."""
    text = path.read_text(encoding="utf-8")
    joined = ", ".join('"%s"' % value for value in values)
    replacement = "%s = PackedStringArray(%s)" % (key, joined)
    pattern = re.compile(r"(?m)^%s = PackedStringArray\([^\r\n]*\)" % re.escape(key))
    if pattern.search(text) is None:
        raise KeyError("%s missing in %s" % (key, path.name))
    new_text = pattern.sub(lambda _m: replacement, text, count=1)
    if new_text == text:
        return False
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(new_text)
    return True


def tech_tags(values) -> list[str]:
    return [str(v).strip() for v in (values or []) if str(v).strip().startswith("tech.")]


class Model:
    def __init__(self) -> None:
        self.network = json.loads(NETWORK_PATH.read_text(encoding="utf-8"))
        self.nodes = self.network["nodes"]
        self.node = {n["id"]: n for n in self.nodes}
        self.order = {n["id"]: i for i, n in enumerate(self.nodes)}
        self.buildings = {}
        self.building_paths = {}
        for path in sorted(BUILDINGS_DIR.glob("*.tres")):
            row = read_tres(path)
            self.buildings[row["id"]] = row
            self.building_paths[row["id"]] = path
        self.goods = {}
        self.good_paths = {}
        for path in sorted(GOODS_DIR.glob("*.tres")):
            row = read_tres(path)
            self.goods[row["id"]] = row
            self.good_paths[row["id"]] = path
        self.resources = {}
        for path in sorted(RESOURCES_DIR.glob("*.tres")):
            row = read_tres(path)
            if "id" in row:
                self.resources[row["id"]] = row
        self._closure_cache: dict[str, frozenset] = {}

    # ------------------------------------------------------------------ graph
    def era(self, tech_id: str) -> int:
        return ERA_INDEX[self.node[tech_id]["era_id"]]

    def invalidate(self) -> None:
        self._closure_cache.clear()
        self.node = {n["id"]: n for n in self.nodes}
        self.order = {n["id"]: i for i, n in enumerate(self.nodes)}

    def closure(self, tech_id: str) -> frozenset:
        cached = self._closure_cache.get(tech_id)
        if cached is not None:
            return cached
        result = {tech_id}
        for parent in self.node[tech_id].get("hard_prerequisite_ids", []):
            result |= self.closure(parent)
        frozen = frozenset(result)
        self._closure_cache[tech_id] = frozen
        return frozen

    def closure_of(self, tech_ids) -> set:
        result: set = set()
        for tech_id in tech_ids:
            result |= self.closure(tech_id)
        return result

    def successors(self) -> dict:
        out = defaultdict(list)
        for node in self.nodes:
            for parent in node.get("hard_prerequisite_ids", []):
                out[parent].append(node["id"])
        return out

    # --------------------------------------------------------------- bindings
    def direct(self, building_id: str) -> list[str]:
        return tech_tags(self.buildings[building_id].get("technology_tags"))

    def required(self, building_id: str) -> list[str]:
        return tech_tags(self.buildings[building_id].get("required_technology_tags"))

    def full_gate(self, building_id: str) -> list[str]:
        return sorted(set(self.direct(building_id)) | set(self.required(building_id)))

    def good_tags(self, good_id: str) -> list[str]:
        return tech_tags(self.goods[good_id].get("technology_tags"))

    def resource_tags(self, resource_id: str) -> list[str]:
        return tech_tags(self.resources[resource_id].get("discovery_technology_tags"))

    def dependency_groups(self, building_id: str, include_construction: bool):
        """Yields (kind, id, acceptable_tech_set) exactly like EconomyCatalog."""
        row = self.buildings[building_id]
        groups = []
        if include_construction:
            goods = row.get("construction_good_ids", [])
            offsets = row.get("construction_candidate_offsets", [])
            candidates = row.get("construction_candidate_good_ids", [])
            for edge, good in enumerate(goods):
                scan = [good]
                if edge + 1 < len(offsets) and offsets[edge + 1] > offsets[edge]:
                    scan = candidates[offsets[edge]:offsets[edge + 1]]
                acceptable = set()
                for candidate in scan:
                    acceptable |= set(self.good_tags(candidate))
                groups.append(("construction_good", good, acceptable))
        goods = row.get("input_good_ids", [])
        required_q16 = row.get("input_required_q16", [])
        offsets = row.get("input_candidate_offsets", [])
        candidates = row.get("input_candidate_good_ids", [])
        for edge, good in enumerate(goods):
            if edge < len(required_q16) and int(required_q16[edge]) < 65536:
                continue
            scan = [good]
            if edge + 1 < len(offsets) and offsets[edge + 1] > offsets[edge]:
                scan = candidates[offsets[edge]:offsets[edge + 1]]
            acceptable = set()
            for candidate in scan:
                acceptable |= set(self.good_tags(candidate))
            groups.append(("input_good", good, acceptable))
        for good in row.get("output_good_ids", []):
            groups.append(("output_good", good, set(self.good_tags(good))))
        for resource in row.get("resource_ids", []):
            groups.append(("natural_resource", resource, set(self.resource_tags(resource))))
        for resource in row.get("resource_generation_ids", []):
            groups.append(("generated_resource", resource, set(self.resource_tags(resource))))
        return groups

    def building_closure_failures(self, building_id: str, include_construction: bool,
                                  direct=None, required=None) -> list:
        direct = self.direct(building_id) if direct is None else direct
        required = self.required(building_id) if required is None else required
        failures = []
        for direct_tech in direct:
            prebuilt = direct_tech in STARTERS
            closure = set(self.closure(direct_tech)) | set(required)
            for kind, dep_id, acceptable in self.dependency_groups(
                    building_id, include_construction and not prebuilt):
                if not (acceptable & closure):
                    failures.append((direct_tech, kind, dep_id))
        return failures

    def all_closure_failures(self, include_construction: bool) -> dict:
        out = {}
        for building_id in self.buildings:
            failures = self.building_closure_failures(building_id, include_construction)
            if failures:
                out[building_id] = failures
        return out

    def producers_by_good(self) -> dict:
        out = defaultdict(list)
        for building_id, row in self.buildings.items():
            for good in row.get("output_good_ids", []):
                out[good].append(building_id)
        return out

    def permit_failures(self) -> list:
        permits = set()
        for building_id, row in self.buildings.items():
            for tech in self.direct(building_id):
                for good in row.get("output_good_ids", []):
                    permits.add((tech, good))
        failures = []
        for good_id in self.goods:
            tags = self.good_tags(good_id)
            if not tags:
                failures.append((good_id, "no_tag"))
            for tag in tags:
                if (tag, good_id) not in permits:
                    failures.append((good_id, tag))
        return failures

    # ------------------------------------------------------------- reporting
    def building_era(self, building_id: str) -> int:
        return max(self.era(t) for t in self.full_gate(building_id))

    def future_gated_buildings(self) -> list:
        """Buildings listed under an earlier technology than their real gate."""
        rows = []
        for building_id in self.buildings:
            direct = self.direct(building_id)
            if not direct:
                continue
            primary_era = self.era(direct[0])
            gate_era = self.building_era(building_id)
            if gate_era > primary_era:
                rows.append((gate_era - primary_era, building_id, direct[0],
                             max(self.full_gate(building_id), key=self.era)))
        rows.sort(reverse=True)
        return rows


def dump_json(path: Path, payload) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent="\t") + "\n"
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
