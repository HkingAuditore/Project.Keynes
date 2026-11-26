#include "world_ext.h"
#include "runtime_world_environment.h"
#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_domain_pod.h"
#include "runtime_country_pod.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "runtime_protocol_guard.h"
#include "runtime_ideology_pod.h"
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "map_overlay_input_publication.h"
#include "metric_mask_tests.h"
#include "runtime_switch_registry.h"
#include "world_ext_simulation_host_internal.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pk {

using namespace godot;

namespace {

// 把生产侧交来的 MapData 数组还原成一份 RuntimeClimateStore。
//
// 键名就是 parity 表的 canonical name（RuntimeClimateParityField::name 的注释里
// 写明了它同时是这个绑定接受的字典键），所以这里不存在第二套名字映射 —— 表是
// 唯一的真相，加一个 parity 字段不需要动这个函数。
//
// 缺一条 comparable 字段就整份拒绝，`missing_fields` 带回是哪几条。**不能**把缺席
// 的字段当成零值继续哈希：那样归约照样出一个数，而两侧的零位置不同，日后会以
// "Climate 算法分叉"的形式浮出来 —— 一个本来在边界上就能一句话说清的问题，变成
// 要从分叉矩阵反推的谜题。cell_count 同理不从数组长度推断：推断出来的值一旦不对，
// 逐条 size 检查会把每条字段都报成长度错，掩盖真正缺失的那一条。
bool build_climate_store_from_fields(const Dictionary &fields,
                                     RuntimeClimateStore &store,
                                     String &error,
                                     Array *missing_fields = nullptr) {
    const int cell_count = static_cast<int>(fields.get("cell_count", 0));
    if (cell_count <= 0) {
        error = String("climate_reference_cell_count_missing");
        return false;
    }
    store.reset(static_cast<uint32_t>(cell_count));
    store.climate_anomaly =
        static_cast<float>(static_cast<double>(fields.get("climate_anomaly", 0.0)));
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    Array missing;
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        // 非 comparable 的两类字段本来就不该出现：no_reference 是生产侧没有对应的
        // MapData 数组，type_mismatch 是两侧元素类型无法逐位比 —— 归约也不含它们。
        if (!fields.has(f.name)) {
            if (f.comparability ==
                    RuntimeClimateParityComparability::COMPARABLE) {
                missing.push_back(String(f.name));
            }
            continue;
        }
        const Variant raw = fields[f.name];
        switch (f.kind) {
        case RuntimeClimateParityKind::F32: {
            if (f.f32 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedFloat32Array values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.f32);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        case RuntimeClimateParityKind::I32: {
            if (f.i32 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_INT32_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedInt32Array values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.i32);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        case RuntimeClimateParityKind::U8: {
            if (f.u8 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedByteArray values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.u8);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        }
    }
    if (!missing.is_empty()) {
        error = String("climate_parity_fields_missing");
        if (missing_fields != nullptr) *missing_fields = missing;
        return false;
    }
    return true;
}

} // namespace

void append_climate_stage_cadence(Dictionary &out,
                                  const RuntimeThreadReport &report) {
    PackedFloat64Array stage_ms;
    PackedInt64Array stage_work;
    PackedStringArray stage_names;
    const size_t count = report.climate_stage_ms.size();
    stage_ms.resize(static_cast<int>(count));
    stage_work.resize(static_cast<int>(count));
    stage_names.resize(static_cast<int>(count));
    for (size_t i = 0; i < count; ++i) {
        stage_ms.set(static_cast<int>(i), report.climate_stage_ms[i]);
        stage_work.set(static_cast<int>(i),
                       static_cast<int64_t>(report.climate_stage_work[i]));
        stage_names.set(static_cast<int>(i),
                        String(runtime_climate_stage_name(
                            static_cast<RuntimeClimateStage>(i))));
    }
    out["climate_stage_ms"] = stage_ms;
    out["climate_stage_work"] = stage_work;
    out["climate_stage_names"] = stage_names;
}

bool DCWorldExt::climate_worker_authoritative() const {
    // 直接读 host，不经任何 GDScript 注入的镜像：抑制门每 tick 都要问这个，而一个
    // 落后一帧的 false 会让主线程在 worker 已经在产出同一天时再跑一遍 Climate。
    if (!_runtime_host) return false;
    return _runtime_host->domain_is_worker_authoritative(
        RuntimeDomainId::CLIMATE);
}

bool DCWorldExt::climate_main_thread_suppressed() const {
    return _runtime_host &&
           _runtime_host->domain_main_thread_suppressed(RuntimeDomainId::CLIMATE);
}

bool DCWorldExt::climate_physics_authoritative() const {
    if (!climate_worker_authoritative() || !_climate_physics_capture_ready || !_map_data ||
        _climate_physics_map_id != _map_data->get_instance_id() || !_climate_physics_committed ||
        !_climate_physics_committed->ready || !_climate_physics_committed->initialized) return false;
    const auto input = _runtime_host->environment_snapshot();
    return input && input->cell_count == static_cast<uint32_t>(_climate_physics_committed->cell_count) &&
        input->climate_physics_knobs.ready && input->climate_physics_knobs.enabled;
}

Dictionary DCWorldExt::get_climate_physics_commit_info() const {
    Dictionary out;
    const bool ready = climate_physics_authoritative();
    out["ready"] = ready;
    out["authoritative"] = ready;
    out["ok"] = ready;
    out["code"] = ready ? "ok" : "physics_not_committed_or_not_granted";
    if (!ready) return out;
    const auto &s = *_climate_physics_committed;
    out["committed_day"] = s.committed_day;
    out["input_generation"] = static_cast<int64_t>(s.input_generation);
    out["generation"] = static_cast<int64_t>(s.generation);
    out["map_instance_id"] = static_cast<int64_t>(_climate_physics_map_id);
    out["cell_count"] = s.cell_count;
    return out;
}

Dictionary DCWorldExt::get_climate_physics_read_view() const {
    Dictionary out = get_climate_physics_commit_info();
    if (!static_cast<bool>(out["ready"])) return out;
    const auto &s = *_climate_physics_committed;
    out["state_hash"] = static_cast<int64_t>(s.state_hash());
    out["last_slp_day"] = s.last_slp_day;
    out["last_wind_day"] = s.last_wind_day;
    out["last_ocean_day"] = s.last_ocean_day;
    auto lane = [&](const char *name, const std::vector<float> &v) {
        PackedFloat32Array a;
        a.resize(static_cast<int>(v.size()));
        if (!v.empty()) std::memcpy(a.ptrw(), v.data(), v.size() * sizeof(float));
        out[name] = a;
    };
    lane("slp", s.slp); lane("wind_x", s.wind_x); lane("wind_y", s.wind_y);
    lane("wind_speed", s.wind_speed); lane("ocean_current_x", s.ocean_current_x);
    lane("ocean_current_y", s.ocean_current_y); lane("ocean_psi", s.ocean_psi);
    lane("upwelling", s.upwelling); lane("wind_stress_curl", s.wind_stress_curl);
    lane("ocean_thermal_anomaly", s.ocean_thermal_anomaly);
    lane("monsoon_thermal", s.monsoon_thermal); lane("synoptic_psi", s.synoptic_psi);
    return out;
}

#include "world_ext_simulation_host_climate_section_parity.inc"

Dictionary DCWorldExt::wait_climate_consumed(
        int64_t after_environment_generation, int64_t timeout_ms) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        // 契约：等待接口永远报告消费游标，即使 worker 从未启动 —— 调用方据此
        // 保持自己的游标不动，而不是把缺失键当成 0。
        out["consumed_generation"] = 0;
        out["after_environment_generation"] = after_environment_generation;
        out["waited_ms"] = 0.0;
        return out;
    }
    if (after_environment_generation < 0) {
        const RuntimeThreadReport snapshot = _runtime_host->report();
        out["ok"] = false;
        out["code"] = "climate_wait_generation_invalid";
        out["consumed_generation"] =
            static_cast<int64_t>(snapshot.climate_consumed_generation);
        return out;
    }
    const auto started = std::chrono::steady_clock::now();
    uint64_t consumed = 0;
    std::string error;
    const bool ok = _runtime_host->wait_climate_consumed(
        static_cast<uint64_t>(after_environment_generation), timeout_ms,
        consumed, error);
    const double waited_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out["ok"] = ok;
    out["code"] = ok ? String("ok") : String(error.c_str());
    out["waited_ms"] = waited_ms;
    out["after_environment_generation"] = after_environment_generation;
    out["consumed_generation"] = static_cast<int64_t>(consumed);
    out["worker_state"] = static_cast<int>(_runtime_host->state());
    const RuntimeThreadReport snapshot = _runtime_host->report();
    out["climate_committed_day"] = snapshot.climate_committed_day;
    out["environment_published_days"] =
        static_cast<int64_t>(snapshot.environment_published_days);
    out["environment_consumed_days"] =
        static_cast<int64_t>(snapshot.environment_consumed_days);
    out["environment_superseded_days"] =
        static_cast<int64_t>(snapshot.environment_superseded_days);
    return out;
}

