# tod_profile.gd
# Time-of-Day (TOD) 全局光照中枢 —— 画面表现第二轮深化（任务 1）
#
# 单一职责：
#   输入 day_phase（0.0=日出 / 0.25=正午 / 0.5=日落 / 0.75=午夜）
#   输出一组稳定字段：sun_dir、sun_color、ambient_color、sky_tint、exposure、night_factor
#
# 这是整个画面表现层的 "唯一太阳源"：HexRenderer / WeatherLayer / UI 都从这里读
# TOD 参数，禁止自行从 day_phase 推导色温或日光方向（day_phase 仅用于动画相位）。
#
# 约束（来自需求 1.4 / 决策记录 5）：
#   * day_night_enabled == false 时强制输出永昼参数，保证回退
#   * 不在此处做节流——默认逐帧重算，若需要可由 WorldClock.day_phase_emit_step 控制
#   * 所有数值都来自 @export 曲线参数，main.gd 注入后可运行时调参

class_name TODProfile
extends RefCounted

# ─── 时相关键帧色板（内部常量） ────────────────────────────────────────
# 参考真实户外摄影色温：日出冷橙 → 正午白 → 日落暖橙 → 午夜冷蓝月光。
# sun_dir 只在水平方位上摆动，不做"地平线下"的 y<0 翻面；Z 轴提供固定
# 倾角让法线方向光永远能照到向南 / 向北的坡面。
const SUN_COLOR_SUNRISE: Color   = Color(1.00, 0.72, 0.42)   # 暖橙（地平线色）
const SUN_COLOR_NOON: Color      = Color(1.00, 0.97, 0.92)   # 正午偏白
const SUN_COLOR_SUNSET: Color    = Color(1.00, 0.66, 0.36)   # 日落深橙
const SUN_COLOR_MIDNIGHT: Color  = Color(0.65, 0.72, 0.90)   # 月光冷白偏蓝

const AMBIENT_NOON: Color        = Color(0.70, 0.75, 0.82)
const AMBIENT_DUSK: Color        = Color(0.45, 0.42, 0.52)
const AMBIENT_MIDNIGHT: Color    = Color(0.22, 0.28, 0.42)

const SKY_TINT_NOON: Color       = Color(0.82, 0.90, 1.00)
const SKY_TINT_DUSK: Color       = Color(0.92, 0.62, 0.48)
const SKY_TINT_MIDNIGHT: Color   = Color(0.18, 0.22, 0.38)

const PHASE_SUNRISE: float = 0.0
const PHASE_NOON: float = 0.25
const PHASE_SUNSET: float = 0.5
const PHASE_MIDNIGHT: float = 0.75

# 永昼（day_night_enabled==false）时的固定参数
const FALLBACK_SUN_DIR: Vector3  = Vector3(0.4, -0.7, 0.6)
const FALLBACK_SUN_COLOR: Color  = Color(1.0, 1.0, 1.0)
const FALLBACK_AMBIENT: Color    = Color(0.65, 0.68, 0.75)
const FALLBACK_SKY_TINT: Color   = Color(0.82, 0.90, 1.00)

# ─── 对外暴露字段（shader uniform 消费这些） ───────────────────────────
# sun_dir：指向光源的单位向量（约定：shader 把它当作 TBN 空间下的入射光方向）
var sun_dir: Vector3 = FALLBACK_SUN_DIR
var sun_color: Color = FALLBACK_SUN_COLOR
var ambient_color: Color = FALLBACK_AMBIENT
var sky_tint: Color = FALLBACK_SKY_TINT
var exposure: float = 1.0
# night_factor ∈ [0, 1]，0=完全白天，1=完全夜晚（供 shader 做过渡插值）
var night_factor: float = 0.0

# ─── 曲线参数（由 main.gd 注入，对应需求 2） ───────────────────────────
# daylight_ratio：白天占全天的比例；默认 0.65 时，日照围绕
# 0.0=日出、0.25=正午、0.5=日落展开，夜晚峰值仍在 0.75=午夜。
var daylight_ratio: float = 0.65
# 夜晚段 night_factor 的上下限：防止夜晚太黑导致玩家无法操作（需求 2.2）
var night_factor_min: float = 0.55
var night_factor_max: float = 0.72
# 全局曝光（需求 7.5 新增开关）
var tod_exposure: float = 1.0

# 信号：每次 recompute 完成发射一次，消费者 connect 即可同步 shader uniform
signal tod_changed(profile: TODProfile)

# ─── 公共 API ─────────────────────────────────────────────────────────

