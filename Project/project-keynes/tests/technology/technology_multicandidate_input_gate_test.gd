extends SceneTree

## A multi-candidate input edge may only be gated by a technology that stands for
## a route to *every* candidate of that edge.
##
## The reported defect: breweries, distilleries and beverage plants accept wheat,
## rice, corn and mixed grain equally, but their gate demanded
## `tech.wild_maize_collection` -- a stone-age technology that produces corn and
## nothing else.  A country that grew wheat never studied it and could never build
## them.  The generator (`tools/technology_tree/wave_a_unlock_integrity.py`)
## produced that gate because its scoring preferred the earliest era and never
## asked how many alternatives a technology actually covered.
##
## The predicate below is pure graph data: a technology `t` on an edge with
## alternatives A0..An is *route specific* when
##   1. it is among the tags of a proper, non-empty subset of the alternatives, and
##   2. some alternative it does not cover has no technology whose hard-prerequisite
##      closure contains `t`.
## Condition 2 is what separates the defect from a benign gate: a land institution
## that every tenancy descends from is on a route to wheat and to rice, so it
## excludes nobody, while a maize-collection technology excludes every non-maize
## route.
##
## Two checks run:
##   A. Every route-specific gate on a hard multi-candidate input edge must be
##      listed in PARTIAL_GATE_WHITELIST.  The table is an exact set: an entry that
##      no longer describes a route-specific gate fails just like an unlisted one,
##      so it can always be recomputed from the data and never rots.
##   B. Multi-grain edges get no whitelist at all: a gate that stands for one crop
##      is a defect however it is documented.
##
## Whitelist reasons
##   PRIMARY   the tag covers the edge's declared primary input; the remaining
##             candidates are later substitute tiers, so no earlier route is cut.
##   DIRECT    the tag is the building's own defining technology and is required
##             no matter which input is used.
##   STARTER   the tag is a starting technology; every country owns it at turn 0.
##   PEER_BOTH the building also requires the technology that covers the other
##             candidate, so both routes are demanded rather than one excluded.
##   OPEN      same shape as the reported defect, but the material is early and
##             cheap and there is no neutral technology in the data to replace it.
##             Kept deliberately, needs a design call.

const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"
const NETWORK_PATH := "res://data/technology/technology_network.json"

const GRAINS := ["grain", "wheat_grain", "rice_grain", "corn_grain"]

const REASON_TEXT := {
	"PRIMARY": "covers the declared primary input; the rest are later substitute tiers",
	"DIRECT": "the building's own defining technology, required whatever the input",
	"STARTER": "starting technology, owned by every country at turn 0",
	"PEER_BOTH": "the building also requires the technology covering the other candidate",
	"OPEN": "same shape as the reported defect, no neutral technology available yet",
}

const PARTIAL_GATE_WHITELIST := {
	"automobiles_plant#3#tech.latex_smoke_coagulation": "PRIMARY",
	"cartridge_works#0#tech.gunpowder_formulation": "PRIMARY",
	"footwear_plant#0#tech.hide_tanning": "PRIMARY",
	"footwear_plant#1#tech.rubber_working": "PRIMARY",
	"goldsmith_workshop#0#tech.gold_panning": "STARTER",
	"insulated_cable_plant#1#tech.plastics_engineering": "DIRECT",
	"jewelry_plant#0#tech.gold_panning": "STARTER",
	"method_automobiles_plant_r10#3#tech.latex_smoke_coagulation": "PRIMARY",
	"method_insulated_cable_plant_r10#1#tech.plastics_engineering": "PRIMARY",
	"method_insulated_cable_plant_r10#1#tech.synthetic_materials": "PEER_BOTH",
	"method_machine_parts_plant_r9#1#tech.digital_control": "DIRECT",
	"method_packaging_plant_r7#0#tech.electrification": "DIRECT",
	"packaging_plant#0#tech.early_glassmaking": "OPEN",
	"processed_food_plant#1#tech.cold_chain": "DIRECT",
	"smart_leather_goods_factory#0#tech.hide_tanning": "PRIMARY",
	"soap_plant#0#tech.herd_management": "OPEN",
	"synthetic_textile_mill#0#tech.synthetic_fiber_engineering": "DIRECT",
}


