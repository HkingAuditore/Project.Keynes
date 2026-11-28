extends Node2D

@export_group("Detail Refresh")
# 新家族渲染器必须先通过图形 A/B；默认保持旧渲染器，避免未验收路径直接影响玩家。
@export var detail_scatter_family_renderer_enabled: bool = false
# 路线 A：树冠层静态化与去闪烁（开局生成后退出每日演替位置重算，脱离全局动态配额抽稀，
# 仅响应城市建筑占位变更；季节/枯荣/积雪/昼夜仍由 dyn_lut/eco_lut 在 GPU 实时驱动）。
@export var detail_scatter_static_canopy_enabled: bool = true
# 大面积森林冠层原型开关（与 detail_scatter_family_renderer_enabled 互斥，默认关闭）。
@export var forest_canopy_prototype_enabled: bool = false
@export_enum("coarse_merged", "chunk_quad") var forest_canopy_geometry_mode: int = 0
@export var detail_scatter_refresh_layers_per_frame: int = 1
@export var detail_scatter_refresh_cells_per_batch: int = 32
@export var detail_scatter_chunked_multimesh_enabled: bool = true
@export_range(2, 32, 1) var detail_scatter_chunk_size_cells: int = 16
@export var detail_scatter_refresh_chunks_per_frame: int = 4
@export_range(1, 128, 1) var detail_scatter_refresh_plan_items_per_frame: int = 16
@export_range(0.25, 10.0, 0.25) var detail_scatter_resident_retention_seconds: float = 2.0
# drain 信用预算：实测 4.0 时高倍速下 backlog 永不排空、帧均 drain 顶满预算
# （tail_vegetation 持续 4-5ms）。配合全链路在途去重后重排队速率大幅下降，
# 2.5ms 足以收敛 backlog，稳态帧成本直接减半。
@export_range(0.0, 20.0, 0.25) var detail_scatter_refresh_apply_budget_ms: float = 2.5
# 入队节流：succession 单元先并入去重累积器，按真实时间窗成批入队。高倍速下
# 跨多天翻转的单元只重建一次，批次数不再随天数线性增长；低速下窗口 < 一日，
# 延迟不可感知。0 表示逐次直通（旧行为）。
@export_range(0.0, 1000.0, 10.0) var detail_scatter_enqueue_coalesce_ms: float = 120.0
# 累积器硬上限：超过即提前冲刷，防止无限堆积。
@export_range(64, 8192, 64) var detail_scatter_enqueue_max_pending_cells: int = 1024
# 积压兜底：待处理批次数超过该阈值时，存量批次与新单元整体去重合并后重新切批，
# 避免同一 chunk 在多个批次里被反复重建的复利积压。
@export_range(2, 64, 1) var detail_scatter_merge_batch_threshold: int = 8
@export var detail_scatter_refresh_log_enabled: bool = false
@export var detail_scatter_rebuild_log_enabled: bool = false
@export_range(0.0, 100.0, 0.25) var detail_scatter_slow_layer_ms: float = 2.0
# 21 层清单接入与散布配额化后总实例数显著上升，旧预算会让全局配额长期
# 触顶、所有层被同比稀释，反过来又抹平生物群系差异。
@export var detail_scatter_desktop_total_instance_budget: int = 120000
@export var detail_scatter_mobile_total_instance_budget: int = 12000

@export_group("Vegetation Lighting")
## 树下接地 AO 暗晕强度（实时调节，支持单株与树簇）。
@export_range(0.0, 1.0, 0.01) var vegetation_ground_ao_strength: float = 0.55:
	set(v):
		vegetation_ground_ao_strength = clampf(v, 0.0, 1.0)
		_push_vegetation_ao_tuning()
## 树下接地 AO 扩散半径。
@export_range(0.8, 2.2, 0.02) var vegetation_ground_ao_radius: float = 1.35:
	set(v):
		vegetation_ground_ao_radius = clampf(v, 0.8, 2.2)
		_push_vegetation_ao_tuning()
## 树下太阳定向软影强度。
@export_range(0.0, 1.2, 0.01) var vegetation_floor_shadow_strength: float = 0.72:
	set(v):
		vegetation_floor_shadow_strength = clampf(v, 0.0, 1.2)
		_push_vegetation_ao_tuning()
## 冠层内部 AO 强度（冠间暗谷深度）。
@export_range(0.0, 1.0, 0.01) var vegetation_contact_ao_strength: float = 0.48:
	set(v):
		vegetation_contact_ao_strength = clampf(v, 0.0, 1.0)
		_push_vegetation_ao_tuning()

func _push_vegetation_ao_tuning() -> void:
	if not is_inside_tree():
		return
	for layer in get("_detail_layers") if "_detail_layers" in self else []:
		if layer != null and is_instance_valid(layer) and layer.has_method("set_vegetation_ao_tuning"):
			layer.set_vegetation_ao_tuning(
				vegetation_ground_ao_strength,
				vegetation_ground_ao_radius,
				vegetation_floor_shadow_strength,
				vegetation_contact_ao_strength
			)
