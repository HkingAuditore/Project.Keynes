extends Node
class_name WorldRuntimeHost

signal world_generation_started()
signal world_generation_failed(reason: String)
signal world_ready(map: MapData, world_data: WorldData, generator: MapGenerator, view_adapter: DCViewAdapter)
signal daily_tick_completed(report: Dictionary)
## 后台 worker 完整日提交通知。该信号只用于展示和诊断，订阅者不得推进模拟。
signal simulation_committed(from_day: int, to_day: int, generation: int)
signal country_peer_serviced(report: Dictionary)
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
const RUNTIME_ECONOMY_DOMAIN_MASK: int = 1 << 8
const RUNTIME_NATURAL_RESOURCE_CATCHUP_DAYS_PER_FRAME: int = 8
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
## Web-only escape hatch. Export/runtime property works without browser environment variables.
@export var runtime_web_allow_gdscript_daily_fallback: bool = false
## 生成/读档完成后在生产路径启动 SHADOW worker。探针可先打开
## runtime_parity_forcing，再让这里启动，避免二次 start 被热切换拒绝。
var runtime_shadow_on_generate: bool = true
var runtime_parity_forcing: bool = false
## Events POD remains an opt-in probe in Stage I. It mirrors the legacy journal
## and never becomes part of the ACTIVE authority mask.
var runtime_events_probe_enabled: bool = false
## Forwarded into start_runtime_worker. Default ACTIVE_ONLY (SHADOW StageOps = 0).
var runtime_economy_execution_mode: String = "ACTIVE_ONLY"
## Keep auto POD_ACTIVE off for player sessions until Effect ACK under worker
## ownership no longer pins country/economy day barriers.
var runtime_economy_auto_pod_active: bool = false
## 把 Climate 域交给 worker 当权威（per-domain ACTIVE），其余十一个域留在主线程。
## 打开后 dispatch_system_schedule 一次性抑制 14 个 climate 节点，MapData 由
## _consume_runtime_commit_if_ready 里的回灌写。
##
## 这是运行时可回退的开关：关掉它并重启 worker 即回到同步路径，主线程重新算
## climate。回退不需要重新生成世界——回灌一直把 worker 状态刷进 MapData，
## slot 与 MapData 在抑制期间保持同步。
##
## 生产默认【开】。抑制面覆盖 native daily slice 图里的 14 个 climate 节点，
## SeasonRefreshSystem 仍留在主线程（它是 SUS 里按 period_ticks 自驱的独立
## system，不在那张图里，而且它是地理级重算，本就该是主线程权威）。
##
## 两个权威写同一批 MapData 数组这件事已经解决：执行序在 _on_clock_day_changed
## 里钉成「回灌(第 N 天) → season refresh → capture(第 N+1 天输入)」，三者同一
## 调用栈内串行，不再依赖节点树的 _process 顺序。并发触碰同一批 slot 导致的
## 0xC0000005 也已修（native_parallel_executor 的 barrier 竞态）。
##
## 已知的两条限制，见 docs/architecture/migration.md
## 第 38 节的实测数字：
##   1. 小地图（≈2400 格）是负收益。climate 本来只占 0.27ms，capture 打包与回灌
##      memcpy 的固定开销比它还大。真正有意义的规模是万级格数以上。
##   2. 大地图上 worker 可能跟不上一天的预算（180x120 下 50 天只有 30 天的回灌
##      落地）。落不下的那天保持 MapData 原值，不是错值，但场会滞后。
##
## 这是运行时可回退的开关（见下方 set_runtime_climate_authority_enabled），回退
## 不需要重新生成世界。
var runtime_climate_authority_enabled: bool = true
## Domains requested for worker authority. Capability default remains the full
## Production request mask. Default is the full twelve-domain graph (0xFFF).
## Player sessions use the same mask so Trigger/Effect/Economy leave the main
## thread; 0x806 remains available for focused Climate|Country|COMMIT soaks.
@export var runtime_authority_domain_mask: int = 0xFFF
## native_daily_inline：单线程内联日。
##
## Web/wasm 上没有可用的 worker 线程。实测证据（浏览器 diag）：
##   fault_code = day_wait_peer_stall_timeout
##   simulation_thread_mode = OFF（requested = ACTIVE）
##   required_domain_mask = 4095 / implemented = 4095 / missing = 0
## 也就是说 ACTIVE 会被 per-domain 门降级成 OFF；而 Country 域的日屏障本来就是
## "等主线程把 CountryPeerIntent 泵进 Effect/Economy 再回传 result"，浏览器里
## 那条泵链不跑，worker 线程一旦起来就只会等到 5s 超时 → FAULTED → 日历冻结。
##
## 打开后 host 不再 spawn 线程，12 域日屏障由主线程逐日串行执行
## （DCWorldExt.run_native_daily_inline_day）；缺 peer 时当场把 Country peer
## 适配器推一轮再重试同一天，而不是在条件变量上等另一个线程。
##
## 桌面端默认不开：浏览器里(OS.has_feature("web"))才生效；桌面/headless 想验证
## 这条路径要显式给 PK_NATIVE_DAILY_INLINE=1（A/B 用）。
@export var runtime_native_daily_inline: bool = true
## Web 用回 native worker 的总开关（默认关闭）。
##
## 关：web 走 `runtime_native_daily_inline`（今天的行为，主线程逐日跑 12 域）。
## 开：web 真的起 worker 线程，并打开三条并行通道：
##   P1 环境帧在 `_process` 里预发布 N+1..N+K（单一发布者）
##   P2 Country peer 由 worker 入口自 promote（deferred 分支仍关闭，见报告）
##   P3 WorldClock 的判据从"有硬屏障"变成"领先量超预算"
##
## 解析顺序：环境变量 `PK_WEB_WORKER=1` > 本导出项 > false。
## 桌面/headless 上 `PK_NATIVE_DAILY_INLINE` 不变时，本开关**只影响 P1/P3**：
## 桌面本来就跑 worker，inline 本来就关着。
@export var runtime_web_worker: bool = false
## P1：环境帧预发布天数 K。0 = 关闭（每 day_changed 一帧，今天的行为）。
## web worker 开关打开时自动置 2（ring 4 槽：1 槽给 worker 正在消费、1 槽给
## 主线程正在写，剩 2 槽可预发布）。
@export var runtime_environment_prefetch_days: int = 0
## 预发布流水线深度（K）：worker 最多能领先日历多少天。
## 真机实测（RTX 4080 + 新 side module）：web 上 worker 是 **7.4 天/秒**、inline 是
## **9.8 天/秒** —— 所以 web 默认仍走 inline（见 _web_worker_requested）。
## 诊断数据说清了原因：worker 路径下单日派发只要 4 ms（inline 46 ms），但
## `prefetch_diag` 里 `lead_over` 长期占 60/66 条，有效吞吐由**跨线程交付节奏**决定。
## 试过把 K 从 2 加深到 6（让在途覆盖往返延迟）：7.43 → 7.45，**无改善**，
## 所以瓶颈不是流水线深度，不要再往这个方向调。已回落 2。
const WEB_WORKER_PREFETCH_DAYS := 2
## P3：领先量上限 = 预发布天数 + 本余量。
##
## 关键：它**必须显著大于 K**。预发布时间锚在日历上（`clock_day + K`），所以
## worker 的领先量在稳态下天然就是 ≤ K；把上限设成 K 会让"管线刚好装满"变成
## "日历停止推进"，而日历一停就再也不会有新帧 —— 两个机制互锁，实测卡在第 3 天。
##
## 于是这条通道的真实语义是**安全网**而不是油门：它只在"worker 被别的发布者
## 喂到日历之外"（P1 关闭、或某条路径绕过预发布器）时才生效，把跑飞封在
## K + 8 天以内（8 = worker 单批上限，见 worker_main 的 target_days clamp）。
const WORKER_LEAD_MARGIN_DAYS := 8
## 发布器的在途深度上限 = K + 本值。
##
## 真机实测（RTX 4080 + Chrome）：把它设成 K+8(=10) 之后 worker 已经追平 inline
## （9.93 vs 9.81 天/秒），但 `worker_time_input_wait_us` 仍有 52 ms/天、`lead` 顶在
## 10 —— 说明流水线又被填满、worker 在等下一帧。环境帧每帧约 0.5 MB，放到 40 天
## ≈20 MB，wasm 堆完全放得下；先看 input_wait 会不会塌下去。
const WORKER_PUBLISH_DEPTH_DAYS := 40
## P3：允许 worker 领先主线程日历的天数上限。0 = 关闭（`_lead_over_budget()`
## 恒 false ⇒ WorldClock 逐表达式等价于改动前）。web worker 开关打开时 = K。
var _max_worker_lead_days: int = 0
## Web worker 的启动结果，进 diag：不用 grep 日志就能知道"到底起没起、为什么没起"。
## 空字符串 = 还没尝试过。
var _web_worker_start_code: String = ""
var _web_worker_start_ok: bool = false
## worker 要了但没成（拒绝启动 / ACTIVE 未被授予 / 能力缺失）时，本会话退回内联。
## 这个标志的存在理由：`_native_daily_inline_requested()` 与 `_web_worker_requested()`
## 互斥，一旦"worker 要了却起不来"，两边都不成立 ⇒ **没有任何日屏障执行者**
## ⇒ 日历停在 day 1（web 上表现为"世界不动"，且 fault_code 为空，极难查）。
var _web_worker_inline_fallback: bool = false
## 只有**存盘**才会把预发布暂停成这个状态。区分它是必须的：
## `_environment_prefetch_days_active == 0` 可能是"能力门否掉了预发布"（例如
## side module 是旧的一份），而把那种情况误判成"存盘暂停"并自动恢复，会让
## 能力门在下一帧就被撤销 —— 发布权重新被预发布器独占、而预发布器根本发不出去
## ⇒ 环境帧为 0 ⇒ 日历停在 day 1（本轮 web 事故的同一个形态）。
var _environment_prefetch_suspended_for_save: bool = false
## K 本尊（预发布天数）。**必须与 `_max_worker_lead_days` 分开**：
## 前者是"发到 clock+K"，后者是"worker 领先超过 K+margin 就停日历"。把两者
## 用同一个变量会立刻互锁 —— 发到 clock+K+margin，worker 追到那里，lead 打满，
## 日历停，于是再也没有新帧（实测卡在第 3 / 第 15 天）。
var _environment_prefetch_days_active: int = 0
## 本次会话是否真的走内联日。只有 _start_production_shadow_worker 成功把它置真
## 之后，_on_clock_day_changed 才会接管日历的推进。
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
## B8 P3：等待切片。C++ 侧是条件变量等待，返回一次有界切片后由本层 pump
## Country peer 服务再进入下一次等待 —— 纯 C++ 等待无法回调 Godot 服务
## Country/Economy barrier，两者互等就是死锁。
const RUNTIME_CLIMATE_WAIT_SLICE_MS: int = 10
## B8-4：Climate ACTIVE 启用策略。requested 来自
## runtime_climate_authority_enabled（会话/玩家想不想要），effective 由
## override + 实测阈值决定。阈值证据落地前 auto 保持历史默认，见 policy 文件。
const ClimateAuthorityPolicyScript = preload("res://scripts/game/climate_authority_policy.gd")
# Use the preload instance type — not class_name ClimateAuthorityPolicy — so
# dependents (e.g. game_save_coordinator) can parse before global class registry.
var _climate_authority_policy = ClimateAuthorityPolicyScript.new()
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
# forwards one per-frame poll (see military_map_layers.gd). Nothing else here.
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
var _climate_capacity_pending_day: int = -1
var _climate_capacity_pending_since_msec: int = 0
const _CLIMATE_CAPACITY_STALL_DIAG_MSEC := 3000
var _climate_capacity_stall_next_diag_msec: int = 0
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
var _physical_visible_arr: PackedByteArray = PackedByteArray()
var _vision_dirty_indices: PackedInt32Array = PackedInt32Array()
## Committed military positions used as low-budget vision sources. The source
## list is refreshed only when the military render revision changes.
var _military_vision_render_revision: int = -1
var _military_vision_source_slot: int = -2
var _military_vision_source_cells: PackedInt32Array = PackedInt32Array()
## Auto-exploration freezes the player's explored map once per military day.
## The trail is explored-only; visible/fog remain owned by `_refresh_vision`.
var _military_exploration_last_view_day: int = -1
var _military_exploration_last_trail_cells: int = 0
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
var _native_vision_configured_n: int = -1
var _native_vision_configured_map_id: int = 0
var _magnetic_navigation_dense_id: int = -2
var _remote_observation_capability: bool = false
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
var _runtime_commit_generation: int = 0
var _runtime_commit_day: int = -1
var _runtime_commit_family_cursors: Dictionary = {}
var _runtime_commit_family_done: Dictionary = {}
var _runtime_pending_visual_generation: int = 0
var _runtime_pending_dirty_families: int = 0
var _runtime_last_commit: Dictionary = {}
## Whole-graph ACTIVE bypasses SUS, so natural resources need a separate
## committed-day cursor.  The target remains queued while the Economy boundary
## lock is held by the worker and is drained on a later render frame.
var _runtime_natural_resource_last_commit_day: int = 0
var _runtime_natural_resource_pending_target_day: int = -1
var _runtime_natural_resource_last_result: Dictionary = {}
## Military committed-day cursor for whole-graph ACTIVE. The military day reads
## committed Country/Economy state, so it can only run after the commit that
## exposes day D; `target` stays queued until that boundary is visible.
var _runtime_military_last_commit_day: int = -1
var _runtime_military_pending_target_day: int = -1
var _runtime_military_last_result: Dictionary = {}
var _runtime_military_ms: float = 0.0
## Season index whose cover the military terrain layer currently holds; -1 until
## the first observed day.
var _military_terrain_season_index: int = -1
var _runtime_last_visual_apply_ms: float = 0.0
var _runtime_last_ui_feedback_ms: float = 0.0
var _runtime_last_gpu_upload_ms: float = 0.0
## Day-callback and host-_process segments for the perf CSV. Day fields are the
## most recent `_on_clock_day_changed`. Process fields accumulate until the next
## perf row, then reset, so a row is the pump cost since the previous row.
var _sched_day_total_ms: float = 0.0
var _sched_day_report_ms: float = 0.0
var _sched_day_snapshots_ms: float = 0.0
var _sched_day_climate_writeback_ms: float = 0.0
var _sched_day_climate_wait_ms: float = 0.0
var _sched_day_capture_ms: float = 0.0
var _sched_day_country_peer_ms: float = 0.0
var _sched_day_country_read_ms: float = 0.0
var _sched_day_promote_ms: float = 0.0
## Web 单日成本探针的 host 侧分段（见 world_clock.gd 的 _dcp_seg 契约）。
## 只在 day_cost_probe_on 为真时被写入；桌面恒 0，且没有任何语句依赖它们。
var _dcp_inline_ms: float = 0.0
var _dcp_commit_ms: float = 0.0
var _dcp_publish_ms: float = 0.0
var _dcp_finish_ms: float = 0.0
var _dcp_resource_ms: float = 0.0
var _dcp_military_ms: float = 0.0
var _dcp_visual_ms: float = 0.0
## 单日单推进声明是否启用（web / 显式内联 A/B）。桌面恒 false。
var _day_barrier_claim_enabled: bool = false
var _sched_proc_frames: int = 0
var _sched_proc_economy_input_ms: float = 0.0
## day_changed 里容量检查/输入抓取被拒绝的次数（只在前 8 次打日志，避免刷屏）。
var _day_capture_blocked_logs: int = 0
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
var _country_worker_transport_last_service: Dictionary = {}
var _country_worker_transport_capture: Dictionary = {}
var _modifier_worker_snapshot_generation: int = 0
var _effect_worker_snapshot_generation: int = 0
var _ideology_worker_snapshot_generation: int = 0
var _trigger_worker_snapshot_generation: int = 0
# R-3d: correctness counters for the GDScript ideology-intent reply.
#
# `submit_ideology_worker_ack` claims that the Effect side committed the transition.
# Two ways that claim can be wrong, both counted here so they are observable instead
# of silent:
#   * duplicate — the same transaction answered twice (a retry raced the first reply,
#     or the POD emitted two intents for one transition);
#   * unknown — an intent with no request id, i.e. nothing to reply to.
# Under the production 0xFFF mask the worker owns EFFECT and drains these itself, so
# BOTH must stay 0: any other value means the fallback pump fired when it should not.
var _ideology_intent_duplicate_acks: int = 0
var _ideology_intent_unknown_acks: int = 0
var _ideology_acked_transactions: Dictionary = {}
# Trigger delivery still uses Effect's native domain adapters. Keep its facade
# transaction alive until Country acknowledges and the worker admits its ACK.
# Effect ids are ingress-allocated while delivery is canonical, so the exact id
# set from handoff_effects() is retained; the legacy max-id cursor below is kept
# only for old-DLL fallback and reporting.
var _trigger_country_delivery_id: int = 0
var _trigger_country_delivery_ids: PackedInt64Array = PackedInt64Array()
var _trigger_country_delivery_ack_sent := false
var _trigger_country_delivery_waiting := false
var _completed_research_signals_reconciled := false
var _country_worker_read_generation: int = 0
var _country_worker_read_last_day: int = -1
var _country_worker_read_last_result: Dictionary = {}
var _country_worker_read_patch_count: int = 0
var _country_worker_read_full_snapshot_count: int = 0
var _country_worker_read_rejected_count: int = 0
var _gm_sequence: int = 1
var _gm_click_claim_territory_enabled: bool = false
var _gm_suppress_popups: bool = false
## GM UI 诊断开关：隐藏所有玩家界面，但保留 GM 面板本身可操作。
var _gm_hide_all_except_gm: bool = false
var _gm_click_claim_pending_days: Dictionary = {}
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
const _PREFETCH_DIAG_INTERVAL_MSEC := 2000
var _prefetch_diag_last_code: StringName = &""
var _prefetch_diag_counts: Dictionary = {}
var _prefetch_diag_next_msec: int = 0
var _prefetch_diag_publish_count: int = 0
var _prefetch_diag_emit_count: int = 0
var _prefetch_diag_last_reason: String = ""
var _prefetch_diag_last_capture_usec: int = 0
var _prefetch_diag_boot: Dictionary = {}
var _prefetch_diag_snapshot: Dictionary = {}
var _prefetch_diag_on_cache: int = -1
var _prefetch_boot_emitted: bool = false
var _ideology_refresh_pending_day: int = -1
var _ideology_instance_refreshed_day: int = -1
var _ideology_derived_pumped_day: int = -1
var _ideology_pump_calls: int = 0
var _ideology_pump_last: Dictionary = {}
var _ideology_instance_refresh_last: Dictionary = {}
const _GI_STRENGTH_PROPS := ["gi_ao_strength", "gi_bent_strength", "gi_bounce_strength"]
var _visual_adapter = preload("res://scripts/game/world_runtime_visual_adapter.gd").new()
# Generation/worker preparation delegates to the passive adapter.
func _prepare_world_data() -> Dictionary:
	return await _generation_adapter._prepare_world_data(self)
