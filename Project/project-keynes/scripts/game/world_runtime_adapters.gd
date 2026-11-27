extends Node

signal presentation_reset()
signal map_fields_received(day: int)
signal map_texture_published(day: int)
signal world_generation_started()
signal world_generation_failed(reason: String)
signal world_ready(map: MapData, world_data: WorldData, generator: MapGenerator, view_adapter: DCViewAdapter)
signal daily_tick_completed(report: Dictionary)
signal simulation_committed(from_day: int, to_day: int, generation: int)
signal simulation_day_records(records: Array)
signal simulation_command_results(results: Array)
signal player_confirmation_updated(view: Dictionary)
signal colonization_quotes_ready()
signal simulation_ui_updated(from_day: int, to_day: int, generation: int)
signal simulation_view_updated(from_day: int, to_day: int, generation: int)
signal generation_progress(stage: String, fraction: float)
signal gm_toggle_changed(toggle_id: String, enabled: bool)
signal gm_tod_preview_changed(active: bool)
signal gm_action_completed(action_id: String, result: Dictionary)
signal annual_report_ready(report_id: int)

const AnnualReportSessionScript = preload("res://scripts/annual/annual_report_session.gd")
var _annual_reports = AnnualReportSessionScript.new()

const WorldSession = preload("res://scripts/game/world_session.gd")
const WorldSessionModules = preload("res://scripts/game/world_session_modules.gd")
const SessionFrameGate = preload("res://scripts/geography/loading_frame_gate.gd")
var _runtime_session = WorldSession.new()
var _session_frames = SessionFrameGate.new()
var _session_extensions: Array = []
var _session_prepare_options: Dictionary = {}
var _generation_request := 0

var _overlay = preload("res://scripts/game/world_runtime_overlay.gd").new()
var publication_reader := preload("res://scripts/game/runtime_publication_reader.gd").new()
var _presentation = preload("res://scripts/game/world_runtime_presentation.gd").new()

const HostGmCommands = preload("res://scripts/game/world_runtime_gm_commands.gd")
const HostRecorders = preload("res://scripts/game/world_runtime_recorders.gd")
const HostValueHelpers = preload("res://scripts/game/world_runtime_host_values.gd")
var _lifecycle = preload("res://scripts/game/world_runtime_lifecycle.gd").new()
const RuntimeForensics = preload("res://scripts/game/runtime_forensics.gd")
const WORLD_SETUP_META := &"world_setup_config"
const DEFAULT_CLIMATE_PROFILE_PATH := "res://data/world/earth_like.tres"
const MOBILE_NATIVE_DAILY_STRIDE_DAYS: int = 20
const MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS: int = 20
const MOBILE_NATURAL_RESOURCE_STRIDE_DAYS: int = 10
const MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE: int = 8
const MOBILE_WEATHER_FIELD_ADVECT_STEPS: int = 2
## Military is a synchronous main-thread runtime (contract §0.1). In whole-graph
## ACTIVE the worker owns the day, so the host replays the military catch-up for
## every committed day it observes — same pattern as the natural-resource drain,
## but with its own 4-day budget because the native military day is the most
## expensive of the two.
const RUNTIME_MILITARY_CATCHUP_DAYS_PER_FRAME: int = 4
const MAP_OVERLAY_REFRESH_INTERVAL_MSEC: int = 100
# overlay 重烘焙是主线程 UI 工作，但「脏」标记由每个模拟日打出，高速下等于永久脏，
# 于是固定 100ms 节流会让它按实测成本无上限地吃墙钟（观测到单模拟日 102ms，是当日
# 模拟成本的六倍）。改为按实测成本反推间隔，把占空比压到 MAP_OVERLAY_DUTY 以内。
const MAP_OVERLAY_MAX_REFRESH_INTERVAL_MSEC: int = 750
const MAP_OVERLAY_DUTY: float = 0.05
const TRIGGER_COUNTRY_COMMAND := 10
const TRIGGER_PUBLISH_EVENT := 13
const COUNTRY_DISCOVER_SIGNAL := 14
const SettlementLabelLayerScript = preload(
	"res://scripts/rendering/settlement_label_layer.gd")
const PkmapIOScript = preload("res://scripts/geography/pkmap_io.gd")
const BuildingVisualIntelCacheScript = preload(
	"res://scripts/rendering/building_visual_intel_cache.gd")

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var continent_size: float = 0.9
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0
@export var generate_test_economy_data: bool = false
@export_enum("资源分层混合:0", "产能基线:1", "百人级:10", "千人级:100", "万人级:1000") \
var test_economy_population_scale: int = 0

## 视野迷雾总开关。实际生效还要求本局有 gameplay start context（正式对局），
## 调试 / 沙盒路径始终全图可见。
@export var fog_of_war_enabled: bool = true
## 主地形「完全未探索像素早退」。是可测量的性能实验，不是玩法开关：
## 净收益取决于迷雾层厚云是否真的比被跳过的地形管线便宜，须靠 headless perf
## A/B 决定。默认关。
@export var fog_early_out_enabled: bool = false

