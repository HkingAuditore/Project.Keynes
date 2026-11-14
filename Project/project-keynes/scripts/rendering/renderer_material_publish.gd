extends RefCounted

## Stateless collaborator for ShrubLayer.

static func _rebuild(host) -> void:

	if host._world_quad == null:
		return
	if host._map == null or host._world == null or host._map.cell_count() == 0:
		host._set_world_quad_mesh(null)
		host._configure_cloud_shadow_field()
		host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
			layer.clear()
		)
		host._mark_detail_budget_total_dirty()
		return

	host._apply_world_quad_geometry()
	if host.PK_WEB_HIDE_WORLD_QUAD and OS.has_feature("web"):
		host._world_quad.visible = false
	# 防御性：若 set_world_ext 尚未注入，尝试从已注入的 MapBaker 取 C++ ext。
	if host._world_ext == null and host._map_baker != null and "_world_ext" in host._map_baker:
		host.set_world_ext(host._map_baker._world_ext)
	var _t_veg = Time.get_ticks_usec()
	host._for_each_vegetation_layer(host._setup_loading_vegetation_layer)
	WebTelemetry.emit("rebuild_phase", {"p": "veg_layers", "dur": int(float(Time.get_ticks_usec()-_t_veg)/1000.0)})
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host._camera_view_initialized:
			host._detail_family_layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)
	if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
		host._queue_missing_prefetch_detail_chunks()
		host._reactivate_deferred_detail_chunks()
	# 世界重建属于加载边界，可一次性完成预算同步；运行期 succession 则按层切片。
	var _t_budget = Time.get_ticks_usec()
	host._apply_detail_global_budget(true)
	WebTelemetry.emit("rebuild_phase", {"p": "detail_budget", "dur": int(float(Time.get_ticks_usec()-_t_budget)/1000.0)})
	host._log_detail_scatter_rebuild_summary("renderer_rebuild")
	if host._shader_mat == null:
		return
	var _t_uniform = Time.get_ticks_usec()
	_apply_uniforms(host, )
	WebTelemetry.emit("rebuild_phase", {"p": "uniforms", "dur": int(float(Time.get_ticks_usec()-_t_uniform)/1000.0)})

# cell LUT 网格尺寸是间接寻址的比例因子：cell_lut_uv 用它把 cell.index 换算成
# texel 中心。推成退化值（Vector2i.ZERO 是 WorldData 的初值，(1,1) 是
# world_map_material.tres 的默认值）会让 lw 被钳到 1、除数被 max() 抬到 1，
# 于是整张地图的每个像素都落到 enum_lut 的同一个 texel —— 全图按某个 cell 的
# biome 着色。那个 cell 通常是海洋，画面就变成"整体偏蓝像蒙在水下，但 height_tex
# 驱动的山体阴影与植被层仍然正常"。
#
# lut_dims 过去只在 _apply_uniforms 里推一次，一旦在 bake 写入 world.lut_dims 之前
# 推了退化值就永远纠正不回来。这里记下已推的值，交给 _sync_cell_lut_dims 每帧比对。

static func _push_cell_lut_dims(host, sm: ShaderMaterial, dims: Vector2i) -> void:

	if dims.x <= 1 and dims.y <= 1 and host._world != null and host._world.enum_lut_tex != null:
		push_warning("[hex_renderer] degenerate lut_dims %s pushed while enum_lut is bound; "
			% str(dims) + "cell LUT indirection will collapse onto one texel")
	sm.set_shader_parameter("lut_dims", Vector2(dims.x, dims.y))
	host._pushed_lut_dims = dims
	# [web-water-pass] 水面 pass 用同一张 enum/dyn LUT，lut_dims 必须同步成同一份——
	# 否则它按旧网格换算 texel uv，整片海会按某个错误 cell 的 biome 上色。
	if host._water_mat != null and sm == host._shader_mat:
		host._water_mat.set_shader_parameter("lut_dims", Vector2(dims.x, dims.y))


# world.lut_dims 由 bake / daily LUT 刷新写入，与 enum/dyn/eco/bounce LUT 纹理的
# 网格严格同源。它一旦与材质上已推的值不一致，间接寻址就整体错位，所以这里补推。
# 稳态下是一次 Vector2i 比较，命中才写 uniform。

static func _sync_cell_lut_dims(host) -> void:

	if host._world == null:
		return
	var dims = host._world.lut_dims
	if dims == host._pushed_lut_dims or dims.x <= 0 or dims.y <= 0:
		return
	# 健康路径下 _apply_uniforms 已把两者对齐，这里不会命中；命中即说明材质上的
	# lut_dims 曾经落在退化值上，把它打出来便于定位是哪条路径先推的。
	print("[hex_renderer] lut_dims resync %s -> %s (cell LUT indirection was misaddressed)"
		% [str(host._pushed_lut_dims), str(dims)])
	_push_cell_lut_dims(host, host._shader_mat, dims)


