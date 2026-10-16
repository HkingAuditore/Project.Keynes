class_name ResourceVisualCatalog
extends RefCounted

const Registry = preload("res://scripts/data/resource_profile_registry.gd")
const Signals = preload("res://scripts/research/research_signal_catalog.gd")
# family: plant=0, animal=1, geology/ground=2, aquatic=3.
# form: cereal=0, maize=1, rice=2, leaf=3, cotton=4, flower=5,
# tree=6, reed=7, horse=8, sheep=9, goat=10, cattle=11, pig=12,
# camel=13, yak=14, cocoons=15, rock=16, vein=17, crystal=18,
# clay=19, sand=20, seep=21, soil=22, tracks=23, fish=24, gas=25, deadwood=26.
const BIO := [
	["bio.maize", 0, 1, "7a9a40", 0, 0.24, 0.0],
	["bio.wheat", 0, 0, "cfae52", 0, 0.32, 0.0],
	["bio.rice", 0, 2, "8fb356", 0, 0.34, 0.0],
	["bio.potato", 0, 3, "5f8445", 0, 0.22, 0.0],
	["bio.horse", 1, 8, "8a5a38", 0, 0.38, 0.0],
	["bio.cotton", 0, 4, "e6e2d2", 0, 0.16, 0.0],
	["bio.flax", 0, 5, "6f8fc4", 0, 0.26, 0.0],
	["bio.spice", 0, 5, "b5523a", 1, 0.32, 0.0],
	["bio.rubber", 0, 6, "3a6a3e", 0, 0.28, 0.0],
	["bio.sheep", 1, 9, "e4dcc6", 0, 0.14, 0.0],
	["bio.goat", 1, 10, "a98d66", 0, 0.22, 0.0],
	["bio.cattle", 1, 11, "d6cdb8", 0, 0.28, 0.0],
	["bio.pig", 1, 12, "cf9a8a", 0, 0.32, 0.0],
	["bio.camel", 1, 13, "c4a066", 0, 0.24, 0.0],
	["bio.yak", 1, 14, "4a3a30", 0, 0.18, 0.0],
	["bio.silkworm", 0, 15, "e8e2c4", 0, 0.48, 0.1],
	["bio.reed", 0, 7, "b9b78e", 0, 0.24, 0.0],
	["bio.bast_fiber", 0, 3, "78985a", 1, 0.24, 0.0],
	["bio.dye_plant", 0, 5, "7d5a9c", 2, 0.28, 0.0],
	["bio.medicinal_herb", 0, 5, "be4f48", 3, 0.30, 0.0],
]
const RESOURCES := [
	# [id, family, form, color_hex, sub_style, specular, metallic]
	# sub_style 现在用于区分形态变体
	["timber", 0, 26, "7a5a3c", 0, 0.22, 0.0],  # 原木堆叠
	["stone", 2, 16, "8f8d85", 0, 0.34, 0.05],  # 不规则岩块
	["fertile_soil", 2, 22, "5a462e", 0, 0.22, 0.0],  # 深色土壤
	["arable_land", 2, 22, "8e7848", 1, 0.18, 0.0],
	["paddy_land", 2, 22, "5c8878", 2, 0.65, 0.0],
	["plantation_land", 2, 22, "688448", 3, 0.20, 0.0],
	["pasture", 2, 22, "6a9248", 4, 0.18, 0.0],
	["coal", 2, 17, "25282b", 0, 0.88, 0.35],
	["oil", 2, 21, "181512", 0, 0.92, 0.15],
	["natural_gas", 2, 25, "9cb4b8", 0, 0.42, 0.0],
	["copper_ore", 2, 17, "4aa585", 1, 0.84, 0.78],
	["iron_ore", 2, 17, "a05a3c", 2, 0.78, 0.75],
	["gold_ore", 2, 17, "e0b840", 3, 0.96, 0.94],
	["silver_ore", 2, 17, "cfd6dc", 4, 0.95, 0.92],
	["salt", 2, 18, "eee8dc", 0, 0.88, 0.10],
	["saltpeter", 2, 18, "d6ddd2", 1, 0.78, 0.10],
	["rare_earth", 2, 17, "b08a5c", 5, 0.76, 0.40],
	["clay", 2, 19, "b0714f", 0, 0.48, 0.0],
	["wild_game", 2, 23, "b89868", 0, 0.24, 0.0],
	["marine_fish", 3, 24, "6cc0d4", 0, 0.82, 0.15],
	["bauxite", 2, 16, "b8683e", 1, 0.28, 0.10],
	["limestone", 2, 16, "cfc7b2", 2, 0.28, 0.05],
	["silica_sand", 2, 20, "dcc890", 0, 0.56, 0.08],
	["phosphate_rock", 2, 16, "989c6c", 3, 0.44, 0.10],
	["tin_ore", 2, 17, "8a7a68", 6, 0.86, 0.65],
	["lead_ore", 2, 17, "5f6e82", 7, 0.90, 0.88],
	["zinc_ore", 2, 17, "7f9a96", 8, 0.80, 0.48],
	["manganese_ore", 2, 17, "6e4a62", 9, 0.74, 0.42],
	["sulfur", 2, 18, "e0c93a", 2, 0.84, 0.15],
	["flint", 2, 16, "5a5e5c", 4, 0.78, 0.10],
	["freshwater_fish", 3, 24, "84cca8", 1, 0.80, 0.15],
]