// P1：环境帧预发布探测。只读、不加锁、不阻塞。
bool DCWorldExt::environment_ring_has_capacity() const {
    if (!_runtime_host) return false;
    return _runtime_host->environment_ring_has_capacity();
}

int64_t DCWorldExt::runtime_committed_day() const {
    if (!_runtime_host) return -1;
    // 廉价路径：一次原子读。预发布器每帧都调它。
    return _runtime_host->committed_day_value();
}

int64_t DCWorldExt::runtime_next_environment_day() const {
    if (!_runtime_host) return -1;
    return _runtime_host->next_environment_day();
}

int64_t DCWorldExt::request_runtime_calendar_day(int64_t date) {
    return _runtime_host ? _runtime_host->request_runtime_calendar_day(date) : -1;
}

Dictionary DCWorldExt::apply_runtime_climate_writeback(
        int64_t after_generation) {
    SimTraceWriteGuard sim_trace_guard{this, "apply_runtime_climate_writeback"};
    Dictionary out;
    const auto writeback_start = std::chrono::steady_clock::now();
    if (after_generation < 0) after_generation = 0;
    after_generation = std::max<int64_t>(
        after_generation, static_cast<int64_t>(_climate_writeback_applied_generation));
    out["last_applied_day"] = _climate_writeback_applied_day;
    out["committed_day"] = _climate_physics_committed ? _climate_physics_committed->committed_day : -1;
    out["input_generation"] = _climate_physics_committed
        ? static_cast<int64_t>(_climate_physics_committed->input_generation) : int64_t(0);
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (!_map_data) {
        out["ok"] = false;
        out["code"] = "runtime_writeback_map_unavailable";
        return out;
    }
    const auto batch_climate = _runtime_display_commit.day_tail
        ? _runtime_display_commit.day_tail->climate : nullptr;
    const auto display = batch_climate ? batch_climate : _runtime_host->latest_climate_display();
    uint32_t slot = 0;
    const bool has_ring = !display && _runtime_host->try_acquire_climate_writeback(
        static_cast<uint64_t>(after_generation), slot);
    if ((!display || display->generation <= static_cast<uint64_t>(after_generation)) && !has_ring) {
        // 不是错误：worker 还没提交更新的一天。ok=true / applied=false 让调用方的
        // 游标保持不动，而不是把"这一帧没有新数据"当成失败去重试。
        out["ok"] = true;
        out["applied"] = false;
        out["code"] = "ok";
        out["generation"] = after_generation;
        out["drops"] =
            static_cast<int64_t>(_runtime_host->climate_writeback_drop_count());
        return out;
    }
    const RuntimeClimateSnapshot &snapshot = display ? *display
        : _runtime_host->climate_writeback_buffer(slot);
    const RuntimeClimateStore &store = snapshot.payload;
    const int cell_count = static_cast<int>(store.cell_count);
    if (cell_count <= 0) {
        if (has_ring) _runtime_host->release_climate_writeback(slot);
        out["ok"] = false;
        out["applied"] = false;
        out["code"] = "runtime_writeback_empty_store";
        return out;
    }

    using PhysicsState = pk_async_physics::RuntimeClimatePhysicsState;
    auto physics = snapshot.physics_writeback;
    const bool projected_physics = physics != nullptr;
    std::string physics_error;
    if (!physics && !store.physics_state.empty()) {
        auto restored = std::make_shared<PhysicsState>();
        if (pk_async_physics::restore_physics_state(store.physics_state.data(),
                store.physics_state.size(), *restored, physics_error)) {
            physics = std::move(restored);
        }
    }
    if (!physics_error.empty() || (physics &&
            (physics->cell_count != cell_count || physics->committed_day != snapshot.committed_day ||
             physics->input_generation != snapshot.input_generation))) {
        if (has_ring) _runtime_host->release_climate_writeback(slot);
        _climate_physics_committed.reset();
        out["ok"] = false; out["applied"] = false;
        out["code"] = physics_error.empty()
            ? String("physics_commit_mismatch") : String(physics_error.c_str());
        return out;
    }
    const bool apply_physics = physics && physics->initialized && physics->ready && climate_worker_authoritative();
    // 物理 family 全部预检通过后才写；任何缺槽都不能宣称 grant。
    bool reused_wind_trajectory = false;
    if (apply_physics) {
        for (const char *name : {"cell_slp", "cell_wind_x", "cell_wind_y", "cell_wind_speed",
                "cell_ocean_current_x", "cell_ocean_current_y", "cell_ocean_psi",
                "cell_upwelling_strength", "cell_wind_stress_curl", "cell_ocean_thermal_anomaly"}) {
            const int sid = component_id(StringName(name));
            if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
                (_slots[sid].external_ref && _slots[sid].arr_f32.size() != cell_count)) {
                if (has_ring) _runtime_host->release_climate_writeback(slot);
                _climate_physics_committed.reset();
                out["ok"] = false; out["applied"] = false;
                out["code"] = String("physics_writeback_slot_invalid:") + name;
                return out;
            }
        }
    }
    // ACTIVE 下主线程气候回合不再调用 soa_begin_climate_transaction，
    // *_arr_prev 与天气分类湿度会停在世界生成时的值。回灌覆盖 current 之前
    // 先把上一份已提交场记进 prev，录制、分类和任何读 prev 的消费者才看得到日变化。
    if (_map_data->has_method(StringName("soa_begin_climate_transaction"))) {
        _map_data->call(StringName("soa_begin_climate_transaction"));
    }
    PackedStringArray touched_slots;
    PackedStringArray skipped;
    int applied_fields = 0;

    // 走 parity 字段表而不是另列一张回灌清单：那张表已经是"哪些场属于 Climate 权威"
    // 的唯一定义（对拍用的就是它），另开一张清单等于让回灌和对拍可以各说各话 ——
    // 漏掉的场会一边在 parity 里显示对齐、一边在 MapData 里冻结。
    const size_t field_count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < field_count; ++i) {
        const RuntimeClimateParityField &field = table[i];
        const char *slot_name = _slot_name_for_property(field.map_data_array);
        if (slot_name == nullptr) {
            skipped.push_back(String(field.name) + String("(unbound)"));
            continue;
        }
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) {
            skipped.push_back(String(field.name) + String("(no_slot)"));
            continue;
        }
        Slot &s = _slots.write[sid];
        switch (field.kind) {
            case RuntimeClimateParityKind::F32: {
                if (field.f32 == nullptr) {
                    skipped.push_back(String(field.name) + String("(no_member)"));
                    continue;
                }
                const std::vector<float> &source = store.*(field.f32);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                // slot.h 的两条约束：dtype 决定哪条数组是活的（写错的那条会静默丢
                // 弃），external_ref 的 slot 不能 resize —— 那会脱开与 GDScript 那侧
                // 的别名，于是回灌写进一块没人读的内存。
                if (s.dtype != SlotDType::F32) {
                    skipped.push_back(String(field.name) + String("(dtype)"));
                    continue;
                }
                if (s.arr_f32.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_f32.resize(cell_count);
                }
                std::memcpy(s.arr_f32.ptrw(), source.data(),
                            static_cast<size_t>(cell_count) * sizeof(float));
                break;
            }
            case RuntimeClimateParityKind::I32: {
                if (field.i32 == nullptr) {
                    skipped.push_back(String(field.name) + String("(no_member)"));
                    continue;
                }
                const std::vector<int32_t> &source = store.*(field.i32);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                if (s.dtype != SlotDType::I32) {
                    skipped.push_back(String(field.name) + String("(dtype)"));
                    continue;
                }
                if (s.arr_i32.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_i32.resize(cell_count);
                }
                std::memcpy(s.arr_i32.ptrw(), source.data(),
                            static_cast<size_t>(cell_count) * sizeof(int32_t));
                break;
            }
            case RuntimeClimateParityKind::U8: {
                const std::vector<uint8_t> &source = store.*(field.u8);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                if (s.arr_u8.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_u8.resize(cell_count);
                }
                std::memcpy(s.arr_u8.ptrw(), source.data(),
                            static_cast<size_t>(cell_count));
                break;
            }
        }
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    }

    // 下面这几条走不了上面那张表：表是按 RuntimeClimateStore 的成员指针索引的，而
    // 它们没有 store 成员（理由见 RuntimeClimateSnapshot::soil_moisture）。共同点是
    // ACTIVE 下主线程那个写者被抑制门关掉了，worker 这份是它们唯一的日频写者 ——
    // 不回灌就等于这条场没有写者，MapData 会停在世界生成时的值。
    //
    // 空 vector = 这一天产出它的 stage 没跑（distribute 按 weather 轮的节拍，不是每
    // 天），此时保持 MapData 原值，不记 skipped：那不是缺陷，是节拍。
    const auto apply_extra = [&](const char *field_name, const char *slot_name,
                                 const std::vector<float> &source) {
        if (source.empty()) return;
        if (static_cast<int>(source.size()) != cell_count) {
            skipped.push_back(String(field_name));
            return;
        }
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) {
            skipped.push_back(String(field_name));
            return;
        }
        Slot &s = _slots.write[sid];
        if (s.dtype != SlotDType::F32) {
            skipped.push_back(String(field_name) + String("(dtype)"));
            return;
        }
        if (s.arr_f32.size() != cell_count && s.external_ref) {
            skipped.push_back(String(field_name) + String("(extern_size)"));
            return;
        }
        if (s.arr_f32.size() != cell_count) s.arr_f32.resize(cell_count);
        std::memcpy(s.arr_f32.ptrw(), source.data(),
                    static_cast<size_t>(cell_count) * sizeof(float));
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    };
    bool wind_written = false;
    if (apply_physics) {
        apply_extra("slp", "cell_slp", physics->slp);
        const int before_wind = applied_fields;
        apply_extra("wind_x", "cell_wind_x", physics->wind_x);
        apply_extra("wind_y", "cell_wind_y", physics->wind_y);
        apply_extra("wind_speed", "cell_wind_speed", physics->wind_speed);
        wind_written = applied_fields == before_wind + 3;
        apply_extra("ocean_current_x", "cell_ocean_current_x", physics->ocean_current_x);
        apply_extra("ocean_current_y", "cell_ocean_current_y", physics->ocean_current_y);
        apply_extra("ocean_psi", "cell_ocean_psi", physics->ocean_psi);
        apply_extra("upwelling", "cell_upwelling_strength", physics->upwelling);
        apply_extra("wind_stress_curl", "cell_wind_stress_curl", physics->wind_stress_curl);
        apply_extra("ocean_thermal_anomaly", "cell_ocean_thermal_anomaly", physics->ocean_thermal_anomaly);
        _phys_slp_buf = physics->slp;
        _phys_monsoon_thermal = physics->monsoon_thermal;
        // Use only the table for the environment that produced this wind.
        const auto env = _runtime_host->environment_snapshot();
        _phys_wind_traj_valid = false;
        if (env && env->cell_pos_x.size() == size_t(cell_count) && env->cell_pos_y.size() == size_t(cell_count) &&
            env->neighbor_indices.size() == size_t(cell_count) * 6 && env->generation == snapshot.input_generation &&
            physics->wind_traj_generation > 0) {
            const auto &k = env->climate_physics_knobs;
            if (physics->wind_traj_valid) {
                _phys_wind_traj_idx = physics->wind_traj_idx;
                _phys_wind_traj_w = physics->wind_traj_w;
                _phys_wind_traj_fp = physics->wind_traj_fingerprint;
                ++_phys_wind_traj_gen;
                _phys_wind_traj_valid = true;
                reused_wind_trajectory = true;
            } else {
                _phys_build_wind_traj(cell_count, env->cell_pos_x.data(), env->cell_pos_y.data(),
                    env->neighbor_indices.data(), physics->wind_x.data(), physics->wind_y.data(),
                    physics->wind_speed.data(), k.wrap_period_x, k.wind_traj_pos_scale, k.wind_traj_dt_days);
            }
            _phys_wind_traj_consume_enabled = k.wind_traj_weather_share != 0;
        }
    }
    apply_extra("soil_moisture", "cell_soil_moisture", snapshot.soil_moisture);
    // pass_a 的日照/热量输出。worker 内部算得对（round 内 pass_a→pass_b 走 out 缓冲，
    // 不经 MapData），坏的是外部读者：渲染、tile 录制、UI 面板读的都是 MapData。
    apply_extra("insolation_now", "cell_insolation_now", snapshot.insolation_now);
    apply_extra("insolation_dev", "cell_insolation_dev", snapshot.insolation_dev);
    apply_extra("day_length", "cell_day_length", snapshot.day_length);
    apply_extra("heat_input", "cell_heat_input", snapshot.heat_input);
    apply_extra("temp_season_offset", "cell_temp_season_offset",
                snapshot.temp_season_offset);

    const auto apply_extra_u8 = [&](const char *field_name, const char *slot_name,
                                    const std::vector<uint8_t> &source) {
        if (source.empty()) return;
        if (static_cast<int>(source.size()) != cell_count) {
            skipped.push_back(String(field_name));
            return;
        }
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) {
            skipped.push_back(String(field_name));
            return;
        }
        Slot &s = _slots.write[sid];
        if (s.dtype != SlotDType::U8) {
            skipped.push_back(String(field_name) + String("(dtype)"));
            return;
        }
        if (s.arr_u8.size() != cell_count && s.external_ref) {
            skipped.push_back(String(field_name) + String("(extern_size)"));
            return;
        }
        if (s.arr_u8.size() != cell_count) s.arr_u8.resize(cell_count);
        std::memcpy(s.arr_u8.ptrw(), source.data(),
                    static_cast<size_t>(cell_count) * sizeof(uint8_t));
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    };
    apply_extra_u8("weather_field_init", "cell_weather_field_init",
                   snapshot.weather_field_init);
    if (const auto &season = snapshot.season) {
        apply_extra("base_moisture", "cell_base_moisture", season->base_moisture);
        apply_extra_u8("landform", "cell_landform", season->landform);
        if (season->day > _climate_writeback_applied_day) {
            const auto bytes = [](const std::vector<uint8_t> &lane) {
                PackedByteArray array;
                array.resize(static_cast<int64_t>(lane.size()));
                std::memcpy(array.ptrw(), lane.data(), lane.size());
                return array;
            };
            _map_data->set("base_landform_arr", bytes(season->base_landform));
            out["season_day"] = season->day;
            out["biome_history"] = bytes(season->biome_history);
            out["vegetation_history"] = bytes(season->vegetation_history);
            out["season_history_next"] = static_cast<int64_t>(season->history_next);
        }
    }
    if (const auto &calendar = snapshot.calendar) {
        out["climate_rng_year"] = calendar->year;
        out["climate_rng_state"] = calendar->rng_state;
        out["climate_anomaly"] = calendar->anomaly;
    }

    if (!snapshot.restored_capture_cursors.empty()) {
        PackedFloat64Array cursors; cursors.resize(snapshot.restored_capture_cursors.size());
        std::memcpy(cursors.ptrw(), snapshot.restored_capture_cursors.data(), cursors.size() * sizeof(double));
        out["restored_capture_cursors"] = cursors;
    }
    const int64_t applied_day = snapshot.committed_day;
    const uint64_t applied_generation = snapshot.generation;
    const uint64_t applied_state_hash = snapshot.state_hash;
    const uint64_t applied_input_generation = snapshot.input_generation;
    const float applied_vapor_first = store.vapor.empty() ? 0.0f : store.vapor[0];
    // B8 P0：把"回灌慢"拆成 memcpy（worker 快照 → slot）与 flush（slot → MapData）
    // 两段。二者混在一个 total 里时，无法判断瓶颈是拷贝量还是 MapData 的写回路径，
    // 而这两条要采取的措施完全不同。
    const auto copy_done = std::chrono::steady_clock::now();
    // Release before flushing: the flush writes MapData, which the worker never
    // touches, so there is no reason to keep a ring slot occupied across it.
    if (has_ring) _runtime_host->release_climate_writeback(slot);

    flush_slots_to_map_keys(touched_slots);
    publish_map_overlay_wind(_map_data, wind_written ? physics->wind_display_signature : std::nullopt);
    _climate_physics_committed = apply_physics ? std::move(physics) : nullptr;
    _climate_physics_map_id = _map_data->get_instance_id();
    // B8 诊断（一次性）：确认天气场在 writeback 之后是否真的进了 MapData。用它
    // 区分"flush 没写进去"与"写进去之后被同 tick 的主线程写者覆盖"。
    {
        static std::atomic<int> s_weather_wb_reports_left{4};
        if (s_weather_wb_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            const Variant map_vapor = _map_data->get(StringName("weather_vapor_arr"));
            float map_first = 0.0f;
            float store_first = 0.0f;
            if (map_vapor.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
                const PackedFloat32Array arr = map_vapor;
                if (arr.size() > 0) map_first = arr[0];
            }
            store_first = applied_vapor_first;
            std::fprintf(stderr,
                "[climate/writeback][b8] day=%lld vapor store0=%.6g map0=%.6g "
                "dirty_fields=%d applied=%d\n",
                static_cast<long long>(applied_day), store_first, map_first,
                static_cast<int>(touched_slots.size()), applied_fields);
            std::fflush(stderr);
        }
    }
    const auto flush_done = std::chrono::steady_clock::now();
    const double copy_ms = std::chrono::duration<double, std::milli>(
        copy_done - writeback_start).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(
        flush_done - copy_done).count();
    const double total_ms = std::chrono::duration<double, std::milli>(
        flush_done - writeback_start).count();

    _climate_writeback_applied_generation = applied_generation;
    _climate_writeback_applied_day = applied_day;
    out["last_applied_day"] = applied_day;
    out["ok"] = true;
    // applied 只在真的写进了字段时为真。曾经这里无条件报 true，于是"回灌假活跃"
    // 让一次全空的写回看起来和成功一模一样。
    out["applied"] = applied_fields > 0;
    out["code"] = "ok";
    out["day"] = applied_day;
    out["committed_day"] = applied_day;
    out["input_generation"] = static_cast<int64_t>(applied_input_generation);
    out["physics_applied"] = apply_physics;
    out["physics_projection_applied"] = apply_physics && projected_physics;
    out["physics_wind_trajectory_reused"] = reused_wind_trajectory;
    out["physics_authoritative"] = climate_physics_authoritative();
    if (_runtime_host) {
        _runtime_host->note_climate_writeback_input_generation(
            applied_input_generation);
    }
    out["generation"] = static_cast<int64_t>(applied_generation);
    out["state_hash"] = static_cast<int64_t>(applied_state_hash);
    out["cell_count"] = static_cast<int64_t>(cell_count);
    // 键名由 GDScript 侧决定（world_runtime_host._apply_runtime_climate_writeback
    // 读的就是这两个）。被 slot 守卫拒掉的字段是"worker 拥有但从不发布"的字段，
    // MapData 会静默停在转权威那天的值 —— 所以拒绝清单必须出得来，不能只报计数。
    out["applied_fields"] = applied_fields;
    out["dirty_fields"] = touched_slots.size();
    out["skipped_fields"] = skipped;
    out["memcpy_ms"] = copy_ms;
    out["flush_map_ms"] = flush_ms;
    out["total_ms"] = total_ms;
    out["drops"] =
        static_cast<int64_t>(_runtime_host->climate_writeback_drop_count());
    return out;
}

#include "world_ext_simulation_host_climate_section_parity_diagnostics.inc"

} // namespace pk
