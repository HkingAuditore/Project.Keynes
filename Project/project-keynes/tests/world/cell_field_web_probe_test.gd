extends SceneTree
## [cell-field-web 2026-11-18] W4（启动自检 + 自动回退）的回归测试。
##
## 方案：`docs/plans/terrain-cell-field-web-plan.md` §3.5（自检 / 判定与回退）、
## §3.6（warmup 只预热选中的那一套）、§4 W4 判据。
##
## 分两半，**headless 与真后端都跑**：
##   A. 不需要 GPU 的部分（headless 就能验）：
##      ① URL `?cellfield=off|on|缺省` 三态纯映射；
##      ② `user://` 缓存键构造（adapter+driver+build 任一变化就 miss）与写读回环；
##      ③ boot meta 读写与「boot 后固定」（写一次后第二次调用不再改）；
##      ④ 模拟 pass / fail 两种 meta：运行期 `_cell_field_active()` / 前缀拼装 /
##         预热前缀三者由**同一个判定口**给出，且陆水同源（§3.7 海岸洞约束）；
##      ⑤ probe shader 自身的静态约束：能在 Godot shader 语言里编过、sampler ≤ 8
##         （Web 材质槽设备预算）、金丝雀值唯一、期望值覆盖够多的格子。
##   B. 需要真后端的部分（headless 打印 SKIPPED）：
##      ⑥ 干净合成表 ⇒ `ok=true`；人为破坏（去掉金丝雀 / 让 layer3 期望错位）⇒
##         `ok=false` 且带 `first_mismatch`；fail 结论 ⇒ 开关口回退。
##
## 跑法（cwd = Project/project-keynes）：
##   godot --headless -s tests/world/cell_field_web_probe_test.gd
##   godot --rendering-driver opengl3 -s tests/world/cell_field_web_probe_test.gd
##   godot --rendering-driver vulkan  -s tests/world/cell_field_web_probe_test.gd

const RendererShaderWaterScript = preload("res://scripts/rendering/renderer_shader_water.gd")
const CellFieldWebProbeScript = preload("res://scripts/rendering/cell_field_web_probe.gd")
const FieldScript = preload("res://scripts/geography/hex_cell_field.gd")

const SHADER_PATH := "res://shaders/world_map.gdshader"
const PROBE_SHADER_PATH := "res://shaders/debug/cell_field_web_probe.gdshader"
const CELL_FIELD_DEFINE := "#define PK_CELL_FIELD\n"

## Web / 桌面 Compatibility 的材质 sampler 槽上限（`uniforms.gdshaderinc` 的预算说明：
## unit 1..8，第 9 张起每帧被引擎内建白纹覆盖）。probe shader 运行时也在这条预算里 ——
## 超了以后**自检本身**就会读到白纹理，把"能跑"误判成"不能跑"。
const WEB_SAMPLER_BUDGET := 8

var _checks := 0
var _failures := 0
var _skipped := 0


func _init() -> void:
	# 延迟一帧：`root` 与 `_ready()` 都要等主循环起来才可靠（与本目录其它测试同模板）。
	call_deferred("_run")


func _run() -> void:
	print("[cell-field-web-probe-test] display=%s rendering_method=%s adapter=%s"
			% [DisplayServer.get_name(), RenderingServer.get_current_rendering_method(),
			RenderingServer.get_video_adapter_name()])
	_test_url_mapping()
	_test_cache_key()
	_test_boot_meta()
	_test_gate_and_prefix_bytes()
	_test_warmup_plan_matches_runtime()
	_test_probe_shader_static()
	await _test_boot_decision()
	await _test_probe_real_backend()
	print("=== cell field web probe: %d checks, %d failures, %d skipped ==="
			% [_checks, _failures, _skipped])
	quit(0 if _failures == 0 else 1)


# ═══════════════════════════════════════════════════════════════════════════
# ① URL `?cellfield=` 三态纯映射（与 micro_url_value_enabled 同构）
# ═══════════════════════════════════════════════════════════════════════════

func _test_url_mapping() -> void:
	var verdict_fail := RendererShaderWaterScript.CELL_FIELD_VERDICT_FAIL
	var verdict_pass := RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS
	for raw in ["off", "OFF", " off ", "0", "false", "False"]:
		_expect(RendererShaderWaterScript.cellfield_url_verdict(raw) == verdict_fail,
			"?cellfield=%s forces the old path (fail)" % String(raw))
	for raw in ["on", "ON", " on ", "1", "true", "True"]:
		_expect(RendererShaderWaterScript.cellfield_url_verdict(raw) == verdict_pass,
			"?cellfield=%s forces the cell-field path (pass)" % String(raw))
	for raw in ["", "  ", "banana", "2", "auto", "yes"]:
		_expect(RendererShaderWaterScript.cellfield_url_verdict(raw) == "",
			"?cellfield=%s is not a force switch (falls back to probe/cache)" % String(raw))
	# 与 micro 的开关同构性：同一批取值在两侧必须是"同类"（都关 / 都默认）。
	_expect(RendererShaderWaterScript.micro_url_value_enabled("off") == false
			and RendererShaderWaterScript.micro_url_value_enabled("1") == true,
		"the cellfield mapping stays isomorphic to micro_url_value_enabled")
	# 三态互不相等（值本身是跨模块契约：cell_field_web_probe.gd 只读不写）。
	_expect(verdict_fail != verdict_pass and verdict_fail != "" and verdict_pass != "",
		"verdict literals are three distinct states (fail/pass/undecided)")


