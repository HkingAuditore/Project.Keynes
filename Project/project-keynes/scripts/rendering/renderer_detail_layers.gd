extends RefCounted

## Stateless collaborator for ShrubLayer.

# ─── web / 移动端植被降档（性能换密度） ─────────────────────────────────
# 受限平台（浏览器 WebGL2 / 移动 GPU）即使把散布构建改成“进世界分帧补齐”，运行期
# 仍要维护全部散布层：每层的 chunk 节点 draw call、MultiMesh 上传、以及 succession
# 触发 chunk 重建，成本都按层数线性增长，web 上这是帧时间的主项，所以只保留约一半图层。
# 调参入口只有这一个常量：0.5 = 约一半，0.34 = 三分之一，1.0 = 不砍。
# 受限平台的共享降档常量由这里统一持有，HexRenderer 仅保留兼容别名。
const WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO: float = 0.5

# 加载期让帧节流（取代旧的"每层一帧"）：每 4 层或累计 12ms 让一帧，保证进度条
# 动画与 web 的主线程心跳。defer 之后单层只剩几毫秒的初始化，这个预算够用。
const DETAIL_LOADING_LAYERS_PER_YIELD: int = 4
const DETAIL_LOADING_YIELD_BUDGET_MS: float = 12.0

# 兜底救援窗口：defer 之后若运行期补齐在这么久之内一株都没建出来（而且刷新管线
# 已经空闲，说明不是"还在排队"），就退回老的"一次性全量构建"。宁可卡一下，
# 也不能让地图永远光秃秃。
const DEFERRED_DETAIL_FILL_RESCUE_SECONDS: float = 8.0

static func _after_visual_profile(host) -> void:

	host._rebuild_detail_layers_if_default()


static func _after_decoration_manifest(host) -> void:

	if host.is_inside_tree():
		host._spawn_detail_layers()
		if host._map != null and host._world != null:
			host._rebuild()


static func set_force_platform_limited_render(host, value: int) -> void:

	host._force_platform_limited_render = clampi(value, -1, 1)


# web 与 mobile 共用同一套"受限平台"降档（层数减半 + 每层密度降到 mobile 档）。

static func _platform_limited_vegetation_render(host) -> bool:

	if host._force_platform_limited_render >= 0:
		return host._force_platform_limited_render != 0
	return OS.has_feature("web") or OS.has_feature("mobile")



static func _web_mobile_layer_keep_ratio(host) -> float:

	if host._web_mobile_layer_keep_ratio_override >= 0.0:
		return clampf(host._web_mobile_layer_keep_ratio_override, 0.0, 1.0)
	return clampf(host.WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO, 0.0, 1.0)


# 默认散布层 profile 列表：优先 decoration_manifest.layers；留空时回退 grass/shrub/tree。
# web / mobile 在这里按 WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO 裁到约一半（桌面原样返回）。

static func _detail_profiles(host) -> Array:

	var manifest = host.decoration_manifest
	var base: Array = []
	if manifest != null and manifest.has_method("valid_layers"):
		base = manifest.valid_layers()
	if base.is_empty():
		if host.grass_visual_profile != null:
			base.append(host.grass_visual_profile)
		if host.shrub_visual_profile != null:
			base.append(host.shrub_visual_profile)
		if host.tree_visual_profile != null:
			base.append(host.tree_visual_profile)
	if _platform_limited_vegetation_render(host, ):
		return _select_platform_limited_detail_profiles(host, base)
	return base


# 按"保留价值"裁层，但保持原始绘制顺序（层序是 shader / 家族 mask 的稳定契约）。

static func _select_platform_limited_detail_profiles(host, layers: Array) -> Array:

	return host.DetailProfileSelection._select_platform_limited_detail_profiles(_web_mobile_layer_keep_ratio(host, ), layers)


# 一层的"保留价值"分档（越大越先保留）。判据不是实例数，而是
# "这一层是不是某个可见角色的唯一代表"：
#   阔叶树 / 灌木 / 草地是全球底色，分别代表森林冠层、灌丛、地表覆盖；
#   针叶（寒带、亚高山）与棕榈（热带海岸）是形状完全不同、biome 唯一的冠层，
#   砍掉会让针叶林/棕榈林被"阔叶树"顶替（形状对不上），所以紧跟三个底色层；
#   仙人掌（荒漠）、芦苇（湿地河岸）是所在群系唯一的植被代表，砍掉整片变裸地；
#   岩石 / 碎石是山地与荒原上唯一的硬质地物；
#   高山花、苔原苔藓、沼泽草、红树根、枯木只是叠在底色之上的点缀，砍掉只少一层细节；
#   带专属底色的乔木（云雾林 / 季风林）与通用阔叶层同形同 biome，只是多一层配色，
#   优先级最低——通用阔叶层已经在同一片林子里出树了。
# 同分时按 manifest 顺序（越靠前越容易保留）。


# 是否当前用的是默认三层（未配置 manifest）。

static func _using_default_layers(host) -> bool:

	var manifest = host.decoration_manifest
	return not (manifest != null and manifest.has_method("valid_layers") and not manifest.valid_layers().is_empty())


# 销毁旧散布层并按当前 profile 列表重建。

