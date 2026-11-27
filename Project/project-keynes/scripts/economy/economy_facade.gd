class_name EconomyFacade
extends RefCounted
const EconomyCommandResultText = preload("res://scripts/economy/economy_command_result_text.gd")

signal economy_event_batch_available(meta: Dictionary)
signal economy_event_batch(batch: Dictionary)
signal construction_command_settled(result: Dictionary)
signal family_colonization_settled(result: Dictionary)
signal infrastructure_command_settled(result: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/economy/default_economy.tres"
const GOOD_PROFILE_DIR := "res://data/goods"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyProfileScript = preload("res://scripts/data/economy_profile.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const EconomyFacadeConfigurationScript = preload("res://scripts/economy/economy_facade_configuration.gd")
const EconomyFacadeDisplayScript = preload(
	"res://scripts/economy/economy_facade_display.gd")
## 与原生 SAT_DIM_* 枚举同序，供 Inspector 与溯源面板直接展示。
## 第 0 维是生存（口粮 + 御寒），不叫「温饱」——「温饱」是生活水平七档里的档位词。
const SATISFACTION_DIMENSION_NAMES := [
	"生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展",
]



const OWNERSHIP_TREASURY_SPONSORED_PRIVATE := 1

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _profession_display_names: Dictionary = {}
var _ethnicity_display_names: Dictionary = {}
var _building_display_names: Dictionary = {}
var _need_display_names: Dictionary = {}
var _good_display_names: Dictionary = {}
var _family_trait_descriptions: Dictionary = {}
var _family_trait_copy: Dictionary = {}
var _family_trait_effect_keys: Dictionary = {}
var _family_effect_displays: Dictionary = {}
var _family_modifier_displays: Dictionary = {}
var _family_trigger_displays: Dictionary = {}
var _family_trait_sequence: int = 0
var _family_founding_sequence: int = 0
var _construction_receipt_cursor: int = 0
var _colonization_receipt_cursors: Dictionary = {}
var _canal_receipt_cursors: Dictionary = {}


## Cold visual metadata boundary. It exposes only catalog-authored category
## columns; renderers never inspect IDs, filenames, outputs, or years.
const BUILDING_VISUAL_CATALOG_KEYS := [
	"building_type_ids", "building_kinds", "building_economic_sectors",
	"building_semantic_tag_offsets", "building_semantic_tags",
	"building_production_climate_profile_indices", "production_climate_profile_ids",
	"building_resource_offsets", "building_production_resource_ids", "building_resource_ids",
	"building_industry_chain_ids", "building_output_offsets", "building_output_good_ids",
	"good_ids", "building_owner_slots", "building_employee_offsets", "building_employee_slots",
	"building_construction_offsets", "building_construction_good_ids",
]

const EconomyQueries = preload("res://scripts/economy/economy_facade_queries.gd")
const EconomyCommands = preload("res://scripts/economy/economy_facade_commands.gd")
const EconomySession = preload("res://scripts/economy/economy_facade_session.gd")
const Opcode = EconomyCommands.Opcode


func building_visual_catalog() -> Dictionary:
	var out := {}
	for key in BUILDING_VISUAL_CATALOG_KEYS:
		if _catalog.has(key):
			out[key] = _catalog[key]
	return out

func configure(world_ext: DCWorldExt, cell_count: int, seed: int, profile = null,
		compiled_catalog: Dictionary = {}) -> Dictionary:
	return EconomyFacadeConfigurationScript.configure.call(null, self, world_ext,
		cell_count, seed, profile, compiled_catalog)

func configure_cooperative(context, world_ext: DCWorldExt, cell_count: int, seed: int,
		profile = null, compiled_catalog: Dictionary = {}) -> Dictionary:
	return await EconomyFacadeConfigurationScript.configure(context, self, world_ext,
		cell_count, seed, profile, compiled_catalog)

func bootstrap(population_packet: Dictionary = {}, market_packet: Dictionary = {},
		building_packet: Dictionary = {}) -> Dictionary:
	return EconomyCommands.bootstrap(self, population_packet, market_packet, building_packet)

func submit(commands: Array[Dictionary]) -> Dictionary:
	return EconomyCommands.submit(self, commands)

func add_stock(cell_idx: int, good_id: StringName, quantity: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.add_stock(self, cell_idx, good_id, quantity, effective_day, sequence)

func mint_to_cohort(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.mint_to_cohort(self, cohort_handle, amount, effective_day, sequence)

func mint_to_treasury(country_handle: int, cell_idx: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.mint_to_treasury(self, country_handle, cell_idx, amount, effective_day, sequence)

func burn_from_cohort(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.burn_from_cohort(self, cohort_handle, amount, effective_day, sequence)

func add_population(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.add_population(self, cohort_handle, amount, effective_day, sequence)

func transfer_country_cash_to_cohort(country_handle: int, cohort_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.transfer_country_cash_to_cohort(self, country_handle, cohort_handle, amount, effective_day, sequence)

func transfer_cohort_cash_to_country(cohort_handle: int, country_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.transfer_cohort_cash_to_country(self, cohort_handle, country_handle, amount, effective_day, sequence)

func transfer_country_good_to_market(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.transfer_country_good_to_market(self, country_handle, cell_idx, good_id, quantity, effective_day, sequence)

func transfer_market_good_to_country(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.transfer_market_good_to_country(self, country_handle, cell_idx, good_id, quantity, effective_day, sequence)

func _submit_country_good_transfer(opcode: int, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands._submit_country_good_transfer(self, opcode, country_handle, cell_idx, good_id, quantity, effective_day, sequence)

func population_cell_summary(cell_idx: int) -> Dictionary:
	return EconomyQueries.population_cell_summary(self, cell_idx)

func named_settlement_snapshot() -> Dictionary:
	return EconomyQueries.named_settlement_snapshot(self)

func settlement_delta(since_revision: int) -> Dictionary:
	return EconomyQueries.settlement_delta(self, since_revision)

func population_cell_snapshot(cell_idx: int, include_details: bool = true) -> Dictionary:
	return EconomyQueries.population_cell_snapshot(self, cell_idx, include_details)

func market_cell_snapshot(cell_idx: int) -> Dictionary:
	return EconomyQueries.market_cell_snapshot(self, cell_idx)

func cell_situation_snapshot(requested_cells: PackedInt32Array) -> Dictionary:
	return EconomyQueries.cell_situation_snapshot(self, requested_cells)

func explain_cohort_satisfaction(cohort_handle: int) -> Dictionary:
	return EconomyQueries.explain_cohort_satisfaction(self, cohort_handle)

func cell_satisfaction_attractiveness(cell_idx: int) -> Dictionary:
	return EconomyQueries.cell_satisfaction_attractiveness(self, cell_idx)

func cell_mobilization_snapshot(cell_idx: int) -> Dictionary:
	return EconomyQueries.cell_mobilization_snapshot(self, cell_idx)

func country_mobilization_summary(country_slot: int) -> Dictionary:
	return EconomyQueries.country_mobilization_summary(self, country_slot)

func mobilization_odds(cell_idx: int, profession: int, action: int,
		spend_bp: int = 0) -> Dictionary:
	return EconomyQueries.mobilization_odds(self, cell_idx, profession, action, spend_bp)

func resolve_player_mobilization(choice: Dictionary) -> Dictionary:
	return EconomyQueries.resolve_player_mobilization(self, choice)

func apply_mobilization_result(cell_idx: int, profession: int, action: int,
		success: bool) -> bool:
	return EconomyQueries.apply_mobilization_result(self, cell_idx, profession, action, success)

func trade_orders_for_cell(cell_idx: int, offset: int = 0, limit: int = 64,
		good_index: int = -1) -> Dictionary:
	return EconomyQueries.trade_orders_for_cell(self, cell_idx, offset, limit, good_index)

func trade_visual_snapshot(cells: PackedInt32Array, visible: PackedByteArray,
        vision_revision: int, selected_cell: int = -1, enabled: bool = true) -> Dictionary:
	return EconomyQueries.trade_visual_snapshot(self, cells, visible, vision_revision, selected_cell, enabled)

func bake_trade_visual_paths(snapshot: Dictionary, map_width: int, hex_size: float) -> Dictionary:
	return EconomyQueries.bake_trade_visual_paths(self, snapshot, map_width, hex_size)

func country_trade_snapshot(country_handle: int, view: String = "summary",
		offset: int = 0, limit: int = 32) -> Dictionary:
	return EconomyQueries.country_trade_snapshot(self, country_handle, view, offset, limit)

func country_economy_overview(country_handle: int, view: String = "summary",
		scope_cell: int = -1, filter_id: int = -1, offset: int = 0,
		limit: int = 0) -> Dictionary:
	return EconomyQueries.country_economy_overview(self, country_handle, view, scope_cell, filter_id, offset, limit)

func building_cell_snapshot(cell_idx: int) -> Dictionary:
	return EconomyQueries.building_cell_snapshot(self, cell_idx)

func construction_type_columns() -> Dictionary:
	return EconomyCommands.construction_type_columns(self)

func construction_sector_ids() -> PackedStringArray:
	return EconomyCommands.construction_sector_ids(self)

func construction_candidates(search: String = "",
		technology_available: PackedByteArray = PackedByteArray(),
		sector: int = -1) -> PackedInt32Array:
	return EconomyCommands.construction_candidates(self, search, technology_available, sector)

func construction_catalog(search: String = "", offset: int = 0,
		limit: int = 32,
		technology_available: PackedByteArray = PackedByteArray(),
		sector: int = -1) -> Dictionary:
	return EconomyCommands.construction_catalog(self, search, offset, limit, technology_available, sector)

func construction_quotes(country_handle: int, cell_idx: int,
		type_ids: PackedInt32Array) -> Dictionary:
	return EconomyCommands.construction_quotes(self, country_handle, cell_idx, type_ids)

func treasury_sponsored_build(country_handle: int, cell_idx: int,
		building_id: StringName, effective_day: int, sequence: int,
		ownership_policy: StringName = &"treasury_sponsored_private") -> Dictionary:
	return EconomyCommands.treasury_sponsored_build(self, country_handle, cell_idx, building_id, effective_day, sequence, ownership_policy)

func treasury_sponsored_demolish(country_handle: int, cell_idx: int,
		building_id: StringName, count: int, effective_day: int,
		sequence: int) -> Dictionary:
	return EconomyCommands.treasury_sponsored_demolish(self, country_handle, cell_idx, building_id, count, effective_day, sequence)

static func _demolish_result_message(code: String) -> String:
	return EconomyCommandResultText._demolish_result_message(code)

func dispatch_construction_command_receipts() -> void:
	EconomyCommands.dispatch_construction_command_receipts(self)

func emit_construction_command_receipts(receipts: Array) -> void:
	EconomyCommands.emit_construction_command_receipts(self, receipts)

func get_canal_route_quote(country_handle: int, start_cell: int, end_cell: int,
		waypoints: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return EconomyCommands.get_canal_route_quote(self, country_handle, start_cell, end_cell, waypoints)

func get_canal_route_quote_detail(country_handle: int,
		quote_token: int) -> Dictionary:
	return EconomyCommands.get_canal_route_quote_detail(self, country_handle, quote_token)

func queue_canal_construction(country_handle: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.queue_canal_construction(self, country_handle, quote_token, effective_day, sequence)

func family_colonization_quotes(country_handle: int, target_cell: int,
		family_filter: int = 0, source_filter: int = -1,
		offset: int = 0, limit: int = 64) -> Dictionary:
	return EconomyCommands.family_colonization_quotes(self, country_handle, target_cell, family_filter, source_filter, offset, limit)

func family_colonization_quote_detail(quote_token: int,
		population: int = -1) -> Dictionary:
	return EconomyCommands.family_colonization_quote_detail(self, quote_token, population)

func start_family_colonization(country_handle: int, family_handle: int,
		source_cell: int, target_cell: int, population: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.start_family_colonization(self,
		country_handle, family_handle, source_cell, target_cell, population, quote_token, effective_day, sequence)

func cancel_family_colonization(country_handle: int, expedition_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.cancel_family_colonization(self, country_handle, expedition_handle, effective_day, sequence)

func set_country_procurement_policy(country_handle: int, enabled: bool,
		treasury_share_bp: int, research_share_bp: int,
		effective_day: int, sequence: int,
		era_share_bp: int = -1, colonization_share_bp: int = -1) -> Dictionary:
	return EconomyCommands.set_country_procurement_policy(self,
		country_handle, enabled, treasury_share_bp, research_share_bp, effective_day, sequence, era_share_bp, colonization_share_bp)

func set_era_procurement_target(country_handle: int, active: bool,
		good_indices: PackedInt32Array, required_quantities: PackedInt64Array,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.set_era_procurement_target(self, country_handle, active, good_indices, required_quantities, effective_day, sequence)

func country_procurement_snapshot(country_handle: int) -> Dictionary:
	return EconomyCommands.country_procurement_snapshot(self, country_handle)

func family_expeditions(country_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	return EconomyCommands.family_expeditions(self, country_handle, offset, limit)

func family_expedition_snapshot(country_handle: int,
		expedition_handle: int) -> Dictionary:
	return EconomyCommands.family_expedition_snapshot(self, country_handle, expedition_handle)

func dispatch_family_colonization_receipts(country_handle: int) -> void:
	EconomyCommands.dispatch_family_colonization_receipts(self, country_handle)

func emit_family_colonization_receipts(receipts: Array, country_handle: int = 0) -> void:
	EconomyCommands.emit_family_colonization_receipts(self, receipts, country_handle)

static func _colonization_result_message(code: String) -> String:
	return EconomyCommandResultText._colonization_result_message(code)

static func _construction_result_message(code: String) -> String:
	return EconomyCommandResultText._construction_result_message(code)

func family_cell_snapshot(cell_idx: int, offset: int = 0, limit: int = 64) -> Dictionary:
	return EconomyQueries.family_cell_snapshot(self, cell_idx, offset, limit)

func family_snapshot(family_handle: int) -> Dictionary:
	return EconomyQueries.family_snapshot(self, family_handle)

func get_family_traits(family_handle: int) -> Dictionary:
	return EconomyQueries.get_family_traits(self, family_handle)

func family_branches(family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	return EconomyQueries.family_branches(self, family_handle, offset, limit)

func get_family_branch_effects(family_handle: int, cell_idx: int) -> Dictionary:
	return EconomyQueries.get_family_branch_effects(self, family_handle, cell_idx)

func queue_family_trait_mutation(family_handle: int, operation: Variant,
		trait_key: StringName, strength_q16: int = 65536,
		effective_day: int = 0, priority: int = 100,
		sequence: int = -1) -> int:
	return EconomyQueries.queue_family_trait_mutation(self, family_handle, operation, trait_key, strength_q16, effective_day, priority, sequence)

func family_founding_offers(offset: int = 0, limit: int = 16) -> Dictionary:
	return EconomyQueries.family_founding_offers(self, offset, limit)

func decorate_family_founding_offer(offer: Dictionary) -> void:
	EconomyQueries.decorate_family_founding_offer(self, offer)

func submit_family_founding_choice(offer_id: int, generation: int,
		choice_index: int, effective_day: int, sequence: int = 0) -> Dictionary:
	return EconomyQueries.submit_family_founding_choice(self, offer_id, generation, choice_index, effective_day, sequence)

func _decorate_family_founding_card(card: Dictionary, settlement_name: String) -> void:
	EconomyQueries._decorate_family_founding_card(self, card, settlement_name)

func _building_icon_for_type(type_id: String) -> StringName:
	return EconomyQueries._building_icon_for_type(self, type_id)

func queue_family_trigger_reward(effect: Dictionary) -> Dictionary:
	return EconomyQueries.queue_family_trigger_reward(self, effect)

func family_industries(family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	return EconomyQueries.family_industries(self, family_handle, offset, limit)

func family_notable_people(family_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	return EconomyQueries.family_notable_people(self, family_handle, offset, limit)

func notable_person_snapshot(person_handle: int) -> Dictionary:
	return EconomyQueries.notable_person_snapshot(self, person_handle)

func building_type_id(building_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	return ids.find(String(building_id))

func building_job_spec(building_id: StringName) -> Dictionary:
	return EconomyCommands.building_job_spec(self, building_id)

func building_placement_spec(building_id: StringName) -> Dictionary:
	return EconomyCommands.building_placement_spec(self, building_id)

func build(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.build(self, cell_idx, building_id, count, owner_handle, effective_day, sequence)

func demolish(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	return EconomyCommands.demolish(self, cell_idx, building_id, count, owner_handle, effective_day, sequence)

func report() -> Dictionary:
	return EconomySession.report(self)

func start_csv_recording(config: Dictionary) -> Dictionary:
	return EconomySession.start_csv_recording(self, config)

func request_stop_csv_recording() -> Dictionary:
	return EconomySession.request_stop_csv_recording(self)

func csv_recording_status() -> Dictionary:
	return EconomySession.csv_recording_status(self)

func begin_forensics_save(chunk_bytes: int) -> Dictionary:
	return EconomySession.begin_forensics_save(self, chunk_bytes)

func read_forensics_save_chunk(chunk_bytes: int) -> PackedByteArray:
	return EconomySession.read_forensics_save_chunk(self, chunk_bytes)

func end_forensics_save() -> Dictionary:
	return EconomySession.end_forensics_save(self)

func country_class_opinion_snapshot() -> Dictionary:
	return EconomySession.country_class_opinion_snapshot(self)

func native_catalog() -> Dictionary:
	return EconomySession.native_catalog(self)

func signature_id(profession_id: StringName, ethnicity_id: StringName) -> int:
	return EconomySession.signature_id(self, profession_id, ethnicity_id)

func good_ids() -> PackedStringArray:
	return EconomySession.good_ids(self)

func profession_ids() -> PackedStringArray:
	return EconomySession.profession_ids(self)

func building_type_ids() -> PackedStringArray:
	return EconomySession.building_type_ids(self)

func bootstrap_finance_columns() -> Dictionary:
	return EconomySession.bootstrap_finance_columns(self)

func bootstrap_cycle_days(cohort_count: int, market_count: int = 0,
		active_building_cell_count: int = 0, building_group_count: int = 0) -> int:
	return EconomySession.bootstrap_cycle_days(self, cohort_count, market_count, active_building_cell_count, building_group_count)

func need_display_name(stable_id: String) -> String:
	return EconomySession.need_display_name(self, stable_id)

func building_display_name(building_index: int) -> String:
	return EconomySession.building_display_name(self, building_index)

func good_display_name(good_index: int) -> String:
	return EconomySession.good_display_name(self, good_index)

func profession_display_name(profession_id: StringName) -> String:
	return EconomySession.profession_display_name(self, profession_id)

static func compose_family_display_name(
		settlement_name: String,
		surname: String,
		format: String = "CITY_SURNAME_SUFFIX",
		separator: String = "-",
		suffix: String = "氏") -> String:
	return EconomyFacadeDisplayScript.compose_family_display_name(
		settlement_name, surname, format, separator, suffix)

func settlement_display_name(cell: int) -> String:
	return EconomySession.settlement_display_name(self, cell)

func _load_family_effect_displays() -> void:
	EconomySession._load_family_effect_displays(self)

static func _load_display_names(directory: String) -> Dictionary:
	# [pk-export-remap] 见 economy_catalog.gd::_load_resources() 同名注释——导出
	# 包里 DirAccess 看到的是带 .remap 后缀的目录项，用 ResourceLoader.list_directory()
	# 才能拿到 x.tres 逻辑名。
	return EconomyFacadeDisplayScript.load_display_names(directory)

func begin_save() -> Dictionary:
	return EconomySession.begin_save(self)

func read_save_chunk() -> PackedByteArray:
	return EconomySession.read_save_chunk(self)

func end_save() -> Dictionary:
	return EconomySession.end_save(self)

func restore_bytes(bytes: PackedByteArray, _chunk_bytes: int = -1) -> Dictionary:
	return EconomySession.restore_bytes(self, bytes, _chunk_bytes)

func restore_ecp2(bytes: PackedByteArray) -> Dictionary:
	return EconomySession.restore_ecp2(self, bytes)

func capture_ecp2(flags: int = 0) -> Dictionary:
	return EconomySession.capture_ecp2(self, flags)

func restore_rejected_reason() -> String:
	return EconomySession.restore_rejected_reason(self)

func event_schema() -> Dictionary:
	return EconomySession.event_schema(self)

func set_trace_cells(cells: PackedInt32Array) -> Dictionary:
	return EconomySession.set_trace_cells(self, cells)

func set_inspector_trace_cell(cell_idx: int) -> Dictionary:
	return EconomySession.set_inspector_trace_cell(self, cell_idx)

func poll_events(consumer_id: StringName, max_events: int = -1,
		kind: int = 0, cell: int = -1, after_event_id: int = -1) -> Dictionary:
	return EconomySession.poll_events(self, consumer_id, max_events, kind, cell, after_event_id)

func ack_events(consumer_id: StringName, up_to_event_id: int) -> Dictionary:
	return EconomySession.ack_events(self, consumer_id, up_to_event_id)

func trace_report() -> Dictionary:
	return EconomySession.trace_report(self)

func dispatch_committed_events(meta: Dictionary) -> Dictionary:
	return EconomySession.dispatch_committed_events(self, meta)

func begin_event_archive(chunk_bytes: int = -1) -> Dictionary:
	return EconomySession.begin_event_archive(self, chunk_bytes)

func read_event_archive_chunk(max_bytes: int = -1) -> PackedByteArray:
	return EconomySession.read_event_archive_chunk(self, max_bytes)

func end_event_archive() -> Dictionary:
	return EconomySession.end_event_archive(self)

func write_event_archive(path: String, chunk_bytes: int = -1) -> Dictionary:
	return EconomySession.write_event_archive(self, path, chunk_bytes)

func world_ext() -> Object:
	return _world_ext

func profile():
	return _profile

func is_configured() -> bool:
	return _configured
