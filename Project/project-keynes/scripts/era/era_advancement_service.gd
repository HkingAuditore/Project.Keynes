class_name EraAdvancementService
extends RefCounted

## Player-session Era Advancement state machine
## (docs/cpp-dots-runtime/era-advancement-runtime.md §3/§5/§6).
##
##   LOCKED → READY → PURCHASING ⇄ PAUSED → COMPLETING → (era+1) LOCKED/READY
##
## Owns only session state: frozen territory/requirements, the per-era trade
## counter and the national procurement policy. Every authoritative mutation is
## delegated to CountryFacade / EconomyFacade (duck-typed, has_method guarded
## so the native APIs can land independently).
##
## Grant rule: current era c is CountryFacade.current_era_index (0 = stone
## even without tech.settled_knowledge). Advancing targets era c+1 and grants
## eras[c+1].milestone_id through CountryFacade.advance_era together with the
## goods consumption. The stone milestone (tech.settled_knowledge) is a
## prelude of the FIRST advancement: it is granted alone when purchasing
## starts, so its buff and the stone era-reward offer land while goods are
## being bought. Completion is deferred while an era-reward offer is still
## unresolved, because the native reward planner rejects a new milestone
## notification while a previous offer is open (that offer would be lost).

signal changed(snapshot: Dictionary)
signal era_advanced(old_index: int, new_index: int, buffs: PackedStringArray)

