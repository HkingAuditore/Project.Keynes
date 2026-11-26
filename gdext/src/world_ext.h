#pragma once

// DCWorldExt — C++ mirror of `scripts/data_core/world.gd` (DCWorld).
//
// I3.A scope (this file): "zero-acceleration wrapper".
// Goal: instantiate via ClassDB("DCWorldExt"), bind to MapData, expose
// `view_f32 / view_i32 / view_u8`, support pools + archetypes — i.e. fulfil
// the same interface that GDScript-side hot loops already call. *No* hot loop
// is reimplemented in C++ yet; the run_xxx entry points belong to I3.B/C.
//
// The point of I3.A is to prove the bridging path:
//   1. world_factory.gd can ClassDB.instantiate("DCWorldExt") under
//      use_gdext_world=true.
//   2. bind_map_data shares the same PackedFloat32Array buffers as MapData
//      (zero-copy COW alias).
//   3. The existing GDScript hot loops still run, reading `world.view_f32(c)`,
//      and produce identical numerical output (= "zero-acceleration").
// Once that holds, I3.B can replace one sub-pass at a time with a C++
// implementation behind `use_gdext_climate`.

#include <array>
#include <cstdint>
#include <deque>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <vector>
#include <memory>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "components/slot.h"
#include "runtime_pod_protocol.h"

namespace pk { struct RuntimeResourceDisplayPatch; }

namespace pk {

class NativeSimulationHost;
class EffectInstanceForwarder;
class NativeCountryRuntime;
class NativeEconomyRuntime;
struct RuntimeClimateStore;
// Military bridge (world_ext_military.cpp). Forward-declared so this header
// stays independent of military_core.h / military_bridge.h.
struct MilitaryCatalog;
struct MilitaryWorldDigest;
struct MilitaryIntent;
struct MilitaryIntentReceipt;
class MilitaryCore;
class NativeMilitaryRuntime;
struct RuntimeEventsRecord;
struct VisionResearchState;

// Adds climate_stage_ms / climate_stage_work / climate_stage_names to a report
// dictionary. Both the thread report and the runtime graph perf snapshot expose
// it, so performance.csv has the same per-stage columns whichever facade the
// caller happened to query.
void append_climate_stage_cadence(godot::Dictionary &out,
                                 const RuntimeThreadReport &report);

struct NativeSliceResult {
    uint32_t status = 0;
    uint32_t work_done = 0;
    uint32_t next_cursor = 0;
    uint32_t dirty_mask = 0;
    uint32_t elapsed_us = 0;
    uint32_t flags = 0;
};

// Immutable identity for the MapData -> Economy input workset. The fields
// are generation-only metadata; captured arrays remain native-owned.
struct EconomyInputGeneration {
    int64_t sample_day = -1;
    uint64_t epoch_id = 0;
    uint64_t map_generation = 0;
    uint64_t building_generation = 0;
    uint64_t country_generation = 0;
    uint64_t resource_generation = 0;

    bool operator==(const EconomyInputGeneration &other) const noexcept {
        return sample_day == other.sample_day &&
               epoch_id == other.epoch_id &&
               map_generation == other.map_generation &&
               building_generation == other.building_generation &&
               country_generation == other.country_generation &&
               resource_generation == other.resource_generation;
    }
};

class DCWorldExt : public godot::RefCounted {
    GDCLASS(DCWorldExt, godot::RefCounted);

public:
    DCWorldExt();
    ~DCWorldExt() override;
    static void shutdown_loading_tasks();

    void sync_runtime_domain_ownership();
    bool economy_worker_owns_natural_resources() const;
    // PK_SIM_DAY_TRACE: one "[main-write]" line with climate slot hashes.
    void sim_trace_main_write(const char *tag);
    struct SimTraceWriteGuard {
        DCWorldExt *self;
        const char *tag;
        ~SimTraceWriteGuard() { self->sim_trace_main_write(tag); }
    };
    // B8 P2：把"生产当前可用"的 wind traj 表导出给 capture。判定与 weather
    // field solve 的消费端同一契约：表已建 + knob 允许消费 + 指纹仍然匹配当前
    // 风场。返回 false 表示这次不该消费 traj（worker 与生产一起走 hopping 回退），
    // 而不是"没有这张表"。
    bool runtime_weather_traj_snapshot(int n_cells,
                                       std::vector<int32_t> &out_idx,
                                       std::vector<float> &out_w) const;
    // B8-2：把生产 cyclone 条目表编码成 worker/存档共用的 blob。空 blob = 当前没有
    // 活跃气旋（仍然是一次有效播种：worker 会接管空表并自行推进）。
    std::vector<uint8_t> runtime_cyclone_state_blob() const;

