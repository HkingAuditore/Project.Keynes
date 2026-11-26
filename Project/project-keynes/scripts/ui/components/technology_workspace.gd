extends Control
class_name TechnologyWorkspace

const WorkspaceCommands = preload("res://scripts/ui/components/technology_workspace_commands.gd")

const ResearchDashboard = preload("res://scripts/ui/components/technology_research_dashboard.gd")

const ResearchStateView = preload("res://scripts/ui/components/technology_research_state_view.gd")

const WorkspaceNavigation = preload("res://scripts/ui/components/technology_workspace_navigation.gd")

const WorkspaceControls = preload("res://scripts/ui/components/technology_workspace_controls.gd")

const TechnologyDetails = preload("res://scripts/ui/components/technology_workspace_details.gd")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const NationalProcurementSliderScript = preload("res://scripts/ui/components/national_procurement_slider.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

# The desktop research desk keeps policy, atlas, and detail as three distinct
# reading zones. Compact screens turn the side zones into mutually exclusive
# drawers so the technology graph never collapses into an unreadable sliver.

signal policy_submitted()

const TechnologyQueueRowScene := preload("res://scenes/ui/technology_queue_row.tscn")
const KPI_IDS := ["Era", "Stock", "Output", "Queue", "Treasury"]
const COMPACT_HIDDEN_KPIS := ["Output", "Treasury"]
const QUEUE_CAPACITY := 8
const HISTORY_DAYS := 30
const MODE_IDS := ["available", "focus", "overview"]

const CASH_SCALE := 10000.0
const POINT_SCALE := 1000.0
const POLICY_WIDTH := 320.0
const DETAIL_WIDTH := 360.0
const COMPACT_POLICY_WIDTH := 300.0
const COMPACT_DETAIL_WIDTH := 320.0
const COMPACT_RAIL_WIDTH := 42.0
const INTERNAL_COMPACT_WIDTH := 1120.0
# Below this workspace height the KPI band collapses to one line so the map and
# lists keep most of the page.
const DENSE_KPI_HEIGHT := 480.0
const MODE_NAV_WIDTH := 300.0
const DOMAIN_COUNT := 4
const MODE_AVAILABLE := 0
const MODE_FOCUS := 1
const MODE_OVERVIEW := 2

var _player_controller = null
var _definitions: Array = []
var _research_definition_count := 0
var _eras: Array = []
var _domains: Array = []
var _lanes: Array = []
var _visual_edges: Array = []
var _era_names: Dictionary = {}
var _technology_indices: Dictionary = {}
var _signal_indices: Dictionary = {}
var _signal_names: Dictionary = {}
var _research: Dictionary = {}
var _has_valid_research := false
var _development: Dictionary = {}
## Normalised EconomyFacade.country_procurement_snapshot (CountryViewModel
## .present_procurement); {available: false} when the native query is absent.
## 科技份额已经统一到国库的预算卷宗里，这里只读不写，不再需要本地乐观覆盖。
var _procurement: Dictionary = {}
var _queue_signature := ""
var _detail_signature := ""
var _last_states := PackedInt32Array()
var _mode := MODE_AVAILABLE
var _selected_technology := -1
var _focus_domain := ""
var _focus_era := 0
var _manual_focus := false
var _initial_focus_pending := true
var _compact := false
var _compact_requested := false
var _policy_open := true
var _detail_open := true

var _kpi_cards: Dictionary = {}
var _kpi_signatures: Dictionary = {}
var _era_label_key := 0
var _current_era_text := ""
var _mode_nav: DossierChapterNav
var _era_plate: Control
var _detail_header: Control
# Per research-day samples feeding the KPI sparklines and ETA estimates.
var _history: Array = []
var _queue_order: Dictionary = {}
var _queue_eta: Dictionary = {}
var _schedule_inputs: Dictionary = {}
var _policy_panel: PanelContainer
var _dial: Control
var _budget: Control
var _available: Control
var _tree: Control
var _overview: Control
var _detail: Control
var _detail_host: PanelContainer
var _policy_rail: Button
var _detail_rail: Button
var _policy_close: Button
var _detail_close: Button
var _main: Control
var _prev_era: Button
var _next_era: Button
var _era_label: Label
var _search: LineEdit
var _queue_zones: Array = []
var _queue_headers: Array = []
var _queue_rows: Array = []
var _research_signature := 0
var _refresh_count := 0
var _current_day := -1
# Host-accepted enqueue that the worker snapshot has not reflected yet. Keeps
# the left-hand queue honest while Country peers / next-day commit catch up.
# Values are {domain, request_id, technology_id}; request_id ties receipts.
var _optimistic_queue: Dictionary = {}
var _receipt_cursor := 0
var _optimistic_country_handle := 0
var _optimistic_baseline_stock := -1
var _optimistic_baseline_consumed := -1
var _optimistic_reconcile_fail_logged := false


func _ready() -> void:
	WorkspaceControls._ready(self)


func set_model(model: Dictionary) -> void:
	if _tree == null:
		_ready()
	if _definitions.is_empty():
		_definitions = model.get("technology_definitions", [])
		_research_definition_count = int(model.get(
			"technology_research_definition_count", _definitions.size()))
		_eras = model.get("technology_eras", [])
		_domains = model.get("technology_domains", [])
		_lanes = model.get("technology_lanes", [])
		_visual_edges = model.get("technology_visual_edges", [])
		for index in range(_definitions.size()):
			_technology_indices[String((_definitions[index] as Dictionary).get(
				"id", ""))] = index
		var signal_definitions: Array = model.get("research_signal_definitions", [])
		for index in range(signal_definitions.size()):
			var signal_definition: Dictionary = signal_definitions[index]
			_signal_indices[String(signal_definition.get("id", ""))] = index
			_signal_names[String(signal_definition.get("id", ""))] = String(
				signal_definition.get("display_name",
					signal_definition.get("id", "")))
		for era in _eras:
			_era_names[String((era as Dictionary).get("id", ""))] = \
				String((era as Dictionary).get("display_name", ""))
		if not _definitions.is_empty():
			_tree.set_catalog(_definitions, _eras, _domains, _visual_edges)
			_overview.set_catalog(_definitions, _eras, _domains)
			_available.set_catalog(_definitions, _domains, _research_definition_count,
				_era_names)
			_ensure_focus_domain()
			_dial.configure(_domains)
			_configure_queues()
	var candidate := _research_from_model(model)
	if not candidate.is_empty():
		_research = candidate
		_has_valid_research = true
	elif not _has_valid_research:
		_research = {}
	var candidate_development = model.get("development", null)
	if candidate_development is Dictionary and not (candidate_development as Dictionary).is_empty():
		_development = candidate_development
	_capture_procurement(model)
	_current_day = int(model.get("current_day", _current_day))
	_apply_research(true)


# Daily ticks reuse this path: only cached values and visible text change.
# GameUIManager already coalesces commit bursts, so every model that reaches
# this point is applied at once. The model dictionary is the view model's
# cache entry and must never be retained or mutated here.
func refresh_research(model: Dictionary) -> void:
	if _tree == null:
		return
	# CountryPanel opens with a cheap shell model and loads the section on the
	# next deferred frame.  That first refresh is also the catalog bootstrap;
	# patching only research here would leave the tree/layout empty forever.
	if _definitions.is_empty():
		set_model(model)
		return
	# Country UI snapshots can be transiently unavailable while a country day
	# publishes. Never replace a valid tree with that shell/error payload.
	var candidate := _research_from_model(model)
	if candidate.is_empty():
		return
	_research = candidate
	_has_valid_research = true
	var candidate_development = model.get("development", null)
	if candidate_development is Dictionary and not (candidate_development as Dictionary).is_empty():
		_development = candidate_development
	_capture_procurement(model)
	_current_day = int(model.get("current_day", _current_day))
	_apply_research()


func _capture_procurement(model: Dictionary) -> void:
	var value = model.get("procurement", null)
	if value is Dictionary:
		_procurement = value


func _process(_delta: float) -> void:
	_poll_optimistic_receipts()
	if not _optimistic_queue.is_empty():
		_reconcile_optimistic_from_live_snapshot()
	if _optimistic_queue.is_empty():
		set_process(false)


func refresh_count() -> int:
	return _refresh_count


func _research_from_model(model: Dictionary) -> Dictionary:
	var value = model.get("research", null)
	if not value is Dictionary:
		return {}
	var candidate: Dictionary = value
	if candidate.has("ok") and not bool(candidate.get("ok", false)):
		return {}
	var states_value = candidate.get("technology_states", null)
	if not states_value is PackedInt32Array:
		return {}
	var states: PackedInt32Array = states_value
	if states.is_empty() or (_research_definition_count > 0 \
			and states.size() != _research_definition_count):
		return {}
	# Compact / section snapshots sometimes omit the handle. Keep a stable
	# copy so optimistic reconcile can always talk to the same country.
	if int(candidate.get("country_handle", 0)) == 0:
		var handle := int(model.get("country_handle", 0))
		if handle == 0 and _player_controller != null \
				and _player_controller.has_method("get_player_country_handle"):
			handle = int(_player_controller.get_player_country_handle())
		if handle != 0:
			candidate = candidate.duplicate(false)
			candidate["country_handle"] = handle
	return candidate


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_compact(compact: bool) -> void:
	if _policy_panel == null:
		return
	_compact_requested = compact
	_update_effective_compact()


func _update_effective_compact() -> void:
	# 触摸档：手机的**逻辑宽度有 1942**（2670/1.375），纯宽度断点永远判成「宽屏」，
	# 于是手机上跑的是三栏桌面版、页签只有 17dp。这里补一条「触摸 + 纵向吃紧」的判据。
	var effective := _compact_requested or (size.x > 0.0 and size.x < INTERNAL_COMPACT_WIDTH) \
		or TouchUI.is_short_viewport()
	if _compact != effective:
		_compact = effective
		_policy_open = not effective
		_detail_open = not effective
	for key in COMPACT_HIDDEN_KPIS:
		var card := _kpi_cards.get(key) as Control
		if card != null:
			card.visible = not _compact
	var queue_card := _kpi_cards.get("Queue") as DossierKpiCard
	if queue_card != null:
		queue_card.show_divider = not _compact
		queue_card.queue_redraw()
	var dense := size.y > 0.0 and size.y < DENSE_KPI_HEIGHT
	for card in _kpi_cards.values():
		(card as DossierKpiCard).dense = dense
	_apply_column_layout()


func reset_navigation() -> void:
	_initial_focus_pending = true
	_manual_focus = false
	_set_mode(MODE_AVAILABLE)
	if not _definitions.is_empty():
		_apply_default_focus()
	_apply_column_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_effective_compact()


func _unhandled_key_input(event: InputEvent) -> void:
	# Hidden workspaces stay in the tree; swallowing Esc there blocks the pause menu.
	if is_visible_in_tree() and event.is_action_pressed("ui_cancel"):
		accept_event()


func tree_view() -> Control:
	return _tree


func available_view() -> Control:
	return _available


func overview_view() -> Control:
	return _overview


func navigation_report() -> Dictionary:
	return {
		"mode": _mode,
		"domain": _focus_domain,
		"lane": _focus_domain,
		"era": _focus_era,
		"policy_open": _policy_open,
		"detail_open": _detail_open,
		"policy_pinned": not _compact,
		"detail_pinned": not _compact,
	}


func _ensure_focus_domain() -> void:
	WorkspaceNavigation._ensure_focus_domain(self)


func _set_mode(mode: int) -> void:
	WorkspaceNavigation._set_mode(self, mode)


func _on_mode_chapter_selected(chapter_id: String) -> void:
	WorkspaceNavigation._on_mode_chapter_selected(self, chapter_id)


func _shift_era(delta: int) -> void:
	WorkspaceNavigation._shift_era(self, delta)


func _on_overview_cell_activated(domain_id: String, era_index: int,
		technology_index: int) -> void:
	WorkspaceNavigation._on_overview_cell_activated(self, domain_id, era_index, technology_index)


func _on_search_submitted(query: String) -> void:
	WorkspaceNavigation._on_search_submitted(self, query)


func _focus_technology(index: int) -> void:
	WorkspaceNavigation._focus_technology(self, index)


func _apply_focus(preferred_index: int) -> void:
	WorkspaceNavigation._apply_focus(self, preferred_index)


func _apply_default_focus() -> void:
	WorkspaceNavigation._apply_default_focus(self)


func _queue_priority_target() -> int:
	return WorkspaceNavigation._queue_priority_target(self)


func _frontier_target() -> int:
	return WorkspaceNavigation._frontier_target(self)


func _era_index(era_id: String) -> int:
	return WorkspaceNavigation._era_index(self, era_id)


func _is_retired(index: int) -> bool:
	return WorkspaceNavigation._is_retired(self, index)


func _deepest_visible_era() -> int:
	return WorkspaceNavigation._deepest_visible_era(self)


func _tree_visible_from_states(index: int, states: PackedInt32Array,
		parents: Array) -> bool:
	return WorkspaceNavigation._tree_visible_from_states(self, index, states, parents)


func _column_policy_width() -> float:
	return COMPACT_POLICY_WIDTH if _compact else POLICY_WIDTH


func _column_detail_width() -> float:
	return COMPACT_DETAIL_WIDTH if _compact else DETAIL_WIDTH



func _set_policy_open(open: bool) -> void:
	_policy_open = true if not _compact else open
	if _compact and open:
		_detail_open = false
	_apply_column_layout()



func _set_detail_open(open: bool) -> void:
	_detail_open = true if not _compact else open
	if _compact and open:
		_policy_open = false
	_apply_column_layout()


func _apply_column_layout() -> void:
	if _main == null or _policy_panel == null or _detail_host == null:
		return
	var left := _column_policy_width()
	var right := _column_detail_width()
	_policy_panel.visible = _policy_open
	_detail_host.visible = _detail_open
	_policy_rail.visible = _compact and not _policy_open
	_detail_rail.visible = _compact and not _detail_open
	_policy_close.visible = _compact
	_detail_close.visible = _compact
	if _detail_header != null:
		_detail_header.visible = _compact
	_policy_panel.offset_left = 0.0
	_policy_panel.offset_right = left
	_detail_host.offset_left = -right
	_detail_host.offset_right = 0.0
	_detail_host.clip_contents = true
	var canvas_left := left if _policy_open else (COMPACT_RAIL_WIDTH if _compact else 0.0)
	var canvas_right := -right if _detail_open else (-COMPACT_RAIL_WIDTH if _compact else 0.0)
	for canvas in [_available, _tree, _overview]:
		if canvas == null:
			continue
		canvas.offset_left = canvas_left
		canvas.offset_right = canvas_right


func _configure_queues() -> void:
	ResearchStateView._configure_queues(self)


func _research_state_signature() -> int:
	return ResearchStateView._research_state_signature(self)


func _apply_research(force: bool = false) -> void:
	ResearchStateView._apply_research(self, force)


func _optimistic_domain(entry) -> int:
	return ResearchStateView._optimistic_domain(self, entry)


func _optimistic_request_id(entry) -> int:
	return ResearchStateView._optimistic_request_id(self, entry)


func _overlay_optimistic_into(states: PackedInt32Array, offsets: PackedInt32Array,
		technologies: PackedInt32Array, erase_confirmed: bool = true) -> void:
	ResearchStateView._overlay_optimistic_into(self, states, offsets, technologies, erase_confirmed)


func _resolve_research_handle() -> int:
	return ResearchStateView._resolve_research_handle(self)


func _force_apply_live_research() -> bool:
	return ResearchStateView._force_apply_live_research(self)


func _reconcile_optimistic_from_live_snapshot() -> void:
	ResearchStateView._reconcile_optimistic_from_live_snapshot(self)


func _poll_optimistic_receipts() -> void:
	ResearchStateView._poll_optimistic_receipts(self)


func _sample_history() -> void:
	ResearchDashboard._sample_history(self)


func _daily_research_rate() -> float:
	return ResearchDashboard._daily_research_rate(self)


func _history_series(key: String, scale: float) -> PackedFloat32Array:
	return ResearchDashboard._history_series(self, key, scale)


func _daily_progress_series() -> PackedFloat32Array:
	return ResearchDashboard._daily_progress_series(self)


func _history_delta(key: String, scale: float) -> float:
	return ResearchDashboard._history_delta(self, key, scale)


func _patch_schedule(states: PackedInt32Array, progress: PackedInt64Array,
		weights: PackedInt32Array, offsets: PackedInt32Array,
		technologies: PackedInt32Array) -> void:
	ResearchDashboard._patch_schedule(self, states, progress, weights, offsets, technologies)


func _schedule_text(index: int, state: int) -> String:
	return ResearchDashboard._schedule_text(self, index, state)


func _update_kpis(states: PackedInt32Array) -> void:
	ResearchDashboard._update_kpis(self, states)


func _kpi_changed(id: String, signature: int) -> bool:
	return ResearchDashboard._kpi_changed(self, id, signature)


func _development_value_text(definition: Dictionary, current: int, qualifier: int,
		consecutive: int, target_days: int) -> String:
	return ResearchDashboard._development_value_text(self, definition, current, qualifier, consecutive, target_days)


func _current_era_label(states: PackedInt32Array) -> String:
	return ResearchDashboard._current_era_label(self, states)


func _scan_era_label(states: PackedInt32Array) -> String:
	return ResearchDashboard._scan_era_label(self, states)


func _era_label_for_milestone(milestone_id: String) -> String:
	return ResearchDashboard._era_label_for_milestone(self, milestone_id)


func _patch_queues(states: PackedInt32Array, progress: PackedInt64Array,
		weights: PackedInt32Array, offsets: PackedInt32Array = PackedInt32Array(),
		technologies: PackedInt32Array = PackedInt32Array()) -> void:
	ResearchDashboard._patch_queues(self, states, progress, weights, offsets, technologies)


func _rebuild_queue_rows(offsets: PackedInt32Array,
		technologies: PackedInt32Array) -> void:
	ResearchDashboard._rebuild_queue_rows(self, offsets, technologies)


func _refresh_detail(refresh_relations: bool = true) -> void:
	TechnologyDetails._refresh_detail(self, refresh_relations)


func _relation_signature(relations: Dictionary) -> String:
	return TechnologyDetails._relation_signature(self, relations)


func _relations_for(index: int, states: PackedInt32Array) -> Dictionary:
	return TechnologyDetails._relations_for(self, index, states)


func _authored_relation_entries(definition: Dictionary, ids_key: String,
		rationales_key: String, states: PackedInt32Array) -> Array:
	return TechnologyDetails._authored_relation_entries(self, definition, ids_key, rationales_key, states)


func _relation_entry_with_rationale(index: int, states: PackedInt32Array,
		rationale: String) -> Dictionary:
	return TechnologyDetails._relation_entry_with_rationale(self, index, states, rationale)


func _relation_entry(index: int, states: PackedInt32Array, prefix: String = "") -> Dictionary:
	return TechnologyDetails._relation_entry(self, index, states, prefix)


func _condition_items(index: int, states: PackedInt32Array) -> Array:
	return TechnologyDetails._condition_items(self, index, states)


func _signal_evidence() -> Dictionary:
	return TechnologyDetails._signal_evidence(self)


func _evaluate_condition(spec: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	return TechnologyDetails._evaluate_condition(self, spec, states, evidence)


func _evaluate_condition_atom(atom: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	return TechnologyDetails._evaluate_condition_atom(self, atom, states, evidence)


func _development_definition(signal_id: String) -> Dictionary:
	return TechnologyDetails._development_definition(self, signal_id)


func _on_available_selected(index: int) -> void:
	WorkspaceCommands._on_available_selected(self, index)


func _on_tree_selected(index: int) -> void:
	WorkspaceCommands._on_tree_selected(self, index)


func _on_tree_activated(index: int) -> void:
	WorkspaceCommands._on_tree_activated(self, index)


func _on_weights_previewed(weights_bp: PackedInt32Array) -> void:
	WorkspaceCommands._on_weights_previewed(self, weights_bp)


func _on_weights_committed(weights_bp: PackedInt32Array) -> void:
	WorkspaceCommands._on_weights_committed(self, weights_bp)


func _procurement_policy() -> Dictionary:
	return WorkspaceCommands._procurement_policy(self)


func _national_daily_budget(policy: Dictionary) -> int:
	return WorkspaceCommands._national_daily_budget(self, policy)


func _daily_research_budget() -> int:
	return WorkspaceCommands._daily_research_budget(self)


func _apply_budget_notice() -> void:
	WorkspaceCommands._apply_budget_notice(self)


func _on_open_budget_requested() -> void:
	WorkspaceCommands._on_open_budget_requested(self)


func _enqueue(index: int) -> void:
	WorkspaceCommands._enqueue(self, index)


func _remove_from_queue(index: int) -> void:
	WorkspaceCommands._remove_from_queue(self, index)


func _research_command_message(code: String) -> String:
	return WorkspaceCommands._research_command_message(self, code)


func _move_in_queue(technology: int, domain: int, position: int) -> void:
	WorkspaceCommands._move_in_queue(self, technology, domain, position)


func _presentation_states(research_states: PackedInt32Array) -> PackedInt32Array:
	var states := PackedInt32Array()
	states.resize(_definitions.size())
	for index in range(mini(research_states.size(), _definitions.size())):
		states[index] = research_states[index]
	for index in range(_research_definition_count, _definitions.size()):
		states[index] = _application_state(_definitions[index], research_states)
	return states


func _presentation_progress(research_progress: PackedInt64Array) -> PackedInt64Array:
	var progress := PackedInt64Array()
	progress.resize(_definitions.size())
	for index in range(mini(research_progress.size(), _definitions.size())):
		progress[index] = research_progress[index]
	return progress


func _application_state(definition: Dictionary,
		research_states: PackedInt32Array) -> int:
	return TechnologyDetails._application_state(self, definition, research_states)


func _application_condition_items(definition: Dictionary,
		states: PackedInt32Array) -> Array:
	return TechnologyDetails._application_condition_items(self, definition, states)


func _append_application_constraints(items: Array, definition: Dictionary,
		field: String, category: String, verification: String) -> void:
	TechnologyDetails._append_application_constraints(self, items, definition, field, category, verification)


func _is_application_definition(definition: Dictionary) -> bool:
	return TechnologyDetails._is_application_definition(self, definition)


func _domain_index_of(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for domain in range(_domains.size()):
		if String((_domains[domain] as Dictionary).get("id", "")) == domain_id:
			return domain
	return maxi(0, ["agriculture", "engineering", "science", "society"].find(domain_id))


func _domain_id(domain: int) -> String:
	if domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("id", ""))
	return ""


func _domain_name(domain: int) -> String:
	if domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("display_name", ""))
	return ""


func _domain_accent(domain: int) -> Color:
	if domain < _domains.size():
		return (_domains[domain] as Dictionary).get("accent", UITokens.ACCENT)
	return UITokens.ACCENT
