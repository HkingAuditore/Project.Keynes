class_name CountryFacade
extends RefCounted

const CommitSignals = preload("res://scripts/country/country_commit_signals.gd")

const TaxOverrideBatch = preload("res://scripts/country/country_tax_override_batch.gd")

signal country_committed(report: Dictionary)

## 11 个时代的里程碑科技索引，与 technology_network.json 的 eras 顺序一致。
static var _era_milestone_indices := PackedInt32Array()
signal research_signal_discovered(event: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/country/default_country.tres"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryProfileScript = preload("res://scripts/data/country_profile.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const PoliticalRegimeCatalogScript = preload(
	"res://scripts/country/political_regime_catalog.gd")
const TAX_RATE_MIN_BP := -100000
const TAX_RATE_MAX_BP := 10000
const TAX_ABSOLUTE_MIN := -1000000000
const TAX_ABSOLUTE_MAX := 1000000000
const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1

enum Opcode {
	CREATE_COUNTRY = 1,
	RENAME_COUNTRY = 2,
	TRANSFER_TERRITORY = 3,
	GRANT_TECHNOLOGY = 4,
	SET_RESEARCH_WEIGHTS = 5,
	ENQUEUE_RESEARCH = 6,
	REMOVE_RESEARCH = 7,
	MOVE_RESEARCH = 8,
	SET_RESEARCH_AUTO_PURCHASE = 9,
	REVEAL_ALL_TECHNOLOGIES = 10,
	SET_TAX_DEFAULT = 11,
	SET_TAX_OVERRIDE = 12,
	CLEAR_TAX_OVERRIDE = 13,
	DISCOVER_COUNTRY_SIGNAL = 14,
	SET_CELL_TAX_DEFAULT = 15,
	CLEAR_CELL_TAX_DEFAULT = 16,
	SET_CELL_TAX_OVERRIDE = 17,
	CLEAR_CELL_TAX_OVERRIDE = 18,
	CLEAR_CELL_TAX_POLICY = 19,
	CLAIM_UNOWNED_TERRITORY = 20,
	## 时代晋升：technology(aux) = good 索引，value = 数量（GOODS_SCALE）。
	## 国库不足时整批拒绝 country_treasury_goods_insufficient。
	CONSUME_TREASURY_GOODS = 21,
	## 22/25/26 保留不用（controller 在 Military），提交即拒绝。
	## 收款/吞并国句柄编码：cell = slot，technology(aux) = generation。
	## value = 金额（MONEY_SCALE），余额不足按余额转移；事件 values 为实转额。
	TRANSFER_CASH_BETWEEN_COUNTRIES = 23,
	## domain = dense good，value = 数量（GOODS_SCALE），不足按余额。
	TRANSFER_GOODS_BETWEEN_COUNTRIES = 24,
	## target_handle = 受害国。同批次原子：领土/现金/物资全部归吞并国，
	## 受害国失效且 generation+1；持旧句柄的后续命令 country_handle_invalid。
	ANNEX_COUNTRY = 27,
	## stable_id carries the political regime stable id for this opcode.
	SET_POLITICAL_REGIME = 28,
}

enum TaxKind {
	INCOME = 0,
	CONSUMPTION = 1,
	BUSINESS = 2,
	IMPORT = 3,
	EXPORT = 4,
}

enum TaxAssessmentMode {
	PERCENT_BP = 0,
	ABSOLUTE = 1,
}

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _political_regime_catalog: Resource = null
var _political_regime_native_catalog: Dictionary = {}
var _configured: bool = false
var _last_event_id: int = 0