# ═══════════════════════════════════════════════════════════════════════════
# ② 缓存键：adapter + 驱动版本 + 引擎构建号，任一变化就 miss
# ═══════════════════════════════════════════════════════════════════════════

func _test_cache_key() -> void:
	var probe := CellFieldWebProbeScript
	var base: String = probe.cache_key("NVIDIA GeForce", "OpenGL ES 3.0", "4.6.2+h1")
	_expect(not base.is_empty(), "cache key is built from adapter+driver+build")
	_expect(base == probe.cache_key("NVIDIA GeForce", "OpenGL ES 3.0", "4.6.2+h1"),
		"cache key is stable for the same device/driver/build")
	for changed in [
			probe.cache_key("AMD Radeon", "OpenGL ES 3.0", "4.6.2+h1"),
			probe.cache_key("NVIDIA GeForce", "OpenGL ES 3.0 (new driver)", "4.6.2+h1"),
			probe.cache_key("NVIDIA GeForce", "OpenGL ES 3.0", "4.6.3+h2")]:
		_expect(String(changed) != base,
			"changing adapter, driver or engine build invalidates the key (%s)" % String(changed))
	# ① 写读回环：真实 key 下能读回 verdict（user:// ⇒ Web 上 IndexedDB）。
	var saved: Dictionary = probe.read_cache()
	probe.write_cache(RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS, [])
	var read_back: Dictionary = probe.read_cache()
	_expect(String(read_back.get("verdict", ""))
			== RendererShaderWaterScript.CELL_FIELD_VERDICT_PASS,
		"a written cache entry is read back with its verdict")
	# ② 键不匹配 ⇒ miss。直接改文件里的 key（模拟"换了显卡 / 升了驱动 / 换了构建号"）。
	var config := ConfigFile.new()
	config.load(probe.CACHE_PATH)
	config.set_value(probe.CACHE_SECTION, "key", "some-other-adapter|driver|build")
	config.save(probe.CACHE_PATH)
	_expect(probe.read_cache().is_empty(),
		"a cache entry written for another adapter/driver/build is a miss")
	# 复原：不污染别的测试 / 下一次启动。
	probe.clear_cache()
	if not saved.is_empty():
		probe.write_cache(String(saved.get("verdict", "")), saved.get("first_mismatch", []))


# ═══════════════════════════════════════════════════════════════════════════
# ③ boot meta：读写 + boot 后固定
# ═══════════════════════════════════════════════════════════════════════════

func _test_boot_meta() -> void:
	var water := RendererShaderWaterScript
	water.reset_cell_field_boot_state()
	_expect(not water.cell_field_boot_decided(),
		"boot verdict starts undecided (meta missing ⇒ no crash, no assumption)")
	_expect(water.cell_field_boot_verdict() == "",
		"an undecided boot verdict reads back as the empty string")
	_expect(water.set_cell_field_boot_verdict(water.CELL_FIELD_VERDICT_PASS),
		"the first write latches the boot verdict")
	_expect(water.cell_field_boot_decided()
			and water.cell_field_boot_verdict() == water.CELL_FIELD_VERDICT_PASS,
		"the latched verdict reads back as pass")
	_expect(not water.set_cell_field_boot_verdict(water.CELL_FIELD_VERDICT_FAIL),
		"a second write is a no-op (boot 后固定 — otherwise switching the URL mid-game"
			+ " would recompile every program)")
	_expect(water.cell_field_boot_verdict() == water.CELL_FIELD_VERDICT_PASS,
		"the first verdict survives the rejected second write")
	water.reset_cell_field_boot_state()
	_expect(not water.cell_field_boot_decided(), "reset clears the boot state (test/GM only)")
	# URL 强制开关是**独立**的一次性读取：非 web 恒为空串。
	_expect(water.cell_field_url_forced_verdict() == "",
		"no ?cellfield= parameter outside web (nothing forced)")
	# meta = skipped（headless / 读不回像素）在受限平台上等于"不启用"，但**不报错**。
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(water.CELL_FIELD_VERDICT_SKIPPED)
	_expect(water.cell_field_boot_allows() == (not DCFeatureFlags.is_compatibility_renderer()),
		"a skipped verdict keeps the old behaviour: enabled only where the self-check"
			+ " is not required (desktop Vulkan / mobile)")
	water.reset_cell_field_boot_state()


# ═══════════════════════════════════════════════════════════════════════════
# ④ 模拟 pass / fail 两种 meta：单一判定口 + 陆水同源
# ═══════════════════════════════════════════════════════════════════════════

