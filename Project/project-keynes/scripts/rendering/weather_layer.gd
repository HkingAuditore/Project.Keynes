# weather_layer.gd v1
# 独立的天气表现层（v9.split：从 world_map.gdshader 中拆出来）。
#
# 节点结构：
#   WeatherLayer (Node2D, z_index=1，挂在 HexRenderer 之下）
#   ├── _overlay_quad   MeshInstance2D + weather_overlay.gdshader  (z_index=0 in layer)
#   ├── _shadow_root    Node2D（云阴影 Sprite2D 池，每 front 一个）  (z_index=1)
#   └── _particles_root Node2D（GPUParticles2D 池，每 front 一个）   (z_index=2)
#
# 数据流：
#   HexRenderer.set_weather_fronts(fronts) → WeatherLayer.set_weather_fronts(fronts)
#       ├─ 写 overlay shader 的 weather_front_centers / types / count uniform
#       ├─ 同步 cloud shadow Sprite2D 池（B5 实装）
#       └─ 同步 GPUParticles2D 池（B6 实装）
#
# 与地形 shader 的分工：
#   - DROUGHT / HEATWAVE 的 multiplicative 调色仍在 world_map.gdshader 内（地表本色变化）
#   - 其余 RAIN / STORM / FOG / BLIZZARD / MONSOON 全部由本层负责

class_name WeatherLayer
extends Node2D

signal visual_fronts_changed(fronts: Array)

const MAX_WEATHER_FRONTS := 16
const OVERLAY_SHADER_PATH := "res://shaders/weather_overlay.gdshader"
# Weather simulation still advances by game day. The presentation layer follows
# snapshots with a small lag so fronts keep moving between day ticks instead of
# snapping once and then freezing until the next tick.
# Phase E（方案 A）：sim 端寿命翻倍后，相邻快照之间的位置变化更大、间隔更长。
# 把 MAX_BLEND 从 1.35s 抬到 2.5s、MAX_PREDICT 从 0.35d 抬到 1.0d，让表现层
# 能在每两次 day-tick 之间持续外推前进，避免"两次快照之间冻住、第三次跳一下"。
#
# 抽动修复（2026-05-18）：进一步把 MAX_BLEND 抬到 5.0s、MAX_PREDICT 抬到 2.5d。
# 原因：SUS 多 tick 切片 + RefreshClimateDaily 偶发抢占下，commit 真实间隔可
# 突变到 3-4s，旧上限 2.5s 会触顶 → lerp 完成后进入 _predict 外推 → 新 commit
# 一到 _front_blend_elapsed=0 重置 + smoothstep 的 ease-in → 视觉上"加速冲一
# 下→突然停→慢慢起步"。抬高上限后 99% commit 间隔都能装进单段 lerp 内。
const _WEATHER_FRONT_INITIAL_BLEND_SEC: float = 0.65
const _WEATHER_FRONT_MIN_BLEND_SEC: float = 0.35
const _WEATHER_FRONT_MAX_BLEND_SEC: float = 5.0
const _WEATHER_FRONT_BLEND_LAG_FACTOR: float = 1.15
const _WEATHER_FRONT_DESPAWN_FADE_SEC: float = 0.85
const _WEATHER_FRONT_MAX_PREDICT_DAYS: float = 2.5
# 抽动修复（2026-05-18）：blend_duration IIR 平滑系数（new × α + prev × (1-α)）。
# α 越小越平滑但响应越慢。0.35 是在"调速档切换后 ~3 次 commit 内追上新间隔"和
# "抑制单次 interval 抖动"之间取的折中。
const _WEATHER_FRONT_BLEND_IIR_ALPHA: float = 0.35

# 云阴影 sprite 的"原始半径"（生成的 ImageTexture 的半径，单位像素）。
# 实际显示半径 = SHADOW_BASE_RADIUS_PX * sprite.scale，scale 由 front.radius 推算。
const SHADOW_BASE_RADIUS_PX := 128

# 任务 5：降水粒子密度制。每单位像素²粒子数，与覆盖面积相乘得到 amount。
# 最小/最大数量 防止小 front 看不见雨 / 巨大 front 暗制 GPU。
const _RAIN_DENSITY_PER_PX2: float = 0.00040  # 约 1 粒/50000 px²
const _RAIN_AMOUNT_MIN: int = 80
const _RAIN_AMOUNT_MAX: int = 640
const _SNOW_DENSITY_PER_PX2: float = 0.00030
const _SNOW_AMOUNT_MIN: int = 60
const _SNOW_AMOUNT_MAX: int = 480
# Pass 2（任务 5）：rain_density_boost_enabled=true 时的密度下限/上限
# 以侍需求 5.1：amount_min 从 80 → 180，BLIZZARD 60 → 120。
const _RAIN_AMOUNT_MIN_BOOST: int = 180
const _RAIN_AMOUNT_MAX_BOOST: int = 900
const _SNOW_AMOUNT_MIN_BOOST: int = 120
const _SNOW_AMOUNT_MAX_BOOST: int = 720
# WeatherType.WT id（与 weather_type.gd / weather_overlay.gdshader 严格一致）
const _WT_CLEAR    := 0
const _WT_RAIN     := 1
const _WT_STORM    := 2
const _WT_BLIZZARD := 3
const _WT_DROUGHT  := 4
const _WT_FOG      := 5
const _WT_HEATWAVE := 6
const _WT_MONSOON  := 7

var _overlay_quad: MeshInstance2D
var _overlay_mat: ShaderMaterial
var _shadow_root: Node2D
var _shadow_pool: Array[Sprite2D] = []   # 16 个 Sprite2D，按 front index 复用
var _shadow_texture: ImageTexture        # 共享的 radial-fade alpha 圆盘
var _shadow_material: CanvasItemMaterial # 共享的 BLEND_MUL 材质
var _particles_root: Node2D
var _particles_pool: Array[GPUParticles2D] = []  # 16 个，按 front index 复用
# 缓存每个 slot 当前配置类型，避免每次 set_weather_fronts 都重建 process_material
var _particles_type_cache: Array[int] = []
# Phase A 止血：缓存每个 slot 上一次写入的 amount / visibility_rect_radius，
# 避免逐帧因 area 微动 ±1 触发 GPUParticles 内部缓冲重建（这是"一顿一顿"的主因之一）。
# 仅当 |Δamount| > 5（约 3% 面积）或 radius 变化 > 5% 时才重写。
var _particles_amount_cache: Array[int] = []
var _particles_vis_radius_cache: Array[float] = []
# v-data-driven：每种 WeatherType 共享一份 ParticleProcessMaterial，避免 16 份各自触发
# shader 编译。key = WeatherType.WT int；由 _get_or_build_process_material(wt) 懒加载。
var _process_material_cache: Dictionary = {}
# v-data-driven：profile.particle_texture 为 null 时的兜底白色贴图，避免空引用。
var _fallback_particle_texture: ImageTexture

var _world_bounds: Rect2 = Rect2()
var _world_time: float = 0.0
var _strength: float = 1.0
var _weather_field_tex: Texture2D = null
# Phase 1：vector_atlas（RGBA8）的 BA 通道是 wind_field（[-1,1] mapped to [0,1]）。
# overlay shader 用它做 per-cell advection 让云沿真实风带流动，不再依赖全局常量 axis。
var _vector_atlas_tex: Texture2D = null
# v9.perf：当前可见 fronts 数量；为 0 时整个 WeatherLayer 隐藏，省一次全屏 pass
var _active_count: int = 0
# 每日 WeatherFront 快照的表现层插值状态。这里存 Dictionary 快照，避免改 WeatherSystem 数据。
var _front_start_snapshots: Array = []
var _front_target_snapshots: Array = []
var _front_visual_snapshots: Array = []
var _front_blend_elapsed: float = 0.0
var _front_blend_duration: float = 0.0
var _last_front_snapshot_time: float = -1.0
var _front_snapshot_interval_sec: float = _WEATHER_FRONT_INITIAL_BLEND_SEC
# 任务 5：STORM 闪电节拍——随 world_time 推进， < 1Hz 触发 80~120ms 的亮斑。
# _storm_next_flash_t：下次开始的 world_time；_storm_flash_end_t：当前亮斑失效时间。
var _storm_next_flash_t: float = 0.0
var _storm_flash_end_t: float = 0.0
var _storm_active: bool = false
var _rng: RandomNumberGenerator

