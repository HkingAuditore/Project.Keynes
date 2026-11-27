extends SceneTree

# Headless：
#   cd Project/project-keynes
#   godot --headless -s tests/world/weather_overlay_field_test.gd
#
# 守的契约：docs/plans/terrain-cell-field-overlays-plan.md
#   §3.4（天气 overlay 采样流程）/ §3.5（类型怎么处理）/ §3.7（迷雾门控与迷雾显示共用函数）
#   §3.9（采样与 sampler 账）/ §4（天气**独立**开关，第一版 Web 也能开）
#
# 为什么单独一个文件而不是塞进 terrain_shader_variant_test.gd：
#   1) 这是**另一份 program**（canvas_item 全屏 quad），与地形的 sampler 普查基线无关，
#      塞进去会把 368 条基线和天气的 8→2 混在一起，回退时看不出是哪一侧变的；
#   2) 这里要多做一次**真实编译**矩阵（PK_WEB_WEATHER_MIN + PK_CELL_FIELD、四套移动 tier
#      前缀），地形那份没有这些前缀形状；
#   3) 与并行推进的迷雾（O3）改 terrain_shader_variant_test.gd 时不会互相冲突。
#
# 断言分四层（全部是非恒真的）：
#   A. **sampler 普查**：PK_CELL_FIELD 开 = 恰好 2 张（cell_table + weather_table，逐名）；
#      关 = 8 张（今天的旧路径，逐名）。用引擎的 uniform 反射数，不按名字后缀数。
#   B. **展开后符号缺席 / 在场**：PK 变体里不许出现 map_index / Bayer / 副格 / 6 邻环 /
#      weather_lut_prev；宏关时这些符号**必须**在（否则缺席断言就是恒真）。
#   C. **源级声明守卫**：weather_table 是 sampler2DArray + filter_nearest + **无 source_color**；
#      旧 LUT 声明在 `#ifndef PK_CELL_FIELD` 块里。
#   D. **GDScript 侧**：独立开关（默认关、独立于地形）、翻转真的重建变体前缀、
#      新 uniform 确实被推送。
#
# 注意：本文件不验证"任意缩放无方块 / 移动端开销 ≤1.15×"（方案 §6 的视觉与帧时间判据）——
# 那两条要开窗口 + 真机矩阵，属于 W5 / 移动端实机验收，headless 里只能保证结构与采样账。

const SHADER_PATH := "res://shaders/weather_overlay.gdshader"
const WEB_MIN_PATH := "res://shaders/include/weather_overlay_web_min.gdshaderinc"
const WeatherLayerScript = preload("res://scripts/rendering/weather_layer.gd")
## [O23 2026-11-18] 迷雾门控参数的唯一真源（本文件只读它的常量，不写字面量）。
const FogOfWarLayerScript = preload("res://scripts/rendering/fog_of_war_layer.gd")

## 前缀：桌面高档（= 非 cheap-noise 的完整路径）。
const PREFIX_DESKTOP := "#define PK_WEATHER_HIGH\n"
## Web 裁剪变体（ANGLE 首帧编译预算）+ 场函数。
const PREFIX_WEB := "#define PK_WEATHER_HIGH\n#define PK_WEB_WEATHER_MIN\n"
## 四套移动 tier 前缀（与 weather_layer._shader_quality_define_prefix 同形状）。
const MOBILE_PREFIXES := {
	"mobile_low": "#define PK_WEATHER_LOW\n#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
	"mobile_mid": "#define PK_WEATHER_MID\n#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
	"mobile_high": "#define PK_WEATHER_HIGH\n#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
}