func _init() -> void:
	var closures := _technology_closures()
	if closures.is_empty():
		push_error("technology network could not be loaded")
		quit(1)
		return
	var goods := _load_tags(GOOD_DIR)
	var buildings := _load_buildings()
	if goods.is_empty() or buildings.is_empty():
		push_error("catalog directories could not be read")
		quit(1)
		return

	var violations := {}
	var grain_defects := []
	var inspected := 0
	for building_id in buildings:
		var profile: Resource = buildings[building_id]
		var direct := _tech_only(profile.technology_tags)
		var required := _tech_only(profile.required_technology_tags)
		var gate := {}
		for tag in direct:
			gate[tag] = true
		for tag in required:
			gate[tag] = true
		var goods_ids: PackedStringArray = profile.input_good_ids
		var required_q16: PackedInt32Array = profile.input_required_q16
		var offsets: PackedInt32Array = profile.input_candidate_offsets
		var candidates: PackedStringArray = profile.input_candidate_good_ids
		for edge in range(goods_ids.size()):
			if edge < required_q16.size() and int(required_q16[edge]) < 65536:
				continue
			var alternatives := _alternatives(goods_ids, offsets, candidates, edge, goods)
			if alternatives.size() < 2:
				continue
			inspected += 1
			var declared := String(goods_ids[edge])
			var covered_by := {}
			for index in range(alternatives.size()):
				for tag in alternatives[index]:
					if not covered_by.has(tag):
						covered_by[tag] = []
					if not (covered_by[tag] as Array).has(index):
						covered_by[tag].append(index)
			for tag in covered_by:
				if not gate.has(tag):
					continue
				if (covered_by[tag] as Array).size() == alternatives.size():
					continue
				if not _route_specific(tag, alternatives, closures):
					continue
				var key := "%s#%d#%s" % [building_id, edge, tag]
				violations[key] = true
				if declared in GRAINS:
					grain_defects.append(key)

	# ---------------------------------------------------------------- check A
	var unlisted := []
	for key in violations:
		if not PARTIAL_GATE_WHITELIST.has(key):
			unlisted.append(key)
	var stale := []
	for key in PARTIAL_GATE_WHITELIST:
		if not violations.has(key):
			stale.append(key)
		if REASON_TEXT.has(PARTIAL_GATE_WHITELIST[key]):
			continue
		push_error("whitelist entry %s has an unknown reason code" % key)
	var unknown := []
	for key in PARTIAL_GATE_WHITELIST:
		if not REASON_TEXT.has(PARTIAL_GATE_WHITELIST[key]):
			unknown.append(key)
	unlisted.sort()
	stale.sort()
	for key in unlisted:
		push_error("route-specific gate not reviewed: %s" % key)
	for key in stale:
		push_error("whitelist entry no longer describes a route-specific gate: %s" % key)

	# ---------------------------------------------------------------- check B
	grain_defects.sort()
	for key in grain_defects:
		push_error("multi-grain edge gated by a single-crop technology: %s" % key)

	var failed := false
	if not unlisted.is_empty():
		push_error("CHECK A failed: %d unreviewed route-specific gates (%d whitelisted)" % [
			unlisted.size(), PARTIAL_GATE_WHITELIST.size()])
		failed = true
	if not stale.is_empty():
		push_error("CHECK A failed: %d whitelist entries are stale" % stale.size())
		failed = true
	if not unknown.is_empty():
		push_error("CHECK A failed: %d whitelist entries use an unknown reason" % unknown.size())
		failed = true
	if not grain_defects.is_empty():
		push_error("CHECK B failed: %d multi-grain edges stand on one crop" % grain_defects.size())
		failed = true
	if failed:
		quit(1)
		return
	print("[PASS] %d multi-option input edges checked; %d reviewed route-specific gates (%s)" % [
		inspected, PARTIAL_GATE_WHITELIST.size(), _reason_census()])
	quit(0)


