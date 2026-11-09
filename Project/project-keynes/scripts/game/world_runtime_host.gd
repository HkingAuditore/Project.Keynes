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
var _environment_publish_next_day_cursor: int = -1
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
	var ext = _generator.get_data_core_world_ext() \
		if _generator != null and _generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("run_native_daily_inline_day"):
		if _reject_web_daily_fallback("web_native_daily_api_missing", "缺少原生日推进入口，请更新网页原生模块"):
			return {"ok": false, "code": "native_daily_inline_api_missing"}
		if _native_daily_inline_active:
			push_error("[runtime-inline] run_native_daily_inline_day 缺失：回退到主线程 daily tick")
			_native_daily_inline_active = false
		return {"ok": false, "code": "native_daily_inline_api_missing"}
	var segment_usec := Time.get_ticks_usec()
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "enter"})
	# 单日单推进声明：今天由**内联执行器**推进。同一 day 上若已有别人声明过
	# （正常不会发生：生产场景里只有本 host 推进模拟），main.gd 那套 GDScript
	# SUS 日 tick 会自己让位。这里只是登记，不影响本函数的执行。
	_claim_day_for_native(day_idx, &"native_inline")
	_apply_climate_writeback_if_authoritative(report)
	_sched_day_climate_writeback_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_writeback"})
	segment_usec = Time.get_ticks_usec()
	_service_country_worker_transport()
	_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_transport"})
	# 输入日必须等于 host 的 committed_day+1。内联日没有跨线程重试，错日会直接
	# 停在 inline_daily_environment_day_mismatch，所以这里按 host 的提交水印取值。
	var host_day := int(report.get("simulation_committed_day",
		report.get("committed_day", -1)))
	var next_day := host_day + 1
	segment_usec = Time.get_ticks_usec()
	if _generator.has_method("capture_runtime_inputs_for_worker"):
		_generator.capture_runtime_inputs_for_worker(
			maxi(0, next_day), _world_clock.season_phase_for_day(day_idx),
			MapGenerator.ENV_CALLSITE_INLINE_DAY)
	_sched_day_capture_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_capture",
		"ms": int(_sched_elapsed_ms(segment_usec))})
	# 探针：native 调用本身的独立 epoch（桌面 _dcp_on() 为假时连计时都不做）。
	var _dcp_native_usec: int = Time.get_ticks_usec() if _dcp_on() else 0
	var result: Dictionary = ext.run_native_daily_inline_day()
	_runtime_native_daily_inline_last = result
	if _dcp_native_usec > 0:
		_dcp_inline_ms = float(Time.get_ticks_usec() - _dcp_native_usec) / 1000.0
	# 每个内联日的耗时/域覆盖：第一次 daily tick 在浏览器里特别贵（一次性初始化），
	# 用这个事件区分"首日一次性成本"和"每天稳态成本"。
	WebTelemetry.emit("inline_day", {
		"day": day_idx,
		"ms": int(_sched_elapsed_ms(segment_usec)),
		"ok": bool(result.get("ok", false)),
		"reason": String(result.get("reason", "")),
		"attempts": int(result.get("attempts", 0)),
		"peer": int(result.get("peer_pumped", 0)),
		"from": int(result.get("from_day", -1)),
		"committed": int(result.get("committed_day", -1)),
		"domain_mask": int(result.get("completed_domain_mask", 0)),
		"work": int(result.get("work_units", 0)),
		# 分域耗时（12 个 stage 名 → ms），以及 capture / 计划 / 提交尾巴 / peer 泵。
		"stages": result.get("stage_ms", {}),
		"capture": int(result.get("capture_ms", 0.0)),
		"pre": int(result.get("pre_stage_ms", 0.0)),
		"climate": int(result.get("climate_ms", 0.0)),
		"plan": int(result.get("plan_build_ms", 0.0)),
		"tail": int(result.get("commit_tail_ms", 0.0)),
		"peer_ms": int(result.get("peer_ms", 0.0)),
		"budget_hit": bool(result.get("budget_exceeded", false)),
		"serial_only": bool(result.get("executor_serial_only", false)),
		"dispatch": int(result.get("executor_dispatch", 0)),
	})
	if bool(result.get("ok", false)):
		_runtime_native_daily_inline_days += 1
	else:
		_runtime_native_daily_inline_pending_days += 1
		# 静默冻结是最难查的失败形态：每 30 次至少留一行能指名原因的日志。
		if _runtime_native_daily_inline_pending_days % 30 == 1:
			print("[runtime-inline] day=%d pending reason=%s attempts=%d peer_pumped=%d host_day=%d" % [
				day_idx, String(result.get("reason", "?")),
				int(result.get("attempts", 0)), int(result.get("peer_pumped", 0)),
				host_day])
	# 提交已经发布；把同一份提交落到 MapData/slot，本帧的 UI/渲染就能读到今天。
	#
	# 探针：这里的 commit 消费是 inline_day 事件**看不到**的那一段——它排在
	# inline_day 打点之后，包含 LUT 重编码 / 天气场纹理刷新 / 自然资源回灌 /
	# 视觉 patch 应用。day_cost_ema 与 inline_day 的差额主要就落在这里。
	if _dcp_on():
		var dcp_commit_usec := Time.get_ticks_usec()
		# 复用同一调用栈里刚取的那份 report（内联日没有 worker 线程，两次读取
		# 必然同值），省掉一天里第二次 get_runtime_thread_report() 打包。
		_consume_runtime_commit_if_ready(report)
		_dcp_commit_ms = float(Time.get_ticks_usec() - dcp_commit_usec) / 1000.0
	else:
		_consume_runtime_commit_if_ready()
	return result


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
	if _is_web_build() and _runtime_worker_fault_paused:
		return
	# OFF/SHADOW keep the synchronous reference authority in this host. The
	# PlayerController only consumes the resulting state for UI; it must not be
	# another simulation entry point.
	var day_started_usec := Time.get_ticks_usec()
	_sched_day_report_ms = 0.0
	_sched_day_snapshots_ms = 0.0
	_sched_day_climate_writeback_ms = 0.0
	_sched_day_climate_wait_ms = 0.0
	_sched_day_capture_ms = 0.0
	_sched_day_country_peer_ms = 0.0
	_sched_day_country_read_ms = 0.0
	_sched_day_promote_ms = 0.0
	# Web 单日成本探针的 host 分段（未开探针时这几行只是置 0，全部是本类私有
	# 字段，没有任何生产读取点）。
	_dcp_inline_ms = 0.0
	_dcp_commit_ms = 0.0
	_dcp_publish_ms = 0.0
	_dcp_finish_ms = 0.0
	_dcp_resource_ms = 0.0
	_dcp_military_ms = 0.0
	_dcp_visual_ms = 0.0
	if not _runtime_ready_for_ticks or _generator == null or _world_clock == null:
		_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
		return
	var segment_usec := Time.get_ticks_usec()
	var report := _generator.get_runtime_thread_report() \
		if _generator.has_method("get_runtime_thread_report") else {}
	_sched_day_report_ms = _sched_elapsed_ms(segment_usec)
	# native_daily_inline：没有 worker 线程，这一天的 12 域日屏障就在本线程上跑。
	# 必须放在下面的 capacity wait 之前 —— 内联执行者自己消费环境帧，ring 容量
	# 从来不是问题，去等一个"worker 消费"的信号只会把主线程钉住。
	if _native_daily_inline_active:
		_annual_reports.before_day(day_idx)
		_run_native_daily_inline_day(day_idx, report)
		_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
		return
	# Capacity waits must yield to _process so peer ACKs and writeback keep
	# running. Retain this semantic day instead of dropping a rejected input.
	if bool(report.get("climate_worker_authoritative", false)):
		segment_usec = Time.get_ticks_usec()
		var capacity := wait_for_climate_consumed(0)
		_sched_day_climate_wait_ms += _sched_elapsed_ms(segment_usec)
		if not bool(capacity.get("ok", false)):
			# Peer pump before parking: Country/fiscal soft-commit may be what
			# frees ring capacity. wait_for_climate_consumed(0) does not pump.
			segment_usec = Time.get_ticks_usec()
			_service_country_worker_transport()
			_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
			_arm_climate_capacity_pending(day_idx)
			_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
			return
	_clear_climate_capacity_pending()
	_annual_reports.before_day(day_idx)
	# Whole-graph only. `authority_ready` stays false until every domain has a
	# POD handler; a per-domain promotion (Climate) must NOT skip the tick,
	# because the other eleven domains are still computed right here. Reading
	# `simulation_worker_ready` instead would stop economy, country, triggers
	# and perf recording the moment Climate alone was promoted — the tick is
	# the entry point for all of them, not just Climate. Climate itself is
	# suppressed further down, inside the native daily graph.
	var whole_graph_authoritative := String(report.get("simulation_thread_mode", "OFF")) == "ACTIVE" \
		and bool(report.get("authority_ready", false))
	if whole_graph_authoritative:
		# 单日单推进声明：今天由 worker 整图权威推进（web 上这条分支不会走到，
		# 内联在上面就 return 了；桌面 _day_barrier_claim_enabled=false → 空转）。
		_claim_day_for_native(day_idx, &"native_worker")
		# Worker owns domain formulas, but the host must still:
		#   writeback → (optional season) → capture next-day environment → peer pump.
		# Skipping capture here parks the worker on environment wait while it still
		# holds the authority-boundary lock; any blocking switch then freezes Godot.
		if bool(report.get("climate_worker_authoritative", false)):
			segment_usec = Time.get_ticks_usec()
			_consume_modifier_worker_snapshot_if_authoritative()
			_consume_effect_worker_snapshot_if_authoritative()
			_service_effect_worker_intents_if_authoritative()
			_consume_trigger_worker_snapshot_if_authoritative()
			_service_trigger_worker_intents_if_authoritative()
			_consume_ideology_worker_snapshot_if_authoritative()
			_service_ideology_worker_intents_if_authoritative()
			_sched_day_snapshots_ms += _sched_elapsed_ms(segment_usec)
		segment_usec = Time.get_ticks_usec()
		_apply_climate_writeback_if_authoritative(report)
		_sched_day_climate_writeback_ms += _sched_elapsed_ms(segment_usec)
		if bool(report.get("climate_worker_authoritative", false)):
			segment_usec = Time.get_ticks_usec()
			var capacity_result := wait_for_climate_consumed(0)
			_sched_day_climate_wait_ms += _sched_elapsed_ms(segment_usec)
			if not bool(capacity_result.get("ok", false)):
				# [android-day1-deadlock 2026-11-01] 这里以前静默 return：一旦 worker
				# 因为没输入而不再消费环境环，day_changed 每次都在这里掉头，capture
				# 永不执行 → ring 恒 0 → worker 永远等输入。安卓上正是这个死循环，
				# 所以把"谁拒绝了这次容量检查"打出来。
				if _day_capture_blocked_logs < 8:
					_day_capture_blocked_logs += 1
					print("[day-capture] blocked day=%d code=%s state=%s consumed=%s ring=%s" % [
						day_idx, String(capacity_result.get("code", "?")),
						str(capacity_result.get("worker_state", -1)),
						str(capacity_result.get("consumed_generation", -1)),
						str(capacity_result.get("ring_pending", -1))])
				segment_usec = Time.get_ticks_usec()
				_service_country_worker_transport()
				_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
				_arm_climate_capacity_pending(day_idx)
				_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
				return
		if _generator.has_method("capture_runtime_inputs_for_worker"):
			# 与 sus_tick_daily 的输入日约定一致，接管当天不能跳过一日。
			segment_usec = Time.get_ticks_usec()
			var capture_result: Dictionary = _generator.capture_runtime_inputs_for_worker(
				maxi(0, day_idx - 1), _world_clock.season_phase_for_day(day_idx),
				MapGenerator.ENV_CALLSITE_HOST_DAY_CHANGED)
			if not bool(capture_result.get("ok", true)) and _day_capture_blocked_logs < 8:
				_day_capture_blocked_logs += 1
				print("[day-capture] failed day=%d code=%s reason=%s" % [
					maxi(0, day_idx - 1), String(capture_result.get("code", "?")),
					String(capture_result.get("fallback_reason",
						capture_result.get("reason", "")))])
			_sched_day_capture_ms += _sched_elapsed_ms(segment_usec)
		segment_usec = Time.get_ticks_usec()
		_service_country_worker_transport()
		_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
		# Country read-view + vision stay on _process (budgeted). Putting them on
		# day_changed inflated day_cost_ema and collapsed 50x throughput while the
		# worker sat in input_wait. Peer pump above is enough for the day barrier.
		_sched_day_country_read_ms = 0.0
		segment_usec = Time.get_ticks_usec()
		_try_promote_economy_pod_active()
		_sched_day_promote_ms += _sched_elapsed_ms(segment_usec)
		_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
		return
	# Climate 在 worker 手上时，先把它上一天的结果落进 MapData，再跑这一天的 tick。
	#
	# run_daily_tick 里有两个读写 MapData 的环节：season refresh 重算 moisture /
	# snow_cover / soil_moisture / PAW 这批与日频写者重叠的场，capture 则把 MapData
	# 打包成 worker 下一天的输入。回灌只挂在 _process 上时，它与本 tick 的先后取决于
	# 节点树的 _process 顺序 —— 也就是「谁最后写 MapData」决定了 worker 下一天读到
	# 什么，而这两条路径谁先谁后并没有任何东西保证。在这里显式回灌一次，把顺序钉成
	#   回灌(第 N 天) → capture(第 N+1 天的输入) → season refresh
	# 三者落在同一个调用栈里串行。
	#
	# 试过反过来排（tick 之后再回灌，让 capture 夹在 season refresh 与回灌之间），
	# 动机是让季节性重算能进入 worker。零改善：四条平坦的场逐项不变。所以季节信号
	# 进不来的原因不是这个执行序，改回确定性更强的这一版。
	#
	# _process 那次回灌保留：它服务于视觉的每帧刷新。apply 侧有 generation 与
	# committed-day 双重门，同一天重复调用不会二次应用。
	if bool(report.get("climate_worker_authoritative", false)):
		_consume_modifier_worker_snapshot_if_authoritative()
		_consume_effect_worker_snapshot_if_authoritative()
		_service_effect_worker_intents_if_authoritative()
		# H8: Trigger before Ideology mirrors the worker stage order, and doing it
		# here (not only after the tick) lets this day's graph pulse hand off the
		# effects the worker just emitted instead of trailing them by a day.
		_consume_trigger_worker_snapshot_if_authoritative()
		_service_trigger_worker_intents_if_authoritative()
		_consume_ideology_worker_snapshot_if_authoritative()
		_service_ideology_worker_intents_if_authoritative()
	_apply_climate_writeback_if_authoritative(report)
	if bool(report.get("climate_worker_authoritative", false)):
		# B8 P3：等输入 ring 有空位再 capture（after_generation=0）。
		# 允许最多 SLOT_COUNT-1 天流水线，大地图不再被“等上一份完全消费”串成单槽。
		# serial_wait soak 仍可显式传具体 generation。
		segment_usec = Time.get_ticks_usec()
		var capacity_result := wait_for_climate_consumed(0)
		_sched_day_climate_wait_ms += _sched_elapsed_ms(segment_usec)
		if not bool(capacity_result.get("ok", false)):
			segment_usec = Time.get_ticks_usec()
			_service_country_worker_transport()
			_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
			_arm_climate_capacity_pending(day_idx)
			_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)
			return
	segment_usec = Time.get_ticks_usec()
	# 单日单推进声明：今天由本 host 的 GDScript SUS tick 推进。若 main.gd 也挂在
	# 同一场景（当前不会），它的 sus_tick_daily 会看到这条声明并让位。
	_claim_day_for_native(day_idx, &"host_sus")
	run_daily_tick(day_idx, _world_clock.season_phase_for_day(day_idx))
	_sched_day_total_ms = _sched_elapsed_ms(day_started_usec)


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
	if _exiting_tree or not is_inside_tree():
		return
	if PK_WEB_SKIP_DEFERRED_VISUAL_LAYERS:
		return
	var session = _runtime_session
	var token: int = session.generation
	var timer := get_tree().create_timer(3.0, true, false, true)
	await timer.timeout
	if _exiting_tree or not is_inside_tree() or not session.is_current(token):
		return
	var started := Time.get_ticks_msec()
	var report: Dictionary = refresh_building_visual_catalog()
	var elapsed := Time.get_ticks_msec() - started
	print("[building-visual] web deferred catalog ok=%s %dms" % [
		str(report.get("ok", false)), elapsed])
	WebTelemetry.emit("bind_step", {"s": "deferred_building_visual_done", "dur": elapsed})

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
	if generated_seed <= 0 or _new_game_config.is_empty():
		return
	var base = _new_game_config.get("base", {})
	if not base is Dictionary:
		return
	var recorded := int((base as Dictionary).get("initial_seed", 0))
	if recorded == generated_seed:
		return
	(base as Dictionary)["initial_seed"] = generated_seed
	push_warning("[session] generated world seed %d adopted (session config requested %d); saves now reproduce this world" % [
		generated_seed, recorded])