func _prepare_world_presentation() -> Dictionary:
	return await _generation_adapter._prepare_world_presentation(self)
func _prepare_world_restore() -> Dictionary:
	return _generation_adapter._prepare_world_restore(self)
func _restore_prepared_world() -> Dictionary:
	return _generation_adapter._restore_prepared_world(self)
func _prepare_world_simulation() -> Dictionary:
	return await _generation_adapter._prepare_world_simulation(self)
func _session_preparation_active() -> bool:
	return _generation_adapter._session_preparation_active(self)
func _session_preparation_failure() -> Dictionary:
	return _generation_adapter._session_preparation_failure(self)
func _start_production_shadow_worker() -> void:
	_generation_adapter._start_production_shadow_worker(self)
func _apply_web_worker_parallel_channels(climate_authority_active: bool,
		started: Dictionary) -> void:
	return _generation_adapter._apply_web_worker_parallel_channels(self, climate_authority_active, started)
func _release_prefetch_barrier_to_clock() -> void:
	_generation_adapter._release_prefetch_barrier_to_clock(self)
func _environment_prefetch_capable() -> bool:
	return _generation_adapter._environment_prefetch_capable(self)
func _stop_previous_runtime_worker() -> Dictionary:
	return await _generation_adapter._stop_previous_runtime_worker(self)
