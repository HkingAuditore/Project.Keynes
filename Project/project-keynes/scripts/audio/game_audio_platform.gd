extends Node

## Platform audio initialization, bank loading, and one-shot sound playback.

const BackendPolicy = preload("res://scripts/audio/audio_backend_policy.gd")
## Presentation-only audio boundary: FMOD on Windows/Android; Web keeps its own path.
const NativeBackend := preload("res://scripts/audio/native_audio_backend.gd")

var _native: NativeBackend

## Dev/test escape hatch: force the portable full-mix backend on any host so the
## Android code path can be smoke-tested on a Windows editor build.
const FORCE_NATIVE_ENV := "PK_AUDIO_FORCE_NATIVE"
const FORCE_NATIVE_ARG := "--audio-native"
const EXTENSION := "res://addons/FmodGodot/FmodGodot.gdextension"

## Android 专用：在加载 FmodGodot 之前把 FMOD 的 JNI_OnLoad 跑起来。
const BOOTSTRAP_EXTENSION := "res://addons/0_fmod_bootstrap/fmod_bootstrap.gdextension"
const DESKTOP_BANK_ROOT := "res://assets/audio/banks/Desktop/"
const MOBILE_BANK_ROOT := "res://assets/audio/banks/Mobile/"

## 四个时代各一个 bank（拆包见 tools/audio/split_music_banks.py）。
## 它们不进 web 的 boot pck：每个 8~10 MB，而一局只会用到其中一个。
const ERA_BANK_NAMES: Array[String] = ["Music_stone", "Music_agrarian", "Music_kingdom", "Music_empire"]
const CLICK_EVENT := "event:/UI/Click"
const UIFeedback := preload("res://scripts/ui/ui_audio_feedback.gd")
const UI_EVENTS := {
	&"click": "Click", &"page": "Page", &"open": "Open", &"close": "Close",
	&"confirm": "Confirm", &"toggle_on": "ToggleOn", &"toggle_off": "ToggleOff", &"tick": "Tick",
}
const UI_COOLDOWN_MS := {&"click": 45, &"page": 90, &"open": 120, &"close": 120,
	&"confirm": 100, &"toggle_on": 45, &"toggle_off": 45, &"tick": 65}
const MusicCatalog := preload("res://scripts/audio/music_event_catalog.gd")

## 游戏事件音效（UI bank）；科技/理念由 ElevenLabs 生成，清单见 Assets/UI/progression。
const EVENT_CUES := {
	&"tech_start": "event:/UI/Event/tech_start",
	&"tech_research": "event:/UI/Event/tech_research",
	&"tech_cancel": "event:/UI/Event/tech_cancel",
	&"territory_expand": "event:/UI/Event/territory_expand",
	&"ideology_draw": "event:/UI/Event/ideology_draw",
	&"ideology_use": "event:/UI/Event/ideology_use",
	&"ideology_reroll": "event:/UI/Event/ideology_reroll",
	&"ideology_reveal": "event:/UI/Event/ideology_reveal",
	&"ideology_choose": "event:/UI/Event/ideology_choose",
	&"ideology_unequip": "event:/UI/Event/ideology_unequip",
	&"ideology_promote": "event:/UI/Event/ideology_promote",
	&"building_complete": "event:/UI/Event/building_complete",
	&"population_grow": "event:/UI/Event/population_grow",
	&"trade": "event:/UI/Event/trade",
}

## 每个 cue 的最小间隔（毫秒）。高频事件必须稀疏，否则会糊成噪音墙：
## 贸易单次结算上限 32768 条信号，人口是 cell 级，逐个播没有意义。
const EVENT_COOLDOWN_MS := {
	&"tech_start": 80,
	&"tech_research": 700,
	&"tech_cancel": 80,
	&"territory_expand": 0,
	&"ideology_draw": 0,
	&"ideology_use": 0,
	&"ideology_reroll": 100,
	&"ideology_reveal": 90,
	&"ideology_choose": 100,
	&"ideology_unequip": 100,
	&"ideology_promote": 700,
	&"building_complete": 150,
	&"population_grow": 2500,
	&"trade": 2500,
}