    void publish_restored_country_territory(godot::Dictionary &out);

    // Monotonic request id for the Economy POD queue (whole-graph ACTIVE).
    // ---- end Military

    // ---- end Military cell stats

    NativeSimulationHost *trigger_pod_host() const { return _runtime_host.get(); }

    // SPLIT AUTHORITY settle (mask 0xFEF: IDEOLOGY on the main thread, EFFECT and
    // MODIFIER on the worker). In that configuration the main thread has no
    // Effect settler -- `run_effect_daily`, both Modifier adapter halves and
    // `run_modifier_daily` all report `path=EFFECT_WORKER` -- so an ideology
    // equip's batch is planned here and never drained. This submits those rows
    // into the worker's Modifier lane and completes the Effect transaction once
    // the worker has committed them.
    //
    // INERT unless the worker is authoritative for EFFECT *and* MODIFIER, tested
    // with the same `domain_is_worker_authoritative` predicate `run_effect_daily`
    // uses to decide it has nothing to do. Anything weaker double-applies rows
    // the local adapter already applied (1.03 -> 1.0609).
    godot::Dictionary settle_split_authority_effects(int64_t day_index);
    struct EffectGameplayCommand {
        int32_t action = 0;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t effective_day = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value_i64 = 0;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
        int64_t request_id = 0;
    };
    // Native gameplay/event Effect ingress. The event journal remains the
    // authority; this queue only preserves the Effect safe-boundary ACK.
    bool submit_effect_gameplay_commands_pod(const EffectGameplayCommand *commands,
                                             size_t count,
                                             std::vector<int64_t> &request_ids,
                                             std::string &error);
    bool effect_gameplay_command_result_pod(int64_t request_id, bool &complete,
                                            bool &ok, std::string &reason) const;
    bool commit_canal_effect(uint64_t project_handle,
                             uint32_t project_generation,
                             uint64_t idempotency_key,
                             std::string &error);

    // §2.0 of the round-1 review: the plane is OFF by default. Until generation,
    // double-application, selector semantics, coefficient semantics and thread
    // ownership are fixed, it must not touch shipped numbers. Tests turn it on
    // explicitly.
    // Inject a table directly. The generator has no DSL for columns yet, so the
    // only way to exercise `NEIGHBOR_COUNT` is to hand-build one.
    bool set_ideology_cell_program_entry_for_test(
        int32_t stat_id, int32_t filter_tag, int32_t operation,
        int32_t coef_q16, int32_t column_kind, int32_t column_tag,
        int32_t cap_units);

    // Native-only hot-path helpers. They resolve no strings in the consumer loop.
    float modifier_climate_radiative_target(int cell, float base_value) const;
    double modifier_country_output_factor(int64_t country_handle) const;
    double modifier_building_output_factor(int64_t building_handle,
                                           int64_t settlement_cell) const;

    void append_economy_read_view_perf(godot::Dictionary &out) const;

    godot::Dictionary poll_runtime_events_snapshot_opts(
        const godot::Dictionary &opts);

    // Returns a pointer to the per-cell annual-mean insolation cache (size n),
    // rebuilding when latitude values, axial tilt or day length change.
    // Shared by run_climate_pass_a and run_climate_pass_a_thread. Bit-equal to the
    // inline dc_insolation_annual_mean(dc_clamp01f(lat[i]), ...) it replaces.
    const float *ensure_insol_annual_mean_cache(const float *lat_ptr, int n,
                                                float axial_tilt_deg, float daylen_amp);