var _generation_adapter = preload("res://scripts/game/world_runtime_generation_adapter.gd").new()
func configure(
	renderer: HexRenderer,
	camera: MapCamera,
	world_clock: WorldClock,
	map_overlay_layer: DataOverlayLayer = null
) -> void:
	_clock_binding.detach()
	if _world_clock != null:
		var old_day_callback := Callable(self, "_on_clock_day_changed")
		if _world_clock.day_changed.is_connected(old_day_callback):
			_world_clock.day_changed.disconnect(old_day_callback)
	if _camera != null and _camera.zoom_changed.is_connected(_on_camera_zoom_changed):
		_camera.zoom_changed.disconnect(_on_camera_zoom_changed)
	if _camera != null and _camera.view_changed.is_connected(_on_camera_view_changed):
		_camera.view_changed.disconnect(_on_camera_view_changed)
	_renderer = renderer
	_camera = camera
	_world_clock = world_clock
	if _renderer != null and _world_clock != null:
		_renderer.configure_shader_clock(_world_clock.set_visual_shader_days_per_year)
	_map_overlay_layer = map_overlay_layer
	if _world_clock != null:
		var day_callback := Callable(self, "_on_clock_day_changed")
		if not _world_clock.day_changed.is_connected(day_callback):
			_world_clock.day_changed.connect(day_callback)
	if _camera != null:
		_camera.zoom_changed.connect(_on_camera_zoom_changed)
		_camera.view_changed.connect(_on_camera_view_changed)
		_on_camera_zoom_changed(_camera.zoom.x)
		_on_camera_view_changed(_camera.current_world_view_rect(), _camera.position, _camera.zoom.x)
	set_process(false)
	_init_tod_profile()
	_day_barrier_claim_enabled = OS.has_feature("web") or _native_daily_inline_requested()