# ─── 地图生成失败诊断（mapgen-diagnostics）───────────────────────────────
# generate_world 失败时把 MapGenerator.last_generation_error 整块留在 host 上，
# 由 player_game 交给 WorldLoadingOverlay 展示/复制/落盘。
var last_world_generation_error: Dictionary = {}


## 完整失败详情纯文本（多行）。UI "复制详情" 与日志文件共用同一段文本。
func last_world_generation_error_text() -> String:
	if last_world_generation_error.is_empty():
		return ""
	var detail := String(last_world_generation_error.get("detail_text", ""))
	if not detail.is_empty():
		return detail
	# 兜底：没有 detail_text 时用 JSON，但必须先剔除原始 native report——
	# 它带 10+ 个 n_cells 级 PackedArray，直接 stringify 会产出几 MB 文本。
	var safe := last_world_generation_error.duplicate()
	safe.erase("native_report_raw")
	return JSON.stringify(safe, "  ", true)


## 生成失败归因：把 MapGenerator 的结构化错误压成"一句中文 + 阶段 + 原因 + 排查建议"。
## 传 preflight_override 时表示失败发生在 generate() 之前（自检拦下）。
func _report_world_generation_failure(preflight_override: Dictionary = {}) -> void:
	var err: Dictionary = {}
	if _generator != null:
		# 浅拷贝：只复制顶层键，native_report_raw 仍指向同一份原始字典（不重复分配）。
		err = _generator.last_generation_error.duplicate()
	if err.is_empty() and not preflight_override.is_empty():
		var first_issue := ""
		var issues: Array = preflight_override.get("issues", [])
		if not issues.is_empty() and issues[0] is Dictionary:
			first_issue = String((issues[0] as Dictionary).get("message", ""))
		err = {
			"stage": "preflight",
			"reason": "preflight_failed",
			"summary": "生成前自检未通过：%s" % first_issue,
			"hint": "按下面 preflight 里点名的缺失项处理；安卓一般是原生库缺失/过旧。",
			"preflight": preflight_override,
			"env": preflight_override.get("env", {}),
			"native_report": {},
			"superseded": false,
		}
	if err.is_empty():
		err = {
			"stage": "unknown",
			"reason": "map_generator_failed",
			"summary": "地图生成器返回空结果，且未留下任何诊断信息。",
			"hint": "这是 MapGenerator 之外的调用层问题；请附完整 logcat/godot.log。",
			"preflight": {},
			"env": {},
			"native_report": {},
			"superseded": false,
		}
	# 被新一轮 generate 取代：不弹失败面板，否则会盖住新一轮的进度条。
	if bool(err.get("superseded", false)):
		print("[mapgen] generation superseded at stage=%s (no failure UI)"
			% String(err.get("stage", "?")))
		return
	if _generator != null:
		err["detail_text"] = _generator.last_generation_error_text()
	last_world_generation_error = err
	var summary := _world_generation_failure_summary(err)
	# 同一行同时 print + push_error：print 给 adb logcat，push_error 给编辑器/错误面板。
	print("[mapgen][fatal] %s" % summary)
	push_error("[mapgen][fatal] %s" % summary)
	world_generation_failed.emit(summary)


## 非 MapGenerator 来源的失败（开局初始化 / 存档恢复）：自建诊断记录后统一上报。
## 走同一条 print+push_error+signal 通道，保证 UI/日志/文件三处看到的是同一段文本。
func _emit_world_generation_failure(stage: String, reason: String, summary: String, hint: String) -> void:
	last_world_generation_error = {
		"stage": stage,
		"reason": reason,
		"summary": summary,
		"hint": hint,
		"preflight": {},
		"env": {},
		"native_report": {},
		"superseded": false,
		"detail_text": _format_world_generation_detail(stage, reason, summary, hint),
	}
	var line := _world_generation_failure_summary(last_world_generation_error)
	print("[mapgen][fatal] %s" % line)
	push_error("[mapgen][fatal] %s" % line)
	world_generation_failed.emit(line)


## 非 MapGenerator 来源失败的多行详情（结构与 MapGenerator 的保持同构，便于统一复制）。
func _format_world_generation_detail(stage: String, reason: String, summary: String, hint: String) -> String:
	var timestamp := Time.get_datetime_string_from_system(true)
	return HostValueHelpers._format_world_generation_detail(
		stage, reason, summary, hint, timestamp)