# lut_dims 的姊妹问题：LUT 纹理**对象**本身漂移。日刷走 _lut_tex_from_data，尺寸
# 对得上时是 ImageTexture.update() 原地上传、对象不变，所以材质那一次绑定长期有效；
# 但只要走了 create_from_image 分支（首次创建、尺寸变更、或纹理被置空后重建），
# world 侧换成新对象而材质仍指着旧的，之后所有日刷内容都写进一张没人采样的纹理，
# 材质就永远停在旧快照上。稳态下这里是四次引用比较，不相等才写 uniform。
#
# [lut-rebind 2026-11-02 真机栈溢出排查] 这条路径**不是**稳态空转：
# bake_cell_luts() 的收尾（map_baker.gd:5582-5585）对 dyn_lut 做了双缓冲 ——
#     var dyn_front := world.dyn_lut_tex
#     world.dyn_lut_tex = _lut_tex_from_data(..., world.dyn_lut_tex_back)
#     world.dyn_lut_tex_back = dyn_front
# 而 `world.dyn_lut_tex_back` 在全工程**没有读者**（只有 world_data 的声明和这两处
# 写入）。于是 world.dyn_lut_tex 的对象**每个游戏日换一次**（A→B→A→B…），本函数
# 的"漂移才补绑"分支因此每天必命中一次并打印 "dyn_lut rebind" —— 崩溃窗口
# （进世界 10~60 s）正好是开局头 1~3 个日边界，日志最后一行就是它。
# 要彻底消掉这条每日重绑，把 map_baker 那两行改回单缓冲即可（本文件无权修改）。
## 重入闸（帧戳，不是 bool）：下面每次重绑会在一帧内改 2~4 个 ShaderMaterial 的
## 纹理参数，并顺带调 _push_fog_uniforms()（天气层 set_fog_mask）与
## _fog_layer.set_enum_lut_texture()（内部写 host.visible）。这些 setter 都是"绑一次"
## 语义；只要其中任何一条（现在或将来，或引擎侧的参数变更通知）再回到本函数，
## 就构成 set_shader_parameter → setter → set_shader_parameter 的递归 —— 真机
## VkThread 那个 3 帧循环栈溢出正是这个形状。用帧戳把本函数钉死为**每帧最多
## 一层**：同帧重入直接丢弃，下一帧的引用比较是幂等的，会自然补上。
## 用帧戳而不是 bool，是因为脚本运行期错误会中断函数、留下永久置位的 bool，
## 那会让整条 LUT 同步静默失效；帧戳下一帧自动失效。



static func _sync_cell_lut_textures(host) -> void:

	if host._world == null or host._shader_mat == null:
		return
	# [qa-skip-lut 2026-11-02] 真机 VkThread 里栈溢出（backtrace 是 3 帧循环），
	# 排查"是不是每日 LUT 纹理重绑/重传触发的"。pk_debug.cfg 里
	# `[render] skip_lut_sync=true` 可跳过这条路径做对照，正常玩家没有该文件。
	if not host._qa_skip_lut_checked:
		host._qa_skip_lut_checked = true
		var qa_cfg = ConfigFile.new()
		if qa_cfg.load("user://pk_debug.cfg") == OK:
			host._qa_skip_lut_sync = bool(qa_cfg.get_value("render", "skip_lut_sync", false))
	if host._qa_skip_lut_sync:
		return
	var frame = Engine.get_process_frames()
	if host._lut_sync_frame == frame:
		host._lut_sync_reentry_count += 1
		# 只打第一条：真机上每帧一条警告会自己把 logcat 冲爆，反而掩盖现场。
		if host._lut_sync_reentry_count == 1:
			push_warning("[hex_renderer] _sync_cell_lut_textures re-entered within one "
				+ "frame; rebind dropped by the re-entrancy guard. A material setter "
				+ "is calling back into the renderer — that is the shape of the "
				+ "VkThread stack-overflow crash; report this line if it appears.")
		return
	host._lut_sync_frame = frame
	# 收集 → 应用两段式：收集阶段只读，应用阶段才碰材质。这样即使某个 setter
	# 同步回调进来，它看到的也是"本帧已开始同步"的状态，而不是半更新的材质。
	var pending: Array[String] = []
	for lut_name in ["enum_lut", "dyn_lut", "bounce_lut"]:
		var pending_tex: Texture2D = host._world.get(lut_name + "_tex")
		if pending_tex == null or host._lut_bound.get(lut_name) == pending_tex:
			continue
		pending.append(lut_name)
	for lut_name in pending:
		_apply_cell_lut_rebind(host, lut_name, host._world.get(lut_name + "_tex"))
	# eco_lut 不在主材质；植被层在 set_world_material_inputs / set_map 路径绑定，
	# 日刷走 ImageTexture.update 保对象稳定，无需在此同步。


## 单张 LUT 的重绑（由 _sync_cell_lut_textures 收集后调用）。_lut_bound 先写后推：
## 万一某条推送抛错，下一帧不会重复打同一行日志（保持不变旧行为）。