# Drift-debug（2026-05-10）：set true 后：
#   1) set_weather_fronts 入口打印 snapshot_interval / blend_duration / forward_bias
#      + 每个 front 的 (raw center, velocity, biased target, start→target delta)
#   2) _process 每秒打印 visual_snapshots[0] 的 center 看是否真的在变
# 验证完成后改回 false 关日志。
const DRIFT_DEBUG_LOG: bool = false
var _drift_debug_last_log_time: float = -1.0

func _ready() -> void:
	z_as_relative = false
	z_index = 1
	# v9.perf：默认整层隐藏，set_weather_fronts() 来了再 visible=true，
	# 在没有任何天气时省掉 overlay quad 的全屏 fragment + framebuffer blend
	visible = false

	_overlay_quad = MeshInstance2D.new()
	_overlay_quad.name = "WeatherOverlayQuad"
	_overlay_quad.z_as_relative = true
	_overlay_quad.z_index = 0
	add_child(_overlay_quad)

	_shadow_root = Node2D.new()
	_shadow_root.name = "CloudShadows"
	_shadow_root.z_as_relative = true
	_shadow_root.z_index = -1
	add_child(_shadow_root)

	_particles_root = Node2D.new()
	_particles_root.name = "WeatherParticles"
	_particles_root.z_as_relative = true
	_particles_root.z_index = 2
	add_child(_particles_root)

	_load_overlay_shader()
	_init_shadow_pool()
	_init_particles_pool()
	# 任务 5：STORM 闪电数值随机
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	set_process(true)

func _process(delta: float) -> void:
	# ambient-shadow：先无条件推进 ambient_time + 推到 shader——这是装饰时钟，
	# 与 game pause 解耦，让云影即使在暂停时也持续飘动+变形。
	if _ambient_cloud_shadow_enabled and _overlay_mat != null:
		_ambient_time += delta
		_overlay_mat.set_shader_parameter("ambient_shadow_time", _ambient_time)

	# ambient-shadow：即使没有 weather，只要 ambient cloud shadow 开启，就要保持 overlay 可见。
	var has_weather: bool = (not _front_target_snapshots.is_empty()) \
			or (not _front_visual_snapshots.is_empty()) \
			or (_weather_field_tex != null)
	if not has_weather and not _ambient_cloud_shadow_enabled:
		_active_count = 0
		visible = false
		return
	# 任务 5：粒子/噪声时间推进受 WorldClock.paused 门控
	# （不依赖 WorldClock 实例，而是看 SceneTree 的 paused 状态——与项目现有暂停机制兑齐）
	# 注意：ambient_time 已在上面推进过了，这里 pause 仅冻结 weather 相关的 world_time。
	if not _effective_running():
		# 暂停时 ambient shadow 仍要保持 overlay 可见且能继续接收 ambient_time 更新，
		# 仅刷一次可见性后退出（不动 fronts/particles/world_time）。
		if _ambient_cloud_shadow_enabled:
			_refresh_visibility()
		return
	_world_time += delta
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("world_time", _world_time)
	if has_weather:
		_update_weather_front_blend(delta)
		# Drift-debug：每秒采样 visual_snapshots[0] 的 center，看 lerp 是否真的在推进。
		if DRIFT_DEBUG_LOG and _world_time - _drift_debug_last_log_time >= 1.0:
			_drift_debug_last_log_time = _world_time
			if _front_visual_snapshots.size() > 0:
				var v0: Dictionary = _front_visual_snapshots[0]
				var s0_c: Vector2 = Vector2.INF
				var t0_c: Vector2 = Vector2.INF
				if _front_start_snapshots.size() > 0:
					s0_c = _front_center(_front_start_snapshots[0])
				if _front_target_snapshots.size() > 0:
					t0_c = _front_center(_front_target_snapshots[0])
				var raw_t: float = 0.0
				if _front_blend_duration > 0.0001:
					raw_t = clampf(_front_blend_elapsed / _front_blend_duration, 0.0, 1.0)
				print("[weather-layer-tick] t=%.2fs visual0=%s start0=%s target0=%s blend_t=%.2f vel=%s" % [
					_world_time, str(_front_center(v0).round()),
					str(s0_c.round()) if s0_c != Vector2.INF else "<none>",
					str(t0_c.round()) if t0_c != Vector2.INF else "<none>",
					raw_t, str(_front_velocity(v0).round()),
				])
	else:
		# 没有天气但有 ambient shadow 时，跳过 fronts/particles/shadow 池同步，
		# 仅靠推进 world_time 让 shader 自己刷 ambient FBM 飘动。
		_refresh_visibility()
	# 任务 5：STORM 闪电推进
	if _storm_active:
		_update_storm_flash()

# 暂停门控：由上层（main.gd 把 WorldClock.paused 同步给 WeatherLayer）写入。
# 默认 true；外部写入 false 后停止 world_time 推进。
var _clock_running: bool = true

func set_clock_running(running: bool) -> void:
	_clock_running = running

func _effective_running() -> bool:
	return _clock_running

# 任务 5：按 world_time 驱动闪电亮斑，频率 < 1Hz，每次持续 80~120ms。
# 在窗口内把 storm_flash uniform 抬到 1.0，窗口外恢复为 0。
func _update_storm_flash() -> void:
	if _overlay_mat == null:
		return
	if _world_time >= _storm_next_flash_t and _world_time > _storm_flash_end_t:
		# 触发新一次亮斑：持续 80~120ms
		var dur_ms: float = _rng.randf_range(80.0, 120.0)
		_storm_flash_end_t = _world_time + dur_ms / 1000.0
		# 下一次：间隔 1.2 ~ 3.0 秒 (< 1Hz)
		_storm_next_flash_t = _storm_flash_end_t + _rng.randf_range(1.2, 3.0)
	var flash: float = 0.0
	if _world_time <= _storm_flash_end_t:
		# 软过渡：从 1.0 线性掉到 0.4，避免硬断视觉上倍感氣凝重
		flash = 1.0
	_overlay_mat.set_shader_parameter("storm_flash", flash)

# ─── 对外接口 ────────────────────────────────────────────────────────────

# 由 HexRenderer 在拿到 WorldData 之后调用一次；提供地图 bounds + 共用的 map_index_atlas + noise_tex。
# 2026-05-19 hex-grounded-offset：新增 hex_size 参数，用于把 shader 里的"邻域采样偏移"
# 按物理 hex 直径换算（替代之前在 uv 域写死的 0.0090~0.0125 魔数），避免和地块尺度共振。
func setup(bounds: Rect2, map_index_atlas: ImageTexture, noise_tex: ImageTexture, hex_size: float = 22.0) -> void:
	_world_bounds = bounds
	_reset_front_blend_state()
	if _overlay_quad != null:
		_overlay_quad.mesh = _build_full_quad(bounds)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("map_index_atlas", map_index_atlas)
		_overlay_mat.set_shader_parameter("noise_tex", noise_tex)
		_overlay_mat.set_shader_parameter("world_origin", bounds.position)
		_overlay_mat.set_shader_parameter("world_size", bounds.size)
		# hex_size = 半径，hex 直径（wp 单位）= 2 * hex_size。
		_overlay_mat.set_shader_parameter("hex_world_diameter", 2.0 * hex_size)
		_overlay_mat.set_shader_parameter("weather_strength", _strength)
		_overlay_mat.set_shader_parameter("weather_field_tex", _weather_field_tex)
		_overlay_mat.set_shader_parameter("weather_field_enabled", _weather_field_tex != null)
		# 进入时把 fronts 数组清空，避免上一张地图的残留
		_push_empty_fronts_to_overlay()
		# v-data-driven：一次性把 8 个 WeatherProfile 的颜色与 flags 推入 shader。
		_push_weather_profile_uniforms_to_overlay()
		# ambient-shadow：把当前开关与强度推一次到 shader，避免 setup 后第一帧用默认值。
		_overlay_mat.set_shader_parameter("ambient_cloud_shadow_enabled", _ambient_cloud_shadow_enabled)
		_overlay_mat.set_shader_parameter("ambient_cloud_shadow_strength", _ambient_cloud_shadow_strength)
		_overlay_mat.set_shader_parameter("ambient_shadow_time", _ambient_time)
	# ambient-shadow：setup 后立刻刷一次可见性，确保启用时在 reset_front_blend 之后还能看到影。
	_refresh_visibility()