func configure(world_ext: DCWorldExt, cell_count: int, seed: int,
		profile = null, compiled_catalog: Dictionary = {},
		political_catalog: Resource = null,
		modifier_catalog: Dictionary = {}) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null:
		return {"ok": false, "reason": "DCWorldExt country API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "CountryProfile unavailable"}
	_catalog = compiled_catalog.duplicate(true) if not compiled_catalog.is_empty() \
		else EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", true)):
		return _catalog
	_political_regime_catalog = political_catalog \
		if political_catalog != null else PoliticalRegimeCatalogScript.load_default()
	if _political_regime_catalog == null \
		or not _political_regime_catalog.has_method("compile_native_catalog"):
		return {"ok": false, "reason": "political_regime_catalog_unavailable"}
	_political_regime_native_catalog = _political_regime_catalog.compile_native_catalog(
		_catalog, modifier_catalog)
	if not bool(_political_regime_native_catalog.get("ok", false)):
		return _political_regime_native_catalog
	for key in ["political_regime_ids", "political_regime_capability_bits",
			"political_regime_catalog_hash", "political_regime_default_id"]:
		_catalog[key] = _political_regime_native_catalog.get(key)
	var native_catalog := _catalog.duplicate(false)
	native_catalog.erase("ok")
	var result: Dictionary = _world_ext.configure_country(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	return result

func bootstrap(is_water: PackedByteArray, packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	return _world_ext.bootstrap_country(packet, is_water)

func submit(commands: Array[Dictionary], preserve_effective_days: bool = false) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	return _world_ext.submit_country_commands(preload(
		"res://scripts/country/country_command_batch.gd").pack(
		commands, preserve_effective_days, TAX_MODE_PERCENT_BP))


## Returns only terminal worker receipts for Country commands admitted through
## the Host. Admission is reported by submit(); this cursor closes the
## Accepted -> Committed/RejectedAtExecution lifecycle without consuming the
## generic runtime receipt queue used by other domains.
func poll_worker_command_receipts(after_publication: int = 0,
		limit: int = 128) -> Dictionary:
	if _world_ext == null:
		return {"ok": false, "code": "country_worker_receipt_api_missing"}
	return _world_ext.poll_country_command_receipts(maxi(after_publication, 0),
		clampi(limit, 1, 4096))


func create_country(stable_id: StringName, display_name: String, first_cell: int,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.CREATE_COUNTRY, "stable_id": String(stable_id),
		"display_name": display_name, "cell": first_cell,
		"effective_day": effective_day, "sequence": sequence}])

func rename_country(handle: int, display_name: String,
		effective_day: int, sequence: int, preserve_effective_days: bool = false) -> Dictionary:
	return submit([{"opcode": Opcode.RENAME_COUNTRY, "target_handle": handle,
		"display_name": display_name, "effective_day": effective_day, "sequence": sequence}], preserve_effective_days)

func transfer_territory(cell: int, target_handle: int,
		effective_day: int, sequence: int, preserve_effective_days: bool = false) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_TERRITORY, "target_handle": target_handle,
		"cell": cell, "effective_day": effective_day, "sequence": sequence}], preserve_effective_days)

func grant_technology(handle: int, technology_id: StringName,
		effective_day: int, sequence: int, preserve_effective_days: bool = false) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	var technology := ids.find(String(technology_id))
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.GRANT_TECHNOLOGY, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}], preserve_effective_days)

func set_research_weights(handle: int, weights_bp: PackedInt32Array,
		effective_day: int, sequence: int) -> Dictionary:
	if weights_bp.size() != 4:
		return {"ok": false, "reason": "research weights require four domains"}
	var total := 0
	for weight in weights_bp:
		if int(weight) < 0 or int(weight) > 10000:
			return {"ok": false, "reason": "research weights must be within 0..10000"}
		total += int(weight)
	if total != 10000:
		return {"ok": false, "reason": "research weights must sum to 10000"}
	return submit([{"opcode": Opcode.SET_RESEARCH_WEIGHTS, "target_handle": handle,
		"weights_bp": weights_bp, "effective_day": effective_day, "sequence": sequence}])

func enqueue_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.ENQUEUE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

func remove_research(handle: int, technology_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.REMOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence}])

func move_research(handle: int, technology_id: StringName, domain: int,
		position: int, effective_day: int, sequence: int) -> Dictionary:
	var technology := _technology_index(technology_id)
	if technology < 0:
		return {"ok": false, "reason": "unknown technology id: %s" % String(technology_id)}
	return submit([{"opcode": Opcode.MOVE_RESEARCH, "target_handle": handle,
		"technology": technology, "domain": domain, "position": position,
		"effective_day": effective_day, "sequence": sequence}])