@export var cell_indirection_enabled: bool = true
@export var ocean_current_visual_enabled: bool = true
@export var sea_ice_atlas_enabled: bool = false
@export var mobile_terrain_horizon_enabled: bool = false
## Diagnostic worlds can prepare their data without starting a runtime.
var start_executor_on_generate: bool = true
var runtime_parity_forcing: bool = false
## Events POD remains an opt-in probe in Stage I. It mirrors the legacy journal
## and never becomes part of the ACTIVE authority mask.
var runtime_events_probe_enabled: bool = false
## Economy can promote its committed mirror after the initial complete day.
var runtime_economy_auto_pod_active: bool = true
## Threadless Web executes the native graph on the calling thread.
@export var runtime_native_daily_inline: bool = true
## Web can request the background executor instead of running it inline.
@export var runtime_web_worker: bool = false
## Web worker 的启动结果，进 diag：不用 grep 日志就能知道"到底起没起、为什么没起"。
## 空字符串 = 还没尝试过。
var _web_worker_start_code: String = ""
var _web_worker_start_ok: bool = false
## worker 要了但没成（拒绝启动 / ACTIVE 未被授予 / 能力缺失）时，本会话退回内联。
## 这个标志的存在理由：`_native_daily_inline_requested()` 与 `_web_worker_requested()`
## 互斥，一旦"worker 要了却起不来"，两边都不成立 ⇒ **没有任何日屏障执行者**
## ⇒ 日历停在 day 1（web 上表现为"世界不动"，且 fault_code 为空，极难查）。
var _web_worker_inline_fallback: bool = false
## 本次会话是否真的走内联日。只有 _start_runtime_executor 成功把它置真
## 之后，_admit_runtime_calendar 才会接管日历的推进。
var _native_daily_inline_active: bool = false
var _runtime_native_daily_inline_days: int = 0
var _runtime_native_daily_inline_pending_days: int = 0
var _runtime_native_daily_inline_last: Dictionary = {}
## Climate 权威下的回灌游标。worker 自带单调序号，与 commit generation 无关。
var _runtime_climate_writeback_generation: int = 0
var _runtime_climate_writeback_days: int = 0
var _runtime_climate_writeback_last_day: int = -1
var _runtime_climate_writeback_applied_fields: int = 0
var _runtime_climate_writeback_skipped: Array = []
## B8 P0：回灌分段耗时（worker 快照 → slot，slot → MapData）。只看 writeback_days
## 分不出"worker 慢"和"回灌慢"，这两条是分诊用的。
var _runtime_climate_writeback_memcpy_ms: float = 0.0
var _runtime_climate_writeback_flush_ms: float = 0.0
## 写回环的发布丢弃计数（worker 侧 ring 满时递增）。B8 的 50/50 验收要求它为 0。
var _runtime_climate_writeback_drops: int = 0
var _climate_runtime = preload("res://scripts/game/world_runtime_climate.gd").new()

var _renderer: HexRenderer = null
# GM 开关「关闭地形 GI」按下时暂存的三个强度原值，关掉开关时原样还回去。
var _gi_saved_strengths: Dictionary = {}
var _camera: MapCamera = null
var _world_clock: WorldClock = null
var _clock_binding = preload("res://scripts/game/runtime_clock_binding.gd").new()
var _map_overlay_layer: DataOverlayLayer = null
var _settlement_label_layer: SettlementLabelLayer:
	get: return _presentation._settlement_label_layer
	set(value): _presentation._settlement_label_layer = value
var _current_map: MapData = null
var _world_data: WorldData = null
var _generator: MapGenerator = null
var _exiting_tree := false
var _view_adapter: DCViewAdapter = null
var _selected_cell: HexCell = null
# ---- Military layers
# F owns the military_* map layers. The host only creates the manager node and
# forwards each scheduled publication poll (see military_map_layers.gd). Nothing else here.
var military_map_layers: Node = null
# Optional test/tool seam. Null means the manager keeps its native render feed;
# a test can inject a read-only feed without changing MilitaryCore or save state.
var military_render_feed = null
var military_map_polled_by_host: bool = true
# ---- Military layers
var _tod_profile: TODProfile = null
var day_night_enabled: bool = true
var _last_seed: int = 0
var _last_tick_report: Dictionary = {}
var _fast_tick_count: int = 0
var _last_fast_tick_ms: int = 0
var _last_tick_timing: Dictionary = {}
var _last_recorder_perf_summary: Dictionary = {}
var _last_ui_perf_summary: Dictionary = {}
var _perf_recorder: RefCounted = null
var _tile_data_recorder: RefCounted = null
var _economy_data_recorder: RefCounted = null
## 每种 fatal reason 只落盘一次；换了原因要重新抓，否则第二个缺陷会被第一个遮住。
var _economy_fatal_dumped_reason := ""
## 卡死看门狗：权威日停在同一天超过阈值就抓现场。0 表示关闭。
@export var stall_watchdog_threshold_msec: int = 15000
const STALL_WATCHDOG_REPEAT_MSEC := 30000
var _stall_watchdog_day: int = -1
var _stall_watchdog_day_started_msec: int = 0
var _stall_watchdog_next_report_msec: int = 0
## Web：runtime perf snapshot 的可用键名只发一次事件，避免反复猜字段名。
var _web_graph_keys_emitted := false
## 探针：web 上跳过「进世界后补」的建筑外观/定居点标签（它们首次绘制会编译新 shader）。
const PK_WEB_SKIP_DEFERRED_VISUAL_LAYERS := false
var _web_hooks_installed := false
var _web_phase_marks: Array = []
var _web_prev_frame_usec := 0
var _web_diag_ticks := 0
## Web 逐帧计时探针（前 120 帧）。
var _web_frame_probe_left := 120
var _web_frame_probe_last_usec := 0
const _RUNTIME_HEALTH_POLL_MSEC := 500
var _runtime_health_next_poll_msec: int = 0
var _pending_tick_start_usec: int = 0
var _pending_tick_sus_ms: float = 0.0
var _pending_tick_render_ms: float = 0.0
var _pending_tick_skipped_day: bool = false
var _map_overlay_request: Dictionary:
	get: return _overlay._map_overlay_request
	set(value): _overlay._map_overlay_request = value