# 全局天气强度（与 HexRenderer.weather_strength 同步）
func set_weather_strength(v: float) -> void:
	_strength = clampf(v, 0.0, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("weather_strength", _strength)

func set_weather_field_texture(tex: Texture2D) -> void:
	_weather_field_tex = tex
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("weather_field_tex", _weather_field_tex)
		_overlay_mat.set_shader_parameter("weather_field_enabled", _weather_field_tex != null)
	_refresh_visibility()

# ambient-shadow：可见性收敛点。任何一个条件成立就保持 overlay 可见：
#  1) 有活跃 fronts（_active_count > 0）
#  2) 有 weather_field_tex（按 cell 渲染天气场）
#  3) ambient cloud shadow 启用（即使 clear 天气也要画影子）
func _refresh_visibility() -> void:
	visible = (_active_count > 0) \
			or (_weather_field_tex != null) \
			or _ambient_cloud_shadow_enabled

# vector_atlas 已退役；保留 setter 让旧调用点安全退化。
func set_vector_atlas_texture(tex: Texture2D) -> void:
	_vector_atlas_tex = tex

# ─── 任务 1：视觉总开关（由 HexRenderer 转发） ──────────────────────────
# 这里的 setter 只负责把值写入 overlay shader uniform；overlay shader 内部
# 的分支会根据这些 uniform 决定是否执行对应特性。为使任务 1 本身"无视觉变化"，
# shader 侧的实际分支会在任务 4~6 中接入。
var _visual_quality: int = 2
var _day_night_enabled: bool = true
var _extreme_ground_enabled: bool = true

func set_visual_quality(q: int) -> void:
	_visual_quality = clampi(q, 0, 2)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("weather_overlay_quality", _visual_quality)

func set_day_night_enabled(v: bool) -> void:
	_day_night_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("day_night_enabled", _day_night_enabled)

func set_extreme_weather_ground_effect_enabled(v: bool) -> void:
	_extreme_ground_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(
			"extreme_weather_ground_effect_enabled", _extreme_ground_enabled
		)

# 任务 2：昼夜相位转发。overlay shader 可用它调暗夜间云色 / 在夜晚
# 把闪电/降水粒子的底色做冷蓝偏移（具体分支在任务 4~5 接入）。
var _day_phase: float = 0.25

func set_day_phase(v: float) -> void:
	_day_phase = fposmod(v, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("day_phase", _day_phase)

# ─── Pass 2（任务 2）：TOD 消费端 ───────────────────────────────────
# TODProfile 的 6 个字段完整推到 overlay shader，同时让粒子模态 / 云阴影
# 也跟着重新染色，达成“夜晚雨雪偏冷灰、白天偏暖白”的视觉一致性（需求 5.5 / 6.2）。
var _tod_sun_color: Color = Color.WHITE
var _tod_ambient_color: Color = Color(0.65, 0.68, 0.75)
var _tod_night_factor: float = 0.0
var _tod_exposure: float = 1.0

func apply_tod(profile: TODProfile) -> void:
	if profile == null:
		return
	_tod_sun_color = profile.sun_color
	_tod_ambient_color = profile.ambient_color
	_tod_night_factor = profile.night_factor
	_tod_exposure = profile.exposure
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(
			"tod_sun_color",
			Vector3(profile.sun_color.r, profile.sun_color.g, profile.sun_color.b)
		)
		_overlay_mat.set_shader_parameter(
			"tod_ambient_color",
			Vector3(profile.ambient_color.r, profile.ambient_color.g, profile.ambient_color.b)
		)
		_overlay_mat.set_shader_parameter("tod_night_factor", profile.night_factor)
		_overlay_mat.set_shader_parameter("tod_exposure", profile.exposure)
	# 任务 5：粒子 modulate 随 TOD 重新染色。
	# base_color * tod_sun_color * (1 - 0.5 * night_factor)
	# 具体到每个 slot 仍用 intensity 控制 alpha，这里只保存“当前色因子”
	# 供 _sync_particles_pool 读取。
	# 云阴影：modulate.a *= (1 - 0.8 * night_factor)——注意需要在 _sync_shadow_pool 里乘
	# 下，这里不再重制。

# 任务 5：开关——是否提升粒子密度（默认开，关闭后回到上一轮的 amount 下限）
var _rain_density_boost_enabled: bool = true

func set_rain_density_boost_enabled(v: bool) -> void:
	_rain_density_boost_enabled = v

# 任务 6：云层 TOD 染色开关，仅同步到 overlay shader。
var _cloud_tod_tint_enabled: bool = true

func set_cloud_tod_tint_enabled(v: bool) -> void:
	_cloud_tod_tint_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("cloud_tod_tint_enabled", _cloud_tod_tint_enabled)

# ambient-shadow：全图飘移云影。enabled=true 时即使无天气 overlay 也会保持可见，
# 在地面上画一层缓慢漂动的灰影斑块，给地图加"晴天有云"的氛围。strength 控制浓度。
# _ambient_time 与游戏 pause 解耦——云影是装饰，不跟着游戏停（区别于 _world_time）。
var _ambient_cloud_shadow_enabled: bool = true
var _ambient_cloud_shadow_strength: float = 0.75
var _ambient_time: float = 0.0

func set_ambient_cloud_shadow_enabled(v: bool) -> void:
	_ambient_cloud_shadow_enabled = v
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("ambient_cloud_shadow_enabled", v)
	_refresh_visibility()

func set_ambient_cloud_shadow_strength(v: float) -> void:
	_ambient_cloud_shadow_strength = clampf(v, 0.0, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter("ambient_cloud_shadow_strength", _ambient_cloud_shadow_strength)

# 抽动修复（2026-05-18）：速度档切换时由 main.gd 调用，重置 interval/duration
# 估计，避免下一次 commit 算出"上次 push 到现在"的超长间隔（例如 x20→x1 切换
# 后第一段 lerp 会被算成几秒长，云突然变慢）。
func reset_snapshot_pacing() -> void:
	_last_front_snapshot_time = -1.0
	_front_snapshot_interval_sec = _WEATHER_FRONT_INITIAL_BLEND_SEC
	# 不清 _front_blend_duration / _front_blend_elapsed，让当前正在进行的 lerp
	# 自然走完，新节奏从下一次 set_weather_fronts 起生效。

# fronts: Array[WeatherFront]（也接受 untyped Array，避免 caller 强转）
func set_weather_fronts(fronts: Array) -> void:
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	var start_candidates := _front_visual_snapshots.duplicate(true)
	var targets := _make_front_snapshots(fronts)
	var aligned := _align_front_blend_snapshots(start_candidates, targets)
	_front_start_snapshots = aligned[0]
	_front_target_snapshots = aligned[1]
	_front_blend_elapsed = 0.0
	if _last_front_snapshot_time < 0.0:
		_front_snapshot_interval_sec = _WEATHER_FRONT_INITIAL_BLEND_SEC
		_front_blend_duration = _WEATHER_FRONT_INITIAL_BLEND_SEC
	else:
		var raw_interval: float = maxf(now_sec - _last_front_snapshot_time, 0.001)
		# 抽动修复（2026-05-18）：snapshot_interval 也走 IIR，吸收单次 commit
		# 切片造成的抖动（例如某 tick 被 climate 抢占多花 1s）。
		_front_snapshot_interval_sec = lerpf(
			_front_snapshot_interval_sec, raw_interval, _WEATHER_FRONT_BLEND_IIR_ALPHA
		)
		var target_duration: float = clampf(
			_front_snapshot_interval_sec * _WEATHER_FRONT_BLEND_LAG_FACTOR,
			_WEATHER_FRONT_MIN_BLEND_SEC,
			_WEATHER_FRONT_MAX_BLEND_SEC
		)
		# IIR 平滑 blend_duration：新值 = 0.35 × target + 0.65 × prev。
		# 防止 interval 抖动直接打到时长上造成"这段飘很快、下段飘很慢"。
		if _front_blend_duration > 0.0001:
			_front_blend_duration = lerpf(
				_front_blend_duration, target_duration, _WEATHER_FRONT_BLEND_IIR_ALPHA
			)
		else:
			_front_blend_duration = target_duration
		if targets.size() < start_candidates.size():
			_front_blend_duration = maxf(_front_blend_duration, _WEATHER_FRONT_DESPAWN_FADE_SEC)
	_last_front_snapshot_time = now_sec

	# Drift-fix（2026-05-10）：对 lerp target 做 forward-bias，让"云会飘"在
	# 1× 速度也能可见。
	#
	# 背景：blend_duration ≈ 1.15 × snapshot_interval，意味着 lerp 完成时刻
	# 比下次 snapshot 到达晚 15%——所以 raw_t >= 1.0 后的外推路径在正常游戏里
	# 永远不到，老的 _predict_front_snapshots 是死代码。视觉位移完全靠
	# "lerp(start, raw_target)" 提供，而 raw_target = 新 tick 的聚类质心，
	# 在身份继承稳住了之后这个质心几乎不动 → 云就静止了。
	#
	# 修法：把 target.center 沿 front.velocity 向前推 forward_bias 个 snapshot。
	# 这样 lerp 终点 = "下次 snapshot 到达时云应该在的位置"，每 frame 内
	# lerp 都在持续向前推进。前后两 tick 的 forward-biased target 又能首尾相接，
	# 所以不会出现"先飘到未来、新 snapshot 一来又被拉回当前"的回弹。
	#
	# forward_bias 的单位是 snapshot interval（与 front.velocity 单位匹配）。
	# 1.15 = blend_duration / snapshot_interval：lerp 把视觉推到下次 snapshot
	# 到达时的预期位置。clamp [0, 1.5] 防止 blend_duration 被 MIN 抬高时过冲。
	var forward_bias: float = clampf(
		_front_blend_duration / maxf(_front_snapshot_interval_sec, 0.001),
		0.0, 1.5
	)
	if DRIFT_DEBUG_LOG:
		print("[weather-layer] set_weather_fronts: n=%d snap_interval=%.3fs blend_dur=%.3fs forward_bias=%.3f starts=%d" % [
			_front_target_snapshots.size(), _front_snapshot_interval_sec,
			_front_blend_duration, forward_bias, _front_start_snapshots.size(),
		])
	if forward_bias > 0.0:
		for i in range(_front_target_snapshots.size()):
			var t: Dictionary = _front_target_snapshots[i]
			var v: Vector2 = _front_velocity(t)
			var raw_center: Vector2 = _front_center(t)
			if v.length_squared() > 0.0001:
				t["center"] = raw_center + v * forward_bias
				_front_target_snapshots[i] = t
			if DRIFT_DEBUG_LOG and i < 3:
				var start_center: Vector2 = Vector2.INF
				if i < _front_start_snapshots.size():
					start_center = _front_center(_front_start_snapshots[i])
				var target_center: Vector2 = _front_center(t)
				var delta: Vector2 = target_center - start_center if start_center != Vector2.INF else Vector2.ZERO
				print("[weather-layer]   front%d type=%d raw=%s vel=%s |vel|=%.1f bias=%s start=%s target=%s |Δ|=%.1f" % [
					i, _front_type(t),
					str(raw_center.round()), str(v.round()), v.length(),
					str((v * forward_bias).round()),
					str(start_center.round()) if start_center != Vector2.INF else "<none>",
					str(target_center.round()), delta.length(),
				])

	# 目标为空时保留当前视觉快照做淡出；如果也没有视觉快照则立即清空。
	_update_weather_front_blend(0.0)

	# 任务 5：识别是否有 STORM front（触发闪电节拍推进）
	_storm_active = false
	for i in range(_front_target_snapshots.size()):
		if _front_intensity(_front_target_snapshots[i]) > 0.001 \
				and _front_type(_front_target_snapshots[i]) == _WT_STORM:
			_storm_active = true
			break
	if not _storm_active and _overlay_mat != null:
		_overlay_mat.set_shader_parameter("storm_flash", 0.0)

# ─── overlay shader uniform 上传 ─────────────────────────────────────────

func _push_fronts_to_overlay(fronts: Array) -> void:
	if _overlay_mat == null:
		return
	var centers := PackedVector4Array()
	var shapes := PackedVector4Array()
	var visuals := PackedVector4Array()
	var types := PackedFloat32Array()
	centers.resize(MAX_WEATHER_FRONTS)
	shapes.resize(MAX_WEATHER_FRONTS)
	visuals.resize(MAX_WEATHER_FRONTS)
	types.resize(MAX_WEATHER_FRONTS)
	var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
	for i in range(MAX_WEATHER_FRONTS):
		if i < n:
			var f = fronts[i]
			var c := _front_center(f)
			centers[i] = Vector4(c.x, c.y, _front_radius(f), _front_intensity(f))
			var ax := _front_axis(f)
			shapes[i] = Vector4(ax.x, ax.y, _front_major_scale(f), _front_minor_scale(f))
			visuals[i] = Vector4(
				_front_cloud_amount(f),
				_front_precip_amount(f),
				_front_dissolve_amount(f),
				_front_life_progress(f)
			)
			types[i] = float(_front_type(f))
		else:
			centers[i] = Vector4.ZERO
			shapes[i] = Vector4(1.0, 0.0, 1.0, 1.0)
			visuals[i] = Vector4.ZERO
			types[i] = -1.0
	_overlay_mat.set_shader_parameter("weather_front_centers", centers)
	_overlay_mat.set_shader_parameter("weather_front_shapes", shapes)
	_overlay_mat.set_shader_parameter("weather_front_visuals", visuals)
	_overlay_mat.set_shader_parameter("weather_front_types", types)
	_overlay_mat.set_shader_parameter("weather_front_count", n)

func _push_empty_fronts_to_overlay() -> void:
	_push_fronts_to_overlay([])

# v-data-driven：把 WeatherProfileRegistry 里 8 个 profile 的 overlay 颜色与 flags 位掩码
# 推入 shader 的 uniform 数组。每局游戏只需调用一次（在 setup() 里）。
# flags 位编码需与 weather_overlay.gdshader 中的 FLAG_* 常量严格一致：
#   bit0 = has_overlay
#   bit1 = enables_lightning
#   bit2 = enables_snow_grain
#   bit3 = enables_rain_streak
#   bit4 = enables_fog_breathe
const _FLAG_HAS_OVERLAY    := 1
const _FLAG_LIGHTNING      := 2
const _FLAG_SNOW_GRAIN     := 4
const _FLAG_RAIN_STREAK    := 8
const _FLAG_FOG_BREATHE    := 16
const _MAX_WEATHER_TYPES   := 8

func _push_weather_profile_uniforms_to_overlay() -> void:
	if _overlay_mat == null:
		return
	var colors := PackedColorArray()
	var flags := PackedInt32Array()
	colors.resize(_MAX_WEATHER_TYPES)
	flags.resize(_MAX_WEATHER_TYPES)
	for wt in range(_MAX_WEATHER_TYPES):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			colors[wt] = Color(0.0, 0.0, 0.0, 0.0)
			flags[wt] = 0
			continue
		# rgb = overlay_color, a = overlay_base_alpha（shader 端直接当作 vec4 读）
		colors[wt] = Color(
			p.overlay_color.r, p.overlay_color.g, p.overlay_color.b,
			p.overlay_base_alpha
		)
		var bits: int = 0
		if p.has_overlay: bits |= _FLAG_HAS_OVERLAY
		if p.enables_lightning: bits |= _FLAG_LIGHTNING
		if p.enables_snow_grain: bits |= _FLAG_SNOW_GRAIN
		if p.enables_rain_streak: bits |= _FLAG_RAIN_STREAK
		if p.enables_fog_breathe: bits |= _FLAG_FOG_BREATHE
		flags[wt] = bits
	_overlay_mat.set_shader_parameter("weather_profile_colors", colors)
	_overlay_mat.set_shader_parameter("weather_profile_flags", flags)

# ─── 池子同步（B5 / B6 实装） ────────────────────────────────────────────

func _sync_shadow_pool(fronts: Array) -> void:
	if _shadow_pool.is_empty():
		return
	# Cloud shadows are now drawn in weather_overlay.gdshader from the same
	# front coverage field, so the old sprite pool is kept disabled.
	for sprite in _shadow_pool:
		sprite.visible = false
	return
	var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
	for i in range(MAX_WEATHER_FRONTS):
		var sprite: Sprite2D = _shadow_pool[i]
		if i >= n:
			sprite.visible = false
			continue
		var f = fronts[i]
		var wt: int = _front_type(f)
		# v-data-driven：是否出云阴影完全来自 profile.has_cloud_shadow，
		# 不再枚举 DROUGHT/HEATWAVE/FOG/CLEAR。
		var profile := WeatherProfileRegistry.get_profile(wt)
		if profile == null or not profile.has_cloud_shadow:
			sprite.visible = false
			continue
		sprite.visible = true
		sprite.position = _front_center(f)
		# 显示半径跟随锋面长短轴，圆盘贴图被拉成云影椭圆。
		var s: float = maxf(_front_radius(f), 1.0) / float(SHADOW_BASE_RADIUS_PX)
		sprite.rotation = _front_axis(f).angle()
		sprite.scale = Vector2(s * _front_major_scale(f), s * _front_minor_scale(f))
		# v-data-driven：颜色与 alpha 缩放全部来自 profile（BLIZZARD 偏白蓝、雨雷暗灰）。
		# MIX 模式下 alpha=0 的像素完全不叠加，只有圆内的像素参与混合。
		var modulate_col: Color = profile.cloud_shadow_color
		# TOD：云阴影 modulate.a *= (1 - 0.55 * night_factor)——夜晚略微收敛，
		# 但不能接近隐形，否则雨雪云影在夜晚几乎看不到。
		var night_scale: float = 1.0 - _tod_night_factor * 0.55
		var max_alpha: float = clampf(profile.cloud_shadow_alpha_scale, 0.0, 1.0)
		var visual_intensity: float = _front_visual_intensity(_front_intensity(f))
		modulate_col.a = clampf(
			visual_intensity * max_alpha * _strength * night_scale, 0.0, max_alpha
		)
		sprite.modulate = modulate_col

func _sync_particles_pool(fronts: Array) -> void:
	if _particles_pool.is_empty():
		return
	var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
	for i in range(MAX_WEATHER_FRONTS):
		var node: GPUParticles2D = _particles_pool[i]
		if i >= n:
			_disable_particle_slot(node, i)
			continue
		var f = fronts[i]
		var wt: int = _front_type(f)
		# v-data-driven：是否出粒子完全来自 profile.has_particles，不再判 type。
		var profile := WeatherProfileRegistry.get_profile(wt)
		if profile == null or not profile.has_particles:
			_disable_particle_slot(node, i)
			continue

		# 类型变了才重新配置 process_material（避免每帧重建）
		if _particles_type_cache[i] != wt:
			_configure_particles_for_type(node, wt)
			_particles_type_cache[i] = wt
			# Phase A 止血：换类型后强制重新下发 amount / visibility_rect
			# （新类型的合法范围可能与旧 cache 完全不同）
			_particles_amount_cache[i] = -1
			_particles_vis_radius_cache[i] = -1.0

		# 每次都更新位置 / emitter 半径 / intensity 调强度
		node.position = _front_center(f)
		# v9.perf：每个 slot 自己设 visibility_rect = ±radius，让引擎能正确剂除而不是
		# 默认那个 (-100,-100,200,200) 小框（front 半径常常远超 100）
		# Phase A 止血：仅当 bound_r 相对缓存值变化 > 5% 时才重写 visibility_rect，
		# 避免每帧因微小数值波动触发 Rect2 重新分配 / culler 重新评估。
		var r: float = maxf(_front_radius(f), 1.0)
		var bound_r: float = r * maxf(maxf(_front_major_scale(f), _front_minor_scale(f)), 1.0)
		var cached_vis_r: float = _particles_vis_radius_cache[i]
		if cached_vis_r <= 0.0 or absf(bound_r - cached_vis_r) > cached_vis_r * 0.05:
			node.visibility_rect = Rect2(-bound_r, -bound_r, bound_r * 2.0, bound_r * 2.0)
			_particles_vis_radius_cache[i] = bound_r
		# v-data-driven：降水密度制——amount 随覆盖面积缩放，所有阈值从 profile 取。
		# _rain_density_boost_enabled=false 时回落到全局常量下限（上一轮更保守的数值）。
		var area: float = PI * r * _front_major_scale(f) * r * _front_minor_scale(f)
		var lo: int
		var hi: int
		if _rain_density_boost_enabled:
			lo = profile.particle_amount_min
			hi = profile.particle_amount_max
		else:
			# 兼容：关闭 boost 时使用之前的保守上下限。
			var is_snow_fallback: bool = (wt == _WT_BLIZZARD)
			lo = _SNOW_AMOUNT_MIN if is_snow_fallback else _RAIN_AMOUNT_MIN
			hi = _SNOW_AMOUNT_MAX if is_snow_fallback else _RAIN_AMOUNT_MAX
		var desired: int = clampi(
			int(ceil(area * profile.particle_density_per_px2)), lo, hi
		)
		# Phase A 止血：amount 每帧 ±1 振荡会触发 GPUParticles 内部缓冲重建（明显卡顿）。
		# 仅当 |Δ| > 5 时才下发；这对应面积变化约 3%，肉眼不可察。
		var cached_amt: int = _particles_amount_cache[i]
		if cached_amt < 0 or absi(desired - cached_amt) > 5:
			node.amount = desired
			_particles_amount_cache[i] = desired
		var max_fall_speed: float = maxf(profile.particle_velocity_max, 1.0)
		var local_fall_budget: float = r * _front_minor_scale(f) * 1.15
		var bounded_lifetime: float = clampf(
			local_fall_budget / max_fall_speed,
			0.38,
			profile.particle_lifetime
		)
		if not is_equal_approx(node.lifetime, bounded_lifetime):
			node.lifetime = bounded_lifetime
		var pm := node.process_material as ParticleProcessMaterial
		if pm != null:
			pm.emission_box_extents = Vector3(
				r * _front_major_scale(f),
				r * _front_minor_scale(f),
				1.0
			)
		# 发射范围用材质的世界单位表达；节点只负责定位。
		# 不再缩放 GPUParticles2D，否则粒子速度和贴图也会被放大，雨雪会飞出天气区域。
		node.rotation = 0.0
		node.scale = Vector2.ONE
		# modulate.a 反映视觉强度；逻辑 intensity 仍保持原值，但表现层用非线性曲线
		# 抬高中低强度天气，避免雨雪刚生成/衰减后几乎不可见。
		var visual_intensity: float = _front_visual_intensity(_front_intensity(f))
		var precip_amount: float = _front_precip_amount(f)
		var alpha_fade: float = clampf(maxf(visual_intensity, precip_amount) / 0.10, 0.0, 1.0)
		var alpha: float = clampf(0.28 + precip_amount * 0.48, 0.0, 0.78) \
				* alpha_fade * _strength
		# TOD 染色：雨雪粒子是前景特效，不能像地表一样被夜晚二次压暗。
		# 使用带下限的 TOD 色温，只保留昼夜冷暖倾向，保证午夜雨雪仍然可读。
		var base_col: Color = profile.particle_base_color
		var night_particle_scale: float = 1.0 - 0.18 * _tod_night_factor
		var tint_r: float = _particle_tod_tint_component(_tod_sun_color.r, _tod_ambient_color.r)
		var tint_g: float = _particle_tod_tint_component(_tod_sun_color.g, _tod_ambient_color.g)
		var tint_b: float = _particle_tod_tint_component(_tod_sun_color.b, _tod_ambient_color.b)
		node.modulate = Color(
			clampf(base_col.r * tint_r * night_particle_scale * _tod_exposure, 0.0, 1.0),
			clampf(base_col.g * tint_g * night_particle_scale * _tod_exposure, 0.0, 1.0),
			clampf(base_col.b * tint_b * night_particle_scale * _tod_exposure, 0.0, 1.0),
			alpha * clampf(maxf(base_col.a, 0.72), 0.0, 1.0)
		)
		node.visible = true
		# v9.perf：从 DISABLED → INHERIT 才会真正开始 process / 渲染粒子
		node.process_mode = Node.PROCESS_MODE_INHERIT
		node.emitting = true
# v9.perf：把 slot 完整地"睡眠"掉（不可见 + 不 process + 标记类型缓存清零）
func _disable_particle_slot(node: GPUParticles2D, slot_idx: int) -> void:
	if node.emitting:
		node.emitting = false
	if node.visible:
		node.visible = false
	node.process_mode = Node.PROCESS_MODE_DISABLED
	_particles_type_cache[slot_idx] = _WT_CLEAR
	# Phase A 止血：slot 重新激活时强制下发 amount/visibility_rect。
	_particles_amount_cache[slot_idx] = -1
	_particles_vis_radius_cache[slot_idx] = -1.0

# ─── WeatherFront 表现层插值 ─────────────────────────────────────────────

func _reset_front_blend_state() -> void:
	_front_start_snapshots.clear()
	_front_target_snapshots.clear()
	_front_visual_snapshots.clear()
	_front_blend_elapsed = 0.0
	_front_blend_duration = 0.0
	_last_front_snapshot_time = -1.0
	_front_snapshot_interval_sec = _WEATHER_FRONT_INITIAL_BLEND_SEC
	_active_count = 0
	# ambient-shadow：reset 也走统一可见性判定，启用时仍保持 visible 让影子继续画。
	_refresh_visibility()
	_push_empty_fronts_to_overlay()
	_sync_shadow_pool([])
	_sync_particles_pool([])
	visual_fronts_changed.emit([])

func _make_front_snapshots(fronts: Array) -> Array:
	var snapshots: Array = []
	var n: int = mini(fronts.size(), MAX_WEATHER_FRONTS)
	for i in range(n):
		var f = fronts[i]
		snapshots.append({
			"center": _front_center(f),
			"radius": _front_radius(f),
			"velocity": _front_velocity(f),
			"type": _front_type(f),
			"intensity": _front_intensity(f),
			"axis": _front_axis(f),
			"major_scale": _front_major_scale(f),
			"minor_scale": _front_minor_scale(f),
			"cloud_amount": _front_cloud_amount(f),
			"precip_amount": _front_precip_amount(f),
			"dissolve_amount": _front_dissolve_amount(f),
			"life_progress": _front_life_progress(f),
		})
	return snapshots

func _align_front_blend_snapshots(start_candidates: Array, targets: Array) -> Array:
	var starts: Array = []
	var aligned_targets: Array = []
	var used: Array[bool] = []
	used.resize(start_candidates.size())
	for i in range(used.size()):
		used[i] = false

	for target in targets:
		var best_idx: int = -1
		var best_dist_sq: float = INF
		var best_candidate_radius: float = 0.0
		var target_center: Vector2 = _front_center(target)
		var target_radius: float = maxf(_front_radius(target), 1.0)
		for i in range(start_candidates.size()):
			if used[i]:
				continue
			var candidate = start_candidates[i]
			if _front_type(candidate) != _front_type(target):
				continue
			var dist_sq: float = _front_center(candidate).distance_squared_to(target_center)
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_idx = i
				best_candidate_radius = maxf(_front_radius(candidate), 1.0)
		var start
		# Continuity-fix（B）：匹配阈值从 1.5 × target_radius 放宽到
		# 2.5 × max(target_radius, candidate_radius)。
		# 旧阈值在 cluster split / merge / wind advect 一天位移 (≈0.4 × radius) +
		# 边界 cell 抖动（再 ±0.5 × radius）叠加后会顶不住——明明是同一朵云，
		# 因为重新聚类的中心移动 1.6 × radius 就被判定为"不同 front"。
		# 取 max 半径意味着大簇能拉近小簇做匹配，避免"split 出的小半"被误判为新生。
		#
		# 抽动修复（2026-05-18）：阈值再放宽到 4.0 × max_radius。
		# 实测在 forward-bias = 1.0~1.5 interval 下，target.center 已经被沿 velocity
		# 预推了"接近一整个半径"的距离，叠加 cluster 重聚类抖动可达 2-3 倍半径，
		# 2.5 还是不够；放到 4.0 能在大半径 front（如 MONSOON）下吸收几乎所有
		# 误判，代价仅是偶发把"刚好擦肩而过的两朵不同云"识别为同一朵——可接受。
		var match_radius: float = maxf(target_radius, best_candidate_radius) * 4.0
		if best_idx >= 0 and best_dist_sq <= match_radius * match_radius:
			used[best_idx] = true
			start = start_candidates[best_idx]
		else:
			start = target.duplicate(true)
			_fade_out_snapshot(start)
		starts.append(start)
		aligned_targets.append(target)

	for i in range(start_candidates.size()):
		if used[i]:
			continue
		var fading_start = start_candidates[i]
		var fading_target = fading_start.duplicate(true)
		_fade_out_snapshot(fading_target)
		starts.append(fading_start)
		aligned_targets.append(fading_target)

	return [starts, aligned_targets]

func _fade_out_snapshot(snapshot: Dictionary) -> void:
	snapshot["intensity"] = 0.0
	snapshot["cloud_amount"] = 0.0
	snapshot["precip_amount"] = 0.0
	snapshot["dissolve_amount"] = 1.0
	snapshot["life_progress"] = 1.0

func _update_weather_front_blend(delta: float) -> void:
	_front_blend_elapsed += maxf(delta, 0.0)
	var duration: float = maxf(_front_blend_duration, 0.0001)
	var raw_t: float = clampf(_front_blend_elapsed / duration, 0.0, 1.0)
	# 抽动修复（2026-05-18）：从 smoothstep 改为线性 t。
	# smoothstep 的 ease-in 会让每段 lerp 的前 ~25% 时长几乎不动，叠加每次 commit
	# 重置 _front_blend_elapsed=0 → 视觉上每隔一次 commit 就"顿一下、再起步"。
	# 线性 t 让云的视觉速度在两次 commit 之间恒定，配合 forward-bias 让首尾相接
	# 处的速度也连续——彻底消除"一抽一抽"的观感。
	var t: float = raw_t
	_front_visual_snapshots = _blend_front_snapshots(t)
	if raw_t >= 1.0:
		_front_target_snapshots = _filter_visible_front_snapshots(_front_target_snapshots)
		_front_start_snapshots = _front_target_snapshots.duplicate(true)
		_front_visual_snapshots = _front_target_snapshots.duplicate(true)
		if _front_target_snapshots.is_empty():
			_front_start_snapshots.clear()
			_front_visual_snapshots.clear()
			_front_blend_elapsed = 0.0
			_front_blend_duration = 0.0
		else:
			var extra_days: float = clampf(
				(_front_blend_elapsed - _front_blend_duration) / maxf(_front_snapshot_interval_sec, 0.001),
				0.0,
				_WEATHER_FRONT_MAX_PREDICT_DAYS
			)
			if extra_days > 0.0:
				_front_visual_snapshots = _predict_front_snapshots(_front_visual_snapshots, extra_days)
	_active_count = mini(_front_visual_snapshots.size(), MAX_WEATHER_FRONTS)
	_refresh_visibility()
	_push_fronts_to_overlay(_front_visual_snapshots)
	_sync_shadow_pool(_front_visual_snapshots)
	_sync_particles_pool(_front_visual_snapshots)
	visual_fronts_changed.emit(_front_visual_snapshots)

func _filter_visible_front_snapshots(snapshots: Array) -> Array:
	var filtered: Array = []
	for snapshot in snapshots:
		if _front_intensity(snapshot) > 0.001:
			filtered.append(snapshot)
	return filtered

func _blend_front_snapshots(t: float) -> Array:
	var visual: Array = []
	var n: int = mini(
		maxi(_front_start_snapshots.size(), _front_target_snapshots.size()),
		MAX_WEATHER_FRONTS
	)
	for i in range(n):
		var has_start: bool = i < _front_start_snapshots.size()
		var has_target: bool = i < _front_target_snapshots.size()
		if not has_start and not has_target:
			continue
		var start = _front_start_snapshots[i] if has_start else null
		var target = _front_target_snapshots[i] if has_target else null
		if start == null and target != null:
			start = target.duplicate(true)
			start["intensity"] = 0.0
		elif target == null and start != null:
			target = start.duplicate(true)
			target["intensity"] = 0.0
		var center: Vector2 = _front_center(start).lerp(_front_center(target), t)
		var radius: float = lerpf(_front_radius(start), _front_radius(target), t)
		var velocity: Vector2 = _front_velocity(start).lerp(_front_velocity(target), t)
		var intensity: float = lerpf(_front_intensity(start), _front_intensity(target), t)
		var axis := _blend_axis(_front_axis(start), _front_axis(target), t)
		var major_scale: float = lerpf(_front_major_scale(start), _front_major_scale(target), t)
		var minor_scale: float = lerpf(_front_minor_scale(start), _front_minor_scale(target), t)
		var cloud_amount: float = lerpf(_front_cloud_amount(start), _front_cloud_amount(target), t)
		var precip_amount: float = lerpf(_front_precip_amount(start), _front_precip_amount(target), t)
		var dissolve_amount: float = lerpf(_front_dissolve_amount(start), _front_dissolve_amount(target), t)
		var life_progress: float = lerpf(_front_life_progress(start), _front_life_progress(target), t)
		if intensity <= 0.001 and t >= 1.0:
			continue
		visual.append({
			"center": center,
			"radius": radius,
			"velocity": velocity,
			"type": _front_type(target),
			"intensity": clampf(intensity, 0.0, 1.0),
			"axis": axis,
			"major_scale": major_scale,
			"minor_scale": minor_scale,
			"cloud_amount": clampf(cloud_amount, 0.0, 1.0),
			"precip_amount": clampf(precip_amount, 0.0, 1.0),
			"dissolve_amount": clampf(dissolve_amount, 0.0, 1.0),
			"life_progress": clampf(life_progress, 0.0, 1.0),
		})
	return visual

func _predict_front_snapshots(snapshots: Array, prediction_days: float) -> Array:
	var predicted: Array = []
	for snapshot in snapshots:
		var p = snapshot.duplicate(true)
		p["center"] = _front_center(p) + _front_velocity(p) * prediction_days
		predicted.append(p)
	return predicted

func _front_center(front) -> Vector2:
	if front is Dictionary:
		return front.get("center", Vector2.ZERO)
	return front.center

func _front_radius(front) -> float:
	if front is Dictionary:
		return float(front.get("radius", 0.0))
	return float(front.radius)

func _front_velocity(front) -> Vector2:
	if front is Dictionary:
		return front.get("velocity", Vector2.ZERO)
	return front.velocity

func _front_type(front) -> int:
	if front is Dictionary:
		return int(front.get("type", _WT_CLEAR))
	return int(front.type)

func _front_intensity(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("intensity", 0.0)), 0.0, 1.0)
	return clampf(float(front.intensity), 0.0, 1.0)

func _front_axis(front) -> Vector2:
	var ax: Vector2 = Vector2.RIGHT
	if front is Dictionary:
		ax = front.get("axis", Vector2.RIGHT)
	elif front.has_method("normalized_axis"):
		ax = front.normalized_axis()
	if ax.length_squared() <= 0.0001:
		return Vector2.RIGHT
	return ax.normalized()

func _front_major_scale(front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("major_scale", 1.0)), 0.05)
	return maxf(float(front.major_scale), 0.05)

func _front_minor_scale(front) -> float:
	if front is Dictionary:
		return maxf(float(front.get("minor_scale", 1.0)), 0.05)
	return maxf(float(front.minor_scale), 0.05)

func _front_cloud_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("cloud_amount", _front_visual_intensity(_front_intensity(front)))), 0.0, 1.0)
	return clampf(float(front.cloud_amount), 0.0, 1.0)

