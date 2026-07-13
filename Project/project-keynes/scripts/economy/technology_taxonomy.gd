class_name TechnologyTaxonomy
extends RefCounted

## UI/design metadata only. Native economy availability is resolved exclusively
## from per-cell `tech.*` bitsets and profile tags; era labels and years never
## participate in runtime predicates.
static var ERAS: Array[Dictionary] = [
	{"id": &"stone", "display_name": "石器时代", "tags": PackedStringArray([
		"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"])},
	{"id": &"bronze", "display_name": "青铜时代", "tags": PackedStringArray([
		"tech.pottery", "tech.bronze_casting"])},
	{"id": &"classical", "display_name": "古典时代", "tags": PackedStringArray([
		"tech.writing", "tech.masonry"])},
	{"id": &"feudal", "display_name": "封建时代", "tags": PackedStringArray([
		"tech.manuscript_culture", "tech.guild_organization"])},
	{"id": &"exploration", "display_name": "探索时代", "tags": PackedStringArray([
		"tech.oceanic_navigation", "tech.printing_press"])},
	{"id": &"enlightenment", "display_name": "启蒙时代", "tags": PackedStringArray([
		"tech.experimental_science", "tech.precision_engineering"])},
	{"id": &"steam", "display_name": "蒸汽时代", "tags": PackedStringArray([
		"tech.coke_smelting", "tech.steam_power"])},
	{"id": &"electrical", "display_name": "电气时代", "tags": PackedStringArray([
		"tech.electrification", "tech.radio", "tech.electrochemistry"])},
	{"id": &"atomic", "display_name": "原子时代", "tags": PackedStringArray([
		"tech.geological_prospecting", "tech.advanced_metallurgy", "tech.nuclear_fission"])},
	{"id": &"information", "display_name": "信息时代", "tags": PackedStringArray([
		"tech.digital_computing", "tech.fiber_optics", "tech.networked_computing",
		"tech.legacy_modern_economy"])},
	{"id": &"ai", "display_name": "人工智能时代", "tags": PackedStringArray([
		"tech.machine_learning", "tech.autonomous_systems", "tech.orbital_flight",
		"tech.orbital_industry", "tech.fusion_power", "tech.asteroid_resource_recovery",
		"tech.deep_space_systems"])},
]

static func era_for_tag(technology_id: StringName) -> StringName:
	for era in ERAS:
		if (era.tags as PackedStringArray).has(String(technology_id)):
			return era.id
	return &""
