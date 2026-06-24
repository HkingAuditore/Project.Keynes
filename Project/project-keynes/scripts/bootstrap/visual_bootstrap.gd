extends RefCounted
class_name DCVisualBootstrap

## Phase D.3：视觉 / TOD / water shader uniform 推送拆分目的地。
##
## ─── 待迁移代码段 ────────────────────────────────────────────────
##   - main.gd 中 @export 视觉开关（visual_quality / day_night_enabled /
##     water_*_enabled 等约 20 个）的 push 逻辑
##   - `_push_visual_toggles` — 一次性把 main 的 @export 推给 HexRenderer
##   - TOD 相关：_tod_profile init + day_phase_changed signal + recompute
##   - Water Calm Noise / River Flow / Caustics 等 shader uniform 同步
##   - perf_sampler_enabled 钩子
##
## 拆完后本文件 ~200 行；main.gd 仅保留"@export 字段定义 + 调用
## VisualBootstrap.push(self, renderer)"。

var _main_ref: WeakRef = null

func _init(main_node) -> void:
	if main_node != null:
		_main_ref = weakref(main_node)

func push_visual_toggles() -> void:
	var main_node = _main_ref.get_ref() if _main_ref != null else null
	if main_node == null:
		return
	main_node._push_visual_toggles_legacy()