signal ui_sound_played(cue: StringName)
signal event_sound_played(cue: StringName)

var status := "not_initialized"

## "native" | "fmod" | "disabled"; set once in _ready() and surfaced to tests/logs.
var backend := "not_initialized"
var _system := 0
var _master := 0
var _banks: Array[int] = []

## era -> StudioBank 句柄。加载后不卸载：切时代时旧 bank 里可能还有正在收尾的
## 事件，卸早了 FMOD 会报 invalid handle；四个加起来约 38 MB，wasm 堆吃得下。
var _era_banks: Dictionary = {}
var _era_bank_pending: Dictionary = {}
var _era_bank_failed: Dictionary = {}
var _web_bank_stream: RefCounted = null
var _ui_descriptions: Dictionary = {}
var _ui_next_ms: Dictionary = {}
var _music_descriptions: Dictionary = {}
var _event_descriptions: Dictionary = {}
var _event_next_ms: Dictionary = {}

## 3D 空间化开关：事件在 Studio 里必须有 Spatialiser 才生效，
## 否则 set_3d_attributes 是空操作。默认关闭，不影响现有 2D 行为。
var _spatial_enabled := false


## Android 的 bank 目录与桌面不同：FMOD Mobile 平台单独构建（见 tools/audio/Build-FmodBanks.ps1）。
func _bank_root() -> String:
	return MOBILE_BANK_ROOT if OS.has_feature("android") else DESKTOP_BANK_ROOT


func _ready() -> void:
	# [android-fmod 2026-11-01] Android 走 FMOD，但带"能补 JNI 才走"的硬门禁：
	#   * 设备实测已确认：扩展能在 Android 上加载、prime() 能返回 0；
	#   * 之前的 abort 是 FMOD 的 JNI_OnLoad 在 FindClass("org/fmod/FMOD") 失败后
	#     继续调 JNI 导致的（不是 load_extension 卡死），现在用 stub 类 + 探测挡住了；
	#   * prime 不成功就不加载扩展，直接回退 portable（下面 _prime_fmod_jni 那段），
	#     所以不会再出现"改了后端反而变哑巴"。
	# 想强制用 portable：PK_AUDIO_FORCE_NATIVE=1 或 --audio-native。
	var native_reason := _native_backend_reason()
	if not native_reason.is_empty():
		_start_native_backend(native_reason)
		return
	if OS.get_environment("PK_FMOD_DISABLE") == "1" \
			or not fmod_platform_supported(OS.get_name(), OS.has_feature("web")):
		backend = "disabled"
		status = "platform_disabled"
		print("[audio] backend=none platform=%s status=%s" % [OS.get_name(), status])
		return
	# Headless 门禁本来是给桌面 CI 仿真用的：批量跑天数时不该拉起音频。Android
	# 的自动化构建恰好也带 `--headless`（export_presets.cfg 的 command_line/
	# extra_args），但 FMOD 并不依赖窗口，手机上没有"无头跑"这回事，所以移动端
	# 不参与这条门禁，否则安卓包会静音。
	if DisplayServer.get_name() == "headless" and OS.get_environment("PK_FMOD_TEST") != "1" \
			and not OS.has_feature("android"):
		backend = "disabled"
		status = "headless_disabled"
		print("[audio] backend=none platform=%s status=%s" % [OS.get_name(), status])
		return
	backend = "fmod"
	print("[audio] Loading FMOD extension (%s)" % OS.get_name())
	if OS.has_feature("android"):
		# Android 必须先补 FMOD 的 JNI 初始化；补不上就不要加载扩展（否则
		# FMOD_Studio_System_Create 会把进程 abort 掉），直接回退 portable。
		var prime := _prime_fmod_jni()
		if prime != 0:
			_fmod_init_failed("jni_prime_failed")
			return
	var loaded := GDExtensionManager.load_extension(EXTENSION)
	print_verbose("[audio] Extension load status: ", loaded)
	if loaded not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
		_fmod_init_failed("extension_load_failed")
		push_warning("[audio] FMOD extension load failed: %s" % loaded)
		return
	if not Engine.has_singleton("FmodAudioServer"):
		_fmod_init_failed("server_missing")
		return
	_system = int(Engine.get_singleton("FmodAudioServer").call("get_studio"))
	for name in ["Master.strings", "Master", "Music", "UI"]:
		var bank := int(ClassDB.class_call_static("StudioSystem", "load_bank_file", _system,
			_bank_root() + name + ".bank", 0))
		if bank == 0:
			_release_banks()
			_fmod_init_failed("bank_load_failed:" + name)
			return
		_banks.append(bank)
	_master = int(ClassDB.class_call_static("StudioSystem", "get_bus", _system, "bus:/"))
	status = "ready"
	# 四个 Suite 事件**不再**在这里预热：它们住在 Music_<era>.bank 里，而 era bank
	# 是进游戏后按时代懒加载的（web 还要先下载）。预热会拿到 0 并缓存成"查过但没
	# 有"，反而拖慢第一次真正能取到事件的时机。改为在 play_*_age_suite 里先
	# _ensure_era_bank()，事件解析自然发生在 bank 到位之后。
	print("[audio] backend=fmod platform=%s banks=%d status=ready" % [OS.get_name(), _banks.size()])
	_connect_settings_and_feedback()
	if OS.has_feature("web"):
		# 主菜单放的是石器组曲（main_menu 只调一次 play_stone_age_suite，没有重试），
		# 而新开局的第一个时代也是石器。所以在扩展就绪时就先把这份 bank 拉起来，
		# 菜单音乐和开场配乐都不用等下载。异步，不阻塞页面。
		_request_web_era_bank(0)