var _map_overlay_tex: ImageTexture:
	get: return _overlay._map_overlay_tex
	set(value): _overlay._map_overlay_tex = value
var _map_overlay_image: Image:
	get: return _overlay._map_overlay_image
	set(value): _overlay._map_overlay_image = value
var _map_overlay_buf: PackedByteArray:
	get: return _overlay._map_overlay_buf
	set(value): _overlay._map_overlay_buf = value
var _map_overlay_dirty: bool:
	get: return _overlay._map_overlay_dirty
	set(value): _overlay._map_overlay_dirty = value
var _map_overlay_last_refresh_msec: int:
	get: return _overlay._map_overlay_last_refresh_msec
	set(value): _overlay._map_overlay_last_refresh_msec = value
var _map_overlay_refresh_count: int:
	get: return _overlay._map_overlay_refresh_count
	set(value): _overlay._map_overlay_refresh_count = value
var _map_overlay_merged_dirty_count: int:
	get: return _overlay._map_overlay_merged_dirty_count
	set(value): _overlay._map_overlay_merged_dirty_count = value
var _map_overlay_last_result: Dictionary:
	get: return _overlay._map_overlay_last_result
	set(value): _overlay._map_overlay_last_result = value
# 上一次重烘焙的实测毫秒，用于把 overlay 的墙钟占用限制在固定占空比内。
var _map_overlay_last_bake_ms: float:
	get: return _overlay._map_overlay_last_bake_ms
	set(value): _overlay._map_overlay_last_bake_ms = value
# 帧尾诊断累加器：自上一 perf 行以来的 overlay 重烘焙总毫秒（发布时清零）。
var _overlay_bake_ms_accum: float:
	get: return _overlay._overlay_bake_ms_accum
	set(value): _overlay._overlay_bake_ms_accum = value
# 帧墙钟：在 fast-tick 发布点用 Engine.get_process_frames() 差分测量（本节点
# 不一定挂在场景树里，不能依赖 _process 回调）。多 tick 帧取区间平均。
var _last_perf_publish_usec: int = 0
var _last_perf_publish_frame: int = 0
var _last_frame_wall_ms: float = 0.0
var _fog_of_war_enabled: bool = false
var _player_country_slot: int = -1
var _player_country_handle: int = 0
var _vision_dirty_indices: PackedInt32Array = PackedInt32Array()
var _runtime_vision_result: Dictionary = {}
var _building_visual_intel: BuildingVisualIntelCache:
	get: return _presentation._building_visual_intel
	set(value): _presentation._building_visual_intel = value
var _building_visual_next_poll_msec: int = 0
var _building_visual_type_count: int:
	get: return _presentation._building_visual_type_count
	set(value): _presentation._building_visual_type_count = value
var _building_visual_force_full_refresh: bool:
	get: return _presentation._building_visual_force_full_refresh
	set(value): _presentation._building_visual_force_full_refresh = value
var _building_visual_diag_logged: bool:
	get: return _presentation._building_visual_diag_logged
	set(value): _presentation._building_visual_diag_logged = value
## Country graph commits can arrive several times during one frame.  Queue a
## single visual refresh so territory/vision/LUT work is coalesced at the frame
## boundary instead of running once per native slice.
var _country_visual_refresh_pending: bool = false
var _country_visual_refresh_reason: String = "country_territory_committed"
var _session_request: Dictionary = {}
var _new_game_config: Dictionary = {}
var _load_slot_id: String = ""
var _pending_load_bundle: Dictionary = {}
var _runtime_ready_for_ticks: bool = false
var _native_environment_active := false
var _calendar_admitted_through := -1