func _front_precip_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("precip_amount", _front_visual_intensity(_front_intensity(front)))), 0.0, 1.0)
	return clampf(float(front.precip_amount), 0.0, 1.0)

func _front_dissolve_amount(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("dissolve_amount", 0.0)), 0.0, 1.0)
	return clampf(float(front.dissolve_amount), 0.0, 1.0)

func _front_life_progress(front) -> float:
	if front is Dictionary:
		return clampf(float(front.get("life_progress", 0.0)), 0.0, 1.0)
	return clampf(float(front.life_progress), 0.0, 1.0)

func _blend_axis(a: Vector2, b: Vector2, t: float) -> Vector2:
	var aa := a.normalized() if a.length_squared() > 0.0001 else Vector2.RIGHT
	var bb := b.normalized() if b.length_squared() > 0.0001 else aa
	if aa.dot(bb) < 0.0:
		bb = -bb
	var out := aa.lerp(bb, t)
	if out.length_squared() <= 0.0001:
		return aa
	return out.normalized()

func _front_visual_intensity(raw_intensity: float) -> float:
	var i: float = clampf(raw_intensity, 0.0, 1.0)
	if i <= 0.0:
		return 0.0
	# 逻辑强度用于数值系统；视觉强度用幂曲线抬高中低段，同时在 0 附近
	# 保持淡出，避免刚清空的 front 留下残影。
	return clampf(pow(i, 0.55) * smoothstep(0.0, 0.08, i), 0.0, 1.0)