# 重新计算一组 TOD 参数。
#   day_phase: 0.0~1.0，来自 WorldClock.day_phase()
#   day_night_enabled: 为 false 时强制输出永昼参数
# 计算完成后通过 tod_changed 信号广播。
func recompute(day_phase: float, day_night_enabled: bool = true) -> void:
	if not day_night_enabled:
		sun_dir = FALLBACK_SUN_DIR
		sun_color = FALLBACK_SUN_COLOR
		ambient_color = FALLBACK_AMBIENT
		sky_tint = FALLBACK_SKY_TINT
		exposure = tod_exposure
		night_factor = 0.0
		tod_changed.emit(self)
		return

	# 规范化到 [0, 1)
	var dp: float = fposmod(day_phase, 1.0)

	# ── 第一步：把 day_phase 重映射为"光照相位"（需求 2.1）
	# day_phase 是环形值：0.0=日出，0.25=正午，0.5=日落，0.75=午夜。
	# daylight_ratio 仍决定一次昼夜里"可见日照"的总长度；当白天较长时，
	# 日出过渡会落在 1.0→0.0 回绕前后，所以所有区间判断都必须支持环形相位。
	# 旧实现把负数 sunrise_start 直接拿来线性比较，导致相位回到 0.0 时误判为白天，
	# 表现为 UI 到零点附近画面突然变亮。
	var ratio: float = clampf(daylight_ratio, 0.2, 0.9)
	var day_half: float = ratio * 0.5
	var transition: float = minf(0.05, day_half * 0.5)
	var sunrise_start: float = PHASE_NOON - day_half
	var sunrise_end: float = sunrise_start + transition
	var sunset_end: float = PHASE_NOON + day_half
	var sunset_start: float = sunset_end - transition

	# ── 第二步：推导 night_factor（0=白天，1=夜晚）。
	# 夜晚段跨越相位回绕，必须用环形区间判断，保证午夜前后连续。
	var nf: float = 0.0
	if _phase_in_wrapped_range(dp, sunrise_start, sunrise_end):
		# 日出过渡：1→0（smoothstep），可能横跨 1.0→0.0。
		var sunrise_t: float = _phase_inverse_lerp_wrap(sunrise_start, sunrise_end, dp)
		nf = 1.0 - smoothstep(0.0, 1.0, sunrise_t)
	elif _phase_in_wrapped_range(dp, sunrise_end, sunset_start):
		# 白天中段：完全白天
		nf = 0.0
	elif _phase_in_wrapped_range(dp, sunset_start, sunset_end):
		# 日落过渡：0→1
		var sunset_t: float = _phase_inverse_lerp_wrap(sunset_start, sunset_end, dp)
		nf = smoothstep(0.0, 1.0, sunset_t)
	else:
		# 夜晚段：[sunset_end, sunrise_start]，保持夜间强度，直到日出过渡再淡出。
		nf = 1.0

	# 连续映射到 night_factor：nf=0 时严格为 0，避免日落/日出边界出现硬跳；
	# nf=1 时达到 night_factor_max，中间段使用 night_factor_min 作为夜色下限参考。
	if nf > 0.0001:
		var nf_curve: float = smoothstep(0.0, 1.0, nf)
		night_factor = nf_curve * lerpf(night_factor_min, night_factor_max, nf)
	else:
		night_factor = 0.0

	# ── 第三步：根据时相插值 sun_color / ambient / sky_tint
	if _phase_in_wrapped_range(dp, sunrise_start, sunrise_end):
		# 日出：午夜冷蓝 → 日出暖橙，跨相位回绕连续过渡。
		var color_sunrise_t: float = smoothstep(
			0.0, 1.0, _phase_inverse_lerp_wrap(sunrise_start, sunrise_end, dp)
		)
		sun_color = SUN_COLOR_MIDNIGHT.lerp(SUN_COLOR_SUNRISE, color_sunrise_t)
		ambient_color = AMBIENT_MIDNIGHT.lerp(AMBIENT_DUSK, color_sunrise_t)
		sky_tint = SKY_TINT_MIDNIGHT.lerp(SKY_TINT_DUSK, color_sunrise_t)
	elif _phase_in_wrapped_range(dp, sunrise_end, PHASE_NOON):
		# 上午：日出暖橙 → 正午白；长白天时该区间也可能跨越 1.0→0.0。
		var morning_t: float = smoothstep(
			0.0, 1.0, _phase_inverse_lerp_wrap(sunrise_end, PHASE_NOON, dp)
		)
		sun_color = SUN_COLOR_SUNRISE.lerp(SUN_COLOR_NOON, morning_t)
		ambient_color = AMBIENT_DUSK.lerp(AMBIENT_NOON, morning_t)
		sky_tint = SKY_TINT_DUSK.lerp(SKY_TINT_NOON, morning_t)
	elif _phase_in_wrapped_range(dp, PHASE_NOON, sunset_start):
		# 白天中段：正午色
		sun_color = SUN_COLOR_NOON
		ambient_color = AMBIENT_NOON
		sky_tint = SKY_TINT_NOON
	elif _phase_in_wrapped_range(dp, sunset_start, sunset_end):
		# 日落：正午白 → 深橙
		var color_sunset_t: float = smoothstep(
			0.0, 1.0, _phase_inverse_lerp_wrap(sunset_start, sunset_end, dp)
		)
		sun_color = SUN_COLOR_NOON.lerp(SUN_COLOR_SUNSET, color_sunset_t)
		ambient_color = AMBIENT_NOON.lerp(AMBIENT_DUSK, color_sunset_t)
		sky_tint = SKY_TINT_NOON.lerp(SKY_TINT_DUSK, color_sunset_t)
	elif _phase_in_wrapped_range(dp, sunset_end, PHASE_MIDNIGHT):
		# 深夜前半段：日落后 → 午夜
		var night_t: float = smoothstep(
			0.0, 1.0, _phase_inverse_lerp_wrap(sunset_end, PHASE_MIDNIGHT, dp)
		)
		sun_color = SUN_COLOR_SUNSET.lerp(SUN_COLOR_MIDNIGHT, night_t)
		ambient_color = AMBIENT_DUSK.lerp(AMBIENT_MIDNIGHT, night_t)
		sky_tint = SKY_TINT_DUSK.lerp(SKY_TINT_MIDNIGHT, night_t)
	else:
		# 午夜后半段：保持午夜冷色，直到日出过渡开始，避免 1.0→0.0 颜色跳变。
		sun_color = SUN_COLOR_MIDNIGHT
		ambient_color = AMBIENT_MIDNIGHT
		sky_tint = SKY_TINT_MIDNIGHT

	# 夜晚 sun_color 幅度再压 50%（保留方向性但不刺眼）——需求 2.3
	if night_factor > 0.0:
		sun_color = sun_color * (1.0 - 0.5 * night_factor)

	# ── 第四步：太阳方向（方位角随 day_phase 做 180° 扫掠）
	# 日出时 sun_dir 指向东方（+X），日落时指向西方（-X），午夜绕到背面。
	# 约定 2D 场景下 shader 把 sun_dir.xy 当作法线空间里的水平方向投影、
	# sun_dir.z 为固定高度分量。
	var sun_angle: float = (dp - 0.25) * TAU   # dp=0.25 时 angle=0（正午从头顶照下）
	var horiz: float = cos(sun_angle) * 0.8    # 水平分量：正午时为 0（头顶），日出/日落时达到 ±0.8
	var vert: float  = sin(sun_angle)          # 竖直分量：正午 +1.0（头顶光），午夜 -1.0
	# 把 y 翻面（Godot 2D 屏幕 y 向下为正）并限制最小 z 分量，避免"光从地下来"。
	sun_dir = Vector3(horiz, -vert, 0.55).normalized()

	exposure = tod_exposure

	tod_changed.emit(self)