var _runtime_commit_generation: int = 0
var _runtime_commit_day: int = -1
var _runtime_last_commit: Dictionary = {}
var _runtime_last_visual_apply_ms: float = 0.0
var _runtime_last_ui_feedback_ms: float = 0.0
var _runtime_last_gpu_upload_ms: float = 0.0
## Day-callback and host-_process segments for the perf CSV. Day fields are the
## most recent `_admit_runtime_calendar`. Process fields accumulate until the next
## perf row, then reset, so a row is the pump cost since the previous row.
var _sched_day_total_ms: float = 0.0
var _sched_day_report_ms: float = 0.0
var _sched_day_snapshots_ms: float = 0.0
var _sched_day_climate_writeback_ms: float = 0.0
var _sched_day_climate_wait_ms: float = 0.0
var _sched_day_capture_ms: float = 0.0
var _sched_day_country_peer_ms: float = 0.0
var _sched_day_country_read_ms: float = 0.0
## Web 单日成本探针的 host 侧分段（见 world_clock.gd 的 _dcp_seg 契约）。
## 只在 day_cost_probe_on 为真时被写入；桌面恒 0，且没有任何语句依赖它们。
var _dcp_inline_ms: float = 0.0
var _dcp_commit_ms: float = 0.0
var _dcp_publish_ms: float = 0.0
var _dcp_finish_ms: float = 0.0
var _dcp_resource_ms: float = 0.0
var _dcp_military_ms: float = 0.0
var _dcp_visual_ms: float = 0.0
var _sched_proc_frames: int = 0
var _sched_proc_economy_input_ms: float = 0.0
## day_changed 里容量检查/输入抓取被拒绝的次数（只在前 8 次打日志，避免刷屏）。
var _sched_proc_peer_ms: float = 0.0
var _sched_proc_snapshots_ms: float = 0.0
var _sched_proc_country_read_ms: float = 0.0
var _sched_proc_country_visual_ms: float = 0.0
var _sched_proc_commit_ms: float = 0.0
var _sched_proc_resource_ms: float = 0.0
var _sched_proc_visual_ms: float = 0.0
var _sched_proc_building_ms: float = 0.0
var _sched_proc_overlay_ms: float = 0.0
var _sched_proc_last_total_ms: float = 0.0
## Country vision/border refresh is off the day-boundary critical path. It runs
## under a per-frame wall budget so a full Dijkstra cannot inflate day_cost_ema.
const COUNTRY_VISUAL_REFRESH_BUDGET_MS: float = 3.0
const COUNTRY_VISUAL_REFRESH_MAX_DEFER_FRAMES: int = 30
var _country_visual_last_refresh_ms: float = 0.0
var _country_visual_refresh_deferred_frames: int = 0
var _country_visual_refresh_run_count: int = 0
var _country_visual_refresh_defer_count: int = 0
var _country_read_last_full_snapshot: bool = false
var _country_read_last_applied_cells: int = 0
var _country_read_last_territory_changed_cells: int = 0
## FAULTED worker parks the WorldClock and retains last-committed diagnostics.
var _runtime_worker_fault_paused: bool = false
var _runtime_last_fault_diagnostics: Dictionary = {}
var _country_worker_transport_capture: Dictionary = {}
var _modifier_worker_snapshot_generation: int = 0
var _country_worker_read_generation: int = 0
var _country_worker_read_last_day: int = -1
var _country_worker_read_last_result: Dictionary = {}
var _country_worker_read_patch_count: int = 0
var _country_worker_read_full_snapshot_count: int = 0
var _country_worker_read_rejected_count: int = 0
var _gm_sequence: int = 1
var _gm_territory_requests := {}
var _gm_territory_publication := 0
var _gm_click_claim_territory_enabled: bool = false
## GM UI 诊断开关：隐藏所有玩家界面，但保留 GM 面板本身可操作。
var _player_confirmation_view: Dictionary = {}
var _gm_tod_preview_enabled: bool = false
var _gm_tod_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _gm_tod_cycle_uv: Vector2 = Vector2(0.25, 0.5)
var _gm_tod_eternal_uv: Vector2 = Vector2(0.25, 0.5)
var _gm_tod_eternal_uv_valid: bool = false
var _gm_tod_sun_height_scale: float = 1.0

const GM_SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]
const GM_CASH_SCALE: int = 10000
const GM_GOODS_SCALE: int = 1000


var _gm_adapter = preload("res://scripts/game/world_runtime_gm_adapter.gd").new()
var _daily_adapter = preload("res://scripts/game/world_runtime_daily_adapter.gd").new()
var _web_beat_next_msec := 0
const _GI_STRENGTH_PROPS := ["gi_ao_strength", "gi_bent_strength", "gi_bounce_strength"]
var _visual_adapter = preload("res://scripts/game/world_runtime_visual_adapter.gd").new()
# Generation/worker preparation delegates to the passive adapter.
var _generation_adapter = preload("res://scripts/game/world_runtime_generation_adapter.gd").new()
func _sched_elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


## Both native execution modes use the same clock admission. The inline
## executor uses the frame callback because this platform has no worker.
func _run_admitted_inline_day() -> void:
	if not _native_daily_inline_active or not _runtime_ready_for_ticks \
			or _runtime_worker_fault_paused:
		return
	var committed := maxi(0, _runtime_commit_day)
	if _calendar_admitted_through <= committed:
		var report := _runtime_control_state()
		if int(report.get("player_advance_through", -1)) <= committed \
				or not String(report.get("player_block_reason", "")).is_empty():
			return
	var date := committed + 2
	WebTelemetry.emit("day_tick", {"s": "begin", "day": date})
	var started := Time.get_ticks_usec()
	_daily_adapter._run_native_daily_inline_day(self, date)
	_sched_day_total_ms = _sched_elapsed_ms(started)
	if _dcp_on():
		_dcp_publish_day(Time.get_ticks_usec() - started)
	WebTelemetry.emit("day_tick", {"s": "end", "day": date})