## 一句话摘要：含 stage + reason + 一句排查建议（玩家能看懂、开发者能定位）。
func _world_generation_failure_summary(err: Dictionary) -> String:
	return HostValueHelpers._world_generation_failure_summary(err)


## --mapgen-selfcheck：把自检 JSON 打到 stdout（安卓：adb logcat -s godot:*）。
## 桌面/headless 走 tests/world/mapgen_selfcheck.tscn；这里覆盖"已经进了游戏场景"的场景。
func _maybe_run_mapgen_selfcheck_cli() -> void:
	if not MapGenerator.mapgen_selfcheck_requested():
		return
	var probe := MapGenerator.new()
	var report: Dictionary = probe.run_mapgen_selfcheck(true)
	print("[mapgen][selfcheck][summary] ok=%s" % str(report.get("ok", false)))


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
	_generation_request += 1
	var request := _generation_request
	var clock_was_paused := _world_clock.paused if _world_clock != null else true
	var closed: Dictionary = await close_world()
	if request != _generation_request or _exiting_tree or not is_inside_tree():
		return
	if not bool(closed.get("ok", false)):
		_emit_world_generation_failure("close", String(closed.get("code", "close_failed")),
			"上一局游戏尚未关闭。", "请保留运行日志。")
		return
	_runtime_session = WorldSession.new()
	_session_frames = SessionFrameGate.new()
	_session_prepare_options = {"seed": seed_override, "safe_area": safe_area,
		"clock_was_paused": clock_was_paused}
	last_world_generation_error.clear()
	_clear_web_daily_fallback_failure()
	var configured: Dictionary = _runtime_session.configure(WorldSessionModules.entries(self, _session_extensions))
	if not bool(configured.get("ok", false)):
		_emit_world_generation_failure("modules", String(configured.get("code", "module_invalid")),
			"游戏系统配置不完整。", String(configured.get("detail", "")))
		return
	var prepared: Dictionary = await _runtime_session.prepare()
	if not bool(prepared.get("ok", false)):
		if prepared.get("code") != "session_cancelled" and not _exiting_tree:
			if last_world_generation_error.is_empty():
				_emit_world_generation_failure("modules", String(prepared.get("code", "module_prepare_failed")),
					"游戏系统准备失败。", String(prepared.get("message", "")))
			await close_world()
		return
	_runtime_ready_for_ticks = true
	# The host process also drains building visual dirty cells. Keep it alive for
	# the normal runtime; overlay refreshes must not disable construction/era
	# intelligence updates.
	set_process(true)
	if _world_clock != null:
		# 只在输入及 worker 均已建立后恢复新世界/存档原有的运行模式。
		_world_clock.pause(bool(_session_prepare_options.clock_was_paused))
		on_clock_running_changed(not _world_clock.paused)
	# Web 构建：世界就绪事件（agent 侧据此判断"可以点开始了"）。
	WebTelemetry.emit("ready", {
		"day": _world_clock.day_index() if _world_clock != null else -1,
		"paused": _world_clock.paused if _world_clock != null else true,
	})
	world_ready.emit(_current_map, _world_data, _generator, _view_adapter)


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
	pass


func _session_ok() -> Dictionary:
	return {"ok": true}


## native_daily_inline 是否要在本次会话生效。
##
## 浏览器里默认生效（没有可用 worker 线程）。桌面/headless 只有显式
## PK_NATIVE_DAILY_INLINE=1 才生效 —— 桌面 worker 路径不受影响。
## PROBE：置 false 可让 web 退回主线程 daily tick（用来二分"首日挂死"是否在内联路径）。
const PK_WEB_FORCE_NO_INLINE := false