## 旧路径（PK_CELL_FIELD 关）今天的 8 张 sampler，逐名。
const LEGACY_SAMPLERS := [
	"enum_lut",
	"map_index_atlas",
	"terrain_edge_distance_tex",
	"terrain_edge_neighbor_tex",
	"weather_lut",
	"weather_lut_prev",
	"wind_lut",
	"wind_lut_prev",
]
## 场函数路径唯一的 2 张（方案 §3.9「sampler ≈ 8 → 2」）。
const FIELD_SAMPLERS := [
	"cell_table",
	"weather_table",
]
## PK 变体里必须**消失**的符号（方案 §3.4 末段：Bayer 选格 / 副格间接寻址 / 6 邻环全删）。
## 每条都是旧路径真实引用过的调用形式，不是"看起来像"的名字。
const FIELD_FORBIDDEN_SYMBOLS := [
	"visual_sample_map_index(",
	"texture(enum_lut",
	"decode_cell_index(",
	"wx_mobile_dither_uv_threshold",
	"wx_edge_secondary_weight",
	"weather_lut_prev",
	"wind_lut_prev",
	"wx_sample_lut(",
	"hex_east",
]

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	# 本机 core.autocrlf=true：工作树可能是 CRLF，跨行 needle 断言会随 checkout 飘。
	source = source.replace("\r\n", "\n")
	_expect(not source.is_empty(), "weather overlay shader source loads")
	_expect(source.contains("PK_CELL_FIELD"),
		"weather overlay knows the PK_CELL_FIELD switch")
	_expect(source.contains("cell_field_overlays.gdshaderinc"),
		"field path consumes the shared cell-field overlay glue")

	_check_sampler_census(source)
	_check_expanded_symbols()
	_check_declaration_source_guards(source)
	_check_web_min_include()
	_check_fog_gate_contract(source)
	await _check_weather_layer_switch()
	print("=== weather overlay field: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# ─────────────────────────────────────────────────────────────────────────────
# A. sampler 普查（方案 §3.9：8 → 2）
# ─────────────────────────────────────────────────────────────────────────────
func _check_sampler_census(source: String) -> void:
	var legacy := _sampler_census(PREFIX_DESKTOP + source)
	var field := _sampler_census(PREFIX_DESKTOP + "#define PK_CELL_FIELD\n" + source)
	_expect(not legacy["uniforms"].is_empty() and not field["uniforms"].is_empty(),
		"both variants compile in the shader language (off=%d / on=%d uniforms)"
			% [Array(legacy["uniforms"]).size(), Array(field["uniforms"]).size()])

	var expected_off: PackedStringArray = _sorted(LEGACY_SAMPLERS)
	_expect(int(legacy["count"]) == expected_off.size()
		and PackedStringArray(legacy["names"]) == expected_off,
		"macro off keeps today's %d samplers, name for name (got %d: %s)"
			% [expected_off.size(), int(legacy["count"]), str(legacy["names"])])

	var expected_on: PackedStringArray = _sorted(FIELD_SAMPLERS)
	_expect(int(field["count"]) == 2,
		"PK_CELL_FIELD drops the weather overlay to exactly 2 samplers (got %d: %s)"
			% [int(field["count"]), str(field["names"])])
	_expect(PackedStringArray(field["names"]) == expected_on,
		"PK_CELL_FIELD samplers are exactly [cell_table, weather_table] (got %s)"
			% str(field["names"]))
	for name in FIELD_SAMPLERS:
		_expect(String(field["kinds"].get(name, "")) == "sampler2DArray",
			"%s is a sampler2DArray (per-cell tables are 1 texel = 1 cell)" % name)

	# Web 裁剪变体 + 场函数：sampler 同样只能是 2（方案 §4「第一版 Web 也能开」）。
	var web := _sampler_census(PREFIX_WEB + "#define PK_CELL_FIELD\n" + source)
	_expect(not Array(web["uniforms"]).is_empty(),
		"PK_WEB_WEATHER_MIN + PK_CELL_FIELD compiles (uniforms=%d)"
			% Array(web["uniforms"]).size())
	_expect(PackedStringArray(web["names"]) == expected_on,
		"web-min + field keeps the same 2 samplers (got %s)" % str(web["names"]))

	# tiled 与场函数正交：场函数路径不读 UV / 纹素地址，所以 MAP_VISUAL_TILED 只是空宏。
	var tiled := _sampler_census(
		"#define PK_WEATHER_HIGH\n#define MAP_VISUAL_TILED\n#define PK_CELL_FIELD\n" + source)
	_expect(not Array(tiled["uniforms"]).is_empty(),
		"MAP_VISUAL_TILED + PK_CELL_FIELD compiles (uniforms=%d)"
			% Array(tiled["uniforms"]).size())
	_expect(PackedStringArray(tiled["names"]) == expected_on,
		"tiled + field keeps the same 2 samplers (got %s)" % str(tiled["names"]))

	# 四套移动 tier 前缀 + 场函数：每套都必须编得过且仍是 2 张。
	for label in MOBILE_PREFIXES:
		var prefix := String(MOBILE_PREFIXES[label])
		var mobile := _sampler_census(prefix + "#define PK_CELL_FIELD\n" + source)
		_expect(not Array(mobile["uniforms"]).is_empty(),
			"%s + PK_CELL_FIELD compiles (uniforms=%d)"
				% [label, Array(mobile["uniforms"]).size()])
		_expect(PackedStringArray(mobile["names"]) == expected_on,
			"%s + PK_CELL_FIELD keeps 2 samplers (got %s)" % [label, str(mobile["names"])])
		# 旧路径在同一前缀下仍是 8 张：证明"减下来的"确实是本任务的改动。
		var mobile_legacy := _sampler_census(prefix + source)
		_expect(int(mobile_legacy["count"]) == expected_off.size(),
			"%s legacy path keeps %d samplers (got %d)"
				% [label, expected_off.size(), int(mobile_legacy["count"])])


# ─────────────────────────────────────────────────────────────────────────────
# B. 展开后符号：PK 变体缺席 / 宏关在场（两条方向都必须非恒真）
# ─────────────────────────────────────────────────────────────────────────────
func _check_expanded_symbols() -> void:
	# 桌面高档（未定义 PK_MOBILE_ANY）：这样旧路径里的 6 邻环 / 副格 / Bayer 块才**在**展开
	# 文本里 —— 反向断言才有意义（定义了 PK_MOBILE_ANY 的话那几段会被预处理器剔掉，
	# "宏关时符号在"就变成假失败）。
	var off := _expand_shader(SHADER_PATH, {"PK_WEATHER_HIGH": true})
	var on := _expand_shader(SHADER_PATH, {
		"PK_CELL_FIELD": true,
		"PK_WEATHER_HIGH": true,
	})
	_expect(off.length() > 4000 and on.length() > 4000 and off != on,
		"the preprocessor expands both variants and the define changes the token stream"
			+ " (%d vs %d chars)" % [off.length(), on.length()])

	for symbol in FIELD_FORBIDDEN_SYMBOLS:
		_expect(not on.contains(String(symbol)),
			"PK variant does not reference `%s`" % symbol)
		# 反向断言：宏关时这些符号必须在，否则上一条就是恒真的空断言。
		_expect(off.contains(String(symbol)),
			"macro-off variant still references `%s` (mirror assertion is not vacuous)"
				% symbol)

	# 新路径确实在调用共享场函数，而不是"删干净了什么也没干"。
	for needle in ["pk_hex_tri(", "pk_overlay_tri(", "pk_soft_warp_tiled(",
			"pk_overlay_fog_k(", "pk_overlay_fog_visibility(", "pk_hex_sharpen(",
			"texelFetch(weather_table", "texelFetch(cell_table"]:
		_expect(on.contains(String(needle)),
			"PK variant calls `%s`" % needle)
		_expect(not off.contains(String(needle)),
			"macro-off variant does not call `%s`" % needle)

	# 固定 3 次读取、展开写、无循环（方案 §3.9 第 2 条）。计数含 helper 的**定义**那一行
	# （`vec4 wx_fetch_weather(ivec2 ...)` 也含 `wx_fetch_weather(`）：
	#   天气 3 cur + 3 prev = 6 个调用点  ⇒ 7
	#   风   3 cur + 3 prev = 6 个调用点  ⇒ 7
	#   迷雾 k 3 个调用点                  ⇒ 4
	#   profile 查表 3 个调用点            ⇒ 4
	#   低雾山地权重 3 个调用点            ⇒ 4
	var expected_counts := {
		"wx_fetch_weather(": 7,
		"wx_fetch_wind(": 7,
		"wx_fetch_fog_k(": 4,
		"wx_profile_row(": 4,
		"wx_biome_mountain_weight(": 4,
	}
	for needle in expected_counts:
		var got := on.count(String(needle))
		_expect(got == int(expected_counts[needle]),
			"`%s` has exactly %d occurrences in the PK variant (3 three-cell taps,"
				% [needle, int(expected_counts[needle])]
			+ " unrolled) — got %d" % got)
	# 场函数路径里不能出现"按格循环"：3 次读取必须是展开的源码，不是 for 里跑 3 遍。
	var pk_body := _extract_region(on, "FrontField sample_field_weather(vec2 world_pos)",
		"\n#endif // PK_CELL_FIELD")
	_expect(not pk_body.is_empty(), "the field-path sample_field_weather body is locatable")
	_expect(pk_body.length() > 1000, "field-path sample_field_weather is not a stub")
	_expect(not pk_body.contains("for ("),
		"field-path sample_field_weather contains no loop (fixed 3 taps)")


# ─────────────────────────────────────────────────────────────────────────────
# C. 源级声明守卫（与展开无关的不变量）
# ─────────────────────────────────────────────────────────────────────────────
func _check_declaration_source_guards(source: String) -> void:
	# weather_table 的声明形态：sampler2DArray + filter_nearest + **不许 source_color**。
	# source_color 会让引擎按 sRGB 预乘/解码，R=weather_type 的字节就被改了。
	var table_decl := "uniform sampler2DArray weather_table : filter_nearest, repeat_disable;"
	_expect(source.contains(table_decl),
		"weather_table is declared as sampler2DArray with filter_nearest, repeat_disable")
	_expect(not source.contains("weather_table : source_color"),
		"weather_table must not carry source_color (R is a weather type byte, not a colour)")
	var table_line := ""
	for line in source.split("\n"):
		if String(line).begins_with("uniform sampler2DArray weather_table"):
			table_line = String(line)
	_expect(not table_line.contains("source_color"),
		"the weather_table declaration line has no source_color (line: `%s`)" % table_line)
	_expect(source.contains("uniform sampler2DArray cell_table : filter_nearest, repeat_disable;"),
		"cell_table is a nearest sampler as well (fog k is a per-cell byte)")

	# 旧 LUT 声明必须在 `#ifndef PK_CELL_FIELD` 块里 —— 只有这样"宏关 8 张 / 宏开 2 张"
	# 才是声明层的差别，而不是运行期分支。
	var guard_at := source.find("#ifndef PK_CELL_FIELD")
	var legacy_decl_at := source.find("uniform sampler2D weather_lut :")
	_expect(guard_at >= 0 and legacy_decl_at >= 0 and guard_at < legacy_decl_at,
		"legacy weather_lut declaration sits inside the `#ifndef PK_CELL_FIELD` block")
	_expect(source.contains("#include \"res://shaders/include/visual_tile_sampling.gdshaderinc\""),
		"legacy path keeps the visual tile sampling include")
	var vt_at := source.find("#define VT_USE_MAP_INDEX")
	_expect(vt_at >= 0 and guard_at < vt_at,
		"VT_USE_MAP_INDEX (the map_index sampler) is also guarded by `#ifndef PK_CELL_FIELD`")

	# 新增 uniform 必须在（方案 §3.4 的清单），且都由宿主推送。
	for name in ["hex_size", "map_dims", "cell_table", "cell_table_size", "cell_table_bound",
			"weather_table", "weather_table_size", "weather_table_bound",
			"weather_cur_layer", "weather_prev_layer", "weather_warp_freq",
			"weather_warp_amp", "fog_field_band"]:
		_expect(_has_uniform_decl(source, String(name)),
			"the field path declares `uniform ... %s ...`" % name)

	# §3.5 的判定结论编码成断言：读完 compute_cloud_lighting 的函数体，它**从来不按
	# type 分支/染色**（"云层光照不按天气类型染色/压暗"），所以彻底把 int 参数删掉，
	# 而不是传一个 wt_dom 进去当摆设。若将来有人加回按类型的 tint 分支，这两条会红。
	_expect(source.contains("vec3 compute_cloud_lighting(CloudLayerSample layer, vec3 base_tint,"
		+ " float light_grad, float thickness, float silver_gain, vec3 sun_col, vec3 amb_col,"
		+ " float local_day)"),
		"compute_cloud_lighting takes no weather-type integer (方案 §3.5：先查表再混结果)")
	_expect(not source.contains("compute_cloud_lighting(CloudLayerSample layer, vec3 base_tint, int"),
		"the legacy `int wt` parameter is really gone")
	_expect(not source.contains("w.type"),
		"no downstream reads the dominant type any more (best.type is diagnostics only)")

	# hex_world_diameter 不得被新代码用来推 hex 尺寸（方案 §1.4 / §3.2 第 2 条）：
	# 场函数网格必须直接吃 hex_size uniform，且网格函数里不出现 hex_world_diameter。
	_expect(source.contains("g.hex_size = max(hex_size, 1e-3);"),
		"the field grid takes hex_size straight from its own uniform")
	var grid_body := _extract_region(source, "PkHexGrid wx_field_grid()", "\n}")
	_expect(not grid_body.is_empty(), "wx_field_grid() body is locatable")
	_expect(not grid_body.contains("hex_world_diameter"),
		"wx_field_grid() never derives the cell size from hex_world_diameter")
	_expect(source.count("hex_world_diameter") > 0,
		"hex_world_diameter is still there for the untouched noise advection scale"
			+ " (%d references)" % source.count("hex_world_diameter"))


# ─────────────────────────────────────────────────────────────────────────────
# Web 裁剪变体：只换噪声栈，不许再引用 map_index / enum_lut
# ─────────────────────────────────────────────────────────────────────────────
func _check_web_min_include() -> void:
	var web_min_raw := FileAccess.get_file_as_string(WEB_MIN_PATH).replace("\r\n", "\n")
	_expect(not web_min_raw.is_empty(), "web-min include loads")
	# 断言只看**代码**：文件头的注释里提到 map_index / enum_lut 是在解释"为什么不能用"，
	# 按原文 grep 会把说明文字当成引用（本文件的第一次跑就是这么假红的）。
	var web_min := _strip_shader_comments(web_min_raw)
	_expect(not web_min.contains("map_index"),
		"web-min include never touches map_index (the field path has no atlas)")
	_expect(not web_min.contains("enum_lut"),
		"web-min include never touches enum_lut (fog k comes from cell_table)")
	_expect(not web_min.contains("uniform sampler"),
		"web-min include declares no sampler of its own")
	_expect(not web_min.contains("texture("),
		"web-min include does no texture sampling at all (it only replaces the noise stack)")
	_expect(web_min_raw.contains("cloud_density_soft_min")
		and web_min_raw.contains("sample_cirrus_band_min"),
		"web-min include keeps its cheap-noise entry points")


# ─────────────────────────────────────────────────────────────────────────────
# E. [O23 2026-11-18] 迷雾门控 = 迷雾显示：同一个函数 + **同一组参数**
#   守的是方案 §3.7 的硬要求：云的消失边界与迷雾薄纱边界必须是同一条线。
#   "函数一致、参数不一致" 仍然会错开（k 的取样位置由扭曲决定），所以这里同时守三件事：
#     ① 三个参数只有**一个**定义处（fog_of_war_layer.gd），weather_layer 只引用；
#     ② 两份 shader 的 PK_CELL_FIELD 变体里，k 的三角形来自同一串函数、同一批参数名，
#        而且天气云的 weather_warp_* 不得出现在 k 的构造里；
#     ③ GDScript 侧推给材质的值与真源**相等**（不是"注释里说要相等"）。
# ─────────────────────────────────────────────────────────────────────────────
func _check_fog_gate_contract(source: String) -> void:
	var layer_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/weather_layer.gd").replace("\r\n", "\n")
	var material_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/weather_layer_material_publish.gd").replace("\r\n", "\n")
	var fog_layer_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/fog_of_war_layer.gd").replace("\r\n", "\n")
	var fog_shader := FileAccess.get_file_as_string(
		"res://shaders/fog_of_war.gdshader").replace("\r\n", "\n")
	_expect(not layer_source.is_empty() and not material_source.is_empty()
			and not fog_layer_source.is_empty()
			and not fog_shader.is_empty(),
		"weather_layer / fog_of_war_layer / fog shader sources all load")

	# ── E1 单一真源（源级）────────────────────────────────────────────────────
	_expect(layer_source.contains(
		"const FogOfWarLayerScript = preload(\"res://scripts/rendering/fog_of_war_layer.gd\")"),
		"weather_layer reads the fog gate params from fog_of_war_layer.gd (the single source)")
	_expect(not layer_source.contains("FOG_FIELD_BAND_DEFAULT")
		and not material_source.contains("FOG_FIELD_BAND_DEFAULT"),
		"the duplicated FOG_FIELD_BAND_DEFAULT constant is really gone from weather_layer")
	_expect(layer_source.contains(
		"var _fog_field_band: float = FogOfWarLayerScript.FOG_FIELD_BAND"),
		"the band member is initialised from the source of truth (no 0.6 literal)")
	_expect(material_source.contains(
		"set_shader_parameter(\"fog_warp_freq\", WeatherLayer.FogOfWarLayerScript.FOG_WARP_FREQ)")
		and material_source.contains(
		"set_shader_parameter(\"fog_warp_amp\", WeatherLayer.FogOfWarLayerScript.FOG_WARP_AMP)"),
		"both fog warp uniforms are pushed straight from FogOfWarLayer constants")

	# 逐行：凡是提到这三个参数的**代码行**，值必须来自真源（或由真源初始化的成员）。
	# 这条能真的失败 —— 把 push 改回 0.0042 / 0.55 会在这里被点名。
	var offenders: Array = []
	var param_lines := 0
	for raw_line in _non_comment_lines(layer_source + "\n" + material_source):
		var text := String(raw_line)
		if not (text.contains("fog_field_band") or text.contains("fog_warp_freq")
				or text.contains("fog_warp_amp")):
			continue
		param_lines += 1
		if not (text.contains("FogOfWarLayerScript.") or text.contains("_fog_field_band")):
			offenders.append(text.strip_edges())
	_expect(param_lines >= 3,
		"weather_layer still has the fog gate parameter lines (%d found)" % param_lines)
	_expect(offenders.is_empty(),
		"every fog gate parameter line reads FogOfWarLayer (offenders: %s)" % str(offenders))

	# 无环形依赖：fog_of_war_layer.gd 的 preload 里没有 weather_layer.gd。
	var fog_preloads := _preload_paths(fog_layer_source)
	_expect(not fog_preloads.is_empty(),
		"fog_of_war_layer.gd's preloads are locatable (%s)" % str(fog_preloads))
	_expect(not fog_preloads.has("res://scripts/rendering/weather_layer.gd"),
		"fog_of_war_layer.gd never preloads weather_layer.gd (weather→fog stays one-way, no cycle)")

	# ── E2 值相等：两个 program 的同名 uniform 都是真源那个数（与美术调参无关）────
	# 直接读真源的常量（不写字面量）⇒ 将来改美术参数时这条断言自动跟随，仍然"同一条线"。
	var fog_gate_values := {
		"fog_field_band": FogOfWarLayerScript.FOG_FIELD_BAND,
		"fog_warp_freq": FogOfWarLayerScript.FOG_WARP_FREQ,
		"fog_warp_amp": FogOfWarLayerScript.FOG_WARP_AMP,
	}
	var fog_gate_sources := {
		"fog_field_band": "FOG_FIELD_BAND",
		"fog_warp_freq": "FOG_WARP_FREQ",
		"fog_warp_amp": "FOG_WARP_AMP",
	}
	for uniform_name in fog_gate_values:
		var owner_value := float(fog_gate_values[uniform_name])
		var source_name := String(fog_gate_sources[uniform_name])
		var weather_default := _uniform_default(source, String(uniform_name))
		var fog_default := _uniform_default(fog_shader, String(uniform_name))
		_expect(is_equal_approx(weather_default, owner_value),
			"weather overlay uniform %s default == FogOfWarLayer.%s (%.6f vs %.6f)"
				% [uniform_name, source_name, weather_default, owner_value])
		_expect(is_equal_approx(fog_default, owner_value),
			"fog shader uniform %s default == FogOfWarLayer.%s (%.6f vs %.6f)"
				% [uniform_name, source_name, fog_default, owner_value])

	# ── E3 shader 源级：k 的三角形只由 fog_warp_* / fog_field_band 决定 ──────────
	var on := _expand_shader(SHADER_PATH, {"PK_WEATHER_HIGH": true, "PK_CELL_FIELD": true})
	var off := _expand_shader(SHADER_PATH, {"PK_WEATHER_HIGH": true})
	var gate_head := "if (fog_mask_enabled && cell_table_bound) {"
	var gate_block := _extract_region(on, gate_head, "fog_vis = pk_overlay_fog_visibility(fog_k);")
	_expect(not gate_block.is_empty() and gate_block.length() > 200,
		"the PK variant's fog gate block is locatable (%d chars)" % gate_block.length())
	for needle in ["fog_warp_freq", "fog_warp_amp", "fog_field_band"]:
		_expect(gate_block.contains(String(needle)),
			"the fog gate block reads `%s` (the fog layer's parameter, not the weather one)"
				% needle)
	_expect(not gate_block.contains("weather_warp"),
		"the fog gate block builds k's triangle WITHOUT weather_warp_* (that is the cloud's"
			+ " own shape parameter, unrelated to fog)")
	# 逐字：k 的三角形与迷雾显示走同一串调用。
	for needle in ["pk_soft_warp_tiled(wp, wrap_period_x, fog_warp_freq, fog_warp_amp * hex_size)",
			"pk_overlay_fog_tri(wp, g, wx_clamp_length(ws_fog, fog_amax))",
			"pk_overlay_fog_weights(t_fog, g, fog_band)",
			"pk_overlay_fog_k(w_fog,"]:
		_expect(gate_block.contains(String(needle)),
			"the fog gate block calls `%s`" % needle)
	# 旧形态（k 用天气自己的三角形 t）必须真的消失了，否则上一条可以靠"两个都留着"通过。
	_expect(not on.contains("wx_fetch_fog_k(t.c0"),
		"k is no longer sampled from the weather triangle's cells (t.c0/c1/c2)")
	# 带宽与长度上限都取自同一个 band ⇒ 与迷雾侧约束 1 / 约束 2 同一口径。
	var amax_expr := "max(PK_HEX_SQRT3 * 0.5 - fog_band * 0.5, 0.0) * hex_size"
	_expect(gate_block.contains(amax_expr),
		"the weather k triangle length-clamps to the same A_max expression as the fog shader")
	_expect(_strip_shader_comments(fog_shader).contains(amax_expr),
		"the fog shader really uses that same A_max expression (mirror assertion)")
	# 同一串函数、同一顺序：两份 program 的 k 构造序列必须一样（函数名 + 相对顺序）。
	var fog_block := _extract_region(_strip_shader_comments(fog_shader),
		"vec2 fog_warp_raw = pk_soft_warp_tiled(", "fog_k_debug = k;")
	_expect(not fog_block.is_empty(),
		"the fog shader's k construction block is locatable (%d chars)" % fog_block.length())
	var k_sequence := ["pk_soft_warp_tiled(", "pk_overlay_fog_tri(", "pk_overlay_fog_weights(",
		"pk_overlay_fog_k(", "pk_overlay_fog_edge_k("]
	var fog_positions: Array = []
	var weather_positions: Array = []
	for fn_name in k_sequence:
		fog_positions.append(fog_block.find(String(fn_name)))
		weather_positions.append(gate_block.find(String(fn_name)))
	for i in range(k_sequence.size()):
		_expect(int(fog_positions[i]) >= 0 and int(weather_positions[i]) >= 0,
			"both programs call `%s` to build k (fog@%d weather@%d)"
				% [k_sequence[i], int(fog_positions[i]), int(weather_positions[i])])
	_expect(_is_strictly_increasing(fog_positions)
			and _is_strictly_increasing(weather_positions),
		"both programs call that pipeline in the SAME order (fog=%s weather=%s)"
			% [str(fog_positions), str(weather_positions)])

	# ── E4 宏关时必须逐字节不变：新符号一个都不许漏进旧路径 ────────────────────
	for needle in ["fog_warp_freq", "fog_warp_amp", "wx_clamp_length", "t_fog",
			"fog_amax"]:
		_expect(not off.contains(String(needle)),
			"macro-off variant carries none of the new symbols (`%s` absent)" % needle)
		_expect(on.contains(String(needle)),
			"PK variant carries `%s` (the mirror assertion is not vacuous)" % needle)


# ─────────────────────────────────────────────────────────────────────────────
# 工具：给上面的 O23 断言用（都只做源码分析，不需要 GPU）
# ─────────────────────────────────────────────────────────────────────────────

## 去掉 `#` 注释行后的代码行（`##` / `#` 都算注释；缩进保留）。
func _non_comment_lines(source: String) -> Array:
	var out: Array = []
	for line in source.split("\n"):
		var trimmed := String(line).strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		out.append(String(line))
	return out


## 从 shader 源码里读某个 uniform 的**默认值**（`uniform float name : hint = X;` 的 X）。
## 找不到时返回 NAN（is_equal_approx(NAN, x) 恒假 ⇒ 断言会红，不会静默通过）。
func _uniform_default(source: String, name: String) -> float:
	for line in source.split("\n"):
		var text := String(line).strip_edges()
		if not text.begins_with("uniform "):
			continue
		if not _has_uniform_decl(text, name):
			continue
		var eq := text.find("=")
		if eq < 0:
			return NAN
		return float(text.substr(eq + 1).split(";")[0].strip_edges())
	return NAN


## 一个文件里所有 preload("res://...") 的路径（按出现顺序）。
func _preload_paths(source: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cursor := 0
	while true:
		var at := source.find("preload(\"res://", cursor)
		if at < 0:
			break
		var start := at + "preload(\"".length()
		var end := source.find("\"", start)
		if end < 0:
			break
		out.append(source.substr(start, end - start))
		cursor = end
	return out


func _is_strictly_increasing(values: Array) -> bool:
	for i in range(1, values.size()):
		if int(values[i]) <= int(values[i - 1]):
			return false
	return true


# ─────────────────────────────────────────────────────────────────────────────
# D. GDScript 侧：独立开关 + 变体重建 + 新 uniform 推送
# ─────────────────────────────────────────────────────────────────────────────
func _check_weather_layer_switch() -> void:
	var layer_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/weather_layer.gd").replace("\r\n", "\n")
	var material_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/weather_layer_material_publish.gd").replace("\r\n", "\n")
	# 开关的项目设置键：与地形**不同**的键（独立开关，方案 §4）。
	_expect(WeatherLayerScript.CELL_FIELD_SETTING
		== "project_keynes/rendering/map_tiles/weather_cell_field_enabled",
		"weather cell field uses its own project setting (got %s)"
			% WeatherLayerScript.CELL_FIELD_SETTING)
	_expect(WeatherLayerScript.CELL_FIELD_SETTING != HexRenderer.CELL_FIELD_SETTING,
		"the weather switch is independent from the terrain switch")
	_expect(layer_source.contains("@export var weather_cell_field_enabled: bool = true"),
		"the export ships enabled (2026-11-18 收尾：出货默认开)")
	_expect(not layer_source.contains("weather_cell_field_enabled = cell_field_boot_allows"),
		"the weather switch is not gated by the web boot verdict (方案 §4：第一版 Web 可开)")
	for needle in ["set_shader_parameter(\"hex_size\"", "set_shader_parameter(\"map_dims\"",
			"set_shader_parameter(\"cell_table\"", "set_shader_parameter(\"cell_table_size\"",
			"set_shader_parameter(\"cell_table_bound\""]:
		_expect(material_source.contains(String(needle)),
			"weather_layer pushes `%s`" % needle)

	# [2026-11-18] 出货默认**开**。本组验的是「开 / 关两态的前缀与重建」，
	# 所以先把**项目设置**临时置 false 再建 layer（`_init()` 读设置作 export 初值），
	# 这样 `mat_off` 真的是关态。走设置而不是走 export setter：setter 会立刻触发一次
	# 材质重建，而那正是本组后面要断言的行为。
	var had_setting := ProjectSettings.has_setting(WeatherLayerScript.CELL_FIELD_SETTING)
	var old_setting = ProjectSettings.get_setting(WeatherLayerScript.CELL_FIELD_SETTING, true)
	ProjectSettings.set_setting(WeatherLayerScript.CELL_FIELD_SETTING, false)
	_expect(not WeatherLayerScript.cell_field_setting_enabled(),
		"an explicit false project setting really reaches the resolver (override wins)")

	var weather := WeatherLayerScript.new()
	root.add_child(weather)
	await process_frame
	var mat_off: ShaderMaterial = weather.get("_overlay_mat")
	_expect(mat_off != null and mat_off.shader != null, "the layer builds an overlay material")
	var code_off := String(mat_off.shader.code) if mat_off != null and mat_off.shader != null else ""
	_expect(code_off.contains("#define PK_WEATHER_"), "overlay prefix starts with a quality tier")
	# ⚠ 只能断言**前缀**，不能断言整个 shader.code：文件正文里的 `#ifndef PK_CELL_FIELD`
	# 本来就含这个名字（那是守卫，不是 define）。
	var prefix_off := _prefix_of(code_off)
	_expect(not prefix_off.contains("#define PK_CELL_FIELD"),
		"default (off) prefix carries no PK_CELL_FIELD ⇒ byte-identical to today")

	weather.set("weather_cell_field_enabled", true)
	await process_frame
	var mat_on: ShaderMaterial = weather.get("_overlay_mat")
	var code_on := String(mat_on.shader.code) if mat_on != null and mat_on.shader != null else ""
	_expect(mat_on != null and mat_on != mat_off,
		"flipping the switch rebuilds the material (define is compile-time)")
	var prefix_on := _prefix_of(code_on)
	_expect(prefix_on.contains("#define PK_CELL_FIELD\n"),
		"flipped prefix defines PK_CELL_FIELD")
	_expect(prefix_on.begins_with("#define PK_WEATHER_"),
		"the quality tier define stays first (cloud_weather_quality_test asserts begins_with)")

	# [O23 2026-11-18] 同一组迷雾门控参数真的被推到**天气材质**上，值等于真源。
	# 这是"参数不是靠注释对齐，而是靠同一个常量"的运行期证据（get_shader_parameter，
	# 不是 grep 源码）；fog 材质那一侧的镜像断言在 fog_cell_field_test.gd 的 B2 组。
	for entry in [["fog_field_band", FogOfWarLayerScript.FOG_FIELD_BAND, "FOG_FIELD_BAND"],
			["fog_warp_freq", FogOfWarLayerScript.FOG_WARP_FREQ, "FOG_WARP_FREQ"],
			["fog_warp_amp", FogOfWarLayerScript.FOG_WARP_AMP, "FOG_WARP_AMP"]]:
		var uniform_name := String(entry[0])
		var owner_value := float(entry[1])
		var got: Variant = mat_on.get_shader_parameter(uniform_name)
		_expect(got != null and is_equal_approx(float(got), owner_value),
			"the weather material carries %s = FogOfWarLayer.%s (got %s vs %.6f)"
				% [uniform_name, String(entry[2]), str(got), owner_value])
	# 天气云自己的形态参数仍来自它自己的常量（两个 uniform 不是同一个槽、也不是同一个真源）。
	for entry in [["weather_warp_freq", WeatherLayerScript.WEATHER_WARP_FREQ_DEFAULT,
			"WEATHER_WARP_FREQ_DEFAULT"],
			["weather_warp_amp", WeatherLayerScript.WEATHER_WARP_AMP_DEFAULT,
			"WEATHER_WARP_AMP_DEFAULT"]]:
		var wname := String(entry[0])
		var wowner := float(entry[1])
		var wgot: Variant = mat_on.get_shader_parameter(wname)
		_expect(wgot != null and is_equal_approx(float(wgot), wowner),
			"the cloud shape parameter %s is still owned by WeatherLayer.%s (got %s vs %.6f)"
				% [wname, String(entry[2]), str(wgot), wowner])

	weather.set("weather_cell_field_enabled", false)
	await process_frame
	var mat_back: ShaderMaterial = weather.get("_overlay_mat")
	var code_back := String(mat_back.shader.code) if mat_back != null and mat_back.shader != null else ""
	_expect(_prefix_of(code_back) == prefix_off,
		"flipping back restores the legacy prefix byte for byte")
	weather.queue_free()
	# 还原项目设置（出货默认开），否则同进程里后续断言会看到被改过的状态。
	if had_setting:
		ProjectSettings.set_setting(WeatherLayerScript.CELL_FIELD_SETTING, old_setting)
	else:
		ProjectSettings.set_setting(WeatherLayerScript.CELL_FIELD_SETTING, null)
	_expect(WeatherLayerScript.cell_field_setting_enabled(),
		"the project setting is back to the shipped default (enabled) after the run")


## shader.code = 前缀（#define …）+ 整个文件源码。取 `shader_type` 之前的部分当"前缀"。
func _prefix_of(code: String) -> String:
	var at := code.find("shader_type")
	return code.substr(0, at) if at >= 0 else code


# ─── 工具 ────────────────────────────────────────────────────────────────────

func _sorted(names: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for name in names:
		out.append(String(name))
	out.sort()
	return out


## 一次 program 的 sampler 普查：判据是引擎的 uniform 反射（sampler = TYPE_OBJECT，
## 2D 与 array 的区别在 hint_string），**不看名字后缀**、也不数"源码里出现过"。
## 与 tests/world/terrain_shader_variant_test.gd::_sampler_census 同一口径。
func _sampler_census(code: String) -> Dictionary:
	var shader := Shader.new()
	shader.code = code
	var sampler_names := PackedStringArray()
	var uniform_names := PackedStringArray()
	var kinds := {}
	for entry in shader.get_shader_uniform_list():
		var entry_name := String(entry.get("name", ""))
		uniform_names.append(entry_name)
		if int(entry.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		sampler_names.append(entry_name)
		var hint_text := String(entry.get("hint_string", ""))
		kinds[entry_name] = "sampler2D" if hint_text == "Texture2D" \
			else ("sampler2DArray" if hint_text == "TextureLayered" else "unknown(%s)" % hint_text)
	sampler_names.sort()
	uniform_names.sort()
	return {
		"count": sampler_names.size(),
		"names": sampler_names,
		"kinds": kinds,
		"uniforms": uniform_names,
	}


## 源码里是否存在 `uniform ... <name> ...` 的声明行（按行首 `uniform` 判，不靠"文件里出现过
## 这个名字"——后者会被注释和调用点满足，是恒真的空断言）。
func _has_uniform_decl(source: String, name: String) -> bool:
	for line in source.split("\n"):
		var text := String(line).strip_edges()
		if not text.begins_with("uniform "):
			continue
		# 去掉类型与 hint 片段后再按"名字是独立 token"判。
		var body := text.substr("uniform ".length()).split(":")[0].split("=")[0]
		for token in body.replace("[", " ").replace("]", " ").split(" ", false):
			if String(token) == name:
				return true
	return false


func _extract_region(text: String, head: String, tail: String) -> String:
	var at := text.find(head)
	if at < 0:
		return ""
	var end_at := text.find(tail, at)
	if end_at < 0:
		end_at = text.length()
	return text.substr(at, end_at - at)


## 极简 shader 预处理器（只服务本文件的"展开后符号"断言）。与
## terrain_shader_variant_test.gd::_expand_shader 同实现同边界：递归展开 include；求值
## `#ifdef / #ifndef / #if defined(X) && !defined(Y)`；剥注释；记 `#define X`。认不出的
## 条件表达式按"两支都算"的保守并集 —— 并集只会让文本更长，所以**缺席**断言不会被它
## 蒙成恒真（最坏情况是偏严而失败，不会假绿）。
func _expand_shader(path: String, defines: Dictionary) -> String:
	var out: Array = []
	_expand_into(path, defines.duplicate(), out, 0)
	return "\n".join(out)


func _expand_into(path: String, defines: Dictionary, out: Array, depth: int) -> void:
	if depth > 16:
		return
	var raw := FileAccess.get_file_as_string(path)
	if raw.is_empty():
		return
	var text := _strip_shader_comments(raw.replace("\r\n", "\n").replace("\r", "\n"))
	var stack: Array = []
	for line in text.split("\n"):
		var trimmed := String(line).strip_edges()
		var active := true
		if not stack.is_empty():
			active = bool(stack[stack.size() - 1]["active"])
		if not trimmed.begins_with("#"):
			if active:
				out.append(line)
			continue
		var body := trimmed.substr(1).strip_edges()
		var head := body
		var rest := ""
		var sep := body.find(" ")
		if sep >= 0:
			head = body.substr(0, sep)
			rest = body.substr(sep + 1).strip_edges()
		match head:
			"ifdef":
				_push_cond(stack, active, defines.has(rest), false)
			"ifndef":
				_push_cond(stack, active, not defines.has(rest), false)
			"if":
				var cond_value := _eval_cond(rest, defines)
				_push_cond(stack, active, cond_value != 0, cond_value < 0)
			"elif":
				if stack.is_empty():
					continue
				var elif_frame: Dictionary = stack[stack.size() - 1]
				if bool(elif_frame["union"]) or not bool(elif_frame["parent"]):
					continue
				if bool(elif_frame["taken"]):
					elif_frame["active"] = false
				var elif_value := _eval_cond(rest, defines)
				if elif_value < 0:
					elif_frame["union"] = true
					elif_frame["active"] = true
				else:
					elif_frame["active"] = elif_value != 0
					elif_frame["taken"] = elif_value != 0
			"else":
				if stack.is_empty():
					continue
				var else_frame: Dictionary = stack[stack.size() - 1]
				if bool(else_frame["union"]):
					else_frame["active"] = bool(else_frame["parent"])
				elif bool(else_frame["taken"]):
					else_frame["active"] = false
				else:
					else_frame["active"] = bool(else_frame["parent"])
					else_frame["taken"] = true
			"endif":
				if not stack.is_empty():
					stack.pop_back()
			"include":
				if active:
					var inc := rest.trim_prefix("\"").trim_suffix("\"")
					if inc.begins_with("res://"):
						_expand_into(inc, defines, out, depth + 1)
			"define":
				if active and not rest.is_empty():
					defines[rest.split(" ")[0]] = true
			"undef":
				if active:
					defines.erase(rest)
			_:
				pass


func _push_cond(stack: Array, parent_active: bool, taken: bool, unknown: bool) -> void:
	stack.append({
		"parent": parent_active,
		"taken": false if unknown else taken,
		"union": unknown,
		"active": parent_active if unknown else (parent_active and taken),
	})


## include 路径里的 `res://` 本身含 `//`，先挡掉，否则 `//` 注释规则会把整行吃掉。
func _strip_shader_comments(text: String) -> String:
	var guarded := text.replace("res://", "res:\u0001~~")
	var block := RegEx.new()
	block.compile("(?s)/\\*.*?\\*/")
	var without_block: String = block.sub(guarded, "", true)
	var line_comment := RegEx.new()
	line_comment.compile("//[^\n]*")
	var stripped: String = line_comment.sub(without_block, "", true)
	return stripped.replace("res:\u0001~~", "res://")


var _cond_text := ""
var _cond_pos := 0


func _eval_cond(expr: String, defines: Dictionary) -> int:
	_cond_text = expr.replace(" ", "")
	_cond_pos = 0
	var value := _cond_or(defines)
	if value >= 0 and _cond_pos < _cond_text.length():
		return -1
	return value


func _cond_or(defines: Dictionary) -> int:
	var value := _cond_and(defines)
	while _cond_accept("||"):
		var right := _cond_and(defines)
		if value == 1 or right == 1:
			value = 1
		elif value < 0 or right < 0:
			value = -1
		else:
			value = 0
	return value


func _cond_and(defines: Dictionary) -> int:
	var value := _cond_unary(defines)
	while _cond_accept("&&"):
		var right := _cond_unary(defines)
		if value == 0 or right == 0:
			value = 0
		elif value < 0 or right < 0:
			value = -1
		else:
			value = 1
	return value


func _cond_unary(defines: Dictionary) -> int:
	if _cond_accept("!"):
		var inner := _cond_unary(defines)
		return -1 if inner < 0 else 1 - inner
	if _cond_accept("("):
		var grouped := _cond_or(defines)
		_cond_accept(")")
		return grouped
	if _cond_text.substr(_cond_pos).begins_with("defined"):
		_cond_pos += "defined".length()
		_cond_accept("(")
		var defined_name := _cond_ident()
		_cond_accept(")")
		return 1 if defines.has(defined_name) else 0
	var identifier := _cond_ident()
	if identifier.is_empty():
		return -1
	if identifier == "0":
		return 0
	if identifier == "1":
		return 1
	if defines.has(identifier):
		var known: Variant = defines[identifier]
		if known is bool:
			return 1
		var known_text := String(known)
		if known_text == "0":
			return 0
		if known_text == "1":
			return 1
		return -1
	return 0


func _cond_accept(token: String) -> bool:
	if _cond_text.substr(_cond_pos, token.length()) == token:
		_cond_pos += token.length()
		return true
	return false


func _cond_ident() -> String:
	var start := _cond_pos
	while _cond_pos < _cond_text.length():
		var ch := _cond_text[_cond_pos]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
				or (ch >= "0" and ch <= "9") or ch == "_":
			_cond_pos += 1
		else:
			break
	return _cond_text.substr(start, _cond_pos - start)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