## Web 单日成本探针总开关（world 时钟持有桶）。桌面恒假。
func _dcp_on() -> bool:
	return _world_clock != null and _world_clock.day_cost_probe_on


## 把 host 这一天的分段一次性交给 WorldClock 的日桶。每个 tag 只写一次。
func _dcp_publish_day(elapsed_usec: int) -> void:
	var clock := _world_clock
	clock.day_cost_add(&"host", float(elapsed_usec) / 1000.0)
	clock.day_cost_add(&"rep", _sched_day_report_ms)
	clock.day_cost_add(&"wb", _sched_day_climate_writeback_ms)
	clock.day_cost_add(&"pcr", _sched_day_country_peer_ms)
	clock.day_cost_add(&"cap", _sched_day_capture_ms)
	clock.day_cost_add(&"wait", _sched_day_climate_wait_ms)
	clock.day_cost_add(&"inl", _dcp_inline_ms)
	clock.day_cost_add(&"cmt", _dcp_commit_ms)
	clock.day_cost_add(&"pub", _dcp_publish_ms)
	clock.day_cost_add(&"fin", _dcp_finish_ms)
	clock.day_cost_add(&"res", _dcp_resource_ms)
	clock.day_cost_add(&"mil", _dcp_military_ms)
	clock.day_cost_add(&"vis", _dcp_visual_ms)


func world_data() -> WorldData:
	return _world_data


func generator() -> MapGenerator:
	return _generator


func view_adapter() -> DCViewAdapter:
	return _view_adapter


var last_world_generation_error: Dictionary = {}


## 完整失败详情纯文本（多行）。UI "复制详情" 与日志文件共用同一段文本。
const PK_WEB_FORCE_NO_INLINE := false


func _native_daily_inline_requested() -> bool:
	return _daily_adapter._native_daily_inline_requested(self)
func _is_web_build() -> bool:
	return _daily_adapter._is_web_build(self)
func _web_worker_requested() -> bool:
	return _daily_adapter._web_worker_requested(self)
func _clear_web_daily_fallback_failure() -> void:
	_daily_adapter._clear_web_daily_fallback_failure(self)
func _reject_web_daily_fallback(code: String, reason: String) -> bool:
	return _daily_adapter._reject_web_daily_fallback(self, code, reason)
func _bind_overlay_resources() -> void:
	_daily_adapter._bind_overlay_resources(self)
func set_map_overlay(request: Dictionary) -> void:
	_daily_adapter.set_map_overlay(self, request)
func clear_map_overlay() -> void:
	_daily_adapter.clear_map_overlay(self)
func mark_map_overlay_dirty(_reason: StringName = &"runtime") -> void:
	_daily_adapter.mark_map_overlay_dirty(self, _reason)
func map_overlay_diagnostics() -> Dictionary:
	return _daily_adapter.map_overlay_diagnostics(self)
func _web_mark(phase: String) -> void:
	_daily_adapter._web_mark(self, phase)
func _web_flush_slow_frame_trace(dt_ms: int) -> void:
	_daily_adapter._web_flush_slow_frame_trace(self, dt_ms)
func _emit_web_frame_probe(frame_usec: int) -> void:
	_daily_adapter._emit_web_frame_probe(self, frame_usec)
func _emit_web_beat(frame_usec: int) -> void:
	_daily_adapter._emit_web_beat(self, frame_usec)
func _process(_delta: float) -> void:
	_run_admitted_inline_day()
	_daily_adapter._process(self, _delta)
	_presentation.publish_ui_view(simulation_ui_updated.emit)
	_presentation.publish_worker_view(simulation_view_updated.emit)
func _service_runtime_progress(frame_usec: int) -> void:
	_daily_adapter._service_runtime_progress(self, frame_usec)
func _runtime_control_state() -> Dictionary:
	return _daily_adapter._runtime_control_state(self)

func _observe_runtime_worker_fault(report: Dictionary = {}) -> void:
	_daily_adapter._observe_runtime_worker_fault(self, report)
func get_runtime_fault_diagnostics() -> Dictionary:
	return _daily_adapter.get_runtime_fault_diagnostics(self)
func is_runtime_fault_paused() -> bool:
	return _daily_adapter.is_runtime_fault_paused(self)
func _consume_modifier_worker_snapshot_if_authoritative() -> void:
	_daily_adapter._consume_modifier_worker_snapshot_if_authoritative(self)
func _consume_country_worker_read_view_if_authoritative() -> void:
	_daily_adapter._consume_country_worker_read_view_if_authoritative(self)
func _service_worker_map_presentation(frame_started_usec: int) -> void:
	var vision_changed := not _vision_dirty_indices.is_empty()
	_presentation.apply_pending_worker_map(_vision_dirty_indices, _publish_worker_map)
	var country_started_usec := Time.get_ticks_usec()
	_daily_adapter._service_country_visual_refresh_budgeted(self, frame_started_usec, vision_changed)
	_sched_proc_country_visual_ms += _sched_elapsed_ms(country_started_usec)