static func _apply_cell_lut_rebind(host, lut_name: String, world_tex: Texture2D) -> void:

	if world_tex == null or host._shader_mat == null:
		return
	host._lut_bound[lut_name] = world_tex
	print("[hex_renderer] %s rebind (material held a stale LUT texture object)" % lut_name)
	host._push_world_uniform(lut_name, world_tex)
	# [web-water-pass] 水面 pass 采的是同一张 enum/dyn LUT（同一对象漂移），
	# bounce_lut 它不用。漏了这条，日刷之后水面会停在旧快照上。
	if host._water_mat != null and lut_name != "bounce_lut":
		host._water_mat.set_shader_parameter(lut_name, world_tex)
	if lut_name == "bounce_lut":
		host._push_world_uniform("gi_bounce_bound", true)
	elif lut_name == "enum_lut":
		# 迷雾层与天气层各自缓存了同一张 enum_lut（A 通道 = 知识度），
		# 它们的 setter 同样是"绑一次"语义，漂移时要一起补。
		if host._fog_layer != null:
			host._fog_layer.set_enum_lut_texture(world_tex)
		host._push_fog_uniforms()


static func _apply_uniforms(host) -> void:

	var sm = host._shader_mat
	var bounds = host._world.world_bounds
	var tiled = host._visual_tiles_active()
	var visual_tiles = host._world.visual_tiles if tiled else null

	# 主地图只保留 height/enum + cell-index LUT + 共享 noise_tex。
	if tiled:
		sm.set_shader_parameter("visual_height_tiles", visual_tiles.height)
		sm.set_shader_parameter("visual_terrain_normal_tiles", visual_tiles.terrain_normal)
		sm.set_shader_parameter("visual_terrain_relief_tiles", visual_tiles.terrain_relief)
		sm.set_shader_parameter("visual_horizon_tiles", visual_tiles.horizon)
		sm.set_shader_parameter("visual_map_index_tiles", visual_tiles.map_index)
		sm.set_shader_parameter("visual_water_depth_tiles", visual_tiles.water_depth)
		sm.set_shader_parameter("visual_terrain_detail_tiles", visual_tiles.terrain_detail)
		sm.set_shader_parameter("visual_edge_neighbor_tiles", visual_tiles.edge_neighbor)
		sm.set_shader_parameter("visual_edge_distance_tiles", visual_tiles.edge_distance)
		host._push_visual_tile_layout_uniforms(sm, visual_tiles.layout)
	else:
		sm.set_shader_parameter("height_tex", host._world.height_tex)
	# [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01 / surface-array-edge 2026-11-02]
	# 主地形非 tiled 路径用 **固定 6 层 array**（terrain_surface_tex）：layer0=normal
	# （RG 粗法线/BA 近景坡度）、layer1=relief（RG 粗段/BA 细段坡度）、layer2=detail、
	# layer3=occluder（两个 16-bit cell id，shader 用 texelFetch）、layer4=edge_distance
	# （R 距离/G crease/BA 海岸占比）、layer5=edge_neighbor（RG 次生 id + B 水深）。
	# 陆地与两个水面程序共用这一个 sampler；合并后少占材质 sampler。
	# 2D terrain_normal_tex 只为植被/建筑/资源/贸易等其它层保留，主地形不再绑它。
	# tiled 桌面路径改绑 visual_terrain_normal/relief/detail_tiles（见上）与
	# visual_water_depth_tiles。运行期不再做任何高度差分。
	var surface_layers = 0
	if not tiled:
		sm.set_shader_parameter("terrain_surface_tex", host._world.terrain_surface_tex)
		if host._world.terrain_surface_tex != null:
			surface_layers = int(host._world.terrain_surface_tex.get_layers())
		# [B] 层数门控：shader 侧 detail/occluder helper 按实际层数采样或返回中性值。
		sm.set_shader_parameter("terrain_surface_layer_count", surface_layers)
		sm.set_shader_parameter("terrain_detail_layer_bound", surface_layers >= 3)
		sm.set_shader_parameter("terrain_occluder_layer_bound", surface_layers >= 4)
		# [surface-array-edge 2026-11-02] layer4/5（edge_distance / edge_neighbor）是否烘出来了。
		# shader 据此决定次生生态过渡 / crease / 海岸占比是否可用（不采越界层）。
		sm.set_shader_parameter("terrain_edge_layers_bound", surface_layers >= 6)
		# [B] micro 第 5 层：material array 达到 5 层时 shader 用 layer4 采样
		# （4 = MapBaker.TERRAIN_MATERIAL_MICRO_LAYER），否则 -1 → 退回旧的 2D micro 路径。
		var material_layers = 0
		if host._world.terrain_material_tex != null:
			material_layers = int(host._world.terrain_material_tex.get_layers())
		sm.set_shader_parameter("terrain_material_micro_layer",
			4 if material_layers >= 5 else -1)
	sm.set_shader_parameter("terrain_normal_tex_bound",
		visual_tiles.terrain_normal != null if tiled else host._world.terrain_normal_tex != null)
	sm.set_shader_parameter("terrain_relief_tex_bound",
		visual_tiles.terrain_relief != null if tiled else host._world.terrain_surface_tex != null)
	# 法线可用性开关（与下面的 terrain_static_baked 分离）：tiled 用静态烘焙数组就绪，
	# legacy/Web 用 surface array 是否就绪。shader 只认这个 bool 决定读不读烘焙法线。
	sm.set_shader_parameter("terrain_baked_normals",
		visual_tiles.static_ready if tiled else host._world.terrain_surface_tex != null)
	# [static-bake 2026-10-10 / surface-array-edge 2026-11-02] 分地形细节法线、海岸邻域、
	# 水面软权重只在 tiled 静态烘焙里产出；非 tiled 打包路径把同一批场塞进 surface array
	# 的 layer4/5（surface_layers>=6），因此两条路径都算"静态烘焙就绪"。
	# **不要**再用它判法线是否可用（旧 RG8 兜底也会把它置 false；法线一律用
	# terrain_baked_normals）。
	sm.set_shader_parameter("terrain_static_baked",
		(tiled and visual_tiles.static_ready and visual_tiles.terrain_relief != null)
		or (not tiled and surface_layers >= 6))
	# [terrain-horizon 2026-07-03] 8 方向 horizon angle：运行期只遮蔽直射光；未绑定/低档自动回退。
	# [terrain-gi 2026-07-31] 同一张图还派生天空可见度(AO)/bent normal/弹射；见 _push_gi_uniforms。
	if not tiled:
		sm.set_shader_parameter("terrain_horizon_tex", host._world.terrain_horizon_tex)
	sm.set_shader_parameter("terrain_horizon_tex_bound",
		bool(visual_tiles.horizon_ready) if tiled else host._world.terrain_horizon_tex != null)
	host._push_gi_uniforms(sm, tiled, visual_tiles)
	if not tiled:
		sm.set_shader_parameter("map_index_atlas", host._world.enum_atlas_tex)
	# [height-flow-pack 2026-08-06] Legacy/Tiled flow 都在 height*.B，不再绑独立 flow sampler。
	# has_flow_tex：height 纹理就绪且 flow_buffer 齐 = 已打包。
	sm.set_shader_parameter("has_flow_tex",
		(visual_tiles.height != null if tiled else host._world.height_tex != null)
		and host._world.flow_buffer.size() >= host._world.hm_size.x * host._world.hm_size.y
		and host._world.hm_size.x > 0 and host._world.hm_size.y > 0)
	# [water-depth-tex 2026-06-26] 海/湖统一水深 R8：绑定后 shader 每水像素 1 次采样取代旧"海洋 5×5
	# height 邻域 + 湖泊 16× biome-atlas 多半径"两套深浅估算；未绑定时 has_water_depth_tex=false →
	# water_pipeline 回退旧逐邻域算法。
	if not tiled:
		sm.set_shader_parameter("water_depth_tex", host._world.water_depth_tex)
	sm.set_shader_parameter("ocean_current_flow_tex", host._world.ocean_current_flow_tex)
	sm.set_shader_parameter("ocean_current_flow_tex_bound", host._world.ocean_current_flow_tex != null)
	sm.set_shader_parameter("has_water_depth_tex",
		visual_tiles.water_depth != null if tiled else host._world.water_depth_tex != null)
	# [terrain-detail-bake 2026-07-05] 静态 biome 细节调制：移动端中/高档和桌面中档用单次采样替代多噪声。
	if not tiled:
		sm.set_shader_parameter("terrain_detail_tex", host._world.terrain_detail_tex)
	sm.set_shader_parameter("has_terrain_detail_tex",
		visual_tiles.terrain_detail != null if tiled else host._world.terrain_detail_tex != null)
	var edge_data_ready = (
		host._world.terrain_edge_neighbor_tex != null
		and host._world.terrain_edge_distance_tex != null
	)
	if not tiled:
		# 2D edge 图仍绑给 fog / 边线 / 天气等独立图层；world_map 与非 tiled 水面程序
		# 改读 surface array 的 layer4/5（[surface-array-edge 2026-11-02]），不再声明
		# 这两个 2D sampler。两个来源任一就绪都算"有 edge 数据"：中性图层会让权重恒 0，
		# 不会画出假过渡。
		sm.set_shader_parameter("terrain_edge_neighbor_tex", host._world.terrain_edge_neighbor_tex)
		sm.set_shader_parameter("terrain_edge_distance_tex", host._world.terrain_edge_distance_tex)
	sm.set_shader_parameter("has_terrain_edge_data",
		true if tiled else (edge_data_ready or surface_layers >= 6))
	sm.set_shader_parameter("terrain_ecotone_width", host.terrain_ecotone_width)
	sm.set_shader_parameter("terrain_ecotone_noise", host.terrain_ecotone_noise)
	# [terrain-material-tiles] The array is shared by all maps and is valid for
	# both legacy and VisualTileSet variants. Shader-side quality gating keeps
	# MID/LOW and failed allocation on the existing detail path.
	sm.set_shader_parameter("terrain_material_tex", host._world.terrain_material_tex)
	sm.set_shader_parameter("terrain_material_tex_bound", host._world.terrain_material_tex_bound)
	sm.set_shader_parameter("terrain_materials_enabled", host.terrain_materials_enabled)
	# [terrain-material-tiles 2026-08-01d] 128 世界单位/张（5.8 hex）下特征尺度为亚 hex 级，
	# 常用 zoom 1-2 全部命中 mip 2-3、颗粒被预滤波抹平；384（17.5 hex/张）让 z=2 命中 mip≈0。
	# [terrain-material-tiles 2026-08-01e] 四参数已提为 @export（见文件头），此处读属性值。
	sm.set_shader_parameter("terrain_material_world_size", host.terrain_material_world_size)
	sm.set_shader_parameter("terrain_material_albedo_strength", host.terrain_material_albedo_strength)
	sm.set_shader_parameter("terrain_material_normal_strength", host.terrain_material_normal_strength)
	sm.set_shader_parameter("terrain_material_roughness_strength", host.terrain_material_roughness_strength)
	sm.set_shader_parameter("terrain_micro_tex", host.TERRAIN_MICRO_TEXTURE)
	sm.set_shader_parameter("has_terrain_micro_tex", host.TERRAIN_MICRO_TEXTURE != null)
	# 走统一推送口：水面 pass 是 world_map 的 WATER_ONLY 变体，同样声明了这两项，
	# 只写 _shader_mat 会让两片 program 的像素尺度门控不同步。
	host._push_world_uniform("camera_zoom", host._camera_zoom)
	host._push_world_uniform("pixel_world_size", host._refresh_pixel_world_size())
	sm.set_shader_parameter("terrain_surface_debug_view", host.terrain_surface_debug_view)
	# map-visual-overhaul-v1：weather_field_tex 已不再绑给主材质——海面天气视觉
	# 全部迁移到 weather_overlay 三层独立云（cirrus/cumulus/fog）。
	if host._weather_layer != null:
		host._weather_layer.set_vector_atlas_texture(null)
	# Systemic Ocean Currents：仅 F6 高对比调试层采样；主路径不依赖它。
	# 方案 0：默认不再每次新材质都绑 upwelling_tex（commit 路径已不烘焙它，绑过来就是 null）。
	# 当 _ocean_current_debug=true 时 set_ocean_current_debug 已 lazy bake 并 set 一次；
	# 这里仅在 _world.upwelling_tex 已存在时同步绑定，避免新材质丢失已 bake 的纹理。
	if host._world.upwelling_tex != null:
		sm.set_shader_parameter("ocean_upwelling_tex", host._world.upwelling_tex)
	# v10.noise-pack：把共享 RGBA 噪声包喂给地形 shader，fbm(p,N) 全局单次采样。
	# [terrain-web-baked-surface-A/B 2026-11-01] normal/relief/detail/occluder 合并进
	# terrain_surface_tex 后，Web 陆地程序腾出的材质槽还给 noise_tex（全部平台统一绑定）。
	sm.set_shader_parameter("noise_tex", host._world.noise_tex)

	# Cell-index 间接寻址是唯一动态视觉路径。
	var _indirect_ready: bool = host._world.enum_atlas_tex != null and host._world.enum_lut_tex != null
	sm.set_shader_parameter("enum_lut", host._world.enum_lut_tex)
	host._lut_bound["enum_lut"] = host._world.enum_lut_tex
	sm.set_shader_parameter("dyn_lut", host._world.dyn_lut_tex)
	host._lut_bound["dyn_lut"] = host._world.dyn_lut_tex
	# eco_lut 仅绑给植被实例层；主地形已退役该 sampler（槽位给 terrain_material_tex）。
	_push_cell_lut_dims(host, sm, host._world.lut_dims)
	# [terrain-gi 档 2] 弹射代表色 LUT：与 enum/dyn/eco 同一 lut_dims 网格、同一日刷节奏。
	sm.set_shader_parameter("bounce_lut", host._world.bounce_lut_tex)
	host._lut_bound["bounce_lut"] = host._world.bounce_lut_tex
	# Web 一次性取证：地表发白时到底哪张 LUT/地形纹理是空的（采样到默认白纹理就会发白）。
	if not host._web_lut_probe_done and OS.has_feature("web"):
		host._web_lut_probe_done = true
		var _head = ""
		if sm.shader != null:
			_head = sm.shader.code.substr(0, 90).replace("\n", " | ")
		WebTelemetry.emit("lut_probe", {
			"enum_lut": host._world.enum_lut_tex != null,
			"dyn_lut": host._world.dyn_lut_tex != null,
			"bounce_lut": host._world.bounce_lut_tex != null,
			"terrain": host._world.terrain_material_tex != null,
			"enum_atlas": host._world.enum_atlas_tex != null,
			"lut_dims": str(host._world.lut_dims),
			"indirect": _indirect_ready,
			"shader_head": _head,
		})
	# [terrain-web-baked-surface-B 2026-11-01] GI 弹射可用性（调试/GM 用）：
	#   - tiled：bounce_lut 颜色 + gi_occluder 数组都就绪；
	#   - 非 tiled packed 路径（Web HIGH）：颜色改由 enum_lut 的 biome 近似、遮挡源在
	#     surface array layer3 → 只需 layer3 就绪（layers>=4），不再需要 bounce_lut。
	var bounce_ready = false
	if tiled:
		bounce_ready = host._world.bounce_lut_tex != null and bool(visual_tiles.gi_occluder_ready)
	elif host._world.terrain_surface_tex != null:
		bounce_ready = int(host._world.terrain_surface_tex.get_layers()) >= 4
	sm.set_shader_parameter("gi_bounce_bound", bounce_ready)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_world_material_inputs(host._world, bounds, _indirect_ready)
	)
	host._sync_detail_and_activity_materials()

	sm.set_shader_parameter("world_origin", bounds.position)
	sm.set_shader_parameter("world_size", bounds.size)
	sm.set_shader_parameter("hex_size", host.hex_size)
	sm.set_shader_parameter("wrap_origin_x", 0.0)
	sm.set_shader_parameter("wrap_period_x", host._wrap_period_x())
	var visual_resolution = Vector2(visual_tiles.layout.logical_size) if tiled \
		else Vector2(host._world.hm_size.x, host._world.hm_size.y)
	sm.set_shader_parameter("hm_resolution", visual_resolution)
	sm.set_shader_parameter("terrain_normal_sample_radius_hex", 1.35)
	sm.set_shader_parameter("terrain_normal_height_scale_hex", 2.10)
	sm.set_shader_parameter("derived_resolution", visual_resolution if tiled \
		else Vector2(host._world.derived_size.x, host._world.derived_size.y))
	sm.set_shader_parameter("visual_reference_resolution",
		visual_resolution)
	sm.set_shader_parameter("sea_level", host._world.sea_level)

	sm.set_shader_parameter("season_phase", host._season_phase)
	sm.set_shader_parameter("climate_anomaly", host._climate_anomaly)
	sm.set_shader_parameter("world_time", host._world_time)
	# 任务 2：把当前 day_phase 同步到新创建的材质上
	sm.set_shader_parameter("day_phase", host._day_phase)
	sm.set_shader_parameter("tod_debug_sun_position_enabled", host._tod_debug_sun_position_enabled)
	sm.set_shader_parameter("tod_debug_sun_uv", host._tod_debug_sun_uv)
	sm.set_shader_parameter("tod_debug_sun_height_scale", host._tod_debug_sun_height_scale)
	sm.set_shader_parameter("eternal_min_elevation_rad", deg_to_rad(host.eternal_min_elevation_deg))
	sm.set_shader_parameter("eternal_max_hour_angle_rad", deg_to_rad(host.eternal_max_hour_angle_deg))
	sm.set_shader_parameter("season_temp_amp", host.season_temp_amp)
	# True Insolation-Driven：CPU / GPU 同源的四个参数输出到 shader
	sm.set_shader_parameter("true_insolation_enabled", host.true_insolation_enabled)
	sm.set_shader_parameter("axial_tilt_rad", deg_to_rad(host.axial_tilt_deg))
	sm.set_shader_parameter("insolation_daylen_amp", host.insolation_daylen_amp)
	sm.set_shader_parameter("insolation_season_gain", host.insolation_season_gain)
	sm.set_shader_parameter("vegetation_season_strength", host.vegetation_season_strength)
	# map-visual-overhaul-v1：把 24 种植被的四季 LUT + climate_anomaly 偏移色 push 到 shader。
	# 一次 setup 推送即可，运行时不刷新（除非热重载植被资源时显式 invalidate）。
	_push_vegetation_season_lut(host, )
	sm.set_shader_parameter("dynamic_snow_strength", host.dynamic_snow_strength)
	sm.set_shader_parameter("debug_force_dyn_snow_only", host.debug_force_dyn_snow_only)
	sm.set_shader_parameter("vegetation_axis_strength", host.vegetation_axis_strength)
	sm.set_shader_parameter("cover_axis_strength", host.cover_axis_strength)
	sm.set_shader_parameter("ecology_visual_strength", host.ecology_visual_strength)
	sm.set_shader_parameter("snowline_visual_strength", host.snowline_visual_strength)
	sm.set_shader_parameter("foliage_density_strength", host.foliage_density_strength)
	sm.set_shader_parameter("temperature_visual_strength", host.temperature_visual_strength)
	sm.set_shader_parameter("moisture_visual_strength", host.moisture_visual_strength)
	sm.set_shader_parameter("vitality_visual_strength", host.vitality_visual_strength)
	sm.set_shader_parameter("ecology_visual_quality", host.ecology_visual_quality)
	host._push_terrain_horizon_uniforms()

	# Milestone 3：默认填空 weather 数组；全局天气强度只由 WeatherLayer 消费。

	sm.set_shader_parameter("visual_quality", host.visual_quality)
	sm.set_shader_parameter("day_night_enabled", host.day_night_enabled)
	sm.set_shader_parameter(
		"extreme_weather_ground_effect_enabled",
		host.extreme_weather_ground_effect_enabled
	)
	# Pass 2：云染色开关与洋流调试开关同步到新建材质
	sm.set_shader_parameter("cloud_tod_tint_enabled", host.cloud_tod_tint_enabled)
	sm.set_shader_parameter("ocean_current_debug", host._ocean_current_debug)
	# 全部水面参数（57 项）统一推送，名单见 WATER_PARAM_NAMES。
	host._push_water_params_to(sm)

	# 挂上 enum_atlas 当海陆判断、noise_tex 给 weather overlay shader 复用
	if host._weather_layer != null:
		host._weather_layer.set_visual_tiles(host._world.visual_tiles if tiled else null)
		host._weather_layer.setup(bounds, host._world.enum_atlas_tex, host._world.noise_tex, host.hex_size, host._world.weather_lut_tex, host._world.lut_dims, host._wrap_period_x(), host._map)
		# [cylindrical-earth-daylight] 云光照真源相位：与 ShrubLayer spawn 同套，setup 后补推一次，
		# 之后由 set_day_phase / set_season_phase 增量刷新（晨昏线随时间扫过）。
		host._weather_layer.set_season_phase(host._season_phase)
		host._weather_layer.set_day_phase(host._day_phase)
		host._weather_layer.set_axial_tilt_rad(deg_to_rad(host.axial_tilt_deg))
		host._weather_layer.set_eternal_daylight_parameters(deg_to_rad(host.eternal_min_elevation_deg), deg_to_rad(host.eternal_max_hour_angle_deg))
		if host._weather_layer.has_method("set_tod_debug_sun_position"):
			host._weather_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
		if host._weather_layer.has_method("set_tod_debug_sun_height_scale"):
			host._weather_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
		host._weather_layer.set_weather_field_texture(null)
		host._weather_layer.set_vector_atlas_texture(null)
		host._weather_layer.set_weather_strength(host.weather_strength)
		host._weather_layer.set_cloud_opacity_scale(host.weather_cloud_opacity)
		# [parallax-rain] 俯视雨幕默认参数（可被外部 set_camera_pitch 覆盖）
		host._weather_layer.set_camera_pitch(host._camera_pitch)
		host._weather_layer.set_wind(host._wind_dir, host._wind_strength)
	if host._border_layer != null:
		host._border_layer.set_hex_size(host.hex_size)
		host._border_layer.set_horizontal_wrap(host._wrap_period_x())
	if host._fog_layer != null:
		host._fog_layer.set_visual_tiles(host._world.visual_tiles if tiled else null)
		host._fog_layer.setup(bounds, host._world.enum_atlas_tex, host._world.lut_dims, host.hex_size, host._wrap_period_x())
		host._fog_layer.set_enum_lut_texture(host._world.enum_lut_tex)
		# [cylindrical-earth-daylight] 迷雾云的 TOD 光照与天气云同源，setup 后补推
		# 一次相位，之后由 set_day_phase / set_season_phase 增量刷新。
		host._fog_layer.set_season_phase(host._season_phase)
		host._fog_layer.set_day_phase(host._day_phase)
		host._fog_layer.set_axial_tilt_rad(deg_to_rad(host.axial_tilt_deg))
		host._fog_layer.set_eternal_daylight_parameters(deg_to_rad(host.eternal_min_elevation_deg), deg_to_rad(host.eternal_max_hour_angle_deg))
		host._fog_layer.set_day_night_enabled(host.day_night_enabled)
		host._fog_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
		host._fog_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
		host._fog_layer.set_visual_quality(host.visual_quality)
		host._fog_layer.set_enabled(host._fog_enabled)
		host._apply_fog_early_out()
	host._push_overlay_edge_transition_data()
	host._push_fog_uniforms()
	host.set_weather_fronts([])

	# Hypsometric 色阶
	sm.set_shader_parameter("color_deep_ocean", host.color_deep_ocean)
	sm.set_shader_parameter("color_mid_ocean", host.color_mid_ocean)
	sm.set_shader_parameter("color_shallow", host.color_shallow)
	sm.set_shader_parameter("color_coast_water", host.color_coast_water)
	sm.set_shader_parameter("color_beach", host.color_beach)
	sm.set_shader_parameter("color_lowland", host.color_lowland)
	sm.set_shader_parameter("color_hill", host.color_hill)
	sm.set_shader_parameter("color_mountain", host.color_mountain)
	sm.set_shader_parameter("color_peak", host.color_peak)
	sm.set_shader_parameter("color_snow", host.color_snow)

	# Hillshading
	sm.set_shader_parameter("hillshade_strength", host.hillshade_strength)
	sm.set_shader_parameter("hillshade_slope_gain", host.hillshade_slope_gain)

	# Rivers
	sm.set_shader_parameter("river_strength", host.river_strength)
	sm.set_shader_parameter("river_threshold_low", host.river_threshold_low)
	sm.set_shader_parameter("river_threshold_high", host.river_threshold_high)
	sm.set_shader_parameter("river_color", host.river_color)
	sm.set_shader_parameter("river_outline_color", host.river_outline_color)

	# Contour
	sm.set_shader_parameter("contour_enabled", host.contour_enabled)
	sm.set_shader_parameter("contour_step", host.contour_step)
	sm.set_shader_parameter("contour_strength", host.contour_strength)
	sm.set_shader_parameter("contour_color", host.contour_color)

	# Coast halo
	sm.set_shader_parameter("coast_halo_color", host.coast_halo_color)
	sm.set_shader_parameter("coast_halo_strength", host.coast_halo_strength)

	# Atlas
	sm.set_shader_parameter("parchment_tint", host.parchment_tint)
	sm.set_shader_parameter("parchment_strength", host.parchment_strength)
	sm.set_shader_parameter("paper_grain_strength", host.paper_grain_strength)

	sm.set_shader_parameter("biome_tint_strength", host.biome_tint_strength)
	sm.set_shader_parameter("land_albedo_saturation", host.land_albedo_saturation)
	sm.set_shader_parameter("tonemap_hue_preserve", host.tonemap_hue_preserve)
	# [web-water-pass] 水面第二 pass 的建/拆/对齐挂在这里：_apply_uniforms() 是
	# "材质重建后把全部输入对齐"的唯一收口，画质换档与 set_map 都会经过它。
	host._sync_water_quad()
	host._push_world_lighting_profile()
	host._configure_cloud_shadow_field()
	host._push_cloud_shadow_material_inputs()