    // ─── Phase F / dots-full-migration §F.1-F.6 hot pass C++ scaffolding ──
    //
    // 6 个待 C++ 化的 hot pass，本提交为 **stub**——每个函数 sig 已就位、
    // _bind_methods 已注册、ClimateProfile 配套 use_gdext_<name> flag 已加，
    // 函数体当前 return -1.0 → GDScript caller 走 fallback。
    //
    // 后续 PR 按 charter §12.4 七步 SOP + tools/migration_harness/template_bench.gd
    // 逐个填充实际算法 + bit-equal 验收。每个 pass 顶部注释列出对应 GDScript
    // 源文件 + 性能目标（charter §7）。
    //
    // 加入顺序按 charter §7 收益优先级：F.1 (P0) → F.2 (P1) → ... → F.6 (P3)。

    // run_bake_coast_sdf_pass（water-bodies systemic）：海/湖统一"离岸像素距离场"。
    //   从 per-pixel terrain(biome_buffer) 的 land-water 边界做 chamfer 3-4 双通距离变换，
    //   产出每像素到最近水体的像素距离（水体=0，向内陆递增，clamp 于 coast_sdf_max_dist_px）。
    //   水集合 = {0,1,18,19,20,21}（与 terrain_index is_water / pk_is_water_terrain 对齐）。
    //   输入 width/height/biome_buffer/coast_sdf_max_dist_px/coast_sdf_wrap_x。
    //   输出 out_buf(F32 PackedFloat32Array)。供 geometry_fields 在 river carve 后刻连续岸坡。
    godot::Dictionary run_bake_coast_sdf_pass(godot::Dictionary knobs);