func _test_gate_and_prefix_bytes() -> void:
	var water := RendererShaderWaterScript
	var verdict_pass := water.CELL_FIELD_VERDICT_PASS
	var verdict_fail := water.CELL_FIELD_VERDICT_FAIL
	var verdict_skipped := water.CELL_FIELD_VERDICT_SKIPPED
	var host := _FakeShaderHost.new()
	host.terrain_cell_field_enabled = true
	# 桌面 Vulkan / 移动的普通变体：两条排除都不成立 ⇒ 只看 boot 结论。
	# 这是**唯一**一条能在两种后端上都有意义的组合（Compatibility 会把预算排除打开，
	# 使 PK 侧恒为 false ⇒ 那条路径另行断言）。
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(verdict_pass)
	_expect(water.cell_field_prefix_for_variant(false, false, true) == CELL_FIELD_DEFINE,
		"pass + desktop variant + toggle on ⇒ PK_CELL_FIELD is prepended")
	# 关掉开关 = 老路径（一个字节都不加）。
	_expect(water.cell_field_prefix_for_variant(false, false, false) == "",
		"toggle off yields the empty string (byte contract: off == today's bytes)")
	# 预算变体 / world-min 变体：W6 已解除两处排除 ⇒ 四种组合（budget × world_min）
	# **全为 true 且返回同一个非空前缀**。W6 之前的写法是三条 `== ""` 的等值断言；
	# 那三条现在会红（前提被推翻），换成的是一条更强的等值断言：四个组合的返回值必须
	# **逐字节等于** CELL_FIELD_DEFINE，而不是"恰好不为空"。
	var combo_prefixes := {}
	for combo_budget in [false, true]:
		for combo_world_min in [false, true]:
			combo_prefixes["budget=%s,world_min=%s" % [str(combo_budget),
				str(combo_world_min)]] = water.cell_field_prefix_for_variant(
					combo_budget, combo_world_min, true)
	var combo_all_cell_field := true
	for combo_key in combo_prefixes:
		if String(combo_prefixes[combo_key]) != CELL_FIELD_DEFINE:
			combo_all_cell_field = false
	_expect(combo_all_cell_field and combo_prefixes.size() == 4,
		"W6 lifted both exclusions: all four budget×world-min combos return exactly"
			+ " PK_CELL_FIELD (got %s)" % str(combo_prefixes).replace("\n", "|"))
	# meta = fail ⇒ 连桌面变体也不给（这是"自动回退"的核心）。
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(verdict_fail)
	_expect(water.cell_field_boot_allows() == false,
		"a failed self-check vetoes the feature on every platform")
	_expect(water.cell_field_prefix_for_variant(false, false, true) == "",
		"fail ⇒ the define disappears even for the desktop variant (automatic fallback)")
	# 真拼装路径（陆地 + 水面）必须都听同一个口。
	var land_prefix := _land_prefix(host)
	var water_prefix: String = water._water_program_prefix(host, "split")
	var active: bool = water._cell_field_active(host)
	var allowed_here: bool = water.cell_field_variant_allowed(
		DCFeatureFlags.is_compatibility_renderer(), water._world_map_web_min_active(host))
	_expect(active == (allowed_here and water.cell_field_boot_allows()),
		"_cell_field_active() == variant allowed AND boot verdict (single decision point)")
	_expect(land_prefix.ends_with(CELL_FIELD_DEFINE) == active,
		"the land program carries the define exactly when _cell_field_active() (got %s)"
			% land_prefix.replace("\n", "|"))
	_expect(water_prefix.ends_with(CELL_FIELD_DEFINE) == active,
		"the water program carries the define exactly when _cell_field_active() (got %s)"
			% water_prefix.replace("\n", "|"))
	_expect(land_prefix.ends_with(CELL_FIELD_DEFINE) == water_prefix.ends_with(CELL_FIELD_DEFINE),
		"land and water agree byte-for-byte on the cell-field segment (no coast holes)")
	# meta = pass 时同一条拼装路径必须真的带上去（否则上面的 fail 断言会被"恒 false"蒙过）。
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(verdict_pass)
	land_prefix = _land_prefix(host)
	water_prefix = water._water_program_prefix(host, "split")
	active = water._cell_field_active(host)
	if DCFeatureFlags.is_compatibility_renderer():
		# [cell-field-web 2026-11-18 / W6] 解禁：Compatibility 上 PK_WEB_TEXTURE_BUDGET 与
		# PK_CELL_FIELD 现在**同时**出现，而且槽位仍然够（6 张，W2 退役旧三槽腾出来的）。
		# 采样器张数用引擎 uniform 反射数（与 terrain_shader_variant_test 的四套前缀普查
		# 同一口径：不猜名字后缀、不看声明文本）。
		var compat_land_samplers := _count_samplers(
			land_prefix + FileAccess.get_file_as_string(SHADER_PATH))
		_expect(active and land_prefix.contains("#define PK_WEB_TEXTURE_BUDGET\n")
				and land_prefix.ends_with(CELL_FIELD_DEFINE)
				and compat_land_samplers == 6,
			("under a compatibility renderer cell field is admitted and the budget variant"
				+ " still fits (samplers=%d, got %s)") % [compat_land_samplers,
					land_prefix.replace("\n", "|")])
	else:
		_expect(active and land_prefix.ends_with(CELL_FIELD_DEFINE)
				and water_prefix.ends_with(CELL_FIELD_DEFINE),
			"pass ⇒ desktop Vulkan land AND water both end with the define (got %s / %s)"
				% [land_prefix.replace("\n", "|"), water_prefix.replace("\n", "|")])
	# skipped：受限平台上等于不启用。
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(verdict_skipped)
	_expect(water.cell_field_prefix_for_variant(false, false, true)
			== ("" if DCFeatureFlags.is_compatibility_renderer() else CELL_FIELD_DEFINE),
		"a skipped verdict never green-lights the web/compatibility path")
	water.reset_cell_field_boot_state()