func _sched_elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


## native_daily_inline：把这一天在调用线程上跑完。
##
## 与 worker 权威路径同序：回灌(第 N-1 天) → peer 泵 → capture(第 N 天输入)
## → 主线程执行 12 域日屏障 → 消费提交。区别只有"谁执行"：这里没有另一个线程，
## 所以任何一步都不允许去等条件变量；缺 peer 时由 C++ 侧在同一线程上把 Country
## peer 适配器推一轮再重试同一天。
func _run_native_daily_inline_day(day_idx: int, report: Dictionary) -> Dictionary:
	return _daily_adapter._run_native_daily_inline_day(self, day_idx, report)
func _on_clock_day_changed(day_idx: int) -> void:
	# 首日挂死定位：进入/离开日 tick 各发一条带绝对时间戳的事件，
	# 静默前最后一条就能区分"挂在 tick 里"还是"挂在 tick 之后"。
	WebTelemetry.emit("day_tick", {"s": "begin", "day": day_idx})
	# Web 单日成本探针：host 这一段的**唯一**一次 epoch 采样。桌面 _dcp_on() 为
	# 假 → 走 else 分支，与原实现逐语句等价。
	if _dcp_on():
		var dcp_usec := Time.get_ticks_usec()
		_clock_day_changed_impl(day_idx)
		_dcp_publish_day(Time.get_ticks_usec() - dcp_usec)
	else:
		_clock_day_changed_impl(day_idx)
	WebTelemetry.emit("day_tick", {"s": "end", "day": day_idx})


## Web 单日成本探针总开关（world 时钟持有桶）。桌面恒假。
func _dcp_on() -> bool:
	return _world_clock != null and _world_clock.day_cost_probe_on


## 单日单推进声明（见 world_clock.gd 的 claim_day_advance）。
## 只有 web / 显式内联 A/B 才登记：桌面上 main.gd 与 WorldRuntimeHost 从不出现在
## 同一个场景里（player_game.tscn 无 main.gd，main.tscn 无 RuntimeHost），声明
## 恒为空，写它没有任何收益 —— 保持桌面路径零多余写入。
func _claim_day_for_native(day_idx: int, owner: StringName) -> void:
	if not _day_barrier_claim_enabled or _world_clock == null:
		return
	_world_clock.claim_day_advance(owner, day_idx)


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


func _clock_day_changed_impl(day_idx: int) -> void:
	_daily_adapter._clock_day_changed_impl(self, day_idx)
func _on_camera_zoom_changed(value: float) -> void:
	if _renderer != null:
		_renderer.set_camera_zoom(value)