# ─── map-visual-overhaul-v1：植被四季 LUT 推送 ──────────────────────────
# 把 VegetationProfileRegistry 加载的 24 个 VegetationProfile 的
#   season_color_lut[4]（春/夏/秋/冬叠乘色）
#   anomaly_color_shift  （climate_anomaly 升高时的叠加色）
# 一次性 push 到 shader 端的两个 uniform 数组：
#   vegetation_season_lut[VEG_COUNT*4] : 按 [veg*4 + season] 索引（VEG_COUNT=28）
#   vegetation_anomaly_shift[VEG_COUNT] : 按 [veg] 索引（VEG_COUNT=28）
# 仅在 setup / _apply_uniforms 调用一次（植被资源不会运行时变化）。

static func _push_vegetation_season_lut(host) -> void:

	host.RendererMapAssets._push_vegetation_season_lut(host._shader_mat, host._push_world_uniform)

# ─── Fast-tick perf opt (E)：细粒度纹理重绑接口 ──────────────────────────
# 背景：原 `set_map` 路径会触发 `_rebuild` → `_build_world_quad_mesh` + `_apply_uniforms`，
#       后者一次性向 shader 写入 60+ uniform（含 geometry / hypsometric / water / TOD…），
#       在加速档 x20 下季节切换每 ~1.5s 触发一次，是肉眼可见的卡顿源头。
# 优化：season 切换时 `_baker.rebake_*_tex_only` 已经把新像素写进了共享 ImageTexture，
#       atlas 句柄并未变化（仍是 `_world.enum_atlas_tex`）。Godot 的 ImageTexture 内部
#       update 机制保证 GPU 端看到新内容，**理论上 shader 端无需任何额外动作**。
#       但为了对 set_shader_parameter 有缓存优化的 Godot 版本保险起见，这里仍重新
#       set 一次 atlas uniform（成本极低，仅 1~3 次 set_shader_parameter），避免脏帧。
# 三个 *_tex_only 方法语义：
#   - set_biome_tex_only      → 重绑 enum_atlas（biome / landform / vegetation / cover
#                                /weather 全部打包在 enum_atlas 的 4 通道里，是 biome
#                                决策影响最直接的 atlas）
#   - set_cover_tex_only      → 同样重绑 enum_atlas（cover 通道与 biome 通道共用 atlas）
#   - set_vegetation_tex_only → 同样重绑 enum_atlas（vegetation 通道与 biome 通道共用）
# 调用方（main.gd._on_season_changed）只需选择最贴合语义的一个调用即可，重复调用
# 是幂等的（同一 ImageTexture 重新 bind 不增加 GPU 成本）。
#
# 显式不做的事（与 `set_map` / `_apply_uniforms` 的关键差异）：
#   - 不重建 _world_quad.mesh（geometry 不变，避免一次几何上传）
#   - 不重新计算 world_bounds / world_origin / world_size / sea_level / hm_resolution
#   - 不重发 hypsometric 调色板、water 视觉、TOD 参数等静态 uniform
#   - 不重置 _weather_layer.setup（weather layer 自有节奏）

