extends RefCounted
class_name GameplayEventBus

signal event_batch_polled(batch: Dictionary)

const EVENT_VEGETATION_SUCCESSION: int = 1
const EVENT_TERRAIN_FLIP: int = 2
const EVENT_WEATHER_FRONT_CHANGED: int = 3
const EVENT_VISUAL_DIRTY_INTENT: int = 4
const EVENT_ECONOMY_EPOCH_COMMITTED: int = 5
const EVENT_ECONOMY_CONSTRUCTION_COMPLETED: int = 6
const EVENT_ECONOMY_TRADE_ARRIVED: int = 7
const EVENT_ECONOMY_SOCIAL_PRESSURE: int = 8
const EVENT_RESEARCH_SIGNAL_DISCOVERED: int = 9
const EVENT_MAP_FEATURE_DISCOVERED: int = 10
const EVENT_WEATHER_OBSERVED: int = 11
const EVENT_RESEARCH_EVIDENCE_CHANGED: int = 12
const EVENT_TECHNOLOGY_ADOPTED: int = 13
const EVENT_TECHNOLOGY_PRACTICE: int = 14
const EVENT_TARIFF_SUBSIDY_INTENT: int = 15

const SOURCE_NATIVE: int = 1
const SOURCE_GDSCRIPT: int = 2
const SOURCE_DEBUG: int = 3

const PAYLOAD_NONE: int = 0
const PAYLOAD_SUCCESSION_V1: int = 1
const PAYLOAD_ECONOMY_EPOCH_V1: int = 2
const PAYLOAD_ECONOMY_CONSTRUCTION_V1: int = 3
const PAYLOAD_ECONOMY_TRADE_V1: int = 4
## i0=新社会压力等级 (0 最紧张 .. 4 最满足)、i1=最差维度、i2=最差需求、
## i3=上一等级；value=人口加权 composite Q16、entity_id=人口、flags=1 表示等级下降。
const PAYLOAD_SOCIAL_PRESSURE_V1: int = 5
const PAYLOAD_RESEARCH_SIGNAL_V1: int = 6
## i0=实践规则，i1=同时运行的合格生产组数，i2=第一实践地块，i3=配方版本；
## value=规则对应的组日、产量或周期数，entity_handle=国家句柄。
const PAYLOAD_TECHNOLOGY_PRACTICE_V1: int = 7
## cell=目的地，entity_id=订单，value=数量；i0=来源地块，i1/i2=出口/进口国 slot，i3=商品。
const PAYLOAD_ECONOMY_TRADE_V2: int = 8
## i0=天气规则，i1=合格领土地块数，i2=第一证据地块，i3=观测协议版本；
## value=最大强度 Q16，entity_handle=国家句柄。
const PAYLOAD_WEATHER_OBSERVED_V1: int = 9

var _world_ext = null
var _schema: Dictionary = {}
var _last_report: Dictionary = {}


func bind_world_ext(ext) -> void:
	_world_ext = ext
	_schema = {}
	if is_available() and _world_ext.has_method("get_gameplay_event_schema"):
		var res = _world_ext.get_gameplay_event_schema()
		if res is Dictionary:
			_schema = res


func is_available() -> bool:
	return _world_ext != null \
		and _world_ext.has_method("publish_gameplay_events") \
		and _world_ext.has_method("poll_gameplay_events") \
		and _world_ext.has_method("ack_gameplay_events")


func schema() -> Dictionary:
	return _schema.duplicate(true)