func _on_camera_view_changed(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	if _renderer != null and _renderer.has_method("set_camera_view"):
		_renderer.set_camera_view(world_rect, center, zoom_value)


func configure_session(request: Dictionary) -> Dictionary:
	_session_request = request.duplicate(true)
	_new_game_config.clear()
	_load_slot_id = ""
	_pending_load_bundle.clear()
	var kind := String(request.get("kind", ""))
	if kind == "new_game":
		var parsed := NewGameConfig.from_dictionary(request.get("config", {}))
		if not bool(parsed.get("ok", false)):
			return parsed
		_new_game_config = (parsed.config as NewGameConfig).to_dictionary()
		return {"ok": true, "code": "ok", "message": ""}
	if kind == "load_game":
		_load_slot_id = String(request.get("slot_id", ""))
		var save_service := _game_save_service()
		if save_service == null:
			return {"ok": false, "code": "game_save_unavailable", "message": "存档服务不可用。"}
		var prepared: Dictionary = save_service.prepare_load(_load_slot_id)
		if not bool(prepared.get("ok", false)):
			return prepared
		var parsed := NewGameConfig.from_dictionary(prepared.get("config", {}))
		if not bool(parsed.get("ok", false)):
			return parsed
		_new_game_config = (parsed.config as NewGameConfig).to_dictionary()
		_pending_load_bundle = prepared.get("bundle", {})
		return {"ok": true, "code": "ok", "message": ""}
	return {"ok": false, "code": "session_request_invalid", "message": "游戏会话请求无效。"}


## 用节点路径解析而非全局标识符，因为 `--script` 无头工具链不注册 autoload。
func _game_save_service() -> Node:
	return get_node_or_null(^"/root/GameSave")


func _game_flow_service() -> Node:
	return get_node_or_null(^"/root/GameFlow")


func current_map() -> MapData:
	return _current_map


func building_visual_intel_cache() -> BuildingVisualIntelCache:
	return _building_visual_intel


func building_visual_type_count() -> int:
	return _building_visual_type_count


## Rebinds the renderer to the authored economy catalog. Save restore calls this
## immediately after PKEC so PKFG validation sees the real type upper bound.
## During pre-restore world generation the economy facade can legitimately be
## unconfigured; that state is deferred without emitting a false stale-DLL warning.
## Web 专用：把 building visual catalog 的构建推到进世界之后。
## 这一步（economy facade 目录 + renderer.configure_building_visuals）在浏览器里
## 实测 42s，放在加载路径里会把"进世界"卡死；延后执行只影响建筑外观的可用时间。
func _defer_building_visual_catalog_after_ready() -> void:
	await _generation_adapter._defer_building_visual_catalog_after_ready(self)
func _bind_presentation_resources() -> void:
	_presentation.bind_resources(_current_map, _generator, _renderer, _camera,
		_fog_of_war_enabled, hex_size, map_wrap_period_x())


func refresh_building_visual_catalog() -> Dictionary:
	_bind_presentation_resources()
	return _presentation.refresh_building_visual_catalog()


func set_selected_cell(cell: HexCell) -> void:
	_selected_cell = cell
	if cell != null and _gm_click_claim_territory_enabled:
		_gm_claim_selected_cell(cell)


func get_selected_cell() -> HexCell:
	return _selected_cell


func world_data() -> WorldData:
	return _world_data


func generator() -> MapGenerator:
	return _generator


func view_adapter() -> DCViewAdapter:
	return _view_adapter


func last_seed() -> int:
	return _last_seed


## 把本次生成真正使用的 seed 写回会话 config（`base.initial_seed`）。
## 0 表示「随机」（map_generator.gd generate(): `cfg.seed != 0 else randi()`），
## 所以任何生成路径都可能产出一个配置文件里没有的 seed；不写回的话，之后存档
## 记录的是旧 seed，读档重建出的是另一张世界，起始格/领土/地形互相矛盾。
func _adopt_generated_seed(generated_seed: int) -> void:
	_generation_adapter._adopt_generated_seed(self, generated_seed)
var last_world_generation_error: Dictionary = {}


## 完整失败详情纯文本（多行）。UI "复制详情" 与日志文件共用同一段文本。
func last_world_generation_error_text() -> String:
	return _generation_adapter.last_world_generation_error_text(self)
func _report_world_generation_failure(preflight_override: Dictionary = {}) -> void:
	_generation_adapter._report_world_generation_failure(self, preflight_override)
func _emit_world_generation_failure(stage: String, reason: String, summary: String, hint: String) -> void:
	_generation_adapter._emit_world_generation_failure(self, stage, reason, summary, hint)
func _format_world_generation_detail(stage: String, reason: String, summary: String, hint: String) -> String:
	return _generation_adapter._format_world_generation_detail(self, stage, reason, summary, hint)
func _world_generation_failure_summary(err: Dictionary) -> String:
	return _generation_adapter._world_generation_failure_summary(self, err)
func _maybe_run_mapgen_selfcheck_cli() -> void:
	_generation_adapter._maybe_run_mapgen_selfcheck_cli(self)
func _ready() -> void:
	_maybe_run_mapgen_selfcheck_cli()


func session_config() -> Dictionary:
	return _new_game_config.duplicate(true)


func last_tick_report() -> Dictionary:
	return _last_tick_report.duplicate()


func is_runtime_ready_for_ticks() -> bool:
	return _runtime_ready_for_ticks


func set_day_night_enabled(enabled: bool) -> void:
	day_night_enabled = enabled
	if _renderer != null:
		_renderer.set_day_night_enabled(enabled)
	if _gm_tod_preview_enabled:
		_gm_tod_sun_uv = _gm_tod_cycle_uv if enabled else _current_eternal_uv()
		if enabled and _world_clock != null:
			_world_clock.hold_visual_day_phase(_gm_tod_cycle_uv.x)
		_apply_gm_tod_sun_preview()
		gm_tod_preview_changed.emit(true)
		return
	if _tod_profile == null or _renderer == null:
		return
	var phase := _world_clock.visual_day_phase if _world_clock != null else 0.25
	_tod_profile.recompute(phase, enabled)
	if _renderer.has_method("apply_tod"):
		_renderer.apply_tod(_tod_profile)


func is_day_night_enabled() -> bool:
	return day_night_enabled


func register_session_module(module) -> Dictionary:
	if _generator != null or _runtime_session.report().state != "CONFIGURING":
		return {"ok": false, "code": "session_composition_locked"}
	if module == null or not module.has_method("descriptor"):
		return {"ok": false, "code": "session_module_contract_invalid"}
	var candidate := _session_extensions.duplicate()
	candidate.append(module)
	var result: Dictionary = _runtime_session.configure(WorldSessionModules.entries(self, candidate))
	if bool(result.get("ok", false)):
		_session_extensions = candidate
	return result


func session_report() -> Dictionary:
	return _runtime_session.report()


func is_session_closing() -> bool:
	return _runtime_session.is_closing()


func begin_state_capture() -> Dictionary:
	return _runtime_session.begin_capture()


func end_state_capture() -> void:
	_runtime_session.end_capture()


func generate_world(seed_override: int = -1, safe_area: Rect2 = Rect2()) -> void:
	await _generation_adapter.generate_world(self, seed_override, safe_area)
func close_world() -> Dictionary:
	return await _lifecycle.close_world(self)


func _cancel_world_preparation() -> void:
	_lifecycle.cancel_world_preparation(self)


func _cancel_session_simulation() -> void:
	_lifecycle.cancel_session_simulation(self)


func _release_session_simulation() -> Dictionary:
	return await _lifecycle.release_session_simulation(self)


func _cancel_session_presentation() -> void:
	_lifecycle.cancel_session_presentation(self)


func _release_session_presentation() -> Dictionary:
	return _lifecycle.release_session_presentation(self)


func _release_world_data() -> Dictionary:
	return await _lifecycle.release_world_data(self)


func _session_noop() -> void:
	_generation_adapter._session_noop(self)
func _session_ok() -> Dictionary:
	return _generation_adapter._session_ok(self)
const PK_WEB_FORCE_NO_INLINE := false


func _native_daily_inline_requested() -> bool:
	return _daily_adapter._native_daily_inline_requested(self)
func _is_web_build() -> bool:
	return _daily_adapter._is_web_build(self)
func _web_worker_requested() -> bool:
	return _daily_adapter._web_worker_requested(self)
func _clear_web_daily_fallback_failure() -> void:
	_daily_adapter._clear_web_daily_fallback_failure(self)
func _web_gdscript_daily_fallback_allowed() -> bool:
	return _daily_adapter._web_gdscript_daily_fallback_allowed(self)
func _reject_web_daily_fallback(code: String, reason: String) -> bool:
	return _daily_adapter._reject_web_daily_fallback(self, code, reason)
func _effective_environment_prefetch_days() -> int:
	return _daily_adapter._effective_environment_prefetch_days(self)
func _preparation_process_frame() -> void:
	await get_tree().process_frame


func is_loading_session() -> bool:
	return not _load_slot_id.is_empty()


# Daily and worker methods delegate to the passive adapter.
func run_daily_tick(day_idx: int, season_phase: float) -> Dictionary:
	return _daily_adapter.run_daily_tick(self, day_idx, season_phase)
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
	_daily_adapter._process(self, _delta)
func _service_worker_lead_and_prefetch() -> void:
	_daily_adapter._service_worker_lead_and_prefetch(self)
func _prefetch_diag_tick_prep() -> void:
	_daily_adapter._prefetch_diag_tick_prep(self)
func _prefetch_diag_enabled() -> bool:
	return _daily_adapter._prefetch_diag_enabled(self)
func _emit_prefetch_boot_once() -> void:
	_daily_adapter._emit_prefetch_boot_once(self)
func _prefetch_diag_boot_payload() -> Dictionary:
	return _daily_adapter._prefetch_diag_boot_payload(self)
func _prefetch_diag_note(code: StringName) -> void:
	_daily_adapter._prefetch_diag_note(self, code)
func _prefetch_diag_collect_extras() -> void:
	_daily_adapter._prefetch_diag_collect_extras(self)
func _prefetch_diag_seen_text() -> String:
	return _daily_adapter._prefetch_diag_seen_text(self)
func _emit_prefetch_diag(code: StringName) -> void:
	_daily_adapter._emit_prefetch_diag(self, code)
func _suspend_environment_prefetch_for_save(reason: String) -> void:
	_daily_adapter._suspend_environment_prefetch_for_save(self, reason)
func _resume_environment_prefetch_after_save() -> void:
	_daily_adapter._resume_environment_prefetch_after_save(self)
func _poll_environment_prefetch_resume() -> void:
	_daily_adapter._poll_environment_prefetch_resume(self)
func _service_runtime_liveness(frame_usec: int, _capacity_pending: bool) -> void:
	_daily_adapter._service_runtime_liveness(self, frame_usec, _capacity_pending)
func _service_runtime_progress(frame_usec: int) -> void:
	_daily_adapter._service_runtime_progress(self, frame_usec)
func _arm_climate_capacity_pending(day_idx: int) -> void:
	_daily_adapter._arm_climate_capacity_pending(self, day_idx)
func _clear_climate_capacity_pending() -> void:
	_daily_adapter._clear_climate_capacity_pending(self)
func _note_climate_capacity_pending_stall() -> void:
	_daily_adapter._note_climate_capacity_pending_stall(self)
func _runtime_control_state() -> Dictionary:
	return _daily_adapter._runtime_control_state(self)
func _observe_runtime_worker_fault(report: Dictionary = {}) -> void:
	_daily_adapter._observe_runtime_worker_fault(self, report)
func get_runtime_fault_diagnostics() -> Dictionary:
	return _daily_adapter.get_runtime_fault_diagnostics(self)
func is_runtime_fault_paused() -> bool:
	return _daily_adapter.is_runtime_fault_paused(self)
func _service_country_worker_transport() -> void:
	_daily_adapter._service_country_worker_transport(self)
func _consume_modifier_worker_snapshot_if_authoritative() -> void:
	_daily_adapter._consume_modifier_worker_snapshot_if_authoritative(self)
func _consume_effect_worker_snapshot_if_authoritative() -> void:
	_daily_adapter._consume_effect_worker_snapshot_if_authoritative(self)
func _service_effect_worker_intents_if_authoritative() -> void:
	_daily_adapter._service_effect_worker_intents_if_authoritative(self)
func _step_ideology_instance_refresh_if_authoritative(day_idx: int) -> void:
	_daily_adapter._step_ideology_instance_refresh_if_authoritative(self, day_idx)
func _consume_ideology_worker_snapshot_if_authoritative() -> void:
	_daily_adapter._consume_ideology_worker_snapshot_if_authoritative(self)
func _service_ideology_worker_intents_if_authoritative() -> void:
	_daily_adapter._service_ideology_worker_intents_if_authoritative(self)
func _consume_trigger_worker_snapshot_if_authoritative() -> void:
	_daily_adapter._consume_trigger_worker_snapshot_if_authoritative(self)
func _service_trigger_worker_intents_if_authoritative() -> void:
	_daily_adapter._service_trigger_worker_intents_if_authoritative(self)
func _service_trigger_country_delivery(trigger, effect, report: Dictionary) -> void:
	_daily_adapter._service_trigger_country_delivery(self, trigger, effect, report)
func _ack_trigger_delivery_ids(trigger) -> Dictionary:
	return _daily_adapter._ack_trigger_delivery_ids(self, trigger)
func _consume_country_worker_read_view_if_authoritative() -> void:
	_daily_adapter._consume_country_worker_read_view_if_authoritative(self)
func _service_country_visual_refresh_budgeted(frame_started_usec: int) -> void:
	_daily_adapter._service_country_visual_refresh_budgeted(self, frame_started_usec)
func _poll_military_vision_revision() -> void:
	_visual_adapter.poll_military_vision_revision(self)
func _observe_military_render_feed(feed) -> void:
	_visual_adapter.observe_military_render_feed(self, feed)
func _consume_runtime_commit_if_ready(report_override: Dictionary = {}) -> void:
	_daily_adapter._consume_runtime_commit_if_ready(self, report_override)
func _queue_runtime_natural_resource_commit(day: int) -> void:
	_daily_adapter._queue_runtime_natural_resource_commit(self, day)
func _drain_runtime_natural_resource_commits() -> void:
	_daily_adapter._drain_runtime_natural_resource_commits(self)
func _queue_runtime_military_commit(day: int) -> void:
	_daily_adapter._queue_runtime_military_commit(self, day)
func _drain_runtime_military_commits() -> void:
	_daily_adapter._drain_runtime_military_commits(self)
func _refresh_military_terrain_after_season() -> void:
	_daily_adapter._refresh_military_terrain_after_season(self)
func _refresh_military_terrain_on_season_edge(day_idx: int) -> void:
	_daily_adapter._refresh_military_terrain_on_season_edge(self, day_idx)
func military_report() -> Dictionary:
	return _daily_adapter.military_report(self)
func _apply_climate_writeback_if_authoritative(report: Dictionary) -> void:
	_daily_adapter._apply_climate_writeback_if_authoritative(self, report)
func wait_for_climate_consumed(after_environment_generation: int) -> Dictionary:
	return _daily_adapter.wait_for_climate_consumed(self, after_environment_generation)
func _try_promote_economy_pod_active() -> void:
	_climate_runtime._try_promote_economy_pod_active(self)
func set_runtime_climate_authority_enabled(enabled: bool) -> Dictionary:
	return _climate_runtime.set_runtime_climate_authority_enabled(self, enabled)
func _restart_worker_with_current_policy() -> Dictionary:
	return _climate_runtime._restart_worker_with_current_policy(self)
func set_climate_authority_override(mode: String) -> Dictionary:
	return _climate_runtime.set_climate_authority_override(self, mode)
func _resolve_climate_authority_policy() -> Dictionary:
	return _climate_runtime._resolve_climate_authority_policy(self)
func climate_authority_diagnostics() -> Dictionary:
	return _climate_runtime.climate_authority_diagnostics(self)
func _apply_runtime_visual_patch(_family: int, _patch: Dictionary) -> void:
	return


func _map_overlay_refresh_interval_msec() -> int:
	_bind_overlay_resources()
	return _overlay._map_overlay_refresh_interval_msec()


func _refresh_map_overlay(force: bool) -> void:
	_bind_overlay_resources()
	_overlay._refresh_map_overlay(force)


func finish_daily_tick(ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	_daily_adapter.finish_daily_tick(self, ui_ms, ui_breakdown)
func get_current_map() -> MapData:
	return _current_map


func get_world_clock_ref() -> WorldClock:
	return _world_clock


func get_generator() -> MapGenerator:
	return _generator


func _gm_map_baker():
	if _generator != null and "_baker" in _generator:
		return _generator._baker
	return null


func get_renderer() -> HexRenderer:
	return _renderer


func get_fast_tick_count() -> int:
	return _fast_tick_count


func get_last_fast_tick_ms() -> int:
	return _last_fast_tick_ms


func get_last_tick_timing() -> Dictionary:
	return _last_tick_timing.duplicate(false)


func get_sus_last_tick_report() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick"):
		return {}
	var report: Dictionary = _generator.sus_report_last_tick()
	return report.duplicate(false)


## R-3d: how the GDScript ideology-intent fallback behaved.
##
## `duplicate_acks` and `unknown_acks` must both be 0 on any session where the worker
## owns EFFECT (the 0xFFF production mask), because the worker drains its own intents
## and this pump should never reply at all. `replies` is informational.
func get_ideology_intent_reply_report() -> Dictionary:
	return {
		"duplicate_acks": _ideology_intent_duplicate_acks,
		"unknown_acks": _ideology_intent_unknown_acks,
		"replies": _ideology_acked_transactions.size(),
	}


func get_sus_last_tick_summary() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick_summary"):
		return {}
	var summary: Dictionary = _generator.sus_report_last_tick_summary()
	return summary.duplicate(false)


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
static func eternal_uv_from_angles(azimuth_deg: float, elevation_deg: float) -> Vector2:
	var elevation := clampf(elevation_deg, 8.0, 85.0)
	var dist := (85.0 - elevation) / 77.0
	var azimuth := deg_to_rad(azimuth_deg)
	# 标记离地图中心越远，太阳越低；标记所在方向就是光线方向（+x 东，+y 北）。
	var offset := Vector2(cos(azimuth), sin(azimuth)) * (dist * 0.5)
	return Vector2(clampf(0.5 + offset.x, 0.0, 1.0), clampf(0.5 + offset.y, 0.0, 1.0))


static func eternal_angles_from_uv(uv: Vector2) -> Vector2:
	var offset := Vector2(clampf(uv.x, 0.0, 1.0) - 0.5, clampf(uv.y, 0.0, 1.0) - 0.5)
	var dist := clampf(offset.length() * 2.0, 0.0, 1.0)
	var elevation := lerpf(85.0, 8.0, dist)
	if offset.length_squared() <= 0.000001:
		return Vector2(0.0, elevation)
	return Vector2(rad_to_deg(atan2(offset.y, offset.x)), elevation)


static func eternal_sun_dir(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var azimuth := deg_to_rad(azimuth_deg)
	var elevation := deg_to_rad(clampf(elevation_deg, 8.0, 85.0))
	var horiz := cos(elevation)
	return Vector3(cos(azimuth) * horiz, sin(azimuth) * horiz, sin(elevation)).normalized()


static func map_screen_to_sun_uv(screen_pos: Vector2, camera_position: Vector2,
		zoom: float, viewport_size: Vector2, bounds: Rect2) -> Vector2:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or zoom <= 0.0:
		return Vector2(0.25, 0.5)
	var world := camera_position + (screen_pos - viewport_size * 0.5) / zoom
	return Vector2(
		fposmod((world.x - bounds.position.x) / bounds.size.x, 1.0),
		clampf((world.y - bounds.position.y) / bounds.size.y, 0.0, 1.0))


static func map_sun_uv_to_screen(uv: Vector2, camera_position: Vector2,
		zoom: float, viewport_size: Vector2, bounds: Rect2) -> Vector2:
	var world := bounds.position + Vector2(
		fposmod(uv.x, 1.0) * bounds.size.x,
		clampf(uv.y, 0.0, 1.0) * bounds.size.y)
	return viewport_size * 0.5 + (world - camera_position) * zoom


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
func on_season_changed(season_idx: int) -> void:
	_presentation.on_season_changed(self, season_idx)
func on_year_changed(_year_idx: int) -> void:
	_presentation.on_year_changed(self, _year_idx)
func fit_camera(safe_area: Rect2 = Rect2()) -> void:
	_presentation.fit_camera(self, safe_area)
func map_wrap_period_x() -> float:
	if _current_map == null:
		return 0.0
	return HexUtils.wrap_period_x(_current_map.width, hex_size)


## Map cell indices to the world position the player actually sees.
##
## `ref_x` is the camera's x, which picks the copy on the correct side of a
## wrapped map — the same role it plays in PlayerController._cell_display_world.
## Out-of-range indices are dropped rather than clamped: a stale index must
## paint nothing, not paint the closest valid hex.
func cell_display_centers(cells: PackedInt32Array, ref_x: float) -> PackedVector2Array:
	return _presentation.cell_display_centers(self, cells, ref_x)
func _bind_renderer_and_camera(safe_area: Rect2) -> void:
	await _visual_adapter._bind_renderer_and_camera(self, safe_area)
func _defer_settlement_labels_after_ready() -> void:
	await _visual_adapter._defer_settlement_labels_after_ready(self)
func _bind_settlement_labels() -> void:
	_visual_adapter._bind_settlement_labels(self)
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
func set_fog_of_war_enabled(enabled: bool) -> void:
	_visual_adapter.set_fog_of_war_enabled(self, enabled)
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
func _refresh_vision() -> Dictionary:
	return _visual_adapter._refresh_vision(self)


## Military auto-exploration owns a frozen explored snapshot, never visible or
## fog. This hook is the single host-side daily boundary:
##   trail -> MapData.explored_arr -> existing _refresh_vision() -> native view.
## It early-outs to a couple of null checks when no exploration work exists.
func _military_exploration_facade():
	if _generator == null or not _generator.has_method("get_military_facade"):
		return null
	return _generator.get_military_facade()


func _drain_military_exploration_trail(facade) -> Dictionary:
	if _current_map == null or _player_country_slot < 0:
		return {"ok": true, "cells": 0, "skipped": true}
	if facade == null or not facade.has_method("get_military_vision_trail"):
		return {"ok": true, "cells": 0, "skipped": true}
	var trail: PackedInt32Array = facade.get_military_vision_trail(_player_country_slot)
	if trail.is_empty():
		return {"ok": true, "cells": 0}
	var cell_count: int = _current_map.cell_count()
	if _current_map.explored_arr.size() != cell_count:
		return {"ok": false, "reason": "military_exploration_explored_size_mismatch"}
	var explored: PackedByteArray = _current_map.explored_arr.duplicate()
	var changed := 0
	for raw_cell in trail:
		var cell := int(raw_cell)
		if cell < 0 or cell >= cell_count:
			return {"ok": false, "reason": "military_exploration_trail_cell_invalid",
				"cell": cell}
		if explored[cell] == 0:
			explored[cell] = 1
			changed += 1
	_current_map.explored_arr = explored
	if not facade.has_method("clear_military_vision_trail"):
		return {"ok": false, "reason": "military_exploration_trail_clear_missing"}
	var cleared: Dictionary = facade.clear_military_vision_trail(_player_country_slot)
	if not bool(cleared.get("ok", false)):
		return {"ok": false, "reason": String(cleared.get("reason",
			"military_exploration_trail_clear_failed"))}
	return {"ok": true, "cells": trail.size(), "changed": changed}


func _prepare_military_exploration_day(day: int) -> Dictionary:
	if _current_map == null or _player_country_slot < 0:
		return {"ok": true, "skipped": true}
	var facade = _military_exploration_facade()
	if facade == null or not facade.has_method("is_configured") \
			or not facade.is_configured():
		return {"ok": true, "skipped": true}
	if not facade.has_method("has_military_exploration_work") \
			or not facade.has_method("set_military_exploration_observer") \
			or not facade.has_method("set_military_exploration_view"):
		return {"ok": true, "skipped": true}
	if not bool(facade.has_military_exploration_work()):
		return {"ok": true, "skipped": true}
	var observer: Dictionary = facade.set_military_exploration_observer(
		_player_country_slot)
	if not bool(observer.get("ok", false)):
		return {"ok": false, "reason": String(observer.get("reason",
			"military_exploration_observer_failed"))}
	# Refresh the committed army positions before the vision pass.  The
	# exploration trail covers visited cells, while the final occupied cell is
	# still the ordinary low-budget vision source.
	_poll_military_vision_revision()
	var drained := _drain_military_exploration_trail(facade)
	if not bool(drained.get("ok", false)):
		return drained
	# A new explored cell or an unsolved map needs the existing vision pass to
	# refresh fog/LUT/dirty indices. Reusing that pass is mandatory: no second
	# visibility algorithm exists here.
	if int(drained.get("changed", 0)) > 0 or not _current_map.fog_solved \
			or _country_visual_refresh_pending:
		var vision := _refresh_vision()
		if not bool(vision.get("ok", false)):
			return {"ok": false, "reason": String(vision.get("reason",
				"military_exploration_vision_refresh_failed"))}
		# Do not consume the general visual-refresh latch here. _refresh_vision
		# only refreshes visible/fog/LUT inputs; territory, borders, building
		# intel and the final LUT publish still belong to the budgeted
		# refresh_country_visuals() path.
	if _current_map.explored_arr.size() != _current_map.cell_count():
		return {"ok": false, "reason": "military_exploration_explored_unavailable"}
	var pushed: Dictionary = facade.set_military_exploration_view(
		_player_country_slot, _current_map.explored_arr, day,
		_current_map.vision_revision)
	if not bool(pushed.get("ok", false)):
		return {"ok": false, "reason": String(pushed.get("reason",
			"military_exploration_view_failed"))}
	_military_exploration_last_view_day = day
	_military_exploration_last_trail_cells = int(drained.get("cells", 0))
	return {"ok": true, "day": day, "trail_cells": int(drained.get("cells", 0)),
		"new_explored": int(drained.get("changed", 0))}


## Called inside GameSaveCoordinator's safe boundary, after the world clock is
## paused and before provider collection. A failure must reject the save: a
## PKFG that silently drops explored cells is worse than no file.
func flush_military_exploration_trail_for_save() -> Dictionary:
	if _current_map == null or _player_country_slot < 0:
		return {"ok": true, "cells": 0, "skipped": true}
	var facade = _military_exploration_facade()
	if facade == null or not facade.has_method("is_configured") \
			or not facade.is_configured():
		return {"ok": true, "cells": 0, "skipped": true}
	if not facade.has_method("get_military_vision_trail"):
		return {"ok": true, "cells": 0, "skipped": true}
	if facade.has_method("set_military_exploration_observer"):
		var observer: Dictionary = facade.set_military_exploration_observer(
			_player_country_slot)
		if not bool(observer.get("ok", false)):
			return {"ok": false, "reason": String(observer.get("reason",
				"military_exploration_observer_failed"))}
	var drained := _drain_military_exploration_trail(facade)
	if not bool(drained.get("ok", false)):
		return drained
	return {"ok": true, "cells": int(drained.get("cells", 0))}
func _ensure_native_vision_configured(ext: Object) -> bool:
	return _visual_adapter._ensure_native_vision_configured(self, ext)
func _has_remote_observation_capability() -> bool:
	return _visual_adapter._has_remote_observation_capability(self)
func _submit_native_observations(facade, result: Dictionary) -> void:
	_visual_adapter._submit_native_observations(self, facade, result)
func _submit_discovered_map_signals(previous: PackedByteArray) -> void:
	_visual_adapter._submit_discovered_map_signals(self, previous)
func _republish_cell_luts(dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = false) -> Dictionary:
	return _visual_adapter._republish_cell_luts(self, dirty_indices, force_full_encode)
func _refresh_country_borders() -> Dictionary:
	return _visual_adapter._refresh_country_borders(self)
func _rebuild_view_adapter() -> void:
	_visual_adapter._rebuild_view_adapter(self)
func _apply_feature_flags() -> void:
	_generation_adapter._apply_feature_flags(self)
func _world_setup_config() -> Dictionary:
	return _generation_adapter._world_setup_config(self)
func _apply_world_setup_base_config() -> void:
	_generation_adapter._apply_world_setup_base_config(self)
func _cmdline_pkmap_path() -> String:
	return _generation_adapter._cmdline_pkmap_path(self)
func _apply_pkmap_override(cfg: MapConfig) -> void:
	_generation_adapter._apply_pkmap_override(self, cfg)
func _load_runtime_climate_profile() -> ClimateProfile:
	return _generation_adapter._load_runtime_climate_profile(self)
func _apply_runtime_climate_profile(generator_ref: MapGenerator) -> void:
	_generation_adapter._apply_runtime_climate_profile(self, generator_ref)
func _apply_mobile_profile_defaults(profile: ClimateProfile, climate_overrides: Dictionary) -> void:
	_generation_adapter._apply_mobile_profile_defaults(self, profile, climate_overrides)
func _init_tod_profile() -> void:
	_generation_adapter._init_tod_profile(self)
func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	_generation_adapter._on_baker_stage_progress(self, stage, fraction)
func _enter_tree() -> void:
	_generation_adapter._enter_tree(self)
func _exit_tree() -> void:
	_generation_adapter._exit_tree(self)
var _loading_visual_usec := 0
var _loading_visual_name := ""
func _loading_visual_step(label: String) -> void:
	_generation_adapter._loading_visual_step(self, label)
const VISUAL_PROGRESS_START := 0.96
const VISUAL_PROGRESS_CEIL := 0.99
const VISUAL_PROGRESS_GAIN := 0.09
var _visual_progress := 0.0

func _advance_visual_progress(stage: String, begin: bool = false) -> void:
	_generation_adapter._advance_visual_progress(self, stage, begin)
func _on_renderer_loading_layer_progress(_layer_index: int, _layer_count: int,
		_layer_name: String) -> void:
	_generation_adapter._on_renderer_loading_layer_progress(self, _layer_index, _layer_count, _layer_name)
func _on_annual_report_ready(report_id: int) -> void:
	annual_report_ready.emit(report_id)


func annual_report_status() -> Dictionary:
	return _generation_adapter.annual_report_status(self)
func annual_report_snapshot(report_id: int) -> Dictionary:
	return _generation_adapter.annual_report_snapshot(self, report_id)
func annual_report_history(offset: int = 0, limit: int = 64) -> Dictionary:
	return _generation_adapter.annual_report_history(self, offset, limit)
func mark_annual_report_presented(report_id: int) -> void:
	_generation_adapter.mark_annual_report_presented(self, report_id)
func annual_reports_waiting_for_year(year: int) -> bool:
	return _generation_adapter.annual_reports_waiting_for_year(self, year)
func annual_report_catalogs() -> Dictionary:
	return _generation_adapter.annual_report_catalogs(self)
func _player_completed_technology_ids() -> Dictionary:
	return _generation_adapter._player_completed_technology_ids(self)