func _particle_tod_tint_component(sun_component: float, ambient_component: float) -> float:
	var night_t: float = clampf(_tod_night_factor, 0.0, 1.0)
	var sun_visible: float = lerpf(clampf(sun_component, 0.0, 1.25), 1.0, 0.45)
	var ambient_visible: float = lerpf(clampf(ambient_component, 0.0, 1.25), 1.0, 0.35)
	var tint: float = lerpf(sun_visible, ambient_visible, night_t * 0.35)
	var floor_value: float = lerpf(0.82, 0.58, night_t)
	return clampf(maxf(tint, floor_value), 0.0, 1.15)

# ─── 内部 ─────────────────────────────────────────────────────────────────

func _load_overlay_shader() -> void:
	var shader := ResourceLoader.load(OVERLAY_SHADER_PATH, "Shader",
		ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("WeatherLayer: shader not found at %s" % OVERLAY_SHADER_PATH)
		return
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = shader
	_overlay_quad.material = _overlay_mat

# ─── 云阴影池初始化 ──────────────────────────────────────────────────────
# 生成一张共享的 radial-fade alpha 圆盘贴图（白色 RGB + 渐变 alpha），
# 配合 BLEND_MIX 材质 + per-sprite 的半透明深色 modulate 实现"云投影压暗"效果。
#
# 历史坑（已修复）：原先用 BLEND_MODE_MUL。MUL 模式下 src.alpha 不参与混合，
# Godot 会把 sprite.modulate.rgb 直接乘到纹理 RGB 上再乘底色，即使圆盘贴图四角
# alpha=0，modulate 的暗色也会把整张 quad 的矩形包围盒范围压暗，
# 在地图上就表现为醒目的"黑色透明矩形"。
# 改为 MIX 后，四角 alpha=0 的像素完全不叠加，只有圆内的像素参与混合。

func _init_shadow_pool() -> void:
	# Fix #7C (2026-06-15): mobile 完全跳过云阴影 Sprite 池。
	# 注意：_sync_shadow_pool (line 605-612) 已是 dead code（云阴影现在在
	# weather_overlay shader 内画），所有 sprite 永远 invisible。但
	# _init_shadow_pool 仍构造 16 个 Sprite2D + 1 张 256x256 alpha 圆盘贴图
	# （~262KB VRAM）+ 添加到 SceneTree。mobile 跳过这些 setup 省启动 hitch
	# + 16 个永久不可见节点的 culling 评估开销。
	# _sync_shadow_pool 入口 `if _shadow_pool.is_empty(): return` 保证空池安全。
	if OS.has_feature("mobile"):
		_shadow_pool.clear()
		return
	_shadow_texture = _build_radial_fade_texture(SHADOW_BASE_RADIUS_PX)
	_shadow_material = CanvasItemMaterial.new()
	_shadow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	_shadow_pool.clear()
	for i in range(MAX_WEATHER_FRONTS):
		var sprite := Sprite2D.new()
		sprite.name = "Shadow_%d" % i
		sprite.texture = _shadow_texture
		sprite.material = _shadow_material
		sprite.centered = true
		sprite.visible = false
		sprite.z_as_relative = true
		sprite.z_index = 0
		_shadow_root.add_child(sprite)
		_shadow_pool.append(sprite)

# 生成 (2*radius_px) × (2*radius_px) 的 RGBA8 云影贴图：
#   - rgb 全白（被 sprite.modulate 染色）
#   - alpha = 低频团块噪声 × 径向软边，避免没有细节的圆盘阴影
# v9.perf：用 PackedByteArray + create_from_data 一次性写完，
# 替换之前 65k 次 Image.set_pixel(Color(...)) 的启动 hitch
func _build_radial_fade_texture(radius_px: int) -> ImageTexture:
	var size := radius_px * 2
	var pixel_count := size * size
	var data := PackedByteArray()
	data.resize(pixel_count * 4)  # RGBA8
	var center: float = float(radius_px) - 0.5
	var inv_r := 1.0 / float(radius_px)
	var idx := 0
	for y in range(size):
		var dy := float(y) - center
		var dy2 := dy * dy
		for x in range(size):
			var dx := float(x) - center
			var d := sqrt(dx * dx + dy2) * inv_r
			var radial: float = smoothstep(1.0, 0.0, d)
			var nx: float = float(x) / float(size)
			var ny: float = float(y) / float(size)
			var n1: float = _value_noise_2d(nx * 5.0 + 13.7, ny * 5.0 - 9.3)
			var n2: float = _value_noise_2d(nx * 10.0 - 31.1, ny * 10.0 + 27.5)
			var n3: float = _value_noise_2d(nx * 18.0 + 3.2, ny * 18.0 + 41.0)
			var cloud: float = n1 * 0.58 + n2 * 0.30 + n3 * 0.12
			cloud = smoothstep(0.34, 0.78, cloud)
			var a: float = pow(radial, 1.35) * lerpf(0.34, 1.0, cloud)
			var ai: int = int(clampf(a, 0.0, 1.0) * 255.0)
			data[idx]     = 255
			data[idx + 1] = 255
			data[idx + 2] = 255
			data[idx + 3] = ai
			idx += 4
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)