static func set_biome_tex_only(host, world: WorldData) -> void:

	if host._shader_mat == null or world == null or world.enum_atlas_tex == null:
		return
	host._push_world_uniform("map_index_atlas", world.enum_atlas_tex)


static func set_cover_tex_only(host, world: WorldData) -> void:

	# Project.Keynes 把 biome / cover / vegetation / weather 共用一张 enum_atlas，
	# 因此 cover 重绑等价于 biome 重绑；保留独立方法名仅为契合方案 E 的 API 命名约定。
	set_biome_tex_only(host, world)


static func set_vegetation_tex_only(host, world: WorldData) -> void:

	# 同上：vegetation 通道与 biome 共用 enum_atlas。
	set_biome_tex_only(host, world)


# ─── [sea-ice-render-source-unify 阶段 A] 海冰单源诊断探针 ────────────────
# 用法（调试用，控制台/F8 调）：
#   HexRenderer.debug_sea_ice_probe(cell)  → 打印三元组：
#     (sea_ice_fraction_cpu, dyn_atlas_smooth.A 像素字节, biome id)
#
# 三者必须满足：
#   q01_byte_ice(sea_ice_fraction_cpu) == dyn_atlas_smooth_buffer[px_idx*4 + 3]
# 否则说明 GD↔C++ 编码漂移或 cache 滞后。
#
# biome id 仅作上下文参考——阶段 A 之后 shader 已不依赖 biome 决定海冰渲染。