func _phase_in_wrapped_range(value: float, start: float, end: float) -> bool:
	var v: float = fposmod(value, 1.0)
	var s: float = fposmod(start, 1.0)
	var e: float = fposmod(end, 1.0)
	if s <= e:
		return v >= s and v <= e
	return v >= s or v <= e

func _phase_inverse_lerp_wrap(start: float, end: float, value: float) -> float:
	var s: float = fposmod(start, 1.0)
	var e: float = fposmod(end, 1.0)
	var v: float = fposmod(value, 1.0)
	var span: float = fposmod(e - s, 1.0)
	if span < 0.0001:
		return 1.0
	var offset: float = fposmod(v - s, 1.0)
	return clampf(offset / span, 0.0, 1.0)

# ─── 调参接口（main.gd 按 @export 值注入） ────────────────────────────

func configure(
		p_daylight_ratio: float,
		p_night_factor_min: float,
		p_night_factor_max: float,
		p_tod_exposure: float
) -> void:
	daylight_ratio = clampf(p_daylight_ratio, 0.2, 0.9)
	night_factor_min = clampf(p_night_factor_min, 0.0, 1.0)
	night_factor_max = clampf(p_night_factor_max, night_factor_min, 1.0)
	tod_exposure = maxf(p_tod_exposure, 0.1)