static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var compiled := Signals.compile_native_catalog()
	var signal_names: PackedStringArray = compiled.get("research_signal_display_names", PackedStringArray())
	for raw in BIO:
		var signal_index := Signals.signal_index(compiled, raw[0])
		out.append({"id": raw[0], "family": raw[1], "form": raw[2],
			"display_name": signal_names[signal_index] if signal_index >= 0 and signal_index < signal_names.size() else raw[0],
			"color": Color(raw[3]), "sub_style": int(raw[4]),
			"specular": float(raw[5]), "metallic": float(raw[6]),
			"bit": Signals.occupancy_bit_for_signal(compiled, raw[0]),
			"profile": null, "priority": 2.0})
	var profiles := {}
	for p in Registry.ordered():
		profiles[String(p.id)] = p
	for raw in RESOURCES:
		var p = profiles.get(raw[0])
		var habitat_code := Registry.habitat_code(p)
		var masks := [0, 1, 2, 4, 8, 10]
		out.append({"id": raw[0], "family": raw[1], "form": raw[2],
			"display_name": String(p.display_name) if p != null else raw[0],
			"color": Color(raw[3]), "sub_style": int(raw[4]),
			"specular": float(raw[5]), "metallic": float(raw[6]),
			"bit": -1, "profile": p,
			"reserve_field": Registry.reserve_map_field(p),
			"reference": Registry.reference_reserve(p),
			"habitat_mask": masks[habitat_code] if habitat_code >= 0 and habitat_code < masks.size() else -1,
			"priority": 0.15 if raw[2] == 22 else 2.0 if String(raw[0]) in [
				"coal", "oil", "natural_gas", "copper_ore", "iron_ore", "gold_ore", "silver_ore",
				"salt", "saltpeter", "rare_earth", "bauxite", "phosphate_rock", "tin_ore", "lead_ore",
				"zinc_ore", "manganese_ore", "sulfur"] else 1.0})
	return out

static func presence_mask(entries_list: Array[Dictionary]) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(entries_list.size())
	out.fill(1)
	# 客观实景不受认知门槛控制；名称、面板和筛选仍由原发现规则负责。
	return out

static func audit(entries_list: Array[Dictionary]) -> Dictionary:
	var ids := {}
	for e in entries_list:
		if ids.has(e.id) or (int(e.bit) < 0 and e.profile == null):
			return {"ok": false, "reason": "resource_visual_mapping_invalid", "id": e.id}
		ids[e.id] = true
	var compiled := Signals.compile_native_catalog()
	# Consume the compiled vocabulary, including NETWORK_SIGNAL_ROWS.
	var signal_ids: PackedStringArray = compiled.get("research_signal_ids", PackedStringArray())
	var bits: PackedInt32Array = compiled.get("research_signal_occupancy_bit", PackedInt32Array())
	for i in mini(signal_ids.size(), bits.size()):
		if bits[i] >= 0 and not ids.has(signal_ids[i]):
			return {"ok": false, "reason": "resource_visual_species_missing", "id": signal_ids[i]}
	for p in Registry.ordered():
		if not ids.has(String(p.id)):
			return {"ok": false, "reason": "resource_visual_reserve_missing", "id": p.id}
	return {"ok": true, "styles": entries_list.size(), "species": BIO.size(),
		"resources": Registry.count()}