func _publish_worker_map(update: Dictionary, day: int, started_usec: int) -> bool:
	# Publish textures before the vision-dependent layers and weather read them.
	var result := _generator.publish_worker_climate_visuals(false, update) \
		if _generator != null else {"reason": "missing_generator"}
	if result.get("lut_encode_path", "none") == "none":
		if not _presentation._map_updates.needs_recovery:
			var message := "[worker-map] Day %d publication failed: %s" % [day, result.get("reason", "no_encode_path")]
			if result.get("map_lut_read_failed", false):
				push_error(message)
			else:
				push_warning(message)
		return false
	map_texture_published.emit(day)
	_vision_dirty_indices = PackedInt32Array()
	if _renderer != null and _world_clock != null:
		_renderer.set_season_phase(_world_clock.season_phase_for_day(day))
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
	mark_map_overlay_dirty(&"worker_committed")
	_runtime_last_visual_apply_ms = _sched_elapsed_ms(started_usec)
	_sched_proc_visual_ms += _runtime_last_visual_apply_ms
	if _dcp_on():
		_dcp_visual_ms = _runtime_last_visual_apply_ms
	_generator.record_runtime_visual_timings(_runtime_last_ui_feedback_ms,
		_runtime_last_visual_apply_ms, _runtime_last_gpu_upload_ms)
	return true

func _consume_runtime_commit_if_ready(report_override: Dictionary = {}) -> void:
	_daily_adapter._consume_runtime_commit_if_ready(self, report_override)
func military_report() -> Dictionary:
	return _daily_adapter.military_report(self)
func _apply_climate_writeback_if_authoritative(report: Dictionary) -> void:
	_daily_adapter._apply_climate_writeback_if_authoritative(self, report)