const CatalogScript = preload("res://scripts/era/era_advancement_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

const STATUS_LOCKED := "locked"
const STATUS_READY := "ready"
const STATUS_PURCHASING := "purchasing"
const STATUS_PAUSED := "paused"
const STATUS_COMPLETING := "completing"
const STATUS_MAX := "max"

const SAVE_VERSION := 1
const DEFAULT_TREASURY_SHARE_BP := 200
const DEFAULT_RESEARCH_SHARE_BP := 5000
## -1 = 沿用原生「谁有需求谁拿剩余」的分配规则（两项都未设置时是 50/50）。
## 玩家一旦在财政页拖动某个通道，该通道就固定按份额切分，0 即暂停。
const SHARE_UNSET := -1
## Days to wait for the milestone to become pending/complete after a
## completion submission before falling back to PURCHASING.
const COMPLETION_TIMEOUT_DAYS := 5
const TECHNOLOGY_STATE_PENDING := 4
const TECHNOLOGY_STATE_COMPLETED := 5
const FLAG_MILESTONE := 2

var _country = null
var _economy = null
var _handle := 0
var _sequence_provider: Callable = Callable()

# --- persisted session state -------------------------------------------------
## "" (idle) | purchasing | paused | completing
var _phase := ""
var _target_era := -1
var _frozen_territory := 0
var _required_good_ids := PackedStringArray()
var _required_quantities := PackedInt64Array()
var _known_era := -1
var _trade_era := -1
var _trade_accumulated := 0
var _completion_day := -1
var _prelude_granted := false
var _treasury_share_bp := DEFAULT_TREASURY_SHARE_BP
var _research_share_bp := DEFAULT_RESEARCH_SHARE_BP
var _era_share_bp := SHARE_UNSET
var _colonization_share_bp := SHARE_UNSET
# --- transient ---------------------------------------------------------------
var _last_trade_total := -1
var _last_refresh_day := -2147483648
var _last_snapshot: Dictionary = {}
var _catalog_cache: Dictionary = {}
var _era_tech_indices: Array = []


## Returns true when this call bound a new session (caller should push the
## transient native policy/target). A first bind keeps restored state; binding
## a different facade/handle afterwards (new world) resets it.
func bind(country_facade, economy_facade, handle: int,
		sequence_provider: Callable = Callable()) -> bool:
	var was_bound: bool = _country != null and _handle != 0
	var rebound: bool = country_facade != _country or handle != _handle
	_country = country_facade
	_economy = economy_facade
	_handle = handle
	_sequence_provider = sequence_provider
	if rebound and was_bound:
		reset()
	if rebound:
		_catalog_cache = {}
		_era_tech_indices = []
		_last_snapshot = {}
	return rebound and is_bound()


func is_bound() -> bool:
	return _country != null and _handle != 0


## Fresh session: forget all frozen/purchase state, keep nothing from a prior world.
func reset() -> void:
	_phase = ""
	_target_era = -1
	_frozen_territory = 0
	_required_good_ids = PackedStringArray()
	_required_quantities = PackedInt64Array()
	_known_era = -1
	_trade_era = -1
	_trade_accumulated = 0
	_completion_day = -1
	_prelude_granted = false
	_treasury_share_bp = DEFAULT_TREASURY_SHARE_BP
	_research_share_bp = DEFAULT_RESEARCH_SHARE_BP
	_era_share_bp = SHARE_UNSET
	_colonization_share_bp = SHARE_UNSET
	_last_trade_total = -1
	_last_refresh_day = -2147483648
	_last_snapshot = {}
	_catalog_cache = {}
	_era_tech_indices = []


# =============================================================================
# Policy
# =============================================================================

func policy() -> Dictionary:
	return {"treasury_share_bp": _treasury_share_bp,
		"research_share_bp": _research_share_bp,
		"era_share_bp": _era_share_bp,
		"colonization_share_bp": _colonization_share_bp}


## 三项（科技 + 时代 + 开拓）都是 national_daily 的份额，合计不得超过 100%。
## era/colonization 允许 -1（未设置，沿用原生旧规则）。
static func validate_policy(treasury_share_bp: int, research_share_bp: int,
		era_share_bp: int = SHARE_UNSET,
		colonization_share_bp: int = SHARE_UNSET) -> Dictionary:
	if treasury_share_bp < 0 or treasury_share_bp > 10000 \
			or research_share_bp < 0 or research_share_bp > 10000:
		return _result(false, "invalid_args", "国家购买预算份额必须在 0–10000 基点之间。")
	for pair in [["时代收购", era_share_bp], ["派遣储备", colonization_share_bp]]:
		var value := int(pair[1])
		if value < SHARE_UNSET or value > 10000:
			return _result(false, "invalid_args",
				"%s份额必须在 0–10000 基点之间。" % String(pair[0]))
	var allocated := research_share_bp + maxi(0, era_share_bp) + maxi(0, colonization_share_bp)
	if allocated > 10000:
		return _result(false, "share_over_allocated",
			"科技、时代收购与派遣储备的份额之和不能超过 100%。")
	return _result(true, "ok", "")


func set_policy(treasury_share_bp: int, research_share_bp: int,
		effective_day: int, sequence: int,
		era_share_bp: int = SHARE_UNSET,
		colonization_share_bp: int = SHARE_UNSET) -> Dictionary:
	var valid := validate_policy(treasury_share_bp, research_share_bp,
		era_share_bp, colonization_share_bp)
	if not bool(valid.ok):
		return valid
	_treasury_share_bp = treasury_share_bp
	_research_share_bp = research_share_bp
	_era_share_bp = era_share_bp
	_colonization_share_bp = colonization_share_bp
	var result := push_policy(effective_day, sequence)
	_emit_refresh()
	return result


func push_policy(effective_day: int, sequence: int) -> Dictionary:
	if _economy == null or _handle == 0 \
			or not _economy.has_method("set_country_procurement_policy"):
		return _result(true, "policy_stored_runtime_pending",
			"国家购买预算已记录，等待经济运行时接口就绪。")
	var result: Dictionary = _economy.set_country_procurement_policy(_handle, true,
		_treasury_share_bp, _research_share_bp, effective_day, sequence,
		_era_share_bp, _colonization_share_bp)
	return _normalized(result, "国家购买预算已更新，将在下一个经济周期生效。")


## Re-pushes policy and (when purchasing) the era target. Used at session start
## and after restore, because both native tables are transient.
func push_runtime_state(effective_day: int) -> void:
	push_policy(effective_day, _next_sequence())
	if _phase == STATUS_PURCHASING:
		_push_target(true, effective_day, _next_sequence())
	elif _phase == STATUS_PAUSED:
		_push_target(false, effective_day, _next_sequence())


# =============================================================================
# Commands
# =============================================================================

func start(effective_day: int, sequence: int) -> Dictionary:
	if not is_bound():
		return _result(false, "session_unavailable", "玩家国家尚未就绪。")
	var model := _build_snapshot(effective_day)
	match String(model.status):
		STATUS_MAX:
			return _result(false, "era_advance_max", "已到达最高时代。")
		STATUS_PURCHASING, STATUS_PAUSED, STATUS_COMPLETING:
			return _result(false, "era_advance_in_progress", "时代晋升已在进行中。")
		STATUS_LOCKED:
			return _result(false, "era_advance_conditions_unmet",
				"至少需要满足 %d 项晋升条件。" % CatalogScript.CONDITIONS_REQUIRED)
	var current := int(model.current_era_index)
	var target := current + 1
	_target_era = target
	_frozen_territory = maxi(1, _territory_count())
	_required_good_ids = PackedStringArray()
	_required_quantities = PackedInt64Array()
	for row in CatalogScript.procurement_goods(target):
		_required_good_ids.append(String(row.good_id))
		_required_quantities.append(CatalogScript.required_quantity(row, _frozen_territory))
	_phase = STATUS_PURCHASING
	_completion_day = -1
	_prelude_granted = false
	var result := _push_target(true, effective_day, sequence)
	if not bool(result.get("ok", false)) \
			and String(result.get("code", "")) != "era_target_runtime_pending":
		# Economy rejected the target: nothing started.
		_phase = ""
		_target_era = -1
		_frozen_territory = 0
		_required_good_ids = PackedStringArray()
		_required_quantities = PackedInt64Array()
		_emit_refresh(effective_day)
		return result
	_grant_prelude_if_needed(effective_day)
	_emit_refresh(effective_day)
	return _result(true, "era_advance_started",
		"时代晋升已开始，国家将按购买预算持续收购所需物资。")


func pause(effective_day: int, sequence: int) -> Dictionary:
	if _phase != STATUS_PURCHASING:
		return _result(false, "era_advance_not_purchasing", "当前没有进行中的收购。")
	_phase = STATUS_PAUSED
	var result := _push_target(false, effective_day, sequence)
	if not bool(result.get("ok", false)) \
			and String(result.get("code", "")) != "era_target_runtime_pending":
		_phase = STATUS_PURCHASING
		_emit_refresh(effective_day)
		return result
	_emit_refresh(effective_day)
	return _result(true, "era_advance_paused", "时代收购已暂停，已购物资保留在国库。")


func resume(effective_day: int, sequence: int) -> Dictionary:
	if _phase != STATUS_PAUSED:
		return _result(false, "era_advance_not_paused", "时代收购没有处于暂停状态。")
	_phase = STATUS_PURCHASING
	var result := _push_target(true, effective_day, sequence)
	if not bool(result.get("ok", false)) \
			and String(result.get("code", "")) != "era_target_runtime_pending":
		_phase = STATUS_PAUSED
		_emit_refresh(effective_day)
		return result
	_emit_refresh(effective_day)
	return _result(true, "era_advance_resumed", "时代收购已继续。")


# =============================================================================
# Daily refresh
# =============================================================================

## Called from the controller's day/commit hooks. Submissions happen at most
## once per game day; `force` only recomputes and republishes the snapshot.
func refresh(day: int, force: bool = false) -> Dictionary:
	if not is_bound():
		return {}
	var new_day := day != _last_refresh_day
	if not new_day and not force:
		return _last_snapshot
	if new_day:
		_last_refresh_day = day
		_sample_trade_counter()
	_detect_era_change()
	if new_day:
		_daily_step(day)
	return _emit_refresh(day)


func _daily_step(day: int) -> void:
	var effective_day := day + 1
	if _phase == STATUS_COMPLETING:
		var milestone_state := _technology_state(CatalogScript.milestone_id(_target_era))
		if milestone_state >= TECHNOLOGY_STATE_PENDING:
			return
		if _completion_day >= 0 and day - _completion_day > COMPLETION_TIMEOUT_DAYS:
			# Accepted at admission but never executed (e.g. treasury moved):
			# go back to buying.
			_phase = STATUS_PURCHASING
			_completion_day = -1
			_push_target(true, effective_day, _next_sequence())
		return
	if _phase != STATUS_PURCHASING:
		return
	if not _prelude_granted:
		_grant_prelude_if_needed(effective_day)
	if not _treasury_satisfies_requirements():
		return
	if _era_reward_unresolved():
		return
	if not _prelude_complete():
		return
	_submit_completion(day)


func _submit_completion(day: int) -> void:
	if _country == null or not _country.has_method("advance_era"):
		return
	var indices := _good_indices(_required_good_ids)
	if indices.size() != _required_good_ids.size():
		return
	var result: Dictionary = _country.advance_era(_handle,
		CatalogScript.milestone_id(_target_era), indices,
		_required_quantities.duplicate(), day + 1, _next_sequence())
	if not bool(result.get("ok", false)):
		# Stay PURCHASING; tomorrow's refresh retries.
		return
	_phase = STATUS_COMPLETING
	_completion_day = day
	# The goods are consumed by the same Country batch; stop the economy from
	# re-buying them before the Country ACK raises the era.
	_push_target(false, day + 1, _next_sequence())


func _detect_era_change() -> void:
	var era := _current_era()
	if era < 0:
		return
	if _known_era < 0:
		_known_era = era
		if _trade_era != era:
			_trade_era = era
			_trade_accumulated = 0
		return
	if era <= _known_era:
		return
	var old_era := _known_era
	_known_era = era
	var include_prelude := old_era == 0
	var buffs := PackedStringArray()
	for target in range(old_era + 1, era + 1):
		buffs.append_array(CatalogScript.buff_lines(target,
			include_prelude and target == CatalogScript.MIN_TARGET_ERA))
	var had_target := _phase == STATUS_PURCHASING or _phase == STATUS_PAUSED \
		or _phase == STATUS_COMPLETING
	if had_target and _phase != STATUS_COMPLETING:
		_push_target(false, _last_refresh_day + 1, _next_sequence())
	_phase = ""
	_target_era = -1
	_frozen_territory = 0
	_required_good_ids = PackedStringArray()
	_required_quantities = PackedInt64Array()
	_completion_day = -1
	_prelude_granted = false
	_trade_era = era
	_trade_accumulated = 0
	era_advanced.emit(old_era, era, buffs)


func _sample_trade_counter() -> void:
	var total := _trade_orders_total()
	if total < 0:
		return
	if _last_trade_total < 0 or total < _last_trade_total:
		# First sample of this session (or the transient counter restarted):
		# take it as the new baseline.
		_last_trade_total = total
		return
	_trade_accumulated += total - _last_trade_total
	_last_trade_total = total


# =============================================================================
# Snapshot (§5)
# =============================================================================

func snapshot() -> Dictionary:
	if _last_snapshot.is_empty():
		return _build_snapshot(_last_refresh_day)
	return _last_snapshot


## Fresh, side-effect-free model (no submissions, no signals).
func preview() -> Dictionary:
	return _build_snapshot(_last_refresh_day)


func _emit_refresh(day: int = -2147483648) -> Dictionary:
	_last_snapshot = _build_snapshot(day if day != -2147483648 else _last_refresh_day)
	changed.emit(_last_snapshot)
	return _last_snapshot


func _build_snapshot(_day: int) -> Dictionary:
	var current := _current_era()
	var ok := current >= 0 and is_bound()
	current = maxi(current, 0)
	var at_max := current >= mini(CatalogScript.MAX_ERA_INDEX,
		CatalogScript.era_count() - 1)
	var next_era := -1 if at_max else current + 1
	var target := _target_era if _phase != "" and _target_era > 0 else next_era
	var territory := _territory_count()
	var conditions: Array[Dictionary] = []
	var met := 0
	if next_era > 0 and ok:
		conditions = _conditions(current, next_era)
		for row in conditions:
			if bool(row.met):
				met += 1
	var status := STATUS_MAX if at_max else (_phase if _phase != "" else (
		STATUS_READY if met >= CatalogScript.CONDITIONS_REQUIRED else STATUS_LOCKED))
	if not ok:
		status = STATUS_LOCKED
	var costs := _costs(target, territory)
	var progress := 0.0
	if status == STATUS_COMPLETING:
		progress = 1.0
	elif not costs.is_empty() and (status == STATUS_PURCHASING or status == STATUS_PAUSED):
		var sum := 0.0
		for row in costs:
			sum += float(row.ratio)
		progress = clampf(sum / float(costs.size()), 0.0, 1.0)
	var buffs := CatalogScript.buff_lines(target,
		target == CatalogScript.MIN_TARGET_ERA and not _prelude_complete()) \
		if target > 0 else PackedStringArray()
	return {
		"ok": ok,
		"current_era_index": current,
		"current_era_name": CatalogScript.era_name(current),
		"next_era_index": next_era,
		"next_era_name": CatalogScript.era_name(next_era) if next_era >= 0 else "",
		"status": status,
		"conditions": conditions,
		"conditions_met": met,
		"conditions_required": CatalogScript.CONDITIONS_REQUIRED,
		"can_start": status == STATUS_READY,
		"territory_count": territory,
		"frozen_territory_count": _frozen_territory if _phase != "" else 0,
		"costs": costs,
		"progress": progress,
		"buffs_preview": buffs,
		"budget": _budget(),
	}


## Why a fully stocked purchase has not completed yet ("" when not blocked).
## Kept outside the §5 snapshot so that model stays exact.
func blocked_reason() -> String:
	var model := snapshot()
	return _blocked_reason(String(model.get("status", "")), model.get("costs", []))


func _conditions(current: int, target: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tech := _tech_progress(current)
	var tech_target := int(ceil(float(tech.total) * CatalogScript.TECH_COMPLETION_RATIO))
	var tech_met := int(tech.total) > 0 and int(tech.completed) >= tech_target
	out.append(_condition("tech", int(tech.completed), tech_target, tech_met,
		"%d / %d 项" % [int(tech.completed), tech_target]))
	out[out.size() - 1]["tooltip"] = "本时代共 %d 项科技，需完成 %d%%（%d 项）；当前已完成 %d 项。" % [
		int(tech.total), int(round(CatalogScript.TECH_COMPLETION_RATIO * 100.0)),
		tech_target, int(tech.completed)]
	var summary := _economy_summary()
	var population := int(summary.get("population", 0))
	var population_target := CatalogScript.population_threshold(target)
	out.append(_condition("population", population, population_target,
		population >= population_target, "%d / %d 人" % [population, population_target]))
	var buildings := int(summary.get("building_units", 0))
	var building_target := CatalogScript.building_threshold(target)
	out.append(_condition("buildings", buildings, building_target,
		buildings >= building_target, "%d / %d 座" % [buildings, building_target]))
	var trade_target := CatalogScript.trade_order_threshold(target)
	out.append(_condition("trade", _trade_accumulated, trade_target,
		_trade_accumulated >= trade_target,
		"%d / %d 次" % [_trade_accumulated, trade_target]))
	return out


static func _condition(key: String, current: int, target: int, met: bool,
		text: String) -> Dictionary:
	return {"key": key, "label": String(CatalogScript.CONDITION_LABELS.get(key, key)),
		"current": current, "target": target, "met": met, "text": text}


func _costs(target: int, territory: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if target <= 0:
		return out
	var stock := _treasury_goods()
	var names := _good_names()
	if _phase != "" and _required_good_ids.size() == _required_quantities.size() \
			and not _required_good_ids.is_empty():
		for i in range(_required_good_ids.size()):
			out.append(_cost_row(String(_required_good_ids[i]),
				int(_required_quantities[i]), stock, names))
		return out
	for row in CatalogScript.procurement_goods(target):
		out.append(_cost_row(String(row.good_id),
			CatalogScript.required_quantity(row, maxi(1, territory)), stock, names))
	return out


static func _cost_row(good_id: String, required: int, stock: Dictionary,
		names: Dictionary) -> Dictionary:
	var have := int(stock.get(good_id, 0))
	return {"good_id": good_id, "name": String(names.get(good_id, good_id)),
		"required": required, "in_treasury": have,
		"ratio": clampf(float(have) / float(maxi(1, required)), 0.0, 1.0)}


func _budget() -> Dictionary:
	var out := {"national_daily": 0, "era_daily": 0,
		"colonization_daily": 0,
		"treasury_share_bp": _treasury_share_bp,
		"research_share_bp": _research_share_bp,
		"era_share_bp": _era_share_bp,
		"colonization_share_bp": _colonization_share_bp}
	var procurement := _procurement_snapshot()
	if bool(procurement.get("ok", false)):
		out.national_daily = int(procurement.get("national_daily_budget", 0))
		out.era_daily = int(procurement.get("era_daily_budget", 0))
		out.colonization_daily = int(procurement.get("colonization_daily_budget", 0))
	return out


func _blocked_reason(status: String, costs: Array) -> String:
	if status != STATUS_PURCHASING:
		return ""
	for row in costs:
		if float(row.ratio) < 1.0:
			return ""
	if _era_reward_unresolved():
		return "请先领取待处理的时代奖励，物资已备齐后将自动完成晋升。"
	if not _prelude_complete():
		return "前置时代里程碑正在生效，完成后将自动晋升。"
	return ""


# =============================================================================
# Persistence (§6 player_view.era_advancement)
# =============================================================================

func to_save() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"phase": _phase,
		"target_era": _target_era,
		"frozen_territory": _frozen_territory,
		"required_good_ids": _required_good_ids.duplicate(),
		"required_quantities": _required_quantities.duplicate(),
		"known_era": _known_era,
		"trade_era": _trade_era,
		"trade_accumulated": _trade_accumulated,
		"completion_day": _completion_day,
		"prelude_granted": _prelude_granted,
		"treasury_share_bp": _treasury_share_bp,
		"research_share_bp": _research_share_bp,
		"era_share_bp": _era_share_bp,
		"colonization_share_bp": _colonization_share_bp,
	}


func restore(state: Dictionary) -> void:
	var keep_country = _country
	var keep_economy = _economy
	var keep_handle := _handle
	var keep_provider := _sequence_provider
	reset()
	_country = keep_country
	_economy = keep_economy
	_handle = keep_handle
	_sequence_provider = keep_provider
	if state.is_empty() or int(state.get("version", 0)) != SAVE_VERSION:
		return
	var phase := String(state.get("phase", ""))
	if not ["", STATUS_PURCHASING, STATUS_PAUSED, STATUS_COMPLETING].has(phase):
		phase = ""
	_phase = phase
	_target_era = int(state.get("target_era", -1))
	_frozen_territory = maxi(0, int(state.get("frozen_territory", 0)))
	_required_good_ids = PackedStringArray(state.get("required_good_ids", PackedStringArray()))
	_required_quantities = PackedInt64Array(state.get("required_quantities", PackedInt64Array()))
	if _required_good_ids.size() != _required_quantities.size() \
			or (_phase != "" and not CatalogScript.is_valid_target(_target_era)):
		_phase = ""
		_target_era = -1
		_required_good_ids = PackedStringArray()
		_required_quantities = PackedInt64Array()
	_known_era = int(state.get("known_era", -1))
	_trade_era = int(state.get("trade_era", -1))
	_trade_accumulated = maxi(0, int(state.get("trade_accumulated", 0)))
	_completion_day = int(state.get("completion_day", -1))
	_prelude_granted = bool(state.get("prelude_granted", false))
	var valid := validate_policy(int(state.get("treasury_share_bp", DEFAULT_TREASURY_SHARE_BP)),
		int(state.get("research_share_bp", DEFAULT_RESEARCH_SHARE_BP)),
		int(state.get("era_share_bp", SHARE_UNSET)),
		int(state.get("colonization_share_bp", SHARE_UNSET)))
	if bool(valid.ok):
		_treasury_share_bp = int(state.get("treasury_share_bp", DEFAULT_TREASURY_SHARE_BP))
		_research_share_bp = int(state.get("research_share_bp", DEFAULT_RESEARCH_SHARE_BP))
		_era_share_bp = int(state.get("era_share_bp", SHARE_UNSET))
		_colonization_share_bp = int(state.get("colonization_share_bp", SHARE_UNSET))
	# The native trade counter is transient: the next sample is the baseline.
	_last_trade_total = -1


# =============================================================================
# Facade adapters
# =============================================================================

func _push_target(active: bool, effective_day: int, sequence: int) -> Dictionary:
	if _economy == null or _handle == 0 \
			or not _economy.has_method("set_era_procurement_target"):
		return _result(false, "era_target_runtime_pending", "时代收购运行时接口尚未就绪。")
	var indices := PackedInt32Array()
	var quantities := PackedInt64Array()
	if active:
		indices = _good_indices(_required_good_ids)
		if indices.size() != _required_good_ids.size():
			return _result(false, "era_target_good_invalid", "时代收购物资无效。")
		quantities = _required_quantities.duplicate()
	var result: Dictionary = _economy.set_era_procurement_target(_handle, active,
		indices, quantities, effective_day, sequence)
	return _normalized(result, "")


func _grant_prelude_if_needed(effective_day: int) -> void:
	if _target_era != CatalogScript.MIN_TARGET_ERA:
		_prelude_granted = true
		return
	for prelude in CatalogScript.prelude_milestone_ids(_target_era):
		if _technology_state(prelude) >= TECHNOLOGY_STATE_PENDING:
			continue
		if _country == null or not _country.has_method("grant_technology"):
			return
		var result: Dictionary = _country.grant_technology(_handle, prelude,
			effective_day, _next_sequence())
		if not bool(result.get("ok", false)):
			return
	_prelude_granted = true


func _prelude_complete() -> bool:
	var target := _target_era if _target_era > 0 else _current_era() + 1
	for prelude in CatalogScript.prelude_milestone_ids(target):
		if _technology_state(prelude) < TECHNOLOGY_STATE_COMPLETED:
			return false
	return true


func _era_reward_unresolved() -> bool:
	if _country == null or not _country.has_method("era_reward_offer"):
		return false
	var offer: Dictionary = _country.era_reward_offer()
	return bool(offer.get("ok", false)) and String(offer.get("status", "NONE")) \
		in ["OPEN", "SELECTED_PENDING", "ERROR"]


func _treasury_satisfies_requirements() -> bool:
	if _required_good_ids.is_empty():
		return false
	var stock := _treasury_goods()
	for i in range(_required_good_ids.size()):
		if int(stock.get(String(_required_good_ids[i]), 0)) < int(_required_quantities[i]):
			return false
	return true


func _current_era() -> int:
	if _country == null or _handle == 0 or not _country.has_method("current_era_index"):
		return -1
	return int(_country.current_era_index(_handle))


func _territory_count() -> int:
	if _country == null or _handle == 0 or not _country.has_method("snapshot"):
		return 0
	var snapshot: Dictionary = _country.snapshot(_handle)
	return int(snapshot.get("territory_count", 0))


func _treasury_goods() -> Dictionary:
	var out := {}
	if _country == null or _handle == 0 or not _country.has_method("treasury_snapshot"):
		return out
	var treasury: Dictionary = _country.treasury_snapshot(_handle)
	var ids: PackedStringArray = treasury.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = treasury.get("quantities", PackedInt64Array())
	for i in range(mini(ids.size(), quantities.size())):
		out[String(ids[i])] = int(quantities[i])
	return out


func _economy_summary() -> Dictionary:
	if _economy == null or _handle == 0 \
			or not _economy.has_method("country_economy_overview"):
		return {}
	var summary: Dictionary = _economy.country_economy_overview(_handle, "summary")
	return summary if bool(summary.get("ok", false)) else {}


func _procurement_snapshot() -> Dictionary:
	if _economy == null or _handle == 0 \
			or not _economy.has_method("country_procurement_snapshot"):
		return {}
	return _economy.country_procurement_snapshot(_handle)


func _trade_orders_total() -> int:
	var procurement := _procurement_snapshot()
	# economy_busy_retry / read_view_pending: skip this sample (-1) instead of
	# reporting 0, which would become a bogus baseline and later count every
	# order since session start into the current era.
	if not bool(procurement.get("ok", false)) or not procurement.has("trade_orders_total"):
		return -1
	return maxi(0, int(procurement.get("trade_orders_total", 0)))


func _catalog() -> Dictionary:
	if not _catalog_cache.is_empty():
		return _catalog_cache
	var catalog: Dictionary = {}
	if _country != null and _country.has_method("native_catalog"):
		catalog = _country.native_catalog()
	if not catalog.has("technology_ids") or not catalog.has("technology_flags"):
		var technology: Dictionary = TechnologyCatalogScript.compile_native_catalog()
		for key in technology:
			if not catalog.has(key):
				catalog[key] = technology[key]
	_catalog_cache = catalog
	return _catalog_cache


func _good_indices(good_ids: PackedStringArray) -> PackedInt32Array:
	var all_ids: PackedStringArray = _economy.good_ids() \
		if _economy != null and _economy.has_method("good_ids") \
		else _catalog().get("good_ids", PackedStringArray())
	var out := PackedInt32Array()
	for good_id in good_ids:
		var index := all_ids.find(String(good_id))
		if index < 0:
			return PackedInt32Array()
		out.append(index)
	return out


func _good_names() -> Dictionary:
	var out := {}
	if _economy == null or not _economy.has_method("good_display_name") \
			or not _economy.has_method("good_ids"):
		return out
	var ids: PackedStringArray = _economy.good_ids()
	for good_id in CatalogScript.all_good_ids():
		var index := ids.find(String(good_id))
		if index >= 0:
			out[String(good_id)] = String(_economy.good_display_name(index))
	return out


func _technology_state(technology_id: StringName) -> int:
	if _country == null or _handle == 0 or not _country.has_method("research_snapshot"):
		return 0
	var ids: PackedStringArray = _catalog().get("technology_ids", PackedStringArray())
	var index := ids.find(String(technology_id))
	if index < 0:
		return 0
	var research: Dictionary = _country.research_snapshot(_handle)
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	return int(states[index]) if index < states.size() else 0


## Non-milestone research technologies of era `era_index` and how many are done.
func _tech_progress(era_index: int) -> Dictionary:
	var indices := _era_technologies(era_index)
	var completed := 0
	if not indices.is_empty() and _country != null and _country.has_method("research_snapshot"):
		var research: Dictionary = _country.research_snapshot(_handle)
		var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
		for index in indices:
			if int(index) < states.size() and int(states[int(index)]) >= TECHNOLOGY_STATE_COMPLETED:
				completed += 1
	return {"completed": completed, "total": indices.size()}


func _era_technologies(era_index: int) -> PackedInt32Array:
	if _era_tech_indices.is_empty():
		var catalog := _catalog()
		var era_order: PackedStringArray = catalog.get("technology_era_ids_ordered",
			PackedStringArray())
		var era_ids: PackedStringArray = catalog.get("technology_era_ids", PackedStringArray())
		var flags: PackedInt32Array = catalog.get("technology_flags", PackedInt32Array())
		var ids: PackedStringArray = catalog.get("technology_ids", PackedStringArray())
		var buckets: Array = []
		for _i in range(era_order.size()):
			buckets.append([])
		for technology in range(mini(era_ids.size(), flags.size())):
			if (int(flags[technology]) & FLAG_MILESTONE) != 0:
				continue
			if technology < ids.size() and String(ids[technology]).begins_with("app."):
				continue
			var position := era_order.find(String(era_ids[technology]))
			if position >= 0:
				(buckets[position] as Array).append(technology)
		# Packed arrays are value types: build plain arrays first, convert once.
		for bucket in buckets:
			_era_tech_indices.append(PackedInt32Array(bucket))
	if era_index < 0 or era_index >= _era_tech_indices.size():
		return PackedInt32Array()
	return _era_tech_indices[era_index]


func _next_sequence() -> int:
	return int(_sequence_provider.call()) if _sequence_provider.is_valid() else 0


static func _normalized(result: Dictionary, success_message: String) -> Dictionary:
	var out := result.duplicate()
	if not out.has("ok"):
		out["ok"] = false
	if not out.has("code"):
		out["code"] = "ok" if bool(out.ok) else String(out.get("reason", "command_rejected"))
	if not out.has("message"):
		out["message"] = success_message if bool(out.ok) else String(out.get("reason", ""))
	return out


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}
