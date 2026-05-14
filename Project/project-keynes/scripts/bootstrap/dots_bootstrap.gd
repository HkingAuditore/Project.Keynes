extends RefCounted
class_name DCDotsBootstrap

## Phase 3.4 / PR-3.4.1（M4 拆分）：main.gd → dots_bootstrap.gd 迁移目的地。
##
## 当前承载（持续扩张中）：
##   - DCFlagBus.install + hot-reload listener（PR-4.4）
##
## ─── 后续待迁移代码段（master plan §5.5 PR-3.4 全部清单）──────────────
##
## 字段（从 main.gd var declaration 段搬）：
##   - `_view_adapter: DCViewAdapter`
##   - `_dc_world` 相关引用 (_dcc_cp / _dc_cp 等 cache)
##   - `_dc_ecs_*` archetype 状态字段
##
## 函数：
##   - `_rebuild_view_adapter()`
##   - DataCore CLI 解析（`_parse_data_core_cli` / `_apply_data_core_cli_to_profile`）
##   - DataCore runtime hot-toggle（`_toggle_data_core_weather_runtime` /
##     `_toggle_data_core_master_runtime`）
##   - DataCore flag snapshot（`_print_data_core_flag_snapshot`）
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 残留 main.gd 仅保留生命周期 + 输入处理 + DC bootstrap 委派；
## 2. 本类持 main 节点弱引用（用于读 generator / map / cp 等）；
## 3. 启动期由 main._ready 调 DCDotsBootstrap.new(self).bootstrap_flag_bus()；
## 4. 信号回调由本类持有（main 不再持有 _on_dcflag_changed）。

var _main_ref: WeakRef = null

func _init(main_node) -> void:
	if main_node != null:
		_main_ref = weakref(main_node)

## 安装 DCFlagBus singleton 并 connect hot-reload listener。
## 返回 DCFlagBus 实例（main 不再持有引用，但需要在场景树里 keep alive）。
func bootstrap_flag_bus():
	var main_node = _main_ref.get_ref() if _main_ref != null else null
	if main_node == null:
		push_warning("[DCDotsBootstrap] bootstrap_flag_bus: main node lost (weakref expired)")
		return null
	var flag_bus = DCFlagBus.install(main_node)
	if flag_bus != null:
		flag_bus.flag_changed.connect(_on_dcflag_changed)
	return flag_bus

## DCFlagBus hot-reload 回调。
## 当 ClimateProfile flag 通过 DCFlagBus.singleton.set_flag(cp, name, value) 改变时
## 自动 unbind/rebind DCWorld + 重建 view adapter，避免重启游戏。
##
## main 上的 _on_dcflag_changed shim 直接 forward 到本函数（兼容现有 connect）。
func _on_dcflag_changed(name: StringName, _new_value, _profile) -> void:
	var main_node = _main_ref.get_ref() if _main_ref != null else null
	if main_node == null:
		return
	var name_str: String = String(name)
	# 1. BIND_CRITICAL：unbind/rebind 重新挂入 SoA
	if DCFlagBus.is_bind_critical(name):
		var generator = main_node._generator if "_generator" in main_node else null
		var current_map = main_node._current_map if "_current_map" in main_node else null
		var dc_world = null
		if generator != null and generator.has_method("get_data_core_world"):
			dc_world = generator.get_data_core_world()
		if dc_world != null and dc_world.has_method("rebind_map_data") and current_map != null:
			# rebind 时 demo_thermal_gradient_enabled 可能已变 → 重新读 cp 决定
			var demo_on: bool = false
			if generator != null:
				var cp = generator._c()
				if cp != null and "demo_thermal_gradient_enabled" in cp:
					demo_on = bool(cp.demo_thermal_gradient_enabled)
			dc_world.rebind_map_data(current_map, demo_on)
			print("[main] DCFlagBus hot-reload: %s changed → DCWorld rebind_map_data done" % name_str)
		# view adapter 也跟着重建（use_world_view_adapter 可能切换路径）
		if main_node.has_method("_rebuild_view_adapter"):
			main_node._rebuild_view_adapter()
	# 2. 非 critical flag：仅打印（subscriber 自行 connect 处理）
	elif OS.is_debug_build():
		print("[main] DCFlagBus hot-reload: %s changed (non-critical, no auto rebind)" % name_str)