func publish_event(
		event_type: int,
		cell_idx: int = -1,
		tick: int = 0,
		phase: int = 0,
		source: int = SOURCE_GDSCRIPT,
		flags: int = 0,
		payload_schema: int = PAYLOAD_NONE,
		payload_i0: int = 0,
		payload_i1: int = 0,
		payload_i2: int = 0,
		payload_i3: int = 0,
		entity_handle: int = 0,
		value_i64: int = 1) -> Dictionary:
	var batch := {
		"count": 1,
		"tick_scalar": tick,
		"phase_scalar": phase,
		"type_scalar": event_type,
		"source_scalar": source,
		"flags_scalar": flags,
		"payload_schema_scalar": payload_schema,
		"cell_idx": PackedInt32Array([cell_idx]),
		"entity_id": PackedInt32Array([cell_idx]),
		"entity_handle": PackedInt64Array([entity_handle if entity_handle != 0 else cell_idx]),
		"value_i64": PackedInt64Array([value_i64]),
		"payload_i0": PackedInt32Array([payload_i0]),
		"payload_i1": PackedInt32Array([payload_i1]),
		"payload_i2": PackedInt32Array([payload_i2]),
		"payload_i3": PackedInt32Array([payload_i3]),
	}
	return publish_events_batch(batch)


func publish_events_batch(batch: Dictionary) -> Dictionary:
	if not is_available():
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable", "published": 0}
	var res = _world_ext.publish_gameplay_events(batch)
	return res if res is Dictionary else {"fallback": true, "reason": "bad_native_publish_result", "published": 0}


func poll_events(
		consumer_id: StringName,
		max_events: int = 256,
		event_type: int = 0,
		auto_ack: bool = false,
		after_event_id: int = -1) -> Dictionary:
	if not is_available():
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable", "count": 0}
	var opts := {
		"consumer_id": consumer_id,
		"max_events": max_events,
		"type": event_type,
		"auto_ack": auto_ack,
	}
	if after_event_id >= 0:
		opts["after_event_id"] = after_event_id
	var res = _world_ext.poll_gameplay_events(opts)
	var batch: Dictionary = res if res is Dictionary else {"fallback": true, "reason": "bad_native_poll_result", "count": 0}
	_last_report = report()
	if int(batch.get("count", 0)) > 0:
		event_batch_polled.emit(batch)
	return batch


func ack_events(consumer_id: StringName, up_to_event_id: int) -> Dictionary:
	if not is_available():
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable"}
	var res = _world_ext.ack_gameplay_events(consumer_id, up_to_event_id)
	return res if res is Dictionary else {"fallback": true, "reason": "bad_native_ack_result"}


func replay_events(start_tick: int, end_tick: int, event_type: int = 0, max_events: int = 0) -> Dictionary:
	if not is_available() or not _world_ext.has_method("replay_gameplay_events"):
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable", "count": 0}
	return _world_ext.replay_gameplay_events({
		"start_tick": start_tick,
		"end_tick": end_tick,
		"type": event_type,
		"max_events": max_events,
	})


func snapshot_journal(opts: Dictionary = {}) -> Dictionary:
	if not is_available() or not _world_ext.has_method("snapshot_gameplay_event_journal"):
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable"}
	return _world_ext.snapshot_gameplay_event_journal(opts)


func restore_journal(snapshot: Dictionary) -> Dictionary:
	if not is_available() or not _world_ext.has_method("restore_gameplay_event_journal"):
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable"}
	return _world_ext.restore_gameplay_event_journal(snapshot)


func clear(opts: Dictionary = {}) -> Dictionary:
	if not is_available() or not _world_ext.has_method("clear_gameplay_events"):
		return {"fallback": true, "reason": "world_ext_event_bus_unavailable"}
	return _world_ext.clear_gameplay_events(opts)


func report() -> Dictionary:
	if not is_available() or not _world_ext.has_method("get_gameplay_event_bus_report"):
		return {"available": false}
	var res = _world_ext.get_gameplay_event_bus_report()
	if res is Dictionary:
		res["available"] = true
		return res
	return {"available": false, "reason": "bad_native_report"}


func poll_succession_cells(consumer_id: StringName = &"detail_renderer", max_events: int = 512, auto_ack: bool = true) -> PackedInt32Array:
	var batch := poll_events(consumer_id, max_events, EVENT_VEGETATION_SUCCESSION, auto_ack)
	var out := PackedInt32Array()
	if bool(batch.get("fallback", false)):
		return out
	var cells: PackedInt32Array = batch.get("cell_idx", PackedInt32Array())
	for idx in cells:
		if int(idx) >= 0:
			out.append(int(idx))
	return out