func _value_noise_2d(x: float, y: float) -> float:
	var ix: int = floori(x)
	var iy: int = floori(y)
	var fx: float = x - float(ix)
	var fy: float = y - float(iy)
	var ux: float = fx * fx * (3.0 - 2.0 * fx)
	var uy: float = fy * fy * (3.0 - 2.0 * fy)
	var a: float = _hash_noise_2d(ix, iy)
	var b: float = _hash_noise_2d(ix + 1, iy)
	var c: float = _hash_noise_2d(ix, iy + 1)
	var d: float = _hash_noise_2d(ix + 1, iy + 1)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)

func _hash_noise_2d(ix: int, iy: int) -> float:
	var n: int = ix * 374761393 + iy * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0

# ─── 粒子池初始化 ────────────────────────────────────────────────────────
# 16 个 GPUParticles2D，每个有自己的 ParticleProcessMaterial（避免共享导致全部 front
# 用一份配置）。process_material 的 emission_sphere_radius / direction / lifetime
# 在 _sync_particles_pool 里根据 front type 调整。

# v-data-driven：每种天气的 amount / lifetime / texture / process_material
# 全部来自 WeatherProfile；不再在 _init_particles_pool 里写死。
# _particles_pool 中每个节点保持未赋材质状态，由 _configure_particles_for_type 首次切换时赋值。

