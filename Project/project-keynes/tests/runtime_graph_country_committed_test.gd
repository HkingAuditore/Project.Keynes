extends SceneTree
# Runtime-graph 路径必须把 Country commit 转成 country_committed，
# 否则开拓 CLAIM 后国界/视野不刷新（Inspector 已显示归属）。

const MapGeneratorScript = preload("res://scripts/geography/map_generator.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

class _FakeCountryExt:
	var _events: Dictionary = {
		"event_ids": PackedInt64Array(),
		"opcodes": PackedInt32Array(),
		"country_handles": PackedInt64Array(),
		"cells": PackedInt32Array(),
		"signal_ids": PackedInt32Array(),
		"signal_source_kinds": PackedInt32Array(),
		"evidence_deltas": PackedInt32Array(),
	}

	func poll_country_events(_after_id: int, _limit: int) -> Dictionary:
		return _events.duplicate(true)


class _FakeCountryFacade:
	signal country_committed(report: Dictionary)
	signal research_signal_discovered(event: Dictionary)

	var _configured: bool = true
	var _report: Dictionary = {}
	var _last_event_id: int = 0
	var _world_ext := _FakeCountryExt.new()
	var dispatch_count: int = 0
	var emit_count: int = 0
	var last_emit: Dictionary = {}

	func is_configured() -> bool:
		return _configured

	func report() -> Dictionary:
		return _report.duplicate(true)

	func world_ext() -> Object:
		return _world_ext

	func dispatch_committed_events(result: Dictionary) -> void:
		if not _configured:
			return
		dispatch_count += 1
		if int(result.get("changed_countries", 0)) <= 0 \
				and int(result.get("changed_cells", 0)) <= 0:
			return
		emit_count += 1
		last_emit = result.duplicate(true)
		country_committed.emit(result.duplicate(true))


func _expect(label: String, ok: bool) -> void:
	if not ok:
		push_error("[runtime-graph-country] FAIL: %s" % label)
		quit(1)
		return
	print("[runtime-graph-country] ok: %s" % label)


func _init() -> void:
	var generator = MapGeneratorScript.new()
	var facade := _FakeCountryFacade.new()
	generator._country_facade = facade

	facade._report = {
		"generation": 1,
		"changed_cells": 0,
		"changed_countries": 0,
	}
	generator._dispatch_runtime_graph_country_committed()
	_expect("first pulse consumes bootstrap generation without emit",
		facade.emit_count == 0
		and facade.dispatch_count == 1
		and int(generator._runtime_graph_last_country_generation) == 1)

	generator._dispatch_runtime_graph_country_committed()
	_expect("same generation does not redispatch",
		facade.emit_count == 0 and facade.dispatch_count == 1)

	facade._report = {
		"generation": 2,
		"changed_cells": 1,
		"changed_countries": 1,
		"stage": "aggregate_publish",
	}
	generator._dispatch_runtime_graph_country_committed()
	_expect("CLAIM generation emits country_committed once",
		facade.emit_count == 1
		and facade.dispatch_count == 2
		and int(facade.last_emit.get("changed_cells", 0)) == 1
		and int(generator._runtime_graph_last_country_generation) == 2)

	generator._dispatch_runtime_graph_country_committed()
	_expect("repeat pulse after CLAIM stays quiet",
		facade.emit_count == 1 and facade.dispatch_count == 2)

	facade._report = {
		"generation": 3,
		"changed_cells": 0,
		"changed_countries": 0,
		"stage": "idle",
	}
	generator._dispatch_runtime_graph_country_committed()
	_expect("zero-count generation still reaches event normalization",
		facade.emit_count == 1
		and facade.dispatch_count == 3
		and int(generator._runtime_graph_last_country_generation) == 3)

	# Mirror CountryFacade gate: territory-only report still broadcasts.
	var real_facade = CountryFacadeScript.new()
	real_facade._configured = true
	real_facade._world_ext = _FakeCountryExt.new()
	var saw := {"n": 0, "last": {}}
	real_facade.country_committed.connect(func(report):
		saw["n"] = int(saw["n"]) + 1
		saw["last"] = report)
	real_facade.dispatch_committed_events({
		"changed_cells": 1,
		"changed_countries": 0,
	})
	_expect("facade emits when only changed_cells is set", int(saw["n"]) == 1)
	real_facade.dispatch_committed_events({
		"changed_cells": 0,
		"changed_countries": 0,
	})
	_expect("facade stays quiet when nothing changed", int(saw["n"]) == 1)

	# advance_runtime_pulse 可在 CLAIM 之后继续跑一个 country slice，使最终
	# report 回到 0/0。Facade 必须从尚未消费的 opcode=20 事件恢复
	# territory dirty，否则国界已变而 VisionSolver 永远不会重算。
	real_facade._world_ext._events = {
		"event_ids": PackedInt64Array([1]),
		"opcodes": PackedInt32Array([CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY]),
		"country_handles": PackedInt64Array([1]),
		"cells": PackedInt32Array([37]),
		"signal_ids": PackedInt32Array([-1]),
		"signal_source_kinds": PackedInt32Array([0]),
		"evidence_deltas": PackedInt32Array([0]),
	}
	real_facade.dispatch_committed_events({
		"generation": 4,
		"changed_cells": 0,
		"changed_countries": 0,
		"stage": "aggregate_publish",
	})
	_expect("stale 0/0 report recovers CLAIM from native event stream",
		int(saw["n"]) == 2
		and int(saw["last"].get("changed_cells", 0)) == 1
		and int(saw["last"].get("changed_countries", 0)) == 1)

	print("[runtime-graph-country] PASS")
	quit(0)