## 科研日预算由国家购买政策（国库份额 × 科研份额）决定，这里只开关自动采购。
func set_research_auto_purchase(handle: int, enabled: bool,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.SET_RESEARCH_AUTO_PURCHASE, "target_handle": handle,
		"technology": 1 if enabled else 0, "effective_day": effective_day, "sequence": sequence}])

## 时代晋升：一次 submit 原子提交 n 条 CONSUME_TREASURY_GOODS + 1 条 GRANT_TECHNOLOGY。
## 任一物资不足则整批（包括时代令牌授予）被拒绝。
## 见 docs/cpp-dots-runtime/era-advancement-runtime.md §2.1。
func advance_era(handle: int, milestone_technology_id: StringName,
		good_indices: PackedInt32Array, quantities: PackedInt64Array,
		effective_day: int, sequence: int) -> Dictionary:
	if good_indices.size() != quantities.size():
		return {"ok": false, "reason": "era_advance_goods_shape_invalid"}
	var technology := _technology_index(milestone_technology_id)
	if technology < 0:
		return {"ok": false,
			"reason": "unknown technology id: %s" % String(milestone_technology_id)}
	var commands: Array[Dictionary] = []
	for i in range(good_indices.size()):
		var quantity := int(quantities[i])
		if quantity <= 0:
			continue
		commands.append({"opcode": Opcode.CONSUME_TREASURY_GOODS,
			"target_handle": handle, "technology": int(good_indices[i]),
			"value": quantity, "effective_day": effective_day, "sequence": sequence})
	# The grant shares effective_day/sequence and is appended last; native
	# ordering is (effective_day, sequence, submit_order), so it runs after
	# every consume in the same atomic batch.
	commands.append({"opcode": Opcode.GRANT_TECHNOLOGY, "target_handle": handle,
		"technology": technology, "effective_day": effective_day, "sequence": sequence})
	return submit(commands)

func reveal_all_technologies(handle: int, effective_day: int,
		sequence: int, preserve_effective_days: bool = false) -> Dictionary:
	return submit([{"opcode": Opcode.REVEAL_ALL_TECHNOLOGIES,
		"target_handle": handle, "effective_day": effective_day, "sequence": sequence}], preserve_effective_days)

## 把国家句柄拆成 (slot, generation) 编入 cell/aux 两个 32 位通道。
static func _receiver_payload(command: Dictionary, receiver_handle: int) -> Dictionary:
	command["cell"] = receiver_handle & 0xffffffff
	command["technology"] = (receiver_handle >> 32) & 0xffffffff
	return command

func transfer_cash_between(from_handle: int, to_handle: int, amount: int,
		effective_day: int = 0, sequence: int = 0) -> Dictionary:
	if amount <= 0 or from_handle == 0 or to_handle == 0 or from_handle == to_handle:
		return {"ok": false, "reason": "country_transfer_between_command_invalid"}
	return submit([_receiver_payload({
		"opcode": Opcode.TRANSFER_CASH_BETWEEN_COUNTRIES,
		"target_handle": from_handle, "value": amount,
		"effective_day": effective_day, "sequence": sequence}, to_handle)])

func transfer_goods_between(from_handle: int, to_handle: int, good: int,
		quantity: int, effective_day: int = 0, sequence: int = 0) -> Dictionary:
	if quantity <= 0 or good < 0 or from_handle == 0 or to_handle == 0 \
			or from_handle == to_handle:
		return {"ok": false, "reason": "country_transfer_between_command_invalid"}
	return submit([_receiver_payload({
		"opcode": Opcode.TRANSFER_GOODS_BETWEEN_COUNTRIES,
		"target_handle": from_handle, "domain": good, "value": quantity,
		"effective_day": effective_day, "sequence": sequence}, to_handle)])

func annex_country(victim_handle: int, annexer_handle: int,
		effective_day: int = 0, sequence: int = 0) -> Dictionary:
	if victim_handle == 0 or annexer_handle == 0 or victim_handle == annexer_handle:
		return {"ok": false, "reason": "country_annex_command_invalid"}
	return submit([_receiver_payload({
		"opcode": Opcode.ANNEX_COUNTRY, "target_handle": victim_handle,
		"effective_day": effective_day, "sequence": sequence}, annexer_handle)])