## FMOD 的 Android 运行库把 JavaVM 缓存在 `JNI_OnLoad` 里，而只有 Java 的
## `System.loadLibrary()` 会触发它；Godot 用 dlopen 加载 GDExtension 依赖，所以
## `FMOD_Studio_System_Create` 会直接失败（设备日志：
##   "JNI_OnLoad has not run, should have occurred during System.LoadLibrary"）。
## `addons/0_fmod_bootstrap` 是一个只有几百 KB 的原生扩展，用 dlsym 从
## libfmod 里取出 `JNI_OnLoad` / `FMOD_Android_JNI_Init` 自己调用，
## 把这一步补上。它必须在加载 FmodGodot 之前跑完。
## 返回码：0=成功；负数=失败步骤（-1 没有 JavaVM，-2 打不开库，-3 没有 JNI_OnLoad，
## -8 缺 `org.fmod.FMOD` Java 类 —— 也就是缺 FMOD Android SDK 的 fmod.jar）。
const JNI_PRIME_REASONS := {
	0: "ok",
	-1: "no JavaVM",
	-2: "libfmod not found in APK",
	-3: "JNI_OnLoad symbol missing",
	-4: "JNI_OnLoad failed",
	-5: "cannot attach JNI env",
	-6: "no Activity",
	-7: "FMOD_Android_JNI_Init failed",
	-8: "missing org.fmod.FMOD (needs fmod.jar from FMOD Android SDK)",
	-100: "bootstrap extension not loaded",
}


func _prime_fmod_jni() -> int:
	if not OS.has_feature("android"):
		return 0
	var loaded := GDExtensionManager.load_extension(BOOTSTRAP_EXTENSION)
	if loaded not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
		push_warning("[audio] FMOD JNI bootstrap extension failed to load: %s" % loaded)
		return -100
	var library := "libfmodL.so" if OS.is_debug_build() else "libfmod.so"
	var code := int(ClassDB.class_call_static("FmodJniBootstrap", "prime", library))
	print("[audio] fmod jni prime(%s)=%d %s" % [library, code, JNI_PRIME_REASONS.get(code, "")])
	return code