# ═══════════════════════════════════════════════════════════════════════════
# ⑤ warmup 计划 = 运行期（逐字节）+ 只预热选中的那一套
# ═══════════════════════════════════════════════════════════════════════════

func _test_warmup_plan_matches_runtime() -> void:
	var water := RendererShaderWaterScript
	# 打开项目设置：模拟"功能已启用"（2026-11-18 起出货默认就是开；这里显式设一遍只是
	# 让断言不依赖 project.godot 的内容，受限平台还差一次 boot 自检结论）。
	var had_setting := ProjectSettings.has_setting(water.CELL_FIELD_SETTING)
	var old_setting = ProjectSettings.get_setting(water.CELL_FIELD_SETTING, true)
	ProjectSettings.set_setting(water.CELL_FIELD_SETTING, true)
	water.reset_cell_field_boot_state()
	water.set_cell_field_boot_verdict(water.CELL_FIELD_VERDICT_PASS)
	var prefixes: Dictionary = water.web_warmup_program_prefixes()
	# ① 四段前缀的**每一段**都必须等于「owner 常量 + 同一个判定口给的那一段」。
	#    [W6] world_water_web 是唯一的例外，而且是有意的：判定口相同（同一个
	#    `cell_field_prefix_for_variant`），但它的**载荷宏**是 PK_WATER_FIELD_MATCHES_LAND
	#    （水面 pass 只要"水陆判据同源"，不需要陆地那一整套场函数分支），并且顺序必须与
	#    运行期 `_create_water_quad` 的 `prefix + WATER_PASS_PREFIX + source` 一致 ⇒
	#    载荷宏落在 WATER_PASS_PREFIX **之前**。写反了 = 逐字节分叉 = 预热白做。
	var cell_segment: String = water.cell_field_prefix_for_variant(true, true, true)
	_expect(cell_segment == CELL_FIELD_DEFINE,
		"the shared gate yields exactly PK_CELL_FIELD with the setting on + boot pass"
			+ " (got %s)" % cell_segment.replace("\n", "|"))
	var owner_prefixes := {
		"world_map": water.web_map_web_prefix_active(),
		"world_map_high": water.WORLD_MAP_WEB_HIGH_PREFIX,
		"world_water_high": water.WATER_WEB_HIGH_PREFIX,
	}
	for label in owner_prefixes:
		var base := String(owner_prefixes[label])
		_expect(String(prefixes.get(label, "")) == base + cell_segment,
			"warmup prefix %s == owner constant + the shared gate (got %s)"
				% [label, String(prefixes.get(label, "")).replace("\n", "|")])
	_expect(String(prefixes.get("world_water_web", ""))
			== water.WATER_FIELD_MATCHES_LAND_DEFINE + water.WATER_PASS_PREFIX,
		"warmup prefix world_water_web == MATCHES_LAND + WATER_PASS_PREFIX, in the same"
			+ " order as _create_water_quad (got %s)"
				% String(prefixes.get("world_water_web", "")).replace("\n", "|"))
	# ② [W6] 四段前缀各自**必须**带自己的载荷宏（逐段一条断言，不合成一条）：
	#    解禁之后"预热编的是一套带宏的变体"这件事必须真的发生在每一段上。
	for define_label in ["world_map", "world_map_high", "world_water_high"]:
		_expect(String(prefixes.get(define_label, "")).contains(CELL_FIELD_DEFINE),
			"web prefix %s carries PK_CELL_FIELD after W6 (got %s)"
				% [define_label, String(prefixes.get(define_label, "")).replace("\n", "|")])
	_expect(String(prefixes.get("world_water_web", "")).contains(
				water.WATER_FIELD_MATCHES_LAND_DEFINE)
			and not String(prefixes.get("world_water_web", "")).contains("PK_CELL_FIELD"),
		"web prefix world_water_web carries PK_WATER_FIELD_MATCHES_LAND (its own payload"
			+ " macro) and no PK_CELL_FIELD (got %s)"
				% String(prefixes.get("world_water_web", "")).replace("\n", "|"))
	# ③ [W6] 同源守卫：水面的载荷宏只在**陆地 program 真的带 PK_CELL_FIELD** 时出现。
	#    用 fake host 关掉开关 ⇒ 水面回到"只有 WATER_PASS_PREFIX"的形态、陆地也不带宏；
	#    打开 ⇒ 两侧同时出现各自的载荷宏。这条是"水面跟随陆地数据源"（方案 §3.7）的
	#    最小证明：任何"自己再判一次平台/画质"的实现都会在这里分叉。
	var gate_host_on := _FakeShaderHost.new()
	gate_host_on.terrain_cell_field_enabled = true
	var gate_host_off := _FakeShaderHost.new()
	gate_host_off.terrain_cell_field_enabled = false
	var gate_water_on: String = water._water_program_prefix(gate_host_on, "web_min") \
		+ water.WATER_PASS_PREFIX
	var gate_water_off: String = water._water_program_prefix(gate_host_off, "web_min") \
		+ water.WATER_PASS_PREFIX
	var gate_land_on: String = _land_prefix(gate_host_on)
	var gate_land_off: String = _land_prefix(gate_host_off)
	_expect(gate_water_off == water.WATER_PASS_PREFIX
			and not gate_water_off.contains("PK_WATER_FIELD_MATCHES_LAND")
			and not gate_land_off.contains("PK_CELL_FIELD")
			and gate_water_on == water.WATER_FIELD_MATCHES_LAND_DEFINE
				+ water.WATER_PASS_PREFIX
			and gate_land_on.contains(CELL_FIELD_DEFINE),
		"the water payload macro appears exactly when the land program carries"
			+ " PK_CELL_FIELD (water off=%s on=%s)"
				% [gate_water_off.replace("\n", "|"), gate_water_on.replace("\n", "|")])
	# ④ 预热计划（真实 _collect_codes()）与上面四段逐字节一致，且每个 program 只有一条。
	var codes: Array = WebShaderWarmup._collect_codes()
	var by_label := {}
	for entry in codes:
		by_label[String(entry.get("label", ""))] = String(entry.get("code", ""))
	var world_map_source := FileAccess.get_file_as_string(SHADER_PATH)
	_expect(String(by_label.get("world_map", ""))
			== String(prefixes["world_map"]) + world_map_source,
		"the warmup plan compiles exactly the runtime web land program (byte for byte)")
	var water_source := FileAccess.get_file_as_string(
		"res://shaders/world_water_web.gdshader")
	_expect(String(by_label.get("world_water_web", ""))
			== String(prefixes["world_water_web"]) + water_source,
		"the warmup plan compiles exactly the runtime web water program (byte for byte)")
	# ⑤ 不许新旧两套同时预热：label 唯一，且没有任何一条 code 里出现两次 define。
	var seen := {}
	var duplicated: Array = []
	for entry in codes:
		var label := String(entry.get("label", ""))
		if seen.has(label):
			duplicated.append(label)
		seen[label] = true
	_expect(duplicated.is_empty(),
		"no shader label is warmed twice (would double the first-compile cost): %s"
			% str(duplicated))
	var doubled: Array = []
	for entry in codes:
		if String(entry.get("code", "")).count(CELL_FIELD_DEFINE) > 1:
			doubled.append(String(entry.get("label", "")))
	_expect(doubled.is_empty(),
		"no warmup entry carries PK_CELL_FIELD more than once: %s" % str(doubled))
	# ⑥ 恢复设置与判定状态。
	if had_setting:
		ProjectSettings.set_setting(water.CELL_FIELD_SETTING, old_setting)
	else:
		ProjectSettings.set_setting(water.CELL_FIELD_SETTING, null)
	water.reset_cell_field_boot_state()
	_expect(water.cell_field_setting_enabled(),
		"the project setting is back to the shipped default (enabled) after the test")