func _reason_census() -> String:
	var counts := {}
	for key in PARTIAL_GATE_WHITELIST:
		var code := String(PARTIAL_GATE_WHITELIST[key])
		counts[code] = int(counts.get(code, 0)) + 1
	var parts := []
	for code in counts:
		parts.append("%s=%d" % [code, int(counts[code])])
	parts.sort()
	return " ".join(parts)


func _alternatives(goods_ids: PackedStringArray, offsets: PackedInt32Array,
		candidates: PackedStringArray, edge: int, goods: Dictionary) -> Array:
	var scan := [String(goods_ids[edge])]
	if edge + 1 < offsets.size() and int(offsets[edge + 1]) > int(offsets[edge]):
		scan = []
		for candidate_edge in range(int(offsets[edge]), int(offsets[edge + 1])):
			scan.append(String(candidates[candidate_edge]))
	var out := []
	for good_id in scan:
		out.append(_tech_only(goods.get(good_id, PackedStringArray())))
	return out


func _route_specific(tag: String, alternatives: Array, closures: Dictionary) -> bool:
	var covered := []
	for index in range(alternatives.size()):
		if (alternatives[index] as PackedStringArray).has(tag):
			covered.append(index)
	if covered.size() == alternatives.size():
		return false
	for index in range(alternatives.size()):
		if covered.has(index):
			continue
		var reachable := false
		for other in alternatives[index]:
			var closure: Dictionary = closures.get(String(other), {})
			if closure.has(tag):
				reachable = true
				break
		if not reachable:
			return true
	return false


func _technology_closures() -> Dictionary:
	var handle := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if handle == null:
		return {}
	var parsed = JSON.parse_string(handle.get_as_text())
	if not parsed is Dictionary:
		return {}
	var parents := {}
	for node_value in (parsed as Dictionary).get("nodes", []):
		var node: Dictionary = node_value
		var ids := PackedStringArray()
		for prerequisite in node.get("hard_prerequisite_ids", []):
			ids.append(String(prerequisite))
		parents[String(node.get("id", ""))] = ids
	var closures := {}
	for technology in parents:
		_closures_of(technology, parents, closures)
	return closures


func _closures_of(technology: String, parents: Dictionary, closures: Dictionary) -> Dictionary:
	if closures.has(technology):
		return closures[technology]
	var closure := {technology: true}
	for parent in (parents.get(technology, PackedStringArray()) as PackedStringArray):
		if not parents.has(parent):
			continue
		for ancestor in _closures_of(parent, parents, closures):
			closure[ancestor] = true
	closures[technology] = closure
	return closure


func _load_tags(directory: String) -> Dictionary:
	var out := {}
	for file_name in ResourceLoader.list_directory(directory):
		if file_name.get_extension().to_lower() != "tres":
			continue
		var resource = ResourceLoader.load("%s/%s" % [directory, file_name], "Resource")
		if resource == null or String(resource.get("id")) == "":
			continue
		out[String(resource.id)] = resource.technology_tags
	return out


func _load_buildings() -> Dictionary:
	var out := {}
	for file_name in ResourceLoader.list_directory(BUILDING_DIR):
		if file_name.get_extension().to_lower() != "tres":
			continue
		var resource = ResourceLoader.load("%s/%s" % [BUILDING_DIR, file_name], "Resource")
		if resource == null or String(resource.get("id")) == "":
			continue
		out[String(resource.id)] = resource
	return out


func _tech_only(tags_value) -> PackedStringArray:
	var out := PackedStringArray()
	for tag in tags_value:
		var normalized := String(tag).strip_edges()
		if normalized.begins_with("tech."):
			out.append(normalized)
	return out