## FMOD 初始化失败的统一落点。
##
## Android 的 FMOD 运行库如果没有先跑过 `JNI_OnLoad`（见 `_prime_fmod_jni`），
## `FMOD_Studio_System_Create` 会直接返回错误。Android 不退到 portable：包内不带
## OGG 资源，失败必须写入 status / logcat 并保持 FMOD 后端失败态。
func _fmod_init_failed(reason: String) -> void:
	status = reason
	if OS.has_feature("android"):
		backend = "disabled"
		push_error("[audio] FMOD unavailable on Android: %s" % reason)
		print("[audio] backend=fmod platform=%s status=failed reason=%s" % [OS.get_name(), reason])
		return
	push_warning("[audio] " + reason)


func _start_native_backend(reason: String) -> void:
	_native = NativeBackend.new()
	_native.name = "NativeAudio"
	add_child(_native)
	backend = "native"
	status = "ready"
	# Android users see this line in `adb logcat | grep '\[audio\]'`; the same line
	# proves the forced branch on Windows.
	print("[audio] backend=native platform=%s reason=%s mix=full_mix" % [OS.get_name(), reason])
	_connect_settings_and_feedback()


func _uses_native_audio() -> bool:
	return not _native_backend_reason().is_empty()


## Pure platform decision, split out so tests can prove the Android branch without
## an Android device. `platform` is OS.get_name(); web/android features cover hosts
## whose display name differs.
##
## 三个平台都走 FMOD：Windows（桌面 bank）、Android（lib/<abi>/ 运行库 + JNI 引导）、
## Web（HTML5 side module）。只有显式强制开关才用 portable 混音。
static func native_backend_reason_for(platform: String, _is_web: bool, is_android: bool,
		forced: bool) -> String:
	return BackendPolicy.native_backend_reason_for(platform, _is_web, is_android, forced)


## FMOD 后端可用的平台。Web 暂不在此列：FmodGodot 上游 v1.1.3 没有 html5 目标，
## HTML5 运行库接入完成后再打开（见 docs/audio/fmod-integration.md 平台边界一节）。
static func fmod_platform_supported(platform: String, is_web: bool) -> bool:
	return BackendPolicy.fmod_platform_supported(platform, is_web)


func _native_backend_reason() -> String:
	if OS.has_feature("android"):
		return ""
	return native_backend_reason_for(OS.get_name(), OS.has_feature("web"),
		OS.has_feature("android"), _force_native_requested())


func _force_native_requested() -> bool:
	if OS.has_feature("android"):
		return false
	if _truthy(OS.get_environment(FORCE_NATIVE_ENV)):
		return true
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		var text := String(arg).strip_edges()
		if text == FORCE_NATIVE_ARG:
			return true
		if text.begins_with(FORCE_NATIVE_ARG + "=") and _truthy(text.get_slice("=", 1)):
			return true
	return false


static func _truthy(value: String) -> bool:
	return value.strip_edges().to_lower() in ["1", "true", "yes", "on"]


func is_native_backend() -> bool:
	return _native != null


func _connect_settings_and_feedback() -> void:
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		settings.settings_changed.connect(apply_settings)
		apply_settings(settings.values())
	var feedback := UIFeedback.new()
	feedback.name = "UIFeedback"
	feedback.audio = self
	add_child(feedback)


func apply_settings(values: Dictionary) -> void:
	if _native != null:
		_native.apply_settings(values)
		return
	if status != "ready" or _master == 0:
		return
	ClassDB.class_call_static("StudioBus", "set_volume", _master,
		clampf(float(values.get("master_volume", 0.8)), 0.0, 1.0))
	ClassDB.class_call_static("StudioBus", "set_mute", _master, bool(values.get("master_muted", false)))