func finish_daily_tick(ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	_daily_adapter.finish_daily_tick(self, ui_ms, ui_breakdown)
func get_sim_breakdowns() -> Dictionary:
	return _daily_adapter.get_sim_breakdowns(self)
func get_environment_perf_summary() -> Dictionary:
	return _daily_adapter.get_environment_perf_summary(self)
func get_recorder_perf_summary() -> Dictionary:
	return _daily_adapter.get_recorder_perf_summary(self)
func dump_render_profile() -> Dictionary:
	return await _gm_adapter.dump_render_profile(self)
func set_perf_recorder(recorder: RefCounted) -> void:
	_gm_adapter.set_perf_recorder(self, recorder)
func get_perf_recorder() -> RefCounted:
	return _gm_adapter.get_perf_recorder(self)
func set_tile_data_recorder(recorder: RefCounted) -> void:
	_gm_adapter.set_tile_data_recorder(self, recorder)
func get_tile_data_recorder() -> RefCounted:
	return _gm_adapter.get_tile_data_recorder(self)
func set_economy_data_recorder(recorder: RefCounted) -> void:
	_gm_adapter.set_economy_data_recorder(self, recorder)
func get_economy_data_recorder() -> RefCounted:
	return _gm_adapter.get_economy_data_recorder(self)
func get_gm_capabilities() -> Dictionary:
	return _gm_adapter.get_gm_capabilities(self)
func get_gm_snapshot(section: String, _context: Dictionary = {}) -> Dictionary:
	return _gm_adapter.get_gm_snapshot(self, section, _context)
func execute_gm_command(command_id: String, raw_args: Dictionary) -> Dictionary:
	return _gm_adapter.execute_gm_command(self, command_id, raw_args)
func get_gm_toggle_state(toggle_id: String) -> Dictionary:
	return _gm_adapter.get_gm_toggle_state(self, toggle_id)
func set_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
	return _gm_adapter.set_gm_toggle(self, toggle_id, enabled)
func _gm_command_specs(technologies: PackedStringArray = PackedStringArray(),
		goods: PackedStringArray = PackedStringArray(),
		buildings: PackedStringArray = PackedStringArray()) -> Array:
	return _gm_adapter._gm_command_specs(self, technologies, goods, buildings)
func _gm_overview_snapshot() -> Dictionary:
	return _gm_adapter._gm_overview_snapshot(self)
func _poll_runtime_health() -> void:
	_gm_adapter._poll_runtime_health(self)
func _observe_economy_fatal(report: Dictionary) -> void:
	_gm_adapter._observe_economy_fatal(self, report)
func _poll_simulation_stall_watchdog() -> void:
	_gm_adapter._poll_simulation_stall_watchdog(self)
func _web_barrier_diag() -> Dictionary:
	return _gm_adapter._web_barrier_diag(self)
func _gm_selected_snapshot(cell_idx: int) -> Dictionary:
	return _gm_adapter._gm_selected_snapshot(self, cell_idx)
func _gm_resource_snapshot(cell_idx: int) -> Array:
	return _gm_adapter._gm_resource_snapshot(self, cell_idx)
func _gm_recorder_snapshot() -> Dictionary:
	return _gm_adapter._gm_recorder_snapshot(self)
func _gm_one_recorder_state(recorder: RefCounted) -> Dictionary:
	return _gm_adapter._gm_one_recorder_state(self, recorder)
func _gm_execute_country_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _gm_adapter._gm_execute_country_command(self, command_id, args, effective_day, sequence)
func _gm_execute_economy_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return _gm_adapter._gm_execute_economy_command(self, command_id, args, effective_day, sequence)
func _gm_validate_args(spec: Dictionary, raw_args: Dictionary) -> Dictionary:
	return _gm_adapter._gm_validate_args(self, spec, raw_args)
func _gm_convert_arg(value, spec: Dictionary) -> Dictionary:
	return _gm_adapter._gm_convert_arg(self, value, spec)
func _gm_find_command_spec(command_id: String) -> Dictionary:
	return _gm_adapter._gm_find_command_spec(self, command_id)
func _gm_resolve_cell(args: Dictionary) -> int:
	return _gm_adapter._gm_resolve_cell(self, args)
func _gm_selected_country_handle() -> int:
	return _gm_adapter._gm_selected_country_handle(self)
func _gm_set_click_claim_territory_enabled(enabled: bool) -> Dictionary:
	return _gm_adapter._gm_set_click_claim_territory_enabled(self, enabled)
func _gm_claim_selected_cell(cell: HexCell) -> void:
	_gm_adapter._gm_claim_selected_cell(self, cell)
func _gm_emit_claim_result(raw_result: Dictionary, cell_idx: int) -> void:
	_gm_adapter._gm_emit_claim_result(self, raw_result, cell_idx)
func _gm_scaled_positive(value, scale: int) -> int:
	return _gm_adapter._gm_scaled_positive(self, value, scale)
func _gm_renderer_toggle_state(property_name: String) -> Dictionary:
	return _gm_adapter._gm_renderer_toggle_state(self, property_name)
func _print_terrain_material_gate_state() -> void:
	_gm_adapter._print_terrain_material_gate_state(self)
func _print_cell_index_view_state() -> void:
	_gm_adapter._print_cell_index_view_state(self)
func _print_enum_lut_view_state() -> void:
	_gm_adapter._print_enum_lut_view_state(self)
func _print_river_flow_state() -> void:
	_gm_adapter._print_river_flow_state(self)
func dump_flow_tex_report() -> Dictionary:
	return await _gm_adapter.dump_flow_tex_report(self)
func _collect_flow_tex_report() -> Dictionary:
	return _gm_adapter._collect_flow_tex_report(self)
func _flow_buffer_stats(buffer: PackedFloat32Array, expected: int) -> Dictionary:
	return _gm_adapter._flow_buffer_stats(self, buffer, expected)
func _flow_texture_descriptor(texture) -> Dictionary:
	return _gm_adapter._flow_texture_descriptor(self, texture)
func _flow_format_descriptor(format: int) -> Dictionary:
	return _gm_adapter._flow_format_descriptor(self, format)
func _flow_sampler_inventory(material: ShaderMaterial) -> Array:
	return _gm_adapter._flow_sampler_inventory(self, material)
func _capture_flow_debug_view(view: int):
	return await _gm_adapter._capture_flow_debug_view(self, view)
func _decode_flow_texture_size_view(image) -> Dictionary:
	return _gm_adapter._decode_flow_texture_size_view(self, image)
func _summarize_flow_debug_image(image) -> Dictionary:
	return _gm_adapter._summarize_flow_debug_image(self, image)
func _print_flow_tex_report_section(name: String, value) -> void:
	_gm_adapter._print_flow_tex_report_section(self, name, value)
func _print_terrain_sampler_inventory() -> void:
	_gm_adapter._print_terrain_sampler_inventory(self)
func _print_daily_lut_upload_state(which: String) -> void:
	_gm_adapter._print_daily_lut_upload_state(self, which)
func _set_terrain_gi_disabled(disabled: bool) -> void:
	_gm_adapter._set_terrain_gi_disabled(self, disabled)
func _print_terrain_gi_state(tag: String) -> void:
	_gm_adapter._print_terrain_gi_state(self, tag)
func _gm_call_renderer_toggle(method: String, enabled: bool) -> bool:
	return _gm_adapter._gm_call_renderer_toggle(self, method, enabled)
func _gm_arg(name: String, type: String, required: bool) -> Dictionary:
	return _gm_adapter._gm_arg(self, name, type, required)
func _gm_choice_arg(name: String, choices) -> Dictionary:
	return _gm_adapter._gm_choice_arg(self, name, choices)
func _gm_positive_arg(name: String, type: String = "float") -> Dictionary:
	return _gm_adapter._gm_positive_arg(self, name, type)
func _gm_day_arg() -> Dictionary:
	return _gm_adapter._gm_day_arg(self)
func _gm_ok(message: String, queued: bool, effective_day: int) -> Dictionary:
	return _gm_adapter._gm_ok(self, message, queued, effective_day)
func _gm_error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return _gm_adapter._gm_error(self, code, message, data)
func _publish_fast_tick_perf_sample(
		t_sus_ms: float,
		t_render_ms: float,
		t_ui_ms: float,
		fast_ms: float,
		was_skipped_day: bool
) -> Dictionary:
	return _daily_adapter._publish_fast_tick_perf_sample(self, t_sus_ms, t_render_ms, t_ui_ms, fast_ms, was_skipped_day)
func _recorder_ready(recorder: RefCounted) -> bool:
	return _daily_adapter._recorder_ready(self, recorder)
func on_speed_changed(new_speed: float) -> void:
	_daily_adapter.on_speed_changed(self, new_speed)
func on_clock_running_changed(running: bool) -> void:
	_daily_adapter.on_clock_running_changed(self, running)
func _sync_runtime_worker_clock() -> void:
	_daily_adapter._sync_runtime_worker_clock(self)
func on_visual_day_phase_changed(visual_day_phase: float) -> void:
	_daily_adapter.on_visual_day_phase_changed(self, visual_day_phase)
func get_gm_tod_sun_preview() -> Dictionary:
	return _gm_adapter.get_gm_tod_sun_preview(self)
func set_gm_tod_sun_preview(enabled: bool, uv: Vector2 = Vector2(0.25, 0.5),
		height_scale: float = 1.0) -> Dictionary:
	return _gm_adapter.set_gm_tod_sun_preview(self, enabled, uv, height_scale)
func gm_tod_screen_to_sun_uv(screen_pos: Vector2) -> Vector2:
	return _gm_adapter.gm_tod_screen_to_sun_uv(self, screen_pos)
func gm_tod_sun_screen_position() -> Vector2:
	return _gm_adapter.gm_tod_sun_screen_position(self)
func _current_eternal_uv() -> Vector2:
	return _gm_adapter._current_eternal_uv(self)
func _gm_preview_marker_uv() -> Vector2:
	return _gm_adapter._gm_preview_marker_uv(self)
func _gm_live_sun_uv() -> Vector2:
	return _gm_adapter._gm_live_sun_uv(self)
func _apply_gm_tod_sun_preview() -> void:
	_gm_adapter._apply_gm_tod_sun_preview(self)
func _clear_gm_tod_sun_preview() -> void:
	_gm_adapter._clear_gm_tod_sun_preview(self)
func _bind_renderer_and_camera(safe_area: Rect2) -> void:
	await _visual_adapter._bind_renderer_and_camera(self, safe_area)
func _defer_settlement_labels_after_ready() -> void:
	await _visual_adapter._defer_settlement_labels_after_ready(self)
func _bind_settlement_labels() -> void:
	_visual_adapter._bind_settlement_labels(self)
func settlement_label_layer() -> SettlementLabelLayer:
	return _presentation._settlement_label_layer
func _bind_country_visuals() -> void:
	_visual_adapter._bind_country_visuals(self)
func _connect_country_committed() -> void:
	_visual_adapter._connect_country_committed(self)
func _on_country_committed(report: Dictionary) -> void:
	_visual_adapter._on_country_committed(self, report)
func _on_research_signal_discovered(event: Dictionary) -> void:
	_visual_adapter._on_research_signal_discovered(self, event)
func _cv_phase(name: String, started_usec: int) -> void:
	_visual_adapter._cv_phase(self, name, started_usec)
func refresh_country_visuals(reason: String) -> Dictionary:
	return _visual_adapter.refresh_country_visuals(self, reason)
func _refresh_resource_visual_context() -> void:
	_visual_adapter._refresh_resource_visual_context(self)
func _refresh_building_visual_intel(vision_report: Dictionary) -> Dictionary:
	return _visual_adapter._refresh_building_visual_intel(self, vision_report)
func player_country_slot() -> int:
	return _visual_adapter.player_country_slot(self)
func finalize_save_restore_visuals() -> Dictionary:
	return _visual_adapter.finalize_save_restore_visuals(self)
func _saved_player_start_cell() -> int:
	return _visual_adapter._saved_player_start_cell(self)
func _report_player_start_cell() -> int:
	return _visual_adapter._report_player_start_cell(self)
func _player_start_cell_drift() -> Dictionary:
	return _visual_adapter._player_start_cell_drift(self)
func is_fog_of_war_enabled() -> bool:
	return _visual_adapter.is_fog_of_war_enabled(self)
func set_fog_of_war_enabled(enabled: bool) -> Dictionary:
	return _visual_adapter.set_fog_of_war_enabled(self, enabled)
func _resolve_fog_of_war_enabled() -> bool:
	return _visual_adapter._resolve_fog_of_war_enabled(self)
func _resolve_player_country_slot() -> int:
	return _visual_adapter._resolve_player_country_slot(self)
func _resolve_player_country_handle() -> int:
	return _visual_adapter._resolve_player_country_handle(self)
func _resolve_player_start_cell() -> int:
	return _visual_adapter._resolve_player_start_cell(self)
func _sync_country_territory_to_map() -> Dictionary:
	return _visual_adapter._sync_country_territory_to_map(self)
func apply_runtime_vision_display() -> Dictionary:
	return _visual_adapter.apply_runtime_vision_display(self)

func _republish_cell_luts(dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = false) -> Dictionary:
	return _visual_adapter._republish_cell_luts(self, dirty_indices, force_full_encode)
func _refresh_country_borders() -> Dictionary:
	return _visual_adapter._refresh_country_borders(self)
func _rebuild_view_adapter() -> void:
	_visual_adapter._rebuild_view_adapter(self)
var _loading_visual_usec := 0
var _loading_visual_name := ""
const VISUAL_PROGRESS_START := 0.96
const VISUAL_PROGRESS_CEIL := 0.99
const VISUAL_PROGRESS_GAIN := 0.09
var _visual_progress := 0.0