func discover_research_signal(handle: int, signal_id: StringName, cell: int,
		source_kind: int, effective_day: int, sequence: int) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("research_signal_ids", PackedStringArray())
	var signal_index := ids.find(String(signal_id))
	if signal_index < 0:
		return {"ok": false, "reason": "unknown research signal id: %s" % String(signal_id)}
	return submit([{
		"opcode": Opcode.DISCOVER_COUNTRY_SIGNAL,
		"target_handle": handle,
		"signal": signal_index,
		"cell": cell,
		"value": source_kind,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func _tax_value_valid(mode: int, value: int) -> bool:
	if mode == TAX_MODE_ABSOLUTE:
		return value >= TAX_ABSOLUTE_MIN and value <= TAX_ABSOLUTE_MAX
	if mode == TAX_MODE_PERCENT_BP:
		return value >= TAX_RATE_MIN_BP and value <= TAX_RATE_MAX_BP
	return false


func set_tax_default(handle: int, kind: int, rate_percent: int,
		effective_day: int, sequence: int) -> Dictionary:
	return set_tax_default_basis_points(
		handle, kind, rate_percent * 100, effective_day, sequence)


func set_tax_default_basis_points(handle: int, kind: int, rate_basis_points: int,
		effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_TAX_DEFAULT,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func set_tax_override(handle: int, kind: int, item_id: StringName,
		rate_percent: int, effective_day: int, sequence: int) -> Dictionary:
	return set_tax_override_basis_points(
		handle, kind, item_id, rate_percent * 100, effective_day, sequence)


func set_tax_override_basis_points(handle: int, kind: int, item_id: StringName,
		rate_basis_points: int, effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


## 按税组批量写 override：整批一次 submit，N 条 SET_TAX_OVERRIDE 同批准入，
## 所以不会出现「同一滑条只生效一半」的跨天中间态——原子性由命令批次保证，
## 不是因为每个 item 单独成功。内核的 building_type 键数与结算表都不变。
func set_tax_override_group_basis_points(handle: int, kind: int,
		building_ids: PackedStringArray, rate_basis_points: int,
		effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	return TaxOverrideBatch.set_tax_override_group_basis_points(
		self, handle, kind, building_ids, rate_basis_points,
		effective_day, sequence, assessment_mode)


func clear_tax_override(handle: int, kind: int, item_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	return submit([{
		"opcode": Opcode.CLEAR_TAX_OVERRIDE,
		"target_handle": handle,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"effective_day": effective_day,
		"sequence": sequence,
	}])


## 按税组批量清除 override：回滚「整组设了统一税率」时用，同样一次 submit。
func clear_tax_override_group(handle: int, kind: int,
		building_ids: PackedStringArray, effective_day: int,
		sequence: int) -> Dictionary:
	return TaxOverrideBatch.clear_tax_override_group(self, handle, kind, building_ids, effective_day, sequence)


## 回滚用：一批命令逐 item 指定各自税率。基线下本来有 override 的 item 用它
## 恢复原值，本来没有的才走 clear_tax_override_group。整批共用一个 sequence：
## 内核按 (effective_day, sequence, submit_order) 排序，同天连拉两次滑条也不会
## 让前一批的条目越到后一批之后。
func set_tax_overrides_batch(handle: int, kind: int,
		item_ids: PackedStringArray, rates_basis_points: PackedInt32Array,
		effective_day: int, sequence: int) -> Dictionary:
	return TaxOverrideBatch.set_tax_overrides_batch(self, handle, kind, item_ids, rates_basis_points, effective_day, sequence)


func tax_policy_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_tax_policy_snapshot(handle) if _configured else {}


func set_cell_tax_default(handle: int, cell: int, kind: int, rate_percent: int,
		effective_day: int, sequence: int) -> Dictionary:
	return set_cell_tax_default_basis_points(
		handle, cell, kind, rate_percent * 100, effective_day, sequence)


func set_cell_tax_default_basis_points(handle: int, cell: int, kind: int,
		rate_basis_points: int, effective_day: int, sequence: int,
		assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_CELL_TAX_DEFAULT,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_default(handle: int, cell: int, kind: int,
		effective_day: int, sequence: int) -> Dictionary:
	if kind < TaxKind.INCOME or kind > TaxKind.EXPORT:
		return {"ok": false, "reason": "invalid tax kind"}
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_DEFAULT,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func set_cell_tax_override(handle: int, cell: int, kind: int,
		item_id: StringName, rate_percent: int, effective_day: int,
		sequence: int) -> Dictionary:
	return set_cell_tax_override_basis_points(
		handle, cell, kind, item_id, rate_percent * 100,
		effective_day, sequence)


func set_cell_tax_override_basis_points(handle: int, cell: int, kind: int,
		item_id: StringName, rate_basis_points: int, effective_day: int,
		sequence: int, assessment_mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	if assessment_mode != TAX_MODE_PERCENT_BP and assessment_mode != TAX_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid tax assessment mode"}
	if not _tax_value_valid(assessment_mode, rate_basis_points):
		return {"ok": false, "reason": "tax value out of range for assessment mode"}
	return submit([{
		"opcode": Opcode.SET_CELL_TAX_OVERRIDE,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"tax_rate_basis_points": rate_basis_points,
		"tax_assessment_mode": assessment_mode,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_override(handle: int, cell: int, kind: int,
		item_id: StringName, effective_day: int, sequence: int) -> Dictionary:
	var item := _tax_item_index(kind, item_id)
	if item < 0:
		return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_OVERRIDE,
		"target_handle": handle,
		"cell": cell,
		"tax_kind": kind,
		"tax_item": item,
		"stable_id": String(item_id),
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func clear_cell_tax_policy(handle: int, cell: int, effective_day: int,
		sequence: int) -> Dictionary:
	return submit([{
		"opcode": Opcode.CLEAR_CELL_TAX_POLICY,
		"target_handle": handle,
		"cell": cell,
		"effective_day": effective_day,
		"sequence": sequence,
	}])


func cell_tax_policy_snapshot(cell: int) -> Dictionary:
	return _world_ext.get_country_cell_tax_policy_snapshot(cell) \
		if _configured else {}


func fiscal_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_fiscal_snapshot(handle) if _configured  else {}


func _tax_item_index(kind: int, item_id: StringName) -> int:
	var key := ""
	match kind:
		TaxKind.INCOME:
			key = "profession_ids"
		TaxKind.CONSUMPTION, TaxKind.IMPORT, TaxKind.EXPORT:
			key = "good_ids"
		TaxKind.BUSINESS:
			key = "building_type_ids"
		_:
			return -1
	var ids: PackedStringArray = _catalog.get(key, PackedStringArray())
	return ids.find(String(item_id))

func research_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_research_snapshot(handle) if _configured else {}

## 当前时代索引（0-based，对应 technology_network.json 的 eras 顺序）。
## 与原生 visual_era_index_for_slot 同语义：**只认已生效（state == 5）的里程碑科技**。
## 不要改用 country_view_model 的 _development_model —— 那套把"已发现"（state 1-4）
## 也算进最高时代，会超前于真实时代。
func current_era_index(handle: int) -> int:
	if not _configured:
		return -1
	var research := research_snapshot(handle)
	if research.is_empty():
		return -1
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	if states.is_empty():
		return -1
	var milestones := era_milestone_indices()
	if milestones.is_empty():
		return -1
	var reached := 0
	for era_index in range(milestones.size()):
		var technology := int(milestones[era_index])
		if technology >= 0 and technology < states.size() and int(states[technology]) >= 5:
			reached = era_index
	return reached


## 11 个时代的里程碑科技索引，顺序与 eras 数组一致。首次调用后缓存。
static func era_milestone_indices() -> PackedInt32Array:
	if not _era_milestone_indices.is_empty():
		return _era_milestone_indices
	var catalog := TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return PackedInt32Array()
	_era_milestone_indices = catalog.get("technology_era_milestone_indices", PackedInt32Array())
	return _era_milestone_indices


func research_signal_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_research_signal_snapshot(handle) if _configured  else {}


func has_completed_technology(handle: int, dense_id: int) -> bool:
	return _configured \
		and _world_ext.has_completed_country_technology(handle, dense_id)

func _technology_index(technology_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("technology_ids", PackedStringArray())
	return ids.find(String(technology_id))

func cell_summary(cell: int) -> Dictionary:
	return _world_ext.get_country_cell_summary(cell) if _configured else {}

func snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_snapshot(handle) if _configured else {}

func political_regime_snapshot(handle: int) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "country facade is not configured"}
	if _world_ext.has_method("get_country_political_regime_snapshot"):
		return _world_ext.get_country_political_regime_snapshot(handle)
	var compact := ui_snapshot(handle, 8)
	return compact.get("politics", {"ok": false,
		"reason": "political_regime_snapshot_unavailable"})

func political_regime_catalog_view() -> Dictionary:
	return _political_regime_catalog.catalog_view() \
		if _political_regime_catalog != null and \
		_political_regime_catalog.has_method("catalog_view") else {
			"ok": false, "reason": "political_regime_catalog_unavailable"}

func has_political_capability(handle: int, capability: StringName) -> bool:
	var snapshot := political_regime_snapshot(handle)
	if not bool(snapshot.get("ok", false)):
		return false
	var bits := int(snapshot.get("capability_bits", 0))
	var raw_regime_key = snapshot.get("regime_key",
		snapshot.get("regime_stable_id", ""))
	var regime_key := String(raw_regime_key)
	if regime_key.is_empty() or raw_regime_key is int:
		var dense := int(snapshot.get("regime_id", -1))
		if dense >= 0 and _political_regime_catalog != null:
			var definitions: Array = _political_regime_catalog.get("definitions")
			if dense < definitions.size():
				# `Resource.get` takes a property name only; the two-argument form
				# is Dictionary's. The dense row IS a PoliticalRegimeDefinition.
				regime_key = String((definitions[dense] as Resource).get("id"))
	var definition: Resource = _political_regime_catalog.definition_for(
		StringName(regime_key)) \
		if _political_regime_catalog != null and \
		_political_regime_catalog.has_method("definition_for") else null
	if definition != null:
		for raw_key in definition.capability_keys:
			if String(raw_key) == String(capability):
				return true
	return capability == &"treasury_construction" and (bits & 1) != 0

func set_political_regime(handle: int, regime_id: StringName,
		effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.SET_POLITICAL_REGIME,
		"target_handle": handle, "stable_id": String(regime_id),
		"effective_day": effective_day, "sequence": sequence}])

func treasury_snapshot(handle: int) -> Dictionary:
	return _world_ext.get_country_treasury_snapshot(handle) if _configured else {}


func bind_era_reward_player_country(handle: int) -> Dictionary:
	return _world_ext.bind_era_reward_player_country(handle) if _configured  else {
			"ok": false, "reason": "era_reward_runtime_unavailable"}


func era_reward_offer() -> Dictionary:
	return _world_ext.get_era_reward_offer() if _configured  else {
			"ok": false, "reason": "era_reward_runtime_unavailable"}


func choose_era_reward(offer_generation: int, choice_index: int,
		effective_day: int, sequence: int = 0) -> Dictionary:
	return _world_ext.choose_era_reward(offer_generation, choice_index,
		effective_day, sequence) if _configured else {
				"ok": false, "reason": "era_reward_runtime_unavailable"}

func report() -> Dictionary:
	return _world_ext.get_country_report() if _configured else {"configured": false}


func peer_protocol_status() -> Dictionary:
	return _world_ext.get_country_peer_protocol_status() if _world_ext != null else {}


func should_run(day_index: int) -> bool:
	return bool(_world_ext.country_should_run(day_index)) if _world_ext != null else false


func capture_worker_pod_catalog() -> Dictionary:
	return _world_ext.capture_country_pod_catalog() if _world_ext != null else {
		"ok": false, "code": "runtime_worker_api_missing"}


func capture_worker_runtime_snapshot() -> Dictionary:
	return _world_ext.capture_country_runtime_snapshot() if _world_ext != null else {
		"ok": false, "code": "runtime_worker_api_missing"}


func worker_read_view(after_generation: int = 0) -> Dictionary:
	return _world_ext.get_country_worker_read_view(maxi(after_generation, 0)) \
		if _world_ext != null else {"ok": false, "code": "country_worker_read_view_api_missing"}


func service_worker_peer_adapter(max_intents: int = 64,
		shadow_replay: bool = true) -> Dictionary:
	return _world_ext.service_country_worker_peer_adapter(
		clampi(max_intents, 1, 4096), shadow_replay) if _world_ext != null else {
		"ok": false, "code": "country_worker_adapter_api_missing"}


func economy_asset_protocol_status() -> Dictionary:
	return _world_ext.get_country_economy_asset_protocol_status() if _world_ext != null else {
		"ok": false, "code": "country_economy_asset_protocol_api_missing"}


func poll_economy_asset_request() -> Dictionary:
	return _world_ext.poll_country_economy_asset_request() if _world_ext != null else {
		"ok": false, "code": "country_economy_asset_protocol_api_missing"}


func submit_economy_asset_result(result: Dictionary) -> Dictionary:
	return _world_ext.submit_country_economy_asset_result(result) if _world_ext != null else {
		"ok": false, "code": "country_economy_asset_protocol_api_missing"}


func capture_annual_state() -> PackedByteArray:
	return _world_ext.capture_annual_report_state() if _world_ext != null else PackedByteArray()


func annual_status() -> Dictionary:
	return _world_ext.get_annual_report_status() if _world_ext != null else {"ok": false}


func restore_annual_state(bytes: PackedByteArray) -> Dictionary:
	return _world_ext.restore_annual_report_state(bytes) if _world_ext != null else {
		"ok": false, "reason": "annual_provider_missing"}


func begin_forensics_save(chunk_bytes: int) -> Dictionary:
	return _world_ext.begin_country_forensics_save(chunk_bytes) if _world_ext != null else {
		"ok": false, "reason": "country_provider_missing"}


func read_forensics_save_chunk(chunk_bytes: int) -> PackedByteArray:
	return _world_ext.read_country_save_chunk(chunk_bytes) if _world_ext != null else PackedByteArray()


func end_forensics_save() -> Dictionary:
	return _world_ext.end_country_save() if _world_ext != null else {
		"ok": false, "reason": "country_provider_missing"}


func ui_snapshot(handle: int, section_mask: int) -> Dictionary:
	return _world_ext.get_country_ui_snapshot(handle, section_mask) if _configured  else {
			"ok": false, "reason": "country_ui_snapshot_unavailable"}

func dispatch_committed_events(result: Dictionary) -> void:
	CommitSignals.dispatch_committed_events(self, result, Opcode)


func dispatch_worker_committed_view(view: Dictionary) -> void:
	CommitSignals.dispatch_worker_committed_view(self, view)


func is_configured() -> bool:
	return _configured

func world_ext() -> Object:
	return _world_ext

func native_catalog() -> Dictionary:
	return _catalog.duplicate(false)

func begin_save(chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	return _world_ext.begin_country_save(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func read_save_chunk(chunk_bytes: int = -1) -> PackedByteArray:
	if not _configured:
		return PackedByteArray()
	return _world_ext.read_country_save_chunk(
		int(_profile.save_chunk_bytes) if chunk_bytes < 0 else chunk_bytes)

func end_save() -> Dictionary:
	return _world_ext.end_country_save() if _configured else {"ok": false, "reason": "not configured"}

func restore_bytes(bytes: PackedByteArray, chunk_bytes: int = 4194304) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var begun: Dictionary = _world_ext.begin_country_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	while cursor < bytes.size():
		var fed: Dictionary = _world_ext.feed_country_restore_chunk(
			bytes.slice(cursor, mini(cursor + chunk_bytes, bytes.size())))
		if not bool(fed.get("ok", false)):
			return fed
		cursor += chunk_bytes
	return _world_ext.end_country_restore()