func _native_daily_inline_requested() -> bool:
	if not runtime_native_daily_inline:
		return false
	if PK_WEB_FORCE_NO_INLINE:
		return false
	# worker 启动失败（或 ACTIVE 没被授予）之后的回退：本会话内强制内联。
	# 这条必须排在 `_web_worker_requested()` 之前 —— 回退的意义就是"worker 要了
	# 但没成"，此时 switches 还停在 worker 侧，不看这个标志就没有执行者了。
	if _web_worker_inline_fallback:
		return true
	# Web 用回 native worker：内联日与 worker 是互斥的两种"日屏障执行者"。
	# 选了 worker 就必须把内联关掉 —— 否则 `config["native_daily_inline"]=true`
	# 会让 host 干脆不 spawn 线程，日屏障又回到主线程。
	if _web_worker_requested():
		return false
	if _is_web_build():
		return true
	# [android-inline 2026-11-01] 移动端默认内联（与 web 同一执行者）。安卓上
	# worker 线程路径会停在 day 1：worker state=PAUSED / attempt_slices=0 /
	# environment ring=0，而主线程又在等它提交（真机与模拟器均可复现）。
	# 内联日由主线程直接跑 12 域，不依赖 worker 线程与 env 环，web 上已验证多年。
	# 想恢复实验性 worker：PK_MOBILE_NATIVE_WORKER=1。
	if (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")) \
			and OS.get_environment("PK_MOBILE_NATIVE_WORKER") != "1":
		return true
	return OS.get_environment("PK_NATIVE_DAILY_INLINE") == "1"


## 「本进程是 web 构建」的单一判据。
##
## `PK_FORCE_WEB_SEMANTICS=1` 是**只在 headless 上使用**的语义镜像：浏览器里
## `OS.has_feature("web")` 改不了，而这条链上的三个决定（谁执行日屏障 / 起不起
## worker / 起不来怎么回退）恰恰是最容易写错、也最需要被回归覆盖的部分。
## 生产环境永远不会设这个变量，所以它对线上零影响。
func _is_web_build() -> bool:
	return OS.has_feature("web") \
		or OS.get_environment("PK_FORCE_WEB_SEMANTICS") == "1"


## Web 用回 native worker 的总开关解析。默认 false。
## 环境变量 `PK_WEB_WORKER=1` 优先于导出项，便于 headless/CI 做 A/B。
## 不缓存：它只在这几处冷路径被读（configure / worker 启动 / _process 里的
## 预发布判定），而缓存会让"导出项在 configure 之后被改"变成静默失效。
func _web_worker_requested() -> bool:
	# [2026-10-31] web defaults to the worker, same as the PC baseline.
	# Real-device data (RTX 4080 + Chrome, 365 days): worker 9.92 days/s vs inline
	# 9.81 -- throughput parity -- while the main thread spends 4 ms/day vs 46 ms
	# (-91%), so almost the whole frame budget goes back to GPU/UI.
	# Fallback chain, highest priority first:
	#   ?worker=0 (Engine meta) > PK_WEB_WORKER=0/1 (env) > runtime_web_worker
	#   > web platform default (true).
	# Desktop is unaffected: it already runs the worker, and
	# `_native_daily_inline_requested()` there only looks at PK_NATIVE_DAILY_INLINE.
	if Engine.has_meta("pk_web_worker"):
		return bool(Engine.get_meta("pk_web_worker"))
	var env := OS.get_environment("PK_WEB_WORKER")
	if env == "1":
		return true
	if env == "0":
		return false
	if runtime_web_worker:
		return true
	return OS.has_feature("web")


## A new, fully closed session may retry; never clear a native simulation fault here.
func _clear_web_daily_fallback_failure() -> void:
	if not _is_web_build() or _runtime_last_fault_diagnostics.get("source") != "web_daily_executor":
		return
	_runtime_worker_fault_paused = false
	_runtime_last_fault_diagnostics.clear()
	_web_worker_start_ok = false
	_web_worker_start_code = ""
	_native_daily_inline_active = false
	if _world_clock != null:
		_world_clock.clear_authority_fault_hold()


func _web_gdscript_daily_fallback_allowed() -> bool:
	return runtime_web_allow_gdscript_daily_fallback \
		or OS.get_environment("PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK") == "1"


## Return true only when this Web session must stop instead of using the legacy tick.
func _reject_web_daily_fallback(code: String, reason: String) -> bool:
	if not _is_web_build() or _web_gdscript_daily_fallback_allowed():
		return false
	if _runtime_worker_fault_paused:
		return true
	_web_worker_start_ok = false
	_web_worker_start_code = code
	_runtime_worker_fault_paused = true
	_runtime_last_fault_diagnostics = {"fault_code": code, "reason": reason,
		"source": "web_daily_executor", "state": "FAULTED"}
	if _world_clock != null:
		_world_clock.latch_authority_fault_hold()
	WebTelemetry.emit("web_daily_executor_failed", {"code": code, "reason": reason})
	_emit_world_generation_failure("runtime_executor", code,
		"网页模拟无法启动：%s" % reason,
		"请更新网页和原生模块，并启用原生执行器及气候权威。诊断用旧脚本回退需显式打开逃生开关。")
	return true


func _effective_environment_prefetch_days() -> int:
	if not _web_worker_requested():
		return clampi(runtime_environment_prefetch_days, 0, 3)
	return maxi(clampi(runtime_environment_prefetch_days, 0, 3), WEB_WORKER_PREFETCH_DAYS)


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
func _environment_publish_next_day() -> int:
	return _daily_adapter._environment_publish_next_day(self)
func _set_environment_publish_next_day(day: int) -> void:
	_daily_adapter._set_environment_publish_next_day(self, day)
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
func _service_trigger_country_delivery(ext: Object, _report: Dictionary) -> void:
	_daily_adapter._service_trigger_country_delivery(self, ext, _report)
func _ack_trigger_delivery_ids(ext: Object) -> Dictionary:
	return _daily_adapter._ack_trigger_delivery_ids(self, ext)
func _consume_country_worker_read_view_if_authoritative() -> void:
	_daily_adapter._consume_country_worker_read_view_if_authoritative(self)
func _service_country_visual_refresh_budgeted(frame_started_usec: int) -> void:
	_daily_adapter._service_country_visual_refresh_budgeted(self, frame_started_usec)
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
	if not runtime_economy_auto_pod_active:
		return
	if _generator == null or not _generator.has_method("get_data_core_world_ext"):
		return
	var ext = _generator.get_data_core_world_ext()
	if ext == null or not ext.has_method("switch_economy_authority"):
		return
	var report: Dictionary = _generator.get_runtime_thread_report() \
		if _generator.has_method("get_runtime_thread_report") else {}
	if String(report.get("simulation_thread_mode", "OFF")) != "ACTIVE":
		return
	if not bool(report.get("economy_pod_active_ready", false)):
		return
	# Already bound OwnedState means POD_ACTIVE promotion has landed.
	if String(report.get("economy_formula_backing", "")) == "owned_state":
		return
	# Cheap prefilter; C++ still try_locks because this races with the worker.
	if int(report.get("worker_day_inflight", 0)) != 0 \
			or int(report.get("economy_inflight_mutations", 0)) != 0:
		return
	var switched: Dictionary = ext.switch_economy_authority("POD_ACTIVE")
	if bool(switched.get("ok", false)):
		print("[runtime-worker] Economy authority promoted to POD_ACTIVE")


## 运行时开关 Climate|Country 权威。关掉后停掉 ACTIVE worker、改以 SHADOW 重启，
## 主线程立刻恢复算 climate/country。打开则相反。不需要重新生成世界。
## B8-4：这个入口现在等价于 force_on / force_off；想回到 auto 用
## set_climate_authority_override("auto")。
func set_runtime_climate_authority_enabled(enabled: bool) -> Dictionary:
	runtime_climate_authority_enabled = enabled
	_climate_authority_policy.set_force_enabled(enabled)
	return _restart_worker_with_current_policy()


func _restart_worker_with_current_policy() -> Dictionary:
	if _generator == null or not _generator.has_method("request_runtime_stop"):
		return climate_authority_diagnostics()
	_generator.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var stop_report: Dictionary = _generator.get_runtime_thread_report() \
			if _generator.has_method("get_runtime_thread_report") else {}
		var state := String(stop_report.get(
			"simulation_host_state", stop_report.get("state", "STOPPED")))
		if state in ["STOPPED", "FAULTED"]:
			break
		# ACTIVE Country parks on peer intents. Blocking here without pumping
		# peer service deadlocks stop() against the worker day barrier.
		_service_country_worker_transport()
		_consume_country_worker_read_view_if_authoritative()
		OS.delay_msec(1)
	var policy: Dictionary = _resolve_climate_authority_policy()
	if bool(policy.get("enabled", false)) \
			and _generator.has_method("capture_country_worker_inputs"):
		_country_worker_transport_capture = _generator.capture_country_worker_inputs()
	_start_production_shadow_worker()
	return climate_authority_diagnostics()


## B8-4：三态策略入口。auto 交给实测阈值，force_on/force_off 覆盖它。
func set_climate_authority_override(mode: String) -> Dictionary:
	var applied: Dictionary = _climate_authority_policy.set_override_mode(mode)
	if not bool(applied.get("ok", false)):
		return applied
	# override 只决定"模式"，不覆写会话 request（诊断要能同时看到"想开"与"实际
	# 生效"）。重启路径自己会重新解析策略，避免半状态。
	var restarted: Dictionary = _restart_worker_with_current_policy()
	return {
		"ok": true,
		"code": "ok",
		"override": mode,
		"policy": _resolve_climate_authority_policy(),
		"diagnostics": restarted,
	}


## 解析当前策略（不改状态）。诊断与启动路径共用同一个函数，避免两处判据漂移。
func _resolve_climate_authority_policy() -> Dictionary:
	var n_cells := _current_map.cell_count() if _current_map != null else 0
	return _climate_authority_policy.resolve(runtime_climate_authority_enabled, n_cells)


## Climate|Country 权威诊断。供 dev console / 对拍场景读，不参与调度决策。
func climate_authority_diagnostics() -> Dictionary:
	var report: Dictionary = _generator.get_runtime_thread_report() \
		if _generator != null and _generator.has_method("get_runtime_thread_report") \
		else {}
	return {
		"enabled": runtime_climate_authority_enabled,
		"worker_authoritative": bool(report.get("climate_worker_authoritative", false)),
		"country_worker_authoritative": bool(report.get(
			"country_worker_authoritative", false)),
		"authoritative_domain_mask": int(report.get("authoritative_domain_mask", 0)),
		"requested_authority_mask": int(report.get("requested_authority_mask", 0)),
		"writeback_generation": _runtime_climate_writeback_generation,
		"writeback_days": _runtime_climate_writeback_days,
		"writeback_last_day": _runtime_climate_writeback_last_day,
		"writeback_applied_fields": _runtime_climate_writeback_applied_fields,
		"writeback_skipped_fields": _runtime_climate_writeback_skipped,
		# B8 P0：交付游标与回灌分段耗时。writeback_days 只说明"回灌落地几天"，
		# 这几条才区分"worker 没消费"（superseded/consumed 落后 published）与
		# "回灌本身慢"（memcpy/flush）。
		"climate_committed_day": int(report.get("climate_committed_day", -1)),
		"climate_consumed_generation": int(report.get(
			"climate_consumed_generation", 0)),
		"environment_published_days": int(report.get(
			"environment_published_days", 0)),
		"environment_consumed_days": int(report.get(
			"environment_consumed_days", 0)),
		"environment_superseded_days": int(report.get(
			"environment_superseded_days", 0)),
		"environment_dropped_days": int(report.get(
			"environment_dropped_days", 0)),
		"environment_ring_pending": int(report.get(
			"environment_ring_pending", 0)),
		"climate_wait_total_ms": int(report.get("climate_wait_total_ms", 0)),
		"climate_wait_last_ms": int(report.get("climate_wait_last_ms", 0)),
		"climate_wait_max_ms": int(report.get("climate_wait_max_ms", 0)),
		"writeback_memcpy_ms": float(_runtime_climate_writeback_memcpy_ms),
		"writeback_flush_ms": float(_runtime_climate_writeback_flush_ms),
		"writeback_drop_count": int(_runtime_climate_writeback_drops),
		"authority_policy": _resolve_climate_authority_policy(),
	}


## 视觉 intent 的兼容适配点。worker 只发布数值 intent；具体 MapData/GPU
## 更新仍留在主线程。当前未迁移的 family 不做隐式写入，避免误把 probe
## 数据当成权威状态。
func _apply_runtime_visual_patch(_family: int, _patch: Dictionary) -> void:
	return


func _map_overlay_refresh_interval_msec() -> int:
	_bind_overlay_resources()
	return _overlay._map_overlay_refresh_interval_msec()


func _refresh_map_overlay(force: bool) -> void:
	_bind_overlay_resources()
	_overlay._refresh_map_overlay(force)


func finish_daily_tick(ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	# Web 单日成本探针：PlayerController 的 UI/HUD 段是它自己算好后从这里递进来的。
	# 必须记在 early-return 之前 —— whole-graph 分支里 commit 消费点已经先调过
	# 一次 finish_daily_tick(0.0)，把 _pending_tick_start_usec 清掉了，PlayerController
	# 这次会在这里直接返回，UI 数字只有记在前面才不会丢。
	if ui_ms > 0.0 and _dcp_on():
		# 直接记进当天的桶：PlayerController 是第 2 个 day_changed 监听者，桶到
		# 下一天开始才 flush，所以这一段仍归属**当天**（不能用 _dcp_publish_day
		# 里那个在 host 分支末尾就清掉的暂存值，否则会错记到隔天）。
		_world_clock.day_cost_add(&"pcui", ui_ms)
	if _pending_tick_start_usec <= 0:
		return
	_last_ui_perf_summary = ui_breakdown.duplicate(false)
	_last_ui_perf_summary["_tick_idx"] = _fast_tick_count
	var fast_ms_before_recorders := (
		Time.get_ticks_usec() - _pending_tick_start_usec) / 1000.0
	var recorder_diag := _publish_fast_tick_perf_sample(
		_pending_tick_sus_ms,
		_pending_tick_render_ms,
		maxf(ui_ms, 0.0),
		fast_ms_before_recorders,
		_pending_tick_skipped_day
	)
	var fast_ms_after_recorders := (
		Time.get_ticks_usec() - _pending_tick_start_usec) / 1000.0
	_last_fast_tick_ms = int(round(fast_ms_after_recorders))
	_last_tick_timing = {
		"tick_idx": _fast_tick_count,
		"fast_ms": fast_ms_after_recorders,
		"fast_ms_before_recorders": fast_ms_before_recorders,
		"t_sus_ms": _pending_tick_sus_ms,
		"t_render_ms": _pending_tick_render_ms,
		"t_ui_ms": maxf(ui_ms, 0.0),
		"was_skipped_day": _pending_tick_skipped_day,
	}
	if recorder_diag.is_empty():
		_last_recorder_perf_summary.clear()
	else:
		recorder_diag["fast_ms_before_recorders"] = fast_ms_before_recorders
		recorder_diag["fast_ms_after_recorders"] = fast_ms_after_recorders
		_last_recorder_perf_summary = recorder_diag
	if _generator != null and _current_map != null:
		_generator.sync_detail_scatter_after_tick(_current_map)
	_pending_tick_start_usec = 0


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
	var out: Dictionary = {}
	if _generator == null:
		return out
	if not _last_ui_perf_summary.is_empty():
		out["ui"] = _last_ui_perf_summary.duplicate(false)
	if _generator.has_method("sus_climate_breakdown"):
		out["climate"] = _generator.sus_climate_breakdown()
	if _generator.has_method("sus_weather_breakdown"):
		out["weather"] = _generator.sus_weather_breakdown()
	if _generator.has_method("sus_enum_atlas_breakdown"):
		out["enum_atlas"] = _generator.sus_enum_atlas_breakdown()
	if _generator.has_method("sus_sea_ice_atlas_breakdown"):
		out["sea_ice_atlas"] = _generator.sus_sea_ice_atlas_breakdown()
	if _generator.has_method("sus_dynamic_visual_atlas_breakdown"):
		out["dynamic_visual_atlas"] = _generator.sus_dynamic_visual_atlas_breakdown()
	if _generator.has_method("sus_ocean_currents_breakdown"):
		out["ocean"] = _generator.sus_ocean_currents_breakdown()
	var tick_report := get_sus_last_tick_report()
	var country_job = tick_report.get("country_daily", {})
	if country_job is Dictionary and _generator.has_method("get_country_report"):
		var country_report: Dictionary = _generator.get_country_report()
		var report_day := int(country_report.get(
			"last_committed_day", country_report.get("day_index", -1)))
		var current_day := int(_world_clock.day_index()) if _world_clock != null else report_day
		if not country_report.is_empty() and report_day >= 0 and report_day >= current_day:
			var country_breakdown: Dictionary = {
				"_tick_idx": _fast_tick_count,
				"country_report_mode": country_report.get(
					"country_report_mode", country_report.get("report_mode", "")),
				"country_state_hash_ms": country_report.get(
					"country_state_hash_ms", country_report.get("state_hash_ms", 0.0)),
				"country_report_build_ms": country_report.get(
					"country_report_build_ms", country_report.get("report_build_ms", 0.0)),
				"research_queue_size": country_report.get("research_queue_size", -1),
				"research_full_scan_fallbacks": country_report.get(
					"research_full_scan_fallbacks", 0),
				"research_activation_ms": country_report.get("research_activation_ms", 0.0),
				"research_allocation_ms": country_report.get("research_allocation_ms", 0.0),
				"research_effect_ack_ms": country_report.get("research_effect_ack_ms", 0.0),
				"research_discovery_ms": country_report.get("research_discovery_ms", 0.0),
				"research_modifier_ms": country_report.get("research_modifier_ms", 0.0),
				"research_report_ms": country_report.get("research_report_ms", 0.0),
				"research_countries_scanned": country_report.get("research_countries_scanned", 0),
				"research_active_countries": country_report.get("research_active_countries", 0),
				"research_pending_checks": country_report.get("research_pending_checks", 0),
				"research_discovery_checks": country_report.get("research_discovery_checks", 0),
				"research_discovery_frontier_mismatches": country_report.get(
					"research_discovery_frontier_mismatches", 0),
				"research_modifier_queries": country_report.get("research_modifier_queries", 0),
				"research_modifier_cache_hits": country_report.get("research_modifier_cache_hits", 0),
				"research_remainder_iterations": country_report.get("research_remainder_iterations", 0),
			}
			out["country"] = country_breakdown
	var economy_job = tick_report.get("economy_daily", {})
	var economy_report: Dictionary = {}
	if economy_job is Dictionary \
		and str((economy_job as Dictionary).get("skipped_reason", "")) == "" \
		and _generator.has_method("get_economy_perf_report"):
		# Use the cached compact snapshot. Building the full economy report here
		# used to allocate hundreds of fields on every fast tick.
		economy_report = _generator.get_economy_perf_report()
		if not economy_report.is_empty():
			economy_report["_tick_idx"] = _fast_tick_count
			out["economy"] = economy_report
			out["class_opinion"] = {
				"_tick_idx": _fast_tick_count,
				"revision": economy_report.get("class_opinion_revision", 0),
				"class_hash": economy_report.get("class_opinion_class_hash", 0),
				"country_count": economy_report.get("class_opinion_country_count", 0),
				"class_count": economy_report.get("class_opinion_class_count", 0),
				"cells_scanned": economy_report.get("class_opinion_cells", 0),
				"slots_scanned": economy_report.get("class_opinion_slots_scanned", 0),
				"last_cells_scanned": economy_report.get("class_opinion_last_cells_scanned", 0),
				"last_slots_scanned": economy_report.get("class_opinion_last_slots_scanned", 0),
				"zero_population_rows": economy_report.get(
					"class_opinion_zero_population_rows", 0),
				"last_zero_population_rows": economy_report.get(
					"class_opinion_last_zero_population_rows", 0),
				"ms": economy_report.get("class_opinion_ms", 0.0),
			}
	if _generator.has_method("get_ideology_report"):
		var ideology: Dictionary = _generator.get_ideology_report()
		if bool(ideology.get("configured", false)):
			ideology["_tick_idx"] = _fast_tick_count
			out["ideology"] = ideology
	if _generator.has_method("get_effect_report"):
		var effect: Dictionary = _generator.get_effect_report()
		if bool(effect.get("configured", false)):
			effect["_tick_idx"] = _fast_tick_count
			out["effect"] = effect
	if _generator.has_method("get_runtime_perf_snapshot"):
		var graph: Dictionary = _generator.get_runtime_perf_snapshot(0)
		if not graph.is_empty():
			graph["_tick_idx"] = _fast_tick_count
			out["runtime_graph"] = graph
	return out.duplicate(false)


func get_environment_perf_summary() -> Dictionary:
	var summary := get_sus_last_tick_summary()
	var out: Dictionary = {
		"tick_idx": _fast_tick_count,
		"fast_ms": _last_fast_tick_ms,
		"map_cells": _current_map.cell_count() if _current_map != null else 0,
		"last_tick": summary,
		"timing": _last_tick_timing.duplicate(false),
		"window": {},
		"recorders": _last_recorder_perf_summary.duplicate(false),
	}
	if _generator != null and _generator.has_method("sus_report_sim_budget_window"):
		out["window"] = _generator.sus_report_sim_budget_window()
	return out


func get_recorder_perf_summary() -> Dictionary:
	return _last_recorder_perf_summary.duplicate(false)


# main.gd dump_render_profile() 的玩家会话等价实现（GM 面板触发，不绑热键）。
# 采样 120 帧输出帧墙钟统计 + SUS/非 SUS 帧均耗时 + 渲染监视器，用来判断高倍速
# 掉帧的成本落在仿真循环内还是渲染/present 侧。
# 输出三通道：print 控制台 + 单次 TXT 快照 + 累积 CSV（A/B 对比友好），
# 落盘路径与 PerfRecorder 一致（桌面 ../../tmp，移动端 user://perf）。
# 返回 {ok, txt_path, csv_path} 或 {ok=false, error}，供 GM 面板回显路径。
# GM/diagnostic methods delegate to the passive adapter.
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
	# 帧墙钟差分：发布点间墙钟 / 期间引擎帧数。1 tick/帧时即上一帧墙钟；
	# 高速多 tick 帧取区间平均，不产生 0 除（frame_delta=0 时保留上一值）。
	var publish_now_usec := Time.get_ticks_usec()
	var publish_now_frame := Engine.get_process_frames()
	if _last_perf_publish_usec > 0:
		var frame_delta := publish_now_frame - _last_perf_publish_frame
		if frame_delta > 0:
			_last_frame_wall_ms = float(publish_now_usec - _last_perf_publish_usec) \
				/ 1000.0 / float(frame_delta)
	_last_perf_publish_usec = publish_now_usec
	_last_perf_publish_frame = publish_now_frame
	var perf_ready := _recorder_ready(_perf_recorder)
	var tile_ready := _recorder_ready(_tile_data_recorder)
	var economy_ready := _recorder_ready(_economy_data_recorder)
	var continuation: Dictionary = {}
	if _generator != null and _generator.has_method("consume_continuation_perf_summary"):
		continuation = _generator.consume_continuation_perf_summary()
	if not perf_ready and not tile_ready and not economy_ready:
		return {}
	var started_usec := Time.get_ticks_usec()
	var detail_report: Dictionary = _renderer.detail_scatter_refresh_report() \
		if _renderer != null and _renderer.has_method("detail_scatter_refresh_report") else {}
	var out: Dictionary = {
		"total_ms": 0.0,
		"perf_ms": 0.0,
		"tile_ms": 0.0,
		"economy_ms": 0.0,
		"perf_recording": perf_ready,
		"tile_recording": tile_ready,
		"economy_recording": economy_ready,
		"tile_recorded": false,
		"tile_rows": 0,
		"tile_reason": "",
		"economy_recorded": false,
		"economy_rows": 0,
		"economy_reason": "",
	}
	var sample: Dictionary = {
		"tick_idx": _fast_tick_count,
		"timestamp_ms": Time.get_ticks_msec(),
		"was_skipped_day": was_skipped_day,
		"fps": Engine.get_frames_per_second(),
		"speed_multiplier": float(_world_clock.speed_multiplier) if _world_clock != null else 0.0,
		"fast_ms": fast_ms,
		"t_sus_ms": t_sus_ms,
		"t_render_ms": t_render_ms,
		"t_ui_ms": t_ui_ms,
		"continuation_frames": int(continuation.get("frames", 0)),
		"continuation_slices": int(continuation.get("slices", 0)),
		"continuation_started_slices": int(
			continuation.get("continuation_started_slices", 0)),
		"continuation_completed_slices": int(
			continuation.get("continuation_completed_slices", 0)),
		"continuation_budget_exhausted": bool(
			continuation.get("continuation_budget_exhausted", false)),
		"continuation_budget_overrun_frames": int(
			continuation.get("continuation_budget_overrun_frames", 0)),
		"continuation_max_budget_overrun_ms": float(
			continuation.get("continuation_max_budget_overrun_ms", 0.0)),
		"continuation_blocked_by_stage": str(
			continuation.get("continuation_blocked_by_stage", "")),
		"continuation_country_slices": int(continuation.get("country_slices", 0)),
		"continuation_economy_slices": int(continuation.get("economy_slices", 0)),
		"continuation_wall_ms": float(continuation.get("wall_ms", 0.0)),
		"continuation_max_frame_wall_ms": float(continuation.get("max_frame_wall_ms", 0.0)),
		"continuation_max_slice_ms": float(continuation.get("max_slice_ms", 0.0)),
		"continuation_last_slice_ms": float(continuation.get("last_slice_ms", 0.0)),
		"continuation_budget_ms": float(continuation.get("budget_ms", 0.0)),
		"continuation_last_stage": str(continuation.get("last_stage", "")),
		"continuation_last_next_stage": str(continuation.get("last_next_stage", "")),
		"continuation_last_substage": str(continuation.get("last_substage", "")),
		"continuation_last_path": str(continuation.get("last_path", "")),
		"continuation_done": bool(continuation.get("done", false)),
		"continuation_stage_counts": JSON.stringify(continuation.get("stage_counts", {})),
		"continuation_stage_wall_ms": JSON.stringify(continuation.get("stage_wall_ms", {})),
		"continuation_stage_max_slice_ms": JSON.stringify(
			continuation.get("stage_max_slice_ms", {})),
		"continuation_substage_counts": JSON.stringify(
			continuation.get("substage_counts", {})),
		"continuation_substage_wall_ms": JSON.stringify(
			continuation.get("substage_wall_ms", {})),
		"continuation_substage_max_slice_ms": JSON.stringify(
			continuation.get("substage_max_slice_ms", {})),
		"continuation_substage_work": JSON.stringify(
			continuation.get("substage_work", {})),
		# WorldClock 帧内分解：pulse = 本帧 continuation 脉冲段（日循环之前运行，
		# fast_ms 看不到）；loop/full 在帧尾才更新，此处读到的是上一帧的值，
		# 稳态下逐行平移一帧不影响对比分析。
		"clock_pulse_ms": _world_clock.get_last_pulse_ms() if _world_clock != null else 0.0,
		"clock_loop_ms": _world_clock.get_last_loop_ms() if _world_clock != null else 0.0,
		"clock_full_ms": _world_clock.get_last_full_proc_ms() if _world_clock != null else 0.0,
		"clock_day_cost_ema_ms": _world_clock.get_day_cost_ms_ema() if _world_clock != null else 0.0,
		"clock_throughput_cap": _world_clock.get_throughput_cap_days_per_frame() if _world_clock != null else 0.0,
		"clock_last_advanced_days": _world_clock.get_last_advanced_days() if _world_clock != null else 0,
		"sched_day_total_ms": _sched_day_total_ms,
		"sched_day_report_ms": _sched_day_report_ms,
		"sched_day_snapshots_ms": _sched_day_snapshots_ms,
		"sched_day_climate_writeback_ms": _sched_day_climate_writeback_ms,
		"sched_day_climate_wait_ms": _sched_day_climate_wait_ms,
		"sched_day_capture_ms": _sched_day_capture_ms,
		"sched_day_country_peer_ms": _sched_day_country_peer_ms,
		"sched_day_country_read_ms": _sched_day_country_read_ms,
		"sched_day_promote_ms": _sched_day_promote_ms,
		"sched_proc_frames": _sched_proc_frames,
		"sched_proc_economy_input_ms": _sched_proc_economy_input_ms,
		"sched_proc_peer_ms": _sched_proc_peer_ms,
		"sched_proc_snapshots_ms": _sched_proc_snapshots_ms,
		"sched_proc_country_read_ms": _sched_proc_country_read_ms,
		"sched_proc_country_visual_ms": _sched_proc_country_visual_ms,
		"sched_proc_commit_ms": _sched_proc_commit_ms,
		"sched_proc_resource_ms": _sched_proc_resource_ms,
		"sched_proc_visual_ms": _sched_proc_visual_ms,
		"sched_proc_building_ms": _sched_proc_building_ms,
		"sched_proc_overlay_ms": _sched_proc_overlay_ms,
		"sched_proc_last_total_ms": _sched_proc_last_total_ms,
		"country_read_full_snapshot_applied": _country_read_last_full_snapshot,
		"country_read_applied_cells": _country_read_last_applied_cells,
		"country_read_territory_changed_cells": _country_read_last_territory_changed_cells,
		"country_read_full_snapshot_count": _country_worker_read_full_snapshot_count,
		"country_read_patch_count": _country_worker_read_patch_count,
		"country_read_rejected_count": _country_worker_read_rejected_count,
		"country_visual_last_refresh_ms": _country_visual_last_refresh_ms,
		"country_visual_refresh_pending": _country_visual_refresh_pending,
		"country_visual_refresh_deferred_frames": _country_visual_refresh_deferred_frames,
		"country_visual_refresh_run_count": _country_visual_refresh_run_count,
		"country_visual_refresh_defer_count": _country_visual_refresh_defer_count,
		# 帧尾探针：标签重建 / 植被 succession drain 读到的是上一帧的值（这些工作
		# 由 tick 触发、在帧尾 _process 执行，天然滞后本行一帧）；overlay 烘焙是
		# 自上一行以来的累计值，发布后清零。
		"tail_label_ms": _settlement_label_layer.get_last_rebuild_ms() \
			if _settlement_label_layer != null else 0.0,
		"tail_label_count": _settlement_label_layer.get_last_rebuild_label_count() \
			if _settlement_label_layer != null else 0,
		"tail_vegetation_ms": _renderer.get_last_detail_drain_ms() \
			if _renderer != null and _renderer.has_method("get_last_detail_drain_ms") else 0.0,
		# succession 队列健康度：全链路在途 cell 数与累计入队去重跳过数。稳态下
		# inflight 应有界（≤ 单批气候 dirty 规模），dedup_skips 应随气候提交增长。
		"tail_vegetation_inflight": int(detail_report.get("inflight_cells", 0)),
		"tail_vegetation_dedup_skips": int(detail_report.get("enqueue_dedup_skips", 0)),
		"tail_vegetation_tasks": int(detail_report.get("frame_tasks", 0)),
		"tail_vegetation_forced_tasks": int(detail_report.get("frame_forced_tasks", 0)),
		"tail_vegetation_max_task_ms": float(detail_report.get("max_task_ms", 0.0)),
		"tail_vegetation_plan_ms": float(detail_report.get("plan_ms", 0.0)),
		"tail_vegetation_encode_ms": float(detail_report.get("encode_ms", 0.0)),
		"tail_vegetation_cache_update_ms": float(detail_report.get("cache_update_ms", 0.0)),
		"tail_vegetation_assemble_ms": float(detail_report.get("assemble_ms", 0.0)),
		"tail_vegetation_upload_ms": float(detail_report.get("upload_ms", 0.0)),
		"tail_overlay_ms": _overlay_bake_ms_accum,
		"tail_overlay_last_bake_ms": _map_overlay_last_bake_ms,
		"tail_overlay_interval_msec": _map_overlay_refresh_interval_msec(),
		"tail_overlay_refresh_count": _map_overlay_refresh_count,
		# 帧级渲染残差探针：frame_wall = 相邻两次发布点间的平均帧墙钟（process
		# frames 差分，多 tick 帧取平均）；engine_process/physics 为引擎监视器原始
		# 值（信息列，其口径与帧墙钟不严格可比）；residual = wall - clock_full -
		# 已知帧尾探针 ≈ 渲染提交 + GPU present + 未埋点 _process 节点。
		# overlay 项只减「最近一次烘焙」而不是跨帧累加值：accum 的时间基准是相邻
		# 两行之间，拿它去减单帧均值会把 residual 恒压成 0，废掉这一列。
		"frame_wall_ms": _last_frame_wall_ms,
		"engine_process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"engine_physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"render_objects_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"render_primitives_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"render_draw_calls_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"render_residual_ms": maxf(0.0, _last_frame_wall_ms
			- (_world_clock.get_last_full_proc_ms() if _world_clock != null else 0.0)
			- (_renderer.get_last_detail_drain_ms() \
				if _renderer != null and _renderer.has_method("get_last_detail_drain_ms") else 0.0)
			- (_settlement_label_layer.get_last_rebuild_ms() \
				if _settlement_label_layer != null else 0.0)
			- _map_overlay_last_bake_ms
			- _sched_proc_country_visual_ms),
	}
	_sched_proc_frames = 0
	_sched_proc_economy_input_ms = 0.0
	_sched_proc_peer_ms = 0.0
	_sched_proc_snapshots_ms = 0.0
	_sched_proc_country_read_ms = 0.0
	_sched_proc_country_visual_ms = 0.0
	_sched_proc_commit_ms = 0.0
	_sched_proc_resource_ms = 0.0
	_sched_proc_visual_ms = 0.0
	_sched_proc_building_ms = 0.0
	_sched_proc_overlay_ms = 0.0
	_overlay_bake_ms_accum = 0.0
	if _generator != null and _generator.has_method("sus_climate_breakdown"):
		var climate_diag: Dictionary = _generator.sus_climate_breakdown()
		if not climate_diag.is_empty():
			sample["climate"] = climate_diag
	if _generator != null and _generator.has_method("sus_weather_breakdown"):
		var weather_diag: Dictionary = _generator.sus_weather_breakdown()
		if not weather_diag.is_empty():
			sample["weather"] = weather_diag
	if _generator != null and _generator.has_method("sus_ocean_currents_breakdown"):
		var ocean_diag: Dictionary = _generator.sus_ocean_currents_breakdown()
		if not ocean_diag.is_empty():
			sample["ocean_currents"] = ocean_diag
	if perf_ready and _perf_recorder != null and _perf_recorder.has_method("is_recording") \
			and bool(_perf_recorder.is_recording()) \
			and _generator != null and _generator.has_method("get_runtime_perf_snapshot"):
		var runtime_graph: Dictionary = _generator.get_runtime_perf_snapshot(0)
		if not runtime_graph.is_empty():
			sample["runtime_graph"] = runtime_graph
	if perf_ready:
		var perf_started_usec := Time.get_ticks_usec()
		HostRecorders.record(_perf_recorder, sample)
		out["perf_ms"] = (Time.get_ticks_usec() - perf_started_usec) / 1000.0
	if tile_ready:
		var tile_started_usec := Time.get_ticks_usec()
		var tile_result = HostRecorders.record(_tile_data_recorder, sample)
		out["tile_ms"] = (Time.get_ticks_usec() - tile_started_usec) / 1000.0
		HostRecorders.apply_tile_result(tile_result, out)
	if economy_ready:
		var economy_started_usec := Time.get_ticks_usec()
		var economy_result = HostRecorders.record(_economy_data_recorder, sample)
		out["economy_ms"] = (Time.get_ticks_usec() - economy_started_usec) / 1000.0
		HostRecorders.apply_economy_result(economy_result, out)
	out["total_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	return out


func _recorder_ready(recorder: RefCounted) -> bool:
	return HostRecorders._recorder_ready(recorder)


func on_speed_changed(new_speed: float) -> void:
	if _renderer != null:
		if _renderer.has_method("set_simulation_speed_multiplier"):
			_renderer.set_simulation_speed_multiplier(new_speed)
		var weather_layer := _renderer.get_node_or_null("WeatherLayer")
		if weather_layer != null and weather_layer.has_method("set_clock_speed_multiplier"):
			weather_layer.set_clock_speed_multiplier(new_speed)
		var fog_layer := _renderer.get_node_or_null("FogOfWarLayer")
		if fog_layer != null and fog_layer.has_method("set_clock_speed_multiplier"):
			fog_layer.set_clock_speed_multiplier(new_speed)
		if weather_layer != null and weather_layer.has_method("reset_snapshot_pacing"):
			weather_layer.reset_snapshot_pacing()
	if _generator == null:
		return
	var cp = _generator._c() if _generator.has_method("_c") else null
	var auto_weather_stride := true
	if cp != null and cp.get("weather_refresh_auto_stride_by_speed") != null:
		auto_weather_stride = bool(cp.weather_refresh_auto_stride_by_speed)
	if not auto_weather_stride:
		return
	var stride := 1
	if new_speed >= 15.0:
		stride = 8
	elif new_speed >= 3.0:
		stride = 4
	_generator.set_weather_refresh_stride(stride)


func on_clock_running_changed(running: bool) -> void:
	if _renderer == null:
		return
	if _world_clock != null and _renderer.has_method("set_simulation_speed_multiplier"):
		_renderer.set_simulation_speed_multiplier(_world_clock.speed_multiplier)
	if _renderer.has_method("set_clock_running"):
		_renderer.set_clock_running(running)
	var weather_layer := _renderer.get_node_or_null("WeatherLayer")
	if weather_layer != null and weather_layer.has_method("set_clock_running"):
		weather_layer.set_clock_running(running)
	var fog_layer := _renderer.get_node_or_null("FogOfWarLayer")
	if fog_layer != null and fog_layer.has_method("set_clock_running"):
		fog_layer.set_clock_running(running)


func _sync_runtime_worker_clock() -> void:
	_clock_binding.synchronize()


func on_visual_day_phase_changed(visual_day_phase: float) -> void:
	if _renderer == null:
		return
	if _gm_tod_preview_enabled:
		if day_night_enabled:
			_gm_tod_cycle_uv.x = fposmod(visual_day_phase, 1.0)
			_gm_tod_sun_uv = _gm_tod_cycle_uv
		_apply_gm_tod_sun_preview()
		return
	_renderer.set_day_phase(visual_day_phase)
	if _tod_profile != null and _renderer.has_method("apply_tod"):
		_tod_profile.recompute(visual_day_phase, day_night_enabled)
		_renderer.apply_tod(_tod_profile)


func get_gm_tod_sun_preview() -> Dictionary:
	if _world_clock == null:
		return _gm_error("clock_unavailable", "时钟尚未就绪。")
	var uv := _gm_preview_marker_uv()
	var angles := eternal_angles_from_uv(_current_eternal_uv())
	var elevation := clampf(angles.y * (_gm_tod_sun_height_scale if _gm_tod_preview_enabled else 1.0),
		8.0, 85.0)
	return {
		"ok": true,
		"preview": _gm_tod_preview_enabled,
		"uv": uv,
		"height_scale": _gm_tod_sun_height_scale if _gm_tod_preview_enabled else 1.0,
		"day_night": day_night_enabled,
		"azimuth_deg": angles.x,
		"elevation_deg": elevation,
	}


func set_gm_tod_sun_preview(enabled: bool, uv: Vector2 = Vector2(0.25, 0.5),
		height_scale: float = 1.0) -> Dictionary:
	if _world_clock == null:
		return _gm_error("clock_unavailable", "时钟尚未就绪。")
	var clamped := Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	_gm_tod_sun_height_scale = clampf(height_scale, 0.2, 1.5)
	if day_night_enabled:
		_gm_tod_cycle_uv = clamped
	else:
		_gm_tod_eternal_uv = clamped
		_gm_tod_eternal_uv_valid = true
	_gm_tod_sun_uv = clamped
	_gm_tod_preview_enabled = enabled
	if enabled:
		if day_night_enabled:
			_world_clock.hold_visual_day_phase(_gm_tod_cycle_uv.x)
		elif not _world_clock.visual_day_phase_held:
			_world_clock.hold_visual_day_phase(_world_clock.visual_day_phase)
		_apply_gm_tod_sun_preview()
	else:
		_clear_gm_tod_sun_preview()
		_world_clock.release_visual_day_phase()
	gm_tod_preview_changed.emit(_gm_tod_preview_enabled)
	return get_gm_tod_sun_preview()


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
	var current := _gm_tod_sun_uv if _gm_tod_preview_enabled else _gm_live_sun_uv()
	if _camera == null or _renderer == null or _camera.zoom.x <= 0.0:
		return current
	var bounds := _renderer.get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return current
	return map_screen_to_sun_uv(screen_pos, _camera.position, _camera.zoom.x,
		_camera.get_viewport_rect().size, bounds)


func gm_tod_sun_screen_position() -> Vector2:
	if _camera == null or _renderer == null or _camera.zoom.x <= 0.0:
		return Vector2(INF, INF)
	var bounds := _renderer.get_world_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Vector2(INF, INF)
	var uv := _gm_tod_sun_uv if _gm_tod_preview_enabled else _gm_live_sun_uv()
	return map_sun_uv_to_screen(uv, _camera.position, _camera.zoom.x,
		_camera.get_viewport_rect().size, bounds)


func _current_eternal_uv() -> Vector2:
	if _gm_tod_eternal_uv_valid:
		return _gm_tod_eternal_uv
	return eternal_uv_from_angles(-60.0, 37.0)


func _gm_preview_marker_uv() -> Vector2:
	if day_night_enabled:
		return _gm_tod_cycle_uv if _gm_tod_preview_enabled else _gm_live_sun_uv()
	return _current_eternal_uv()


func _gm_live_sun_uv() -> Vector2:
	var phase := 0.25
	var season := 1.0
	if _world_clock != null:
		phase = _world_clock.visual_day_phase
		season = _world_clock.season_phase()
	var tilt := deg_to_rad(23.5)
	if _renderer != null:
		tilt = deg_to_rad(float(_renderer.axial_tilt_deg))
	var year_progress := fposmod(season, 4.0) * 0.25
	var decl := tilt * cos(TAU * year_progress)
	var lat_signed := clampf(decl / (PI * 0.5), -1.0, 1.0)
	return Vector2(fposmod(phase, 1.0), lat_signed * 0.5 + 0.5)


func _apply_gm_tod_sun_preview() -> void:
	if _renderer == null or not _gm_tod_preview_enabled:
		return
	if _tod_profile == null:
		_init_tod_profile()
	if day_night_enabled:
		_gm_tod_sun_uv = _gm_tod_cycle_uv
		_renderer.set_day_phase(_gm_tod_cycle_uv.x)
		if _tod_profile != null and _renderer.has_method("apply_tod"):
			_tod_profile.recompute(_gm_tod_cycle_uv.x, true)
			_renderer.apply_tod(_tod_profile)
		if _renderer.has_method("set_tod_debug_sun_position"):
			_renderer.set_tod_debug_sun_position(true, _gm_tod_cycle_uv)
	else:
		var uv := _current_eternal_uv()
		_gm_tod_sun_uv = uv
		var angles := eternal_angles_from_uv(uv)
		var elevation := clampf(angles.y * _gm_tod_sun_height_scale, 8.0, 85.0)
		var phase := _world_clock.visual_day_phase if _world_clock != null else 0.25
		if _tod_profile != null and _renderer.has_method("apply_tod"):
			_tod_profile.recompute(phase, false)
			_tod_profile.sun_dir = eternal_sun_dir(angles.x, elevation)
			_renderer.apply_tod(_tod_profile)
		if _renderer.has_method("set_tod_debug_sun_position"):
			_renderer.set_tod_debug_sun_position(true, uv)
	if _renderer.has_method("set_tod_debug_sun_height_scale"):
		_renderer.set_tod_debug_sun_height_scale(_gm_tod_sun_height_scale)


func _clear_gm_tod_sun_preview() -> void:
	if _renderer == null:
		return
	if _renderer.has_method("set_tod_debug_sun_position"):
		_renderer.set_tod_debug_sun_position(false, _gm_tod_sun_uv)
	if _renderer.has_method("set_tod_debug_sun_height_scale"):
		_renderer.set_tod_debug_sun_height_scale(1.0)


func on_season_changed(season_idx: int) -> void:
	if _generator == null or _current_map == null or _world_data == null:
		return
	var cp = _generator._c() if _generator.has_method("_c") else null
	mark_map_overlay_dirty(&"season_changed")
	var use_legacy := false
	if cp != null and "season_refresh_legacy_signal" in cp:
		use_legacy = bool(cp.season_refresh_legacy_signal)
	if not use_legacy:
		return
	if _generator.has_method("queue_season_refresh"):
		_generator.queue_season_refresh(season_idx)
	else:
		_generator.refresh_seasonal(_current_map, _world_data, season_idx)


func on_year_changed(_year_idx: int) -> void:
	if _generator != null and _current_map != null and _world_data != null:
		_generator.refresh_yearly(_current_map, _world_data)
		mark_map_overlay_dirty(&"year_changed")


func fit_camera(safe_area: Rect2 = Rect2()) -> void:
	if _camera != null:
		_camera.fit_to_viewport(1.0, safe_area, true)


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
	var out := PackedVector2Array()
	if _current_map == null or cells.is_empty():
		return out
	var wrap_period := map_wrap_period_x()
	out.resize(cells.size())
	var kept := 0
	for index in range(cells.size()):
		var cell := _current_map.cell_at(int(cells[index]))
		if cell == null:
			continue
		var canonical := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		out[kept] = HexUtils.nearest_display_world(canonical, ref_x, wrap_period)
		kept += 1
	if kept != out.size():
		out.resize(kept)
	return out


# Visual/vision methods delegate to the passive adapter.
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
	DCFeatureFlags.set_cell_indirection(cell_indirection_enabled)
	DCFeatureFlags.set_ocean_current_visual(ocean_current_visual_enabled)
	DCFeatureFlags.set_sea_ice_atlas(sea_ice_atlas_enabled)
	# 桌面默认开；移动端由 mobile_terrain_horizon_enabled 开关控制；Web 只有
	# Compatibility/WebGL2 后端，逐像素 marching 开销和离屏 viewport 读回都偏重
	# （readback 在部分浏览器/驱动上会强制同步 flush GPU 管线），默认关闭——
	# 这里必须和 DCFeatureFlags.terrain_horizon_gpu_bake_active() 的 fallback
	# 语义保持一致。之前只判断了 "mobile"，漏判 Web，导致每次开局都把这条显式
	# meta 覆盖成 true，盖掉了 feature_flags.gd 里"web 默认关"的设计。
	var terrain_horizon_enabled: bool
	if OS.has_feature("mobile"):
		terrain_horizon_enabled = mobile_terrain_horizon_enabled
	elif DCFeatureFlags.is_web():
		terrain_horizon_enabled = false
	else:
		terrain_horizon_enabled = true
	DCFeatureFlags.set_terrain_horizon_gpu_bake(terrain_horizon_enabled)


func _world_setup_config() -> Dictionary:
	if not _new_game_config.is_empty():
		return _new_game_config
	if not Engine.has_meta(WORLD_SETUP_META):
		return {}
	var raw = Engine.get_meta(WORLD_SETUP_META)
	if raw is Dictionary and String((raw as Dictionary).get("source", "")) == "world_setup":
		return raw as Dictionary
	return {}


func _apply_world_setup_base_config() -> void:
	var config := _world_setup_config()
	if config.is_empty():
		return
	var base = config.get("base", {})
	if base is Dictionary:
		map_width = clampi(int((base as Dictionary).get("map_width", map_width)),
			10, DCFeatureFlags.max_map_width())
		map_height = clampi(int((base as Dictionary).get("map_height", map_height)),
			8, DCFeatureFlags.max_map_height())
		initial_seed = max(0, int((base as Dictionary).get("initial_seed", initial_seed)))
		sea_level = clampf(float((base as Dictionary).get("sea_level", sea_level)), 0.1, 0.8)
		num_continents = clampi(int((base as Dictionary).get("num_continents", num_continents)), 1, 8)
		continent_size = clampf(float((base as Dictionary).get("continent_size", continent_size)), 0.2, 0.9)
		river_count = clampi(int((base as Dictionary).get("river_count", river_count)), 0, 30)
		generate_test_economy_data = bool((base as Dictionary).get(
			"generate_test_economy_data", generate_test_economy_data))
		var requested_population_scale := int((base as Dictionary).get(
			"test_economy_population_scale", test_economy_population_scale))
		test_economy_population_scale = requested_population_scale \
			if requested_population_scale in [0, 1, 10, 100, 1000] else 0
	var render = config.get("render", {})
	if render is Dictionary:
		mobile_terrain_horizon_enabled = bool((render as Dictionary).get(
			"mobile_terrain_horizon_enabled", mobile_terrain_horizon_enabled
		))


func _cmdline_pkmap_path() -> String:
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		if item.begins_with("pkmap="):
			return item.substr(6).strip_edges()
	return ""


func _apply_pkmap_override(cfg: MapConfig) -> void:
	if cfg == null:
		return
	var path := ""
	var setup := _world_setup_config()
	var base = setup.get("base", {})
	if base is Dictionary:
		path = String((base as Dictionary).get("pkmap_path", "")).strip_edges()
	var cmdline := _cmdline_pkmap_path()
	if not cmdline.is_empty():
		# `pkmap=` 是开新局的开发入口。读档时地图来源必须以存档 config 为准：
		# 用命令行换一张图会让重建世界与存档世界不一致（起始格/领土/地形互相
		# 矛盾），最终在视野收尾被判为失败。这里直接忽略并留一条 warning。
		if not _pending_load_bundle.is_empty():
			push_warning("[pkmap] ignoring pkmap= cmdline override during load (saved source: %s)" % path)
		else:
			path = cmdline
	if path.is_empty():
		return
	cfg.map_source = "pkmap"
	cfg.pkmap_path = path
	var peeked: Dictionary = PkmapIOScript.peek_pkmap(path)
	if not bool(peeked.get("ok", false)):
		push_error("[pkmap] 无法预读 %s：%s" % [path, String(peeked.get("message", ""))])
		return
	cfg.width = int(peeked.get("width", cfg.width))
	cfg.height = int(peeked.get("height", cfg.height))
	cfg.sea_level = float(peeked.get("sea_level", cfg.sea_level))
	var packed_seed := int(peeked.get("seed", 0))
	if packed_seed != 0:
		cfg.seed = packed_seed
	map_width = cfg.width
	map_height = cfg.height
	sea_level = cfg.sea_level


func _load_runtime_climate_profile() -> ClimateProfile:
	var profile := ResourceLoader.load(DEFAULT_CLIMATE_PROFILE_PATH, "Resource") as ClimateProfile
	if profile != null:
		profile = profile.duplicate(true) as ClimateProfile
	else:
		push_warning("[PlayerGame] default ClimateProfile missing; using in-memory defaults.")
		profile = ClimateProfile.new()
	profile.set_meta(&"source_path", DEFAULT_CLIMATE_PROFILE_PATH)
	return profile


func _apply_runtime_climate_profile(generator_ref: MapGenerator) -> void:
	if generator_ref == null:
		return
	var profile := _load_runtime_climate_profile()
	var config := _world_setup_config()
	var climate_overrides: Dictionary = {}
	if not config.is_empty():
		var climate = config.get("climate", {})
		if climate is Dictionary:
			var profile_props := {}
			for prop in profile.get_property_list():
				profile_props[String(prop.get("name", ""))] = true
			for name in (climate as Dictionary).keys():
				var key := String(name)
				if not profile_props.has(key):
					continue
				profile.set(key, (climate as Dictionary)[name])
				climate_overrides[key] = true
	if OS.has_feature("mobile"):
		_apply_mobile_profile_defaults(profile, climate_overrides)
	generator_ref.climate_profile = profile


func _apply_mobile_profile_defaults(profile: ClimateProfile, climate_overrides: Dictionary) -> void:
	if profile.get("native_daily_sim_stride") != null and not climate_overrides.has("native_daily_sim_stride"):
		profile.native_daily_sim_stride = MOBILE_NATIVE_DAILY_STRIDE_DAYS
	if profile.get("native_daily_commit_lag_budget_days") != null and not climate_overrides.has("native_daily_commit_lag_budget_days"):
		profile.native_daily_commit_lag_budget_days = MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS
	if profile.get("native_daily_sea_ice_spread_dt_cap_days") != null and not climate_overrides.has("native_daily_sea_ice_spread_dt_cap_days"):
		profile.native_daily_sea_ice_spread_dt_cap_days = float(MOBILE_NATIVE_DAILY_STRIDE_DAYS)
	if profile.get("natural_resource_daily_stride") != null and not climate_overrides.has("natural_resource_daily_stride"):
		profile.natural_resource_daily_stride = maxi(int(profile.natural_resource_daily_stride), MOBILE_NATURAL_RESOURCE_STRIDE_DAYS)
	if profile.get("dynamic_visual_atlas_upload_stride") != null and not climate_overrides.has("dynamic_visual_atlas_upload_stride"):
		profile.dynamic_visual_atlas_upload_stride = maxi(int(profile.dynamic_visual_atlas_upload_stride), MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE)
	if profile.get("weather_field_advect_steps") != null and not climate_overrides.has("weather_field_advect_steps"):
		profile.weather_field_advect_steps = mini(int(profile.weather_field_advect_steps), MOBILE_WEATHER_FIELD_ADVECT_STEPS)


func _init_tod_profile() -> void:
	if _tod_profile != null:
		return
	_tod_profile = TODProfile.new()
	_tod_profile.configure(0.65, 0.55, 0.72, 1.0)


func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	generation_progress.emit(stage, fraction)


func _enter_tree() -> void:
	_exiting_tree = false
	add_to_group(&"world_sessions")


func _exit_tree() -> void:
	_clock_binding.detach()
	_exiting_tree = true
	_runtime_session.request_close()
	_session_frames.cancel()
	if _generator != null:
		_generator.cancel_loading_work()
		_generator.request_runtime_stop()


var _loading_visual_usec := 0
var _loading_visual_name := ""
func _loading_visual_step(label: String) -> void:
	# 这条日志行打印的是"上一步"的耗时；进度同理：每次调用时把上一步标记为完成，
	# 把生成后阶段的游标向前推一格。label 本身只进日志，UI 文案用固定 stage key。
	_advance_visual_progress("bind")
	var now:=Time.get_ticks_usec()
	if _loading_visual_usec>0:
		var step_ms := float(now-_loading_visual_usec)/1000.0
		print("[loading-visual-substep] %s %.1fms" % [_loading_visual_name, step_ms])
		WebTelemetry.emit("visual_step", {"label": _loading_visual_name, "dur": step_ms})
	_loading_visual_usec=now
	_loading_visual_name=label


# ─── 生成后阶段进度（绑渲染器 → 植被图层 → 建筑外观）─────────────────────────
# 生成器返回后到 hide_completed() 之间没有任何 bake_progress，原先只有一次
# "upload"=98% 就静默到 100%。这里用与生成器同款的单调几何游标：
# 每推进一步向 VISUAL_PROGRESS_CEIL 逼近固定比例，严格单调、永不回退、
# 也永远到不了 1.0（100% 只属于 WorldLoadingOverlay.hide_completed()）。
# fraction 语义是"UI 完成度绝对值"，overlay 的 ABSOLUTE_STAGES 直接照搬。
const VISUAL_PROGRESS_START := 0.96
const VISUAL_PROGRESS_CEIL := 0.99
const VISUAL_PROGRESS_GAIN := 0.09
var _visual_progress := 0.0

func _advance_visual_progress(stage: String, begin: bool = false) -> void:
	if _visual_progress <= 0.0:
		# 0.0 = 本次生成还没进入后期阶段（或已复位）：不打扰 overlay 的现有进度。
		# 只有 generate_world 里"生成器已返回"那一次调用带 begin=true。
		if not begin:
			return
		_visual_progress = VISUAL_PROGRESS_START
	else:
		_visual_progress = minf(VISUAL_PROGRESS_CEIL,
			_visual_progress + (VISUAL_PROGRESS_CEIL - _visual_progress) * VISUAL_PROGRESS_GAIN)
	generation_progress.emit(stage, _visual_progress)


## HexRenderer 建完一个植被层回调一次（_rebuild_cooperative →
## _setup_loading_vegetation_layers_for_deferred_fill 的逐层循环）。
## 有些画质档位会构建 14+ 层，逐层推进才不会在 98% 处长时间停住。
func _on_renderer_loading_layer_progress(_layer_index: int, _layer_count: int,
		_layer_name: String) -> void:
	_advance_visual_progress("visual")


func _on_annual_report_ready(report_id: int) -> void:
	annual_report_ready.emit(report_id)


func annual_report_status() -> Dictionary:
	return _annual_reports.status()


func annual_report_snapshot(report_id: int) -> Dictionary:
	return _annual_reports.snapshot(report_id)


func annual_report_history(offset: int = 0, limit: int = 64) -> Dictionary:
	return _annual_reports.history(offset, limit)


func mark_annual_report_presented(report_id: int) -> void:
	_annual_reports.mark_presented(report_id)


func annual_reports_waiting_for_year(year: int) -> bool:
	return _annual_reports.waiting_for_year(year)


func annual_report_catalogs() -> Dictionary:
	if _generator == null:
		return {}
	var economy = _generator.get_economy_facade()
	var country: Dictionary = _generator.get_country_facade().native_catalog()
	var professions := PackedStringArray()
	for id in economy.profession_ids():
		professions.append(economy.profession_display_name(StringName(id)))
	var buildings := PackedStringArray()
	for index in economy.building_type_ids().size():
		buildings.append(economy.building_display_name(index))
	var goods := PackedStringArray()
	for index in economy.good_ids().size():
		goods.append(economy.good_display_name(index))
	# 资源名与「认没认出来」走同一个循环、同一个下标：报表里的 resource id 就是
	# ResourceProfileRegistry.ordered() 的下标，两个数组必须等长同序。
	var viewer: Dictionary = _player_completed_technology_ids()
	var know_discovery: bool = bool(viewer.get("ok", false))
	var known: PackedStringArray = viewer.get("ids", PackedStringArray())
	var resources := PackedStringArray()
	var discovered := PackedByteArray()
	for profile in ResourceProfileRegistry.ordered():
		resources.append(String(profile.display_name))
		if know_discovery:
			discovered.append(1 if ResourceProfileRegistry.discovery_visible(profile, known) else 0)
	var out: Dictionary = {"profession_names": professions, "building_names": buildings,
		"resource_names": resources, "good_names": goods,
		"technology_names": country.get("technology_display_names", PackedStringArray())}
	# 拿不到玩家科技快照时**不带这个键**：调用方"没报告"与"查了是 0"是两件事，
	# 缺省必须表现为"不过滤"，否则一次读档期的查询失败会把整栏资源吞掉。
	if know_discovery:
		out["resource_discovered"] = discovered
	return out


## 玩家已完成科技 id。年报"资源"栏要据此藏掉还没认出来的矿种。
## 认矿门控（ResourceProfile.discovery_technology_tags）本来就在 GDScript 侧，
## 原生只管"能不能采"，所以这条过滤只能在这里做 —— 与地图覆盖层、悬停卡同一套判定。
func _player_completed_technology_ids() -> Dictionary:
	if _generator == null or not _generator.has_method("get_country_facade"):
		return {"ok": false}
	var facade = _generator.get_country_facade()
	if facade == null or not facade.has_method("snapshot"):
		return {"ok": false}
	if _player_country_handle == 0:
		_player_country_handle = _resolve_player_country_handle()
	if _player_country_handle == 0:
		return {"ok": false}
	var snapshot: Dictionary = facade.snapshot(_player_country_handle)
	if not bool(snapshot.get("ok", false)):
		return {"ok": false}
	return {"ok": true, "ids": snapshot.get("technology_ids", PackedStringArray())}