# ═══════════════════════════════════════════════════════════════════════════
# ⑥ probe shader / 合成表的静态约束（不需要 GPU）
# ═══════════════════════════════════════════════════════════════════════════

func _test_probe_shader_static() -> void:
	var probe := CellFieldWebProbeScript
	var source := FileAccess.get_file_as_string(PROBE_SHADER_PATH)
	_expect(not source.is_empty(), "the probe shader source loads")
	var shader := Shader.new()
	shader.code = source
	var uniforms: Array = shader.get_shader_uniform_list()
	_expect(not uniforms.is_empty(),
		"the probe shader compiles in the Godot shader language (%d uniforms)"
			% uniforms.size())
	var names := {}
	var samplers := PackedStringArray()
	for entry in uniforms:
		names[String(entry.get("name", ""))] = true
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			samplers.append(String(entry.get("name", "")))
	# 它自己也要守 Web 的材质槽预算：超了以后"自检本身"就会读到白纹理（假失败）。
	_expect(samplers.size() <= WEB_SAMPLER_BUDGET,
		"the probe shader fits the %d-slot web material budget (declares %d: %s)"
			% [WEB_SAMPLER_BUDGET, samplers.size(), ", ".join(samplers)])
	_expect(samplers.has("cell_table"),
		"the probe declares cell_table (VT_USE_CELL_TABLE reached visual_tile_sampling)")
	for required in ["hex_size", "world_origin", "world_size", "cell_table_size",
			"cell_table_bound", "terrain_ecotone_width", "terrain_warp_range",
			"probe_canary_texel", "probe_canary_layer", "visual_quality", "pixel_world_size"]:
		_expect(names.has(required), "the probe exposes %s" % required)
	# 场函数真的进来了（include 顺序正确才会出现这两个符号）。
	var surface_include := "#include \"res://shaders/include/terrain_surface_detail.gdshaderinc\""
	var field_include := "#include \"res://shaders/include/hex_cell_field.gdshaderinc\""
	_expect(source.contains(surface_include) and source.contains(field_include),
		"the probe includes the real field include next to terrain_surface_detail")
	_expect(source.find(surface_include) < source.find(field_include),
		"hex_cell_field is included AFTER terrain_surface_detail (GLSL has no"
			+ " forward declarations — contract §8 D1)")
	_expect(source.contains("render_mode blend_disabled"),
		"blend_disabled: alpha carries the canary byte, blend_mix would scale rgb by it")
	# 合成表的性质（GPU 侧与 CPU 期望同源，但这几条与 GPU 无关）。
	var layer0_biomes := {}
	var layer3_biomes := {}
	var canary_hits := 0
	for row in probe.TABLE_H:
		for col in probe.TABLE_W:
			layer0_biomes[probe.layer_byte(probe.LAYER_CLASS, 0, col, row)] = true
			layer3_biomes[probe.layer_byte(probe.LAYER_BY_INDEX, 0, col, row)] = true
			if probe.layer_byte(probe.LAYER_AUX, 0, col, row) == probe.CANARY_VALUE:
				canary_hits += 1
	_expect(canary_hits == 1,
		"the canary value appears exactly once in its layer/channel (%d hits)" % canary_hits)
	_expect(not layer0_biomes.has(0) and not layer3_biomes.has(0),
		"synthetic biomes never use byte 0 (0 is indistinguishable from a black texture)")
	var min3 := 255
	for value in layer3_biomes:
		min3 = mini(min3, int(value))
	var max0 := 0
	for value in layer0_biomes:
		max0 = maxi(max0, int(value))
	_expect(min3 > max0,
		"layer0 and layer3 biome ranges are disjoint (%d.. vs ..%d) ⇒ reading the wrong"
			% [min3, max0] + " layer cannot pass the comparison")
	# 期望值覆盖：够多的格子 + 行都在表内 + 真的有负列被 posmod（方案 §3.4 第 4 条）。
	var distinct := {}
	var rows_ok := true
	var negative_col := 0
	for py in probe.VIEW_PX:
		for px in probe.VIEW_PX:
			var wp: Vector2 = probe.pixel_world(px, py)
			var expected: Dictionary = probe.expected_pixel(px, py)
			distinct[Vector2i(int(expected["col"]), int(expected["row"]))] = true
			if int(expected["row"]) < 0 or int(expected["row"]) >= probe.TABLE_H:
				rows_ok = false
			# map_w = 0 ⇒ 不 posmod，直接看未回绕的 offset col。
			var raw: Dictionary = FieldScript.field_at(wp, probe.HEX_SIZE, Vector2.ZERO,
					0.84, probe.TABLE_H, 0)
			if int(FieldScript.cell_offset(raw, int(raw["dom"])).x) < 0:
				negative_col += 1
	_expect(rows_ok,
		"every probe pixel maps to a row inside the synthetic table (row is not posmod'd)")
	_expect(distinct.size() >= 8,
		"the probe lattice covers many distinct cells (%d)" % distinct.size())
	_expect(negative_col > 0,
		"the lattice really exercises pk_posmod with a negative column (%d pixels)"
			% negative_col)