## 启用 3D 监听（相机位置驱动）。调用前请确认事件已在 Studio 里加了 Spatialiser，
## 可以用哪个事件试：print(ClassDB.class_call_static("StudioEventDescription", "is3D", desc))
func enable_spatial_listener() -> bool:
	if _native != null:
		return false
	if status != "ready":
		return false
	var r := int(ClassDB.class_call_static("StudioSystem", "set_num_listeners", _system, 1))
	_spatial_enabled = r == 0
	if _spatial_enabled:
		set_process(true)
		_update_listener()
	return _spatial_enabled


func spatial_enabled() -> bool:
	return _spatial_enabled


## 2D 地图坐标映射到 3D 平面（z=0）。相机朝向固定，因为地图是俯视 2D。
func _update_listener() -> void:
	if not _spatial_enabled or _system == 0:
		return
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var pos := camera.global_position
	ClassDB.class_call_static("StudioSystem", "set_listener_attributes", _system, 0,
		Transform3D(Basis(), Vector3(pos.x, pos.y, 0.0)), Vector3.ZERO)


func _process(_delta: float) -> void:
	_update_listener()


## 播放一次游戏事件音效。按 cue 冷却，高频事件不会刷屏。
## 返回 false 表示被冷却挡下或事件不在 bank 里 —— 调用方不需要处理。
func play_event_cue(cue: StringName, world_pos: Vector2 = Vector2.INF) -> bool:
	if status != "ready" or not EVENT_CUES.has(cue):
		return false
	var now := Time.get_ticks_msec()
	if now < int(_event_next_ms.get(cue, 0)):
		return false
	if _native != null:
		if not _native.play_cue("events", cue):
			return false
		_event_next_ms[cue] = now + int(EVENT_COOLDOWN_MS.get(cue, 0))
		event_sound_played.emit(cue)
		return true
	var description := int(_event_descriptions.get(cue, 0))
	if description == 0:
		description = int(ClassDB.class_call_static("StudioSystem", "get_event", _system, EVENT_CUES[cue]))
		if description == 0:
			return false
		_event_descriptions[cue] = description
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	if _spatial_enabled and world_pos != Vector2.INF:
		ClassDB.class_call_static("StudioEventInstance", "set_3d_attributes", instance,
			Transform3D(Basis(), Vector3(world_pos.x, world_pos.y, 0.0)), Vector3.ZERO)
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	if result == 0:
		_event_next_ms[cue] = now + int(EVENT_COOLDOWN_MS.get(cue, 0))
		event_sound_played.emit(cue)
	return result == 0


func play_ui_click() -> bool:
	return play_ui(&"click")


## Semantic one-shots share the FMOD Master bus with music and settings.
func play_ui(cue: StringName = &"click") -> bool:
	if status != "ready" or not UI_EVENTS.has(cue):
		return false
	var now := Time.get_ticks_msec()
	if now < int(_ui_next_ms.get(cue, 0)):
		return false
	if _native != null:
		if not _native.play_cue("ui", cue):
			return false
		_ui_next_ms[cue] = now + int(UI_COOLDOWN_MS[cue])
		ui_sound_played.emit(cue)
		return true
	var description := int(_ui_descriptions.get(cue, 0))
	if description == 0:
		description = int(ClassDB.class_call_static("StudioSystem", "get_event", _system,
			"event:/UI/" + String(UI_EVENTS[cue])))
		if description == 0:
			return false
		_ui_descriptions[cue] = description
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	if result == 0:
		_ui_next_ms[cue] = now + int(UI_COOLDOWN_MS[cue])
		ui_sound_played.emit(cue)
	return result == 0


## 时代升级过渡：单次播放，叠加在当前音乐上，不打断它。
func play_transition(key: StringName) -> bool:
	return _play_one_shot(MusicCatalog.transition_path(key))


## 胜利 stinger：单次播放，叠加在当前音乐上，不打断它。
func play_stinger(key: StringName) -> bool:
	return _play_one_shot(MusicCatalog.stinger_path(key))