static func _spawn_detail_layers(host) -> void:

	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.queue_free()
	host._detail_family_layer = null
	host._detail_family_dirty_chunks.clear()
	for layer in host._detail_layers:
		if is_instance_valid(layer):
			layer.queue_free()
	host._detail_layers.clear()
	# 层销毁意味着旧世界的 succession 队列全部失效：任务里的 layer 引用虽有
	# is_instance_valid 兜底，但 cell 语义已跨世界失效，必须整体重置（含全链路
	# 在途集合，否则旧世界 cell 会永久屏蔽新世界的重排队）。
	host._detail_refresh_queue.clear()
	host._detail_refresh_batches.clear()
	host._detail_refresh_indices = PackedInt32Array()
	host._reset_detail_refresh_plan()
	host._scatter_pending_cells = PackedInt32Array()
	host._scatter_pending_seen.clear()
	host._scatter_requeue_cells.clear()
	host._scatter_inflight.clear()
	host._scatter_cell_family_masks.clear()
	host._scatter_cell_profile_masks.clear()
	host._scatter_cell_generations.clear()
	host._detail_deferred_chunks.clear()
	host._detail_deferred_profile_masks.clear()
	host._detail_offscreen_deferred_cells = 0
	host._detail_coalesced_cells = 0
	host._detail_stale_generation_drops = 0
	host._detail_evicted_superchunks = 0
	host._detail_next_resident_sweep_msec = 0
	host._drain_credit_ms = 0.0
	host._detail_budget_target_fraction = 1.0
	host._detail_budget_applied_fraction = -1.0
	host._detail_budget_apply_fraction = 1.0
	host._detail_budget_apply_cursor = 0
	host._detail_budget_apply_active = false
	host._detail_budget_apply_count = 0
	host._detail_budget_apply_skip_count = 0
	host._detail_budget_apply_ms_total = 0.0
	host._detail_budget_last_apply_ms = 0.0
	host._detail_budget_cached_total = 0
	host._detail_budget_total_dirty = true
	host._detail_budget_total_scan_count = 0
	host._detail_budget_last_scan_ms = 0.0
	var profiles = _detail_profiles(host, )
	var veg_tier = host._mobile_quality_tier_from_define(host._mobile_quality_tier_define)
	for i in range(profiles.size()):
		var prof: Resource = profiles[i]
		var layer = ShrubLayer.new()
		layer.name = _detail_layer_name(host, prof, i)
		layer.profile = prof
		layer.set_mobile_quality_tier(veg_tier)
		if layer.has_method("set_defer_initial_rebuild"):
			layer.set_defer_initial_rebuild(host.detail_scatter_family_renderer_enabled)
		if layer.has_method("set_chunked_multimesh_enabled"):
			layer.set_chunked_multimesh_enabled(host.detail_scatter_chunked_multimesh_enabled, host.detail_scatter_chunk_size_cells)
		layer.set_world_ext(host._world_ext)
		host.add_child(layer)
		# [cylindrical-earth-daylight] 新层补推昼夜光照所需状态（与地形同源）：
		# 相位/季节驱动晨昏线，axial_tilt 决定季节赤纬，day_night_enabled 为总开关。
		layer.set_season_phase(host._season_phase)
		layer.set_day_phase(host._day_phase)
		layer.set_axial_tilt_rad(deg_to_rad(host.axial_tilt_deg))
		layer.set_eternal_daylight_parameters(deg_to_rad(host.eternal_min_elevation_deg), deg_to_rad(host.eternal_max_hour_angle_deg))
		layer.set_day_night_enabled(host.day_night_enabled)
		if layer.has_method("set_tod_debug_sun_position"):
			layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
		if layer.has_method("set_tod_debug_sun_height_scale"):
			layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
		if host._tod_valid:
			layer.set_tod(host._tod_sun_color, host._tod_ambient_color, host._tod_night_factor, host._tod_exposure)
			if layer.has_method("set_tod_sun_dir"):
				layer.set_tod_sun_dir(host._tod_sun_dir)
		layer.set_camera_zoom(host._camera_zoom)
		if host._camera_view_initialized and layer.has_method("set_camera_view"):
			layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)
		layer.set_lod_debug_view(host.terrain_surface_debug_view == 6)
		host._detail_layers.append(layer)
	host._detail_family_layer = host.VegetationFamilyLayerScript.new()
	host._detail_family_layer.name = "VegetationFamilyLayer"
	host.add_child(host._detail_family_layer)
	if host._cloud_shadow_field != null:
		host._push_cloud_shadow_material_inputs()



static func _detail_layer_name(host, prof: Resource, i: int) -> String:

	if prof != null and "detail_kind" in prof:
		match int(prof.detail_kind):
			0:
				return "ShrubLayer" if i == 0 else "ShrubLayer%d" % i
			1:
				return "TreeLayer" if i == 0 else "TreeLayer%d" % i
			2:
				return "GrassLayer" if i == 0 else "GrassLayer%d" % i
	return "DetailLayer%d" % i


# 仅在使用默认三层（无 manifest）时，profile @export 改动后刷新对应层 profile。

static func _rebuild_detail_layers_if_default(host) -> void:

	if not host.is_inside_tree() or not _using_default_layers(host, ):
		return
	_spawn_detail_layers(host, )
	if host._map != null and host._world != null:
		host._rebuild()


# 注入 C++ DCWorldExt（main.gd 在 set_map 前调用），转发给每个散布层。