func _init_particles_pool() -> void:
	# Fix #7B (2026-06-15): mobile 完全跳过 GPU 粒子池构造。
	# log_next.txt 实测 fronts=12 时 primitives 1644→5418，~3700 增量主要来自
	# 12 个 GPUParticles2D 实例（每个 amount=80-900 粒子，按 area 缩放）。
	# Adreno 830 上 GPUParticles 内部 visibility_rect / process_material 切换
	# 累积明显帧消耗。雨/雪视觉降级为 weather_overlay shader 内的 streak/grain
	# effect（line 405-460 那段），mobile 玩家仍能看到天气表现。
	# _sync_particles_pool 入口的 `if _particles_pool.is_empty(): return` 守卫
	# 保证空池不会触发 NPE。
	if OS.has_feature("mobile"):
		_fallback_particle_texture = _build_fallback_particle_texture()
		_process_material_cache.clear()
		_particles_pool.clear()
		_particles_type_cache.clear()
		_particles_amount_cache.clear()
		_particles_vis_radius_cache.clear()
		return
	_fallback_particle_texture = _build_fallback_particle_texture()
	_process_material_cache.clear()
	_particles_pool.clear()
	_particles_type_cache.clear()
	_particles_amount_cache.clear()
	_particles_vis_radius_cache.clear()
	for i in range(MAX_WEATHER_FRONTS):
		var p := GPUParticles2D.new()
		p.name = "Particles_%d" % i
		p.amount = 80  # 占位，_configure_particles_for_type 会覆盖为 profile.particle_amount_min
		p.lifetime = 1.6
		p.preprocess = 0.0  # v9.perf：preprocess 启动时一次性 GPU 模拟，对每个 slot 都跑代价大；改为 0
		p.one_shot = false
		p.explosiveness = 0.0
		p.emitting = false
		p.visible = false
		p.local_coords = false
		p.z_as_relative = true
		p.z_index = 0
		# v9.perf：闲置粒子完全停 process，避免 16 个常驻 GPUParticles 每帧 GPU/CPU 开销
		p.process_mode = Node.PROCESS_MODE_DISABLED
		# 不预设 process_material / texture——首次 _configure_particles_for_type 才赋。
		_particles_root.add_child(p)
		_particles_pool.append(p)
		_particles_type_cache.append(_WT_CLEAR)
		_particles_amount_cache.append(-1)        # -1 = 强制首次写入
		_particles_vis_radius_cache.append(-1.0)  # 同上