func _play_one_shot(event_path: String) -> bool:
	if _native != null:
		return _native.play_transition(event_path)
	if status != "ready" or event_path.is_empty():
		return false
	var description := _music_description(event_path)
	if description == 0:
		return false
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	return result == 0


## 确保某个时代的 bank 已加载。返回 false 表示"现在还不能播"，调用方直接放弃这一次。
##
## 为什么返回 false 是可接受的：`set_era()` 由 `player_controller._sync_era_music()`
## 在每个 committed day 重调，所以 web 上下载完成后的下一个游戏日就会自然补播，
## 不需要在这里排队重放（那会引入一套额外的状态机）。
##
## 桌面/Android：四个 era bank 都在 pck 里，同步 load_bank_file，当场出结果。
## Web：boot pck 只带 Master/Master.strings/Music/UI，era bank 是独立文件，要先
##      fetch 到 emscripten FS 才能 load_bank_file。
func _ensure_era_bank(era: int) -> bool:
	if status != "ready":
		return false
	if era < 0 or era >= ERA_BANK_NAMES.size():
		return false
	if _era_banks.has(era):
		return true
	if OS.has_feature("web"):
		_request_web_era_bank(era)
		return false
	var name := ERA_BANK_NAMES[era]
	var bank := int(ClassDB.class_call_static("StudioSystem", "load_bank_file", _system,
		_bank_root() + name + ".bank", 0))
	if bank == 0:
		_era_bank_failed[era] = "load_failed"
		push_warning("[audio] era bank load failed: %s" % name)
		return false
	_era_banks[era] = bank
	print("[audio] era bank loaded: %s" % name)
	return true


func _request_web_era_bank(era: int) -> void:
	if _era_bank_pending.has(era) or _era_bank_failed.has(era):
		return
	if _web_bank_stream == null:
		_web_bank_stream = load("res://scripts/audio/web_bank_stream.gd").new()
		if _web_bank_stream == null or not bool(_web_bank_stream.call("is_supported")):
			_era_bank_failed[era] = "no_javascriptbridge"
			push_warning("[audio] era bank loader unavailable; suite music stays silent")
			return
	_era_bank_pending[era] = true
	var name := ERA_BANK_NAMES[era]
	_web_bank_stream.call("ensure", name, func(path: String) -> void:
		_on_web_era_bank_ready(era, path))


func _on_web_era_bank_ready(era: int, fs_path: String) -> void:
	_era_bank_pending.erase(era)
	var name := ERA_BANK_NAMES[era] if era >= 0 and era < ERA_BANK_NAMES.size() else "?"
	if fs_path.is_empty():
		_era_bank_failed[era] = "fetch_failed"
		push_warning("[audio] era bank fetch failed, suite music stays silent: %s" % name)
		return
	var bank := int(ClassDB.class_call_static("StudioSystem", "load_bank_file", _system, fs_path, 0))
	if bank == 0:
		_era_bank_failed[era] = "load_failed"
		push_warning("[audio] era bank load failed (web): %s" % name)
		return
	_era_banks[era] = bank
	print("[audio] era bank ready(web): %s" % name)


func _music_description(event_path: String) -> int:
	var cached := int(_music_descriptions.get(event_path, 0))
	if cached != 0:
		return cached
	var description := int(ClassDB.class_call_static("StudioSystem", "get_event", _system, event_path))
	if description != 0:
		if ClassDB.class_has_method("StudioEventDescription", "load_sample_data"):
			ClassDB.class_call_static("StudioEventDescription", "load_sample_data", description)
		_music_descriptions[event_path] = description
	return description


func _release_banks() -> void:
	for era in _era_banks.keys():
		ClassDB.class_call_static("StudioBank", "unload", _era_banks[era])
	_era_banks.clear()
	_era_bank_pending.clear()
	for index in range(_banks.size() - 1, -1, -1):
		ClassDB.class_call_static("StudioBank", "unload", _banks[index])
	_banks.clear()