# ═══════════════════════════════════════════════════════════════════════════
# ⑧ boot 判定入口（ensure_decided）：优先级顺序 + 幂等 + cached/fresh
# ═══════════════════════════════════════════════════════════════════════════

func _test_boot_decision() -> void:
	var water := RendererShaderWaterScript
	var probe := CellFieldWebProbeScript
	var had_setting := ProjectSettings.has_setting(water.CELL_FIELD_SETTING)
	var old_setting = ProjectSettings.get_setting(water.CELL_FIELD_SETTING, false)
	# ① 项目设置关着（v1 出货默认）：不跑自检、不写 meta ⇒ boot 零成本。
	water.reset_cell_field_boot_state()
	ProjectSettings.set_setting(water.CELL_FIELD_SETTING, false)
	var off_decision: Dictionary = await probe.ensure_decided(self)
	_expect(String(off_decision.get("reason", "")) == "setting_off"
			and not water.cell_field_boot_decided(),
		"with the setting off the probe is not even run (zero boot cost, got %s)"
			% String(off_decision.get("reason", "")))
	# ② URL 强制开关优先于自检与缓存，并且同样写进 boot meta（之后固定）。
	ProjectSettings.set_setting(water.CELL_FIELD_SETTING, true)
	water.reset_cell_field_boot_state()
	Engine.set_meta(water.PK_WEB_CELL_FIELD_FORCE_META, water.CELL_FIELD_VERDICT_FAIL)
	var forced_fail: Dictionary = await probe.ensure_decided(self)
	_expect(String(forced_fail.get("reason", "")) == "forced_fail"
			and water.cell_field_boot_verdict() == water.CELL_FIELD_VERDICT_FAIL
			and not water.cell_field_boot_allows(),
		"?cellfield=off wins over probe and cache and latches fail (got %s)"
			% String(forced_fail.get("reason", "")))
	# ③ boot 后固定：再调一次只是读回结论，不会再判一次。
	var again: Dictionary = await probe.ensure_decided(self)
	_expect(String(again.get("reason", "")).begins_with("already_")
			and water.cell_field_boot_verdict() == water.CELL_FIELD_VERDICT_FAIL,
		"a second boot call is a no-op returning the latched verdict (got %s)"
			% String(again.get("reason", "")))
	water.reset_cell_field_boot_state()
	Engine.set_meta(water.PK_WEB_CELL_FIELD_FORCE_META, water.CELL_FIELD_VERDICT_PASS)
	var forced_pass: Dictionary = await probe.ensure_decided(self)
	_expect(String(forced_pass.get("reason", "")) == "forced_pass"
			and water.cell_field_boot_allows(),
		"?cellfield=on wins over probe and cache and latches pass")
	# ④ 没有强制时的平台默认 / 缓存：三种环境各自的诚实结论。
	water.reset_cell_field_boot_state()
	probe.clear_cache()
	var plain: Dictionary = await probe.ensure_decided(self)
	var plain_reason := String(plain.get("reason", ""))
	var plain_verdict := water.cell_field_boot_verdict()
	if not DCFeatureFlags.is_compatibility_renderer():
		_expect(plain_reason == "desktop" and plain_verdict == water.CELL_FIELD_VERDICT_PASS,
			"desktop Vulkan / mobile needs no self-check (latches pass, got %s)"
				% plain_reason)
	elif not probe.real_backend_available():
		_expect(plain_reason == "headless" and plain_verdict == water.CELL_FIELD_VERDICT_SKIPPED,
			"headless records skipped instead of a fake green (got %s)" % plain_reason)
	else:
		_expect(plain_reason == "fresh_pass" and plain_verdict == water.CELL_FIELD_VERDICT_PASS
				and bool(plain.get("cached", true)) == false,
			"the boot entry runs the probe once on a compatibility backend (got %s)"
				% plain_reason)
		# 同设备同驱动同构建号 ⇒ 下一次启动直接读缓存（`cached=true` + reason 里区分）。
		water.reset_cell_field_boot_state()
		var cached: Dictionary = await probe.ensure_decided(self)
		_expect(String(cached.get("reason", "")) == "cached_pass"
				and bool(cached.get("cached", false)),
			"a second boot on the same adapter+driver+build reads the cached verdict"
				+ " (got %s)" % String(cached.get("reason", "")))
	# 复原：清掉缓存与判定状态，不污染下一次启动 / 其它测试。
	probe.clear_cache()
	water.reset_cell_field_boot_state()
	if had_setting:
		ProjectSettings.set_setting(water.CELL_FIELD_SETTING, old_setting)
	else:
		ProjectSettings.set_setting(water.CELL_FIELD_SETTING, null)


