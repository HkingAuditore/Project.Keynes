# dc_system_test.gd
# Phase C.1 — DCSystem 基类自检。
#
# 验证：
#   1. dummy DCSystem 可被构造、bind_world、setup 自动 cache _cid
#   2. 与 SusJob 兼容：可用 SlicedUpdateScheduler.register_job 注册并 tick
#   3. declare_reads / declare_writes 中的 component 没注册时 ready=false
#
# Headless execution:
#     godot --headless --script tests/dc_system_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== DCSystem base class test ===")
	# 1. 构造 World + 注册 component
	var world: DCWorld = DCWorld.new()
	var cid_temp: int = world.register_component(DCComponentIds.CELL_TEMP, DCComponentIds.F32, 1, false)
	var cid_moist: int = world.register_component(DCComponentIds.CELL_MOISTURE, DCComponentIds.F32, 1, false)
	world.create_entities(8)
	_expect("CELL_TEMP registered", cid_temp >= 0)
	_expect("CELL_MOISTURE registered", cid_moist >= 0)

	# 2. 构造 dummy DCSystem
	var sys := DummyDCSystem.new()
	sys.id = &"dummy_test"
	sys.bind_world(world)
	_expect("dummy.setup cached cid for cell.temp", int(sys._cid.get(DCComponentIds.CELL_TEMP, -1)) == cid_temp)
	_expect("dummy.setup cached cid for cell.moisture", int(sys._cid.get(DCComponentIds.CELL_MOISTURE, -1)) == cid_moist)
	# data_core_ready 需要 world.is_bound() == true，但本测试没 bind_map_data
	# 所以应该是 false（兜底分支）。
	_expect("data_core_ready=false (no bind_map_data)", not sys.data_core_ready())

	# 3. tick 自检：return done=true
	# 构造一个 SusTickContext（DCSystem.run_slice / should_run 类型对齐 SusJob，
	# 要求传 SusTickContext；本基类 tick(ctx) 自身参数无类型，但传 SusTickContext
	# 是统一推荐做法）。
	var ctx: SusTickContext = SusTickContext.make(1, 1, 0.5, 1.0, &"frame")
	var r: Dictionary = sys.tick(ctx)
	_expect("tick return done=true", bool(r.get("done", false)))
	_expect("tick incremented call counter", sys._tick_count == 1)

	# 4. SusJob 兼容：通过 run_slice 调用 forward 到 tick
	var r2: Dictionary = sys.run_slice(ctx)
	_expect("run_slice forwards to tick", sys._tick_count == 2)

	# 5. should_run 默认（policy == null）返回 true
	_expect("should_run default=true", sys.should_run(ctx))

	# 6. describe()
	var d: String = sys.describe()
	_expect("describe contains id", "dummy_test" in d)
	_expect("describe contains reads count", "reads=2" in d)

	# 7. declare_writes 中的 component 没注册时 ready=false
	var sys_bad := DummyDCSystemBad.new()
	sys_bad.id = &"dummy_bad"
	sys_bad.bind_world(world)
	_expect("ready=false when declared writes missing component",
		not sys_bad._components_ready)

	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


# ─── helpers ───────────────────────────────────────────────────────

func _expect(label: String, cond: bool) -> void:
	_checks += 1
	if cond:
		return
	push_error("[dc_system_test] FAIL %s" % label)
	_failures += 1


# ─── Dummy systems ─────────────────────────────────────────────────

class DummyDCSystem extends DCSystem:
	var _tick_count: int = 0

	func declare_reads() -> Array[StringName]:
		return [DCComponentIds.CELL_TEMP, DCComponentIds.CELL_MOISTURE]

	func declare_writes() -> Array[StringName]:
		return [DCComponentIds.CELL_TEMP]  # 重叠 reads 应只 cache 一次

	func tick(_ctx) -> Dictionary:
		_tick_count += 1
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}


class DummyDCSystemBad extends DCSystem:
	# 故意声明一个不存在的 component，验证 ready 应为 false
	func declare_writes() -> Array[StringName]:
		return [&"cell.bogus_field_does_not_exist"]