# v-data-driven：每个 slot 在第一次切换 type 时调用（避免每帧重建）。
# 所有参数从 WeatherProfile 读取；process_material 每个 slot 独立，
# 这样 _sync_particles_pool 可以按 front 的长短轴写发射盒，互不覆盖。
func _configure_particles_for_type(node: GPUParticles2D, wt: int) -> void:
	var profile := WeatherProfileRegistry.get_profile(wt)
	if profile == null:
		return
	node.amount = maxi(profile.particle_amount_min, 1)
	node.lifetime = profile.particle_lifetime
	node.process_material = _build_process_material_from_profile(profile)
	var tex: Texture2D = profile.particle_texture
	if tex == null:
		tex = _fallback_particle_texture
	node.texture = tex

# 构造 per-weather ParticleProcessMaterial，从 profile 字段逐一填入。
# emission_box_extents 由 _sync_particles_pool 按每个 front 的长短轴更新。
func _build_process_material_from_profile(profile: WeatherProfile) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3.ONE
	pm.direction = profile.particle_direction
	pm.spread = profile.particle_spread
	pm.gravity = profile.particle_gravity
	pm.initial_velocity_min = profile.particle_velocity_min
	pm.initial_velocity_max = profile.particle_velocity_max
	pm.angular_velocity_min = profile.particle_angular_velocity_min
	pm.angular_velocity_max = profile.particle_angular_velocity_max
	pm.scale_min = profile.particle_scale_min
	pm.scale_max = profile.particle_scale_max
	pm.color = profile.particle_base_color
	return pm

# 懒加载 + 缓存：每种 WeatherType 至多一份 ParticleProcessMaterial。
func _get_or_build_process_material(wt: int) -> ParticleProcessMaterial:
	if _process_material_cache.has(wt):
		return _process_material_cache[wt]
	var profile := WeatherProfileRegistry.get_profile(wt)
	if profile == null or not profile.has_particles:
		return null
	var pm := _build_process_material_from_profile(profile)
	_process_material_cache[wt] = pm
	return pm

# 兜底贴图：1×1 全白 RGBA8，当 profile.particle_texture 为 null 时使用，
# 避免空引用崩溃（需求 3.5）。
func _build_fallback_particle_texture() -> ImageTexture:
	var data := PackedByteArray([255, 255, 255, 255])
	var img := Image.create_from_data(1, 1, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)

func _build_full_quad(bounds: Rect2) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	var verts := PackedVector2Array([
		p,
		p + Vector2(s.x, 0.0),
		p + s,
		p + Vector2(0.0, s.y),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