# ═══════════════════════════════════════════════════════════════════════════
# ⑦ 真后端：干净 ⇒ pass；人为破坏 ⇒ fail 并回退
# ═══════════════════════════════════════════════════════════════════════════

func _test_probe_real_backend() -> void:
	var probe := CellFieldWebProbeScript
	if not probe.real_backend_available():
		_skipped += 1
		print("  [SKIPPED] probe readback needs a real rendering backend"
			+ " (--headless uses the dummy renderer). Run:")
		print("  [SKIPPED]   godot --rendering-driver opengl3"
			+ " -s tests/world/cell_field_web_probe_test.gd")
		print("  [SKIPPED]   godot --rendering-driver vulkan "
			+ "-s tests/world/cell_field_web_probe_test.gd")
		return
	# ① 干净合成表：必须 pass，而且 reason 是 fresh（不是从缓存里捡来的结论）。
	var clean: Dictionary = await probe.run({"tree": self})
	_expect(bool(clean.get("ok", false)),
		"a clean synthetic cell_table passes on %s (%s)"
			% [String(clean.get("adapter", "")), str(clean.get("first_mismatch", []))])
	_expect(String(clean.get("reason", "")) == "fresh",
		"the raw probe reports reason=fresh (got %s)" % String(clean.get("reason", "")))
	_expect(clean.has("adapter") and clean.has("driver") and clean.has("cached")
			and bool(clean.get("cached", true)) == false,
		"the raw probe never reports a cached result (cache belongs to ensure_decided)")
	# ② 人为破坏 A：去掉金丝雀（= "纹理读不到 / 被白纹覆盖"的表现）⇒ 必须 fail。
	var broken_canary: Dictionary = await probe.run(
		{"tree": self, "corrupt": probe.CORRUPT_CANARY})
	var canary_mismatch: Array = broken_canary.get("first_mismatch", [])
	_expect(not bool(broken_canary.get("ok", true))
			and String(broken_canary.get("reason", "")) == "mismatch",
		"removing the canary texel fails the probe (got ok=%s / reason=%s)"
			% [str(broken_canary.get("ok")), String(broken_canary.get("reason", ""))])
	_expect(canary_mismatch.size() == 5 and int(canary_mismatch[2]) == 3,
		"the canary corruption is reported on channel A with pixel coords (%s)"
			% str(canary_mismatch))
	# ③ 人为破坏 B：layer3（index 空间）内容错位 ⇒ B 通道必须 fail。
	var broken_biome: Dictionary = await probe.run(
		{"tree": self, "corrupt": probe.CORRUPT_BIOME})
	var biome_mismatch: Array = broken_biome.get("first_mismatch", [])
	_expect(not bool(broken_biome.get("ok", true)),
		"corrupting layer3 (class_by_index) fails the probe")
	_expect(biome_mismatch.size() == 5 and int(biome_mismatch[2]) == 2,
		"the layer3 corruption is reported on channel B (%s)" % str(biome_mismatch))
	# ④ 破坏 ⇒ 结论 fail ⇒ 开关口回退（这就是方案 §3.5 的"自动降级"）。
	var water := RendererShaderWaterScript
	water.reset_cell_field_boot_state()
	var verdict: String = water.CELL_FIELD_VERDICT_PASS if bool(broken_canary.get("ok", false)) \
		else water.CELL_FIELD_VERDICT_FAIL
	water.set_cell_field_boot_verdict(verdict)
	_expect(verdict == water.CELL_FIELD_VERDICT_FAIL
			and water.cell_field_prefix_for_variant(false, false, true) == "",
		"a broken table latches fail and the prefix generator falls back to the old path")
	water.reset_cell_field_boot_state()