    // ─── Phase C.1（dots-total-cpp roadmap）：System schedule graph 节点 ──
    //
    // 这组 _exec_node_* 是 system_schedule.h 内 SystemNode.exec_fn 的成员函数
    // 指针目标。public 仅是为了让 `&DCWorldExt::_exec_node_xxx` 能在 cpp
    // 全局静态表 SCHEDULE_GRAPH 中取地址；**不**对外提供调用语义——只能由
    // system_schedule.cpp 的 dispatch_system_schedule loop 调用。
    //
    // 每个节点直接镜像 run_native_daily_tick line 960-1063 内对应 if-bundle
    // 块的语义：读 bundle key → 调 run_<X>_pass → 累加 breakdown（含 climate_ms
    // / ocean_ms / stage_b_ms 跨 pass 累加）→ 写节点级 side-effect（stage_b 的
    // 4 个 breakdown 回填、weather 的 _native_fronts_snapshot 写入）。
    // 返回 true=成功；false=fallback 触发，dispatch loop 走 finish_with_failure。
    bool _exec_node_climate_pass_a     (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_ocean_water        (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_ocean_land         (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_climate_pass_b     (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_wind_air           (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_wind_surface       (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_sea_ice            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_transpiration      (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_albedo             (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_vegetation_dynamics(godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_climate_feedback   (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_stage_b            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_stage_b_after_hydrology(godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_weather            (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);
    bool _exec_node_runtime_hydrology  (godot::Dictionary& bundle,
                                        const godot::Dictionary& tick_knobs,
                                        godot::Dictionary& breakdown);

    // ─── perf 2026-07-08, Item 1：phys pass 每调用固定开销缓存 ───────────
    // 解析四个 phys pass 共用的 cell_* slot id + 重建 is_water_lut，按
    // FNV-1a(n_cells, water_terrain_ids) 指纹失效。命中后各 pass 直接读
    // _phys_sid_* / _phys_is_water_lut 成员，省掉重复 component_id(StringName)
    // 与 256 字节 LUT 重建。邻居索引仍由 knob 传入（保留 fallback）。
    // 仅在指纹失配时重算（地图 regen / 水掩膜变化），主线程同步调用。
    void _phys_resolve_static(int n_cells, const godot::PackedByteArray &water_ids);
    // cell_lat_norm slot 的只读指针；slot 缺失或尺寸不符返回 nullptr（调用方退化为
    // 用 cell_pos_y 自归一化）。需先调用 _phys_resolve_static()。
    const float *_phys_lat_norm_ptr(int n_cells);
    // 缓存 WIND coast/sea BFS 结果（coast_dist/sea_dist 等）到成员；指纹失配才重建。
    // TR/NB/water_ids 来自当前 pass 已解析的 slot/knob（调用方传入）。
    void _phys_ensure_wind_coast(int n_cells, const uint8_t *TR, const int32_t *NB,
                                 const bool *is_water_lut, const godot::PackedByteArray &water_ids);
    // NS 化 Phase 0：在 wind pass 末尾由最终风槽构建半拉格朗日回溯轨迹表
    // （每 cell 3×i32 邻居索引 + 3×f32 权重），供动量自平流与 weather/wind_air
    // SL 平流消费。内部用 pk::parallel_for_range，只读 slots、写 own-row。
    void _phys_build_wind_traj(int n_cells, const float *POSX, const float *POSY,
                               const int32_t *NB, const float *WX, const float *WY,
                               const float *WSP, double wrap_period_x,
                               double traj_pos_scale, double traj_dt_days);

    void async_climate_shutdown_all();

    // ───────────────────────────────────────────────────────────────────
    // Async Climate Round（plan §async-stage-1，2026-06-14）
    //
    // Goal：把整个 climate daily round（pass_a → pass_b → ocean_water →
    // ocean_land → wind_air → wind_surface → sea_ice → transp 8 个 pass）
    // 整体扔给 worker thread 跑，主线程只做 kick/poll 和短暂 memcpy。
    // 主线程目标：每帧 climate 相关工作 < 1.5ms（kick + poll + flush）。
    //
    // 本阶段（Stage 1）：
    //   - 搭好 round-level async 框架（input/output/work buf + 单 worker
    //     thread + std::condition_variable wake/wait）
    //   - 8 pass 中只有 transpiration 实现 pure std::vector kernel；
    //     其它 7 pass 留 stub（input → output 直传，不修改）
    //   - GDScript 端用一个隔离的测试入口（cp.use_climate_round_async = true
    //     时 climate_daily_system 走 async 路径，否则走原 sync 路径）
    //
    // 线程安全契约（与 demo async 完全一致，不重复说明）：worker 全程只碰
    // std::vector / atomic / mutex / cv，绝不调任何 Godot API。
    //
    // 单例语义：本机制只支持一个 async climate round 任务（不需要 task_id
    // 多路），全局状态指针 _async_climate_round_state 由 lazy alloc 维护。
    // 析构时由 ~DCWorldExt 调 async_climate_round_shutdown 安全 join。

    // S3：Dictionary → ClimateInputBuf 的唯一提取实现。async_climate_round_kick
    // 与 capture_runtime_inputs（SHADOW worker 的输入边界）都调它，保证两条驱动
    // 路径拿到逐位相同的输入缓冲。调用方负责并发保护。
    // prefer_slot_lanes=true 时，pass_a 读的 per-cell lane 改从 _slots 取而不是从
    // Dictionary（即 MapData 镜像）取。SHADOW capture 必须用它：生产 pass_a 读的是
    // _slots，MapData 镜像只在部分 pass 末尾 flush，两者在同一日起点未必相等——
    // 那种差异会以"同一份内核算出不同结果"的形式出现在对拍里，极难归因。
    void fill_climate_round_input(const godot::Dictionary &input, int n_cells,
                                  pk_async_climate::ClimateInputBuf &buf,
                                  bool prefer_slot_lanes = false);

    // 记下生产 pass_b 用的海冰浓度 lane。它不是 slot，也不在 pass_a 留存的 kin 里。
    void record_production_pass_b_input(int n_cells, const float *sea_ice_frac,
                                       const float *temp_transport_anomaly);

    // 同理，sea_ice 的温度 lane：生产刻意从 GDScript 的 cell.temperature 打包传入，
    // 不是 SoA cell_temp。两者差一整段 ocean_land 修正，读错会多算冰。
    void record_production_sea_ice_input(
        const pk_async_climate::SeaIceLanes &lanes, int n_cells);

    // 记下生产 wind_surface 真正读到的 oanom。它由跳过 round 的分片 ocean stage
    // 写，worker 补不出来 —— 见 pk_async_climate::WindSurfaceInput 的注释。
    void record_production_wind_surface_input(int n_cells, const float *ocean_anomaly);

    // 记下生产 ocean_water 真正用的 baseline / temp_before——两者都是非 slot 的
    // 派生量，见 pk_async_climate::OceanWaterInput 的注释。
    void record_production_ocean_water_input(int n_cells, const float *baseline,
                                            const float *temp_before);

    // 从一个 sync pass 的 knobs Dictionary 里抽出它那段 round 标量，记进
    // _production_round_scalars。pass_bit 用 passes_mask 的位（0x02 pass_b /
    // 0x04 ocean_water / 0x08 ocean_land / 0x10 wind_air / 0x20 wind_surface /
    // 0x40 sea_ice）。在每个 pass 的标量拉取之后调用，读的就是那个 pass 自己用的
    // Dictionary —— 所以不会产生第二个取值来源。
    // pass_a 的 25 个标量没有对应的 knobs Dictionary 记录点（生产在 pass 内部就把
    // 它们组装成 ClimateRoundScalars 了）。直接抄那一份，而不是再解析一次字典。
    void record_production_pass_a_scalars(
        const pk_async_climate::ClimateRoundScalars &src);
    void record_production_round_scalars(int pass_bit,
                                        const godot::Dictionary &knobs);

    // stage 10（climate_feedback）：把生产这一次真正读到的输入 lane 连同标量整份留存。
    // 为什么不能让 worker 用 environment 快照的同名 lane：feedback 跑在 stage_b 段、
    // 也就是 weather 之后，而快照是 tick 起始拍的；weather_type / weather_intensity 在
    // 这两个时刻之间正好被 weather pass 整场重写过。
    void record_production_feedback_input(
            const pk_async_climate::ClimateFeedbackKnobs &knobs, int n_cells,
            const uint8_t *is_water, const uint8_t *weather_type,
            const float *weather_intensity, const uint8_t *weather_field_init,
            const float *temp_transport_anomaly, const float *base_moisture,
            const float *soil_moisture);

    // stage 9（vegetation_dynamics）同理，但它读的东西更多：8 张查表 + 11 条输入
    // lane，其中 terrain / landform / vegetation 三条会被上一天的演替后处理（GDScript
    // 侧写 cell.vegetation）改动，而那次写入不属于任何 climate stage —— 拿快照那份等于
    // 用演替前的植被算演替后的活力。
    void record_production_vegetation_input(
            const pk_async_climate::VegetationDynamicsKnobs &knobs,
            const pk_async_climate::VegetationDynamicsTables &tables,
            const pk_async_climate::VegetationDynamicsLanes &lanes,
            int n_cells);

    // stage 11（weather field solve）同理，但它还要记七组跨 tick 状态的初值。
    // 那七组都不是 RuntimeClimateStore 的成员，worker 若从零起步，ψ 与对流抑制要好
    // 几天才与生产收敛，而这几天会被分叉矩阵记成算法分叉。
    void record_production_weather_input(
            const pk_async_climate::WeatherFieldKnobs &knobs,
            const pk_async_climate::SynopticAdvanceKnobs &synoptic,
            bool synoptic_enabled,
            const pk_async_climate::WeatherFieldLanes &lanes,
            const pk_async_climate::WeatherFieldState &state,
            int n_cells,
            const uint8_t *field_init = nullptr);

    // weather distribute（stage 11 后段）同理。cover 与两条积雪计数都是没有 store
    // 成员承接的 in/out，记初值、worker 用 scratch。
    void record_production_weather_distribute_input(
            const pk_async_climate::WeatherDistributeKnobs &knobs,
            const pk_async_climate::WeatherDistributeLanes &lanes,
            const pk_async_climate::WeatherDistributeState &state,
            int n_cells);

    // stage 12（runtime hydrology）同理。运河拓扑代号也跟着过去：worker 侧的
    // 编译缓存按它失效，对不上就会在运河变更的那一天潜默用旧拓扑。
    void record_production_hydrology_input(
            const pk_async_climate::HydrologyKnobs &knobs,
            const pk_async_climate::HydrologyLanes &lanes,
            bool has_neighbors, uint64_t canal_topology_generation,
            int n_cells);

    // 把 pass_a 读的 slot-backed lane 覆盖进 buf。返回 false 表示 slot 不完整
    // （未 bind / 尺寸不符），此时 buf 保持调用方给的内容。
    bool override_climate_round_input_from_slots(int n_cells,
                                                pk_async_climate::ClimateInputBuf &buf);

#include "world_ext_declarations_core.inc"
#include "world_ext_declarations_runtime.inc"
#include "world_ext_declarations_climate.inc"
#include "world_ext_declarations_surface.inc"
#include "world_ext_declarations_physical_raster.inc"
#include "world_ext_declarations_weather.inc"
#include "world_ext_declarations_circulation.inc"
#include "world_ext_declarations_climate_async.inc"
#include "world_ext_declarations_economy.inc"
#include "world_ext_declarations_country.inc"
#include "world_ext_declarations_military.inc"
#include "world_ext_declarations_rules.inc"
#include "world_ext_declarations_generation.inc"
#include "world_ext_declarations_visual.inc"
#include "world_ext_declarations_demo.inc"
protected:
    static void _bind_methods();
    static void _bind_core_methods();
    static void _bind_runtime_methods();
    static void _bind_climate_methods();
    static void _bind_economy_methods();
    static void _bind_country_methods();
    static void _bind_military_methods();
    static void _bind_effect_methods();
    static void _bind_modifier_methods();
    static void _bind_ideology_methods();
    static void _bind_trigger_methods();
    static void _bind_events_methods();
    static void _bind_generation_methods();
    static void _bind_bake_encoders_methods();
    static void _bind_visual_methods();
    static void _bind_demo_methods();

private:
#include "world_ext_declarations_climate_state.inc"
#include "world_ext_declarations_map_state.inc"
#include "world_ext_declarations_simulation_state.inc"
#include "world_ext_declarations_world_state.inc"
    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
    void _flush_slot_to_map(int comp_id, bool notify_resources = true);
    int  _bind_index_for_slot(int comp_id);
    // Reverse of the above: MapData property name -> slot name. The Climate
    // parity table names MapData arrays, so write-back needs to get from there
    // to a slot. Returns the slot name so callers outside world_ext.cpp do not
    // need BIND_TABLE in scope. nullptr when the property is not bound.
    static const char *_slot_name_for_property(const char *property_name);
    bool _slot_is_visual_dirty(int comp_id);
    godot::Dictionary _queue_bio_observations(
        int64_t country_handle, int64_t effective_day,
        const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &signals);
    friend class NativeMilitaryRuntime;
    bool publish_legacy_military_events(std::vector<RuntimeEventsRecord> &records);
    int64_t _emit_gameplay_event(int64_t tick,
                                 int32_t phase,
                                 int32_t type,
                                 int32_t source,
                                 int32_t flags,
                                 uint64_t entity_handle,
                                 int32_t entity_id,
                                 int32_t cell_idx,
                                 int32_t payload_schema,
                                 int64_t value_i64,
                                 int32_t payload_i0,
                                 int32_t payload_i1,
                                 int32_t payload_i2,
                                 int32_t payload_i3);
    void _emit_succession_events(const godot::PackedInt32Array &indices,
                                 const godot::PackedByteArray &to_veg,
                                 const uint8_t *old_veg,
                                 int old_veg_size,
                                 int64_t tick,
                                 int32_t phase,
                                 int32_t source);
    void _append_gameplay_event_to_arrays(const GameplayEventRecord &ev,
                                          godot::PackedInt64Array &ids,
                                          godot::PackedInt64Array &ticks,
                                          godot::PackedInt32Array &phase,
                                          godot::PackedInt32Array &type,
                                          godot::PackedInt32Array &source,
                                          godot::PackedInt32Array &flags,
                                          godot::PackedInt64Array &entity_handle,
                                          godot::PackedInt32Array &entity,
                                          godot::PackedInt32Array &cell,
                                          godot::PackedInt32Array &schema,
                                          godot::PackedInt64Array &value,
                                          godot::PackedInt32Array &p0,
                                          godot::PackedInt32Array &p1,
                                          godot::PackedInt32Array &p2,
                                          godot::PackedInt32Array &p3) const;
    godot::Dictionary _run_native_generation_publish_pass(
        int seed,
        const godot::Dictionary &cfg,
        const godot::Dictionary &profile,
        const godot::Dictionary &budget);
};

} // namespace pk