# ─────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────

## 跑一遍真实的前缀拼装，只返回**前缀部分**（把探针源码切掉）。
## 直接调 RendererShaderWater 的静态实现，不抄一份拼装逻辑 —— 断言的全部意义就是
## "被测代码在开关关着时不加任何字节 / 开着时加的正是同一段"。
func _land_prefix(host) -> String:
	var probe := Shader.new()
	probe.code = "PROBE_SOURCE"
	var variant: Shader = RendererShaderWaterScript._apply_shader_variant_prefix(
		host, probe, SHADER_PATH)
	if variant == null:
		return "<null>"
	var code := String(variant.code)
	return code.substr(0, code.length() - "PROBE_SOURCE".length())


## [cell-field-web 2026-11-18 / W6] 用一个 program 的 GPU 侧采样器张数（引擎 uniform 反射：
## TYPE_OBJECT 就是真正占纹理单元的那一组）。口径与 terrain_shader_variant_test 的
## sampler 普查相同 —— 不猜名字后缀、不数声明文本，所以"多一张/少一张"都能被抓到。
func _count_samplers(code: String) -> int:
	var shader := Shader.new()
	shader.code = code
	var count := 0
	for entry in shader.get_shader_uniform_list():
		if int(entry.get("type", TYPE_NIL)) == TYPE_OBJECT:
			count += 1
	return count


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


## `RendererShaderWater._apply_shader_variant_prefix / _water_program_prefix` 真正读到的
## 字段（字段名必须与 HexRenderer 一致）。字段集与 tests/world/terrain_shader_variant_test.gd
## 的 FakeShaderHost 相同 —— 两处都只服务「前缀拼装」，不是"重现 renderer"。
class _FakeShaderHost extends RefCounted:
	var _world = null
	var visual_quality: int = 0
	var _mobile_quality_tier_define: String = ""
	var split_land_water_passes: bool = true
	var _split_program_failed: bool = false
	var _forced_water_program_kind: String = ""
	var terrain_surface_debug_view: int = 0
	var terrain_cell_field_enabled: bool = false
	var shader_path: String = "res://shaders/world_map.gdshader"
	var WORLD_MAP_SHADER_PATH: String = "res://shaders/world_map.gdshader"
	var SPLIT_LAND_ONLY_DEFINE: String = ""
	var SPLIT_WATER_ONLY_DEFINE: String = ""
	var CloudShadowFieldScript = null

	func _init() -> void:
		var water_impl = preload("res://scripts/rendering/renderer_shader_water.gd")
		SPLIT_LAND_ONLY_DEFINE = water_impl.SPLIT_LAND_ONLY_DEFINE
		SPLIT_WATER_ONLY_DEFINE = water_impl.SPLIT_WATER_ONLY_DEFINE
		CloudShadowFieldScript = preload("res://scripts/rendering/cloud_shadow_field.gd")
