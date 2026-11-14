#include "world_ext.h"
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
    if (!_runtime_host) return false;
    return _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::CLIMATE) ||
           _runtime_host->domain_grant_pending(RuntimeDomainId::CLIMATE);
}

bool DCWorldExt::climate_physics_authoritative() const {
    if (!climate_worker_authoritative() || !_climate_physics_capture_ready || !_map_data ||
        _climate_physics_map_id != _map_data->get_instance_id() || !_climate_physics_committed ||
        !_climate_physics_committed->ready || !_climate_physics_committed->initialized) return false;
    const auto input = _runtime_host->environment_snapshot();
    return input && input->cell_count == static_cast<uint32_t>(_climate_physics_committed->cell_count) &&
        input->climate_physics_knobs.ready && input->climate_physics_knobs.enabled;
}

Dictionary DCWorldExt::get_climate_physics_read_view() const {
    Dictionary out;
    const auto committed = _climate_physics_committed;
    const bool ready = climate_physics_authoritative();
    out["ready"] = ready;
    out["authoritative"] = ready;
    out["ok"] = ready;
    out["code"] = ready ? "ok" : "physics_not_committed_or_not_granted";
    if (!ready) return out;
    const auto &s = *committed;
    out["committed_day"] = s.committed_day;
    out["input_generation"] = static_cast<int64_t>(s.input_generation);
    out["generation"] = static_cast<int64_t>(s.generation);
    out["state_hash"] = static_cast<int64_t>(s.state_hash());
    out["cell_count"] = s.cell_count;
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

Dictionary DCWorldExt::set_runtime_ideology_parity_enabled(bool enabled) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_ideology_parity_enabled(enabled);
    out["ok"] = true;
    out["code"] = "ok";
    out["enabled"] = _runtime_host->ideology_parity_enabled();
    return out;
}

Dictionary DCWorldExt::set_runtime_climate_parity_forcing(bool enabled) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_climate_parity_forcing(enabled);
    out["ok"] = true;
    out["code"] = "ok";
    out["enabled"] = _runtime_host->climate_parity_forcing();
    out["forced_days"] =
        static_cast<int64_t>(_runtime_host->climate_parity_forced_days());
    return out;
}

// 这三条枚举跨边界时给的是字符串而不是序号：GDScript 侧一律用 String() 包装它们
// （map_generator.gd:2434 的 != "comparable"、runtime_climate_parity_test 的
// in ["f32","i32","u8"]），而 Godot 4 的 String() 构造不接受 int —— 给序号会在那一行
// 抛 "Nonexistent 'String' constructor"，把 _collect_runtime_climate_parity_fields
// 整个打断，于是 reference publish 永远 pending、SHADOW 对拍一天都比不上。
static const char *pk_parity_kind_name(RuntimeClimateParityKind kind) {
    switch (kind) {
        case RuntimeClimateParityKind::F32: return "f32";
        case RuntimeClimateParityKind::I32: return "i32";
        case RuntimeClimateParityKind::U8:  return "u8";
    }
    return "f32";
}

static const char *pk_parity_comparability_name(
        RuntimeClimateParityComparability c) {
    switch (c) {
        case RuntimeClimateParityComparability::COMPARABLE: return "comparable";
        case RuntimeClimateParityComparability::TYPE_MISMATCH:
            return "type_mismatch";
        case RuntimeClimateParityComparability::NO_REFERENCE:
            return "no_reference";
    }
    return "no_reference";
}

static const char *pk_parity_tolerance_name(RuntimeClimateParityTolerance t) {
    switch (t) {
        case RuntimeClimateParityTolerance::BITWISE: return "bitwise";
        case RuntimeClimateParityTolerance::SLICED:  return "sliced";
        case RuntimeClimateParityTolerance::CHAINED: return "chained";
    }
    return "bitwise";
}

Array DCWorldExt::get_runtime_climate_parity_fields() const {
    Array out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        Dictionary row;
        row["name"] = String(f.name);
        row["map_data_array"] = String(f.map_data_array);
        row["kind"] = String(pk_parity_kind_name(f.kind));
        row["comparability"] = String(pk_parity_comparability_name(f.comparability));
        row["tolerance"] = String(pk_parity_tolerance_name(f.tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(f.tolerance);
        row["stage"] = static_cast<int>(f.stage);
        row["stage_name"] = String(runtime_climate_stage_name(f.stage));
        row["note"] = String(f.note != nullptr ? f.note : "");
        out.push_back(row);
    }
    return out;
}

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
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_climate_writeback(
            after_generation < 0 ? 0u : static_cast<uint64_t>(after_generation),
            slot)) {
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
    const RuntimeClimateSnapshot &snapshot =
        _runtime_host->climate_writeback_buffer(slot);
    const RuntimeClimateStore &store = snapshot.payload;
    const int cell_count = static_cast<int>(store.cell_count);
    if (cell_count <= 0) {
        _runtime_host->release_climate_writeback(slot);
        out["ok"] = false;
        out["applied"] = false;
        out["code"] = "runtime_writeback_empty_store";
        return out;
    }

    using PhysicsState = pk_async_physics::RuntimeClimatePhysicsState;
    std::shared_ptr<PhysicsState> physics;
    if (!store.physics_state.empty()) {
        physics = std::make_shared<PhysicsState>();
        std::string error;
        if (!pk_async_physics::restore_physics_state(store.physics_state.data(), store.physics_state.size(), *physics, error) ||
            physics->cell_count != cell_count || physics->committed_day != snapshot.committed_day ||
            physics->input_generation != snapshot.input_generation) {
            _runtime_host->release_climate_writeback(slot);
            _climate_physics_committed.reset();
            out["ok"] = false; out["applied"] = false;
            out["code"] = error.empty() ? String("physics_commit_mismatch") : String(error.c_str());
            return out;
        }
    }
    const bool apply_physics = physics && physics->initialized && physics->ready && climate_worker_authoritative();
    // 物理 family 全部预检通过后才写；任何缺槽都不能宣称 grant。
    if (apply_physics) {
        for (const char *name : {"cell_slp", "cell_wind_x", "cell_wind_y", "cell_wind_speed",
                "cell_ocean_current_x", "cell_ocean_current_y", "cell_ocean_psi",
                "cell_upwelling_strength", "cell_wind_stress_curl", "cell_ocean_thermal_anomaly"}) {
            const int sid = component_id(StringName(name));
            if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
                (_slots[sid].external_ref && _slots[sid].arr_f32.size() != cell_count)) {
                _runtime_host->release_climate_writeback(slot);
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
    if (apply_physics) {
        apply_extra("slp", "cell_slp", physics->slp);
        apply_extra("wind_x", "cell_wind_x", physics->wind_x);
        apply_extra("wind_y", "cell_wind_y", physics->wind_y);
        apply_extra("wind_speed", "cell_wind_speed", physics->wind_speed);
        apply_extra("ocean_current_x", "cell_ocean_current_x", physics->ocean_current_x);
        apply_extra("ocean_current_y", "cell_ocean_current_y", physics->ocean_current_y);
        apply_extra("ocean_psi", "cell_ocean_psi", physics->ocean_psi);
        apply_extra("upwelling", "cell_upwelling_strength", physics->upwelling);
        apply_extra("wind_stress_curl", "cell_wind_stress_curl", physics->wind_stress_curl);
        apply_extra("ocean_thermal_anomaly", "cell_ocean_thermal_anomaly", physics->ocean_thermal_anomaly);
        _phys_slp_buf = physics->slp;
        _phys_monsoon_thermal = physics->monsoon_thermal;
        // traj 是派生缓存，使用本次提交风场重建，绝不携带 worker 裸指针。
        const auto env = _runtime_host->environment_snapshot();
        _phys_wind_traj_valid = false;
        if (env && env->cell_pos_x.size() == size_t(cell_count) && env->cell_pos_y.size() == size_t(cell_count) &&
            env->neighbor_indices.size() == size_t(cell_count) * 6 && env->generation == snapshot.input_generation &&
            physics->wind_traj_generation > 0) {
            const auto &k = env->climate_physics_knobs;
            _phys_build_wind_traj(cell_count, env->cell_pos_x.data(), env->cell_pos_y.data(),
                env->neighbor_indices.data(), physics->wind_x.data(), physics->wind_y.data(), physics->wind_speed.data(),
                k.wrap_period_x, k.wind_traj_pos_scale, k.wind_traj_dt_days);
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
    _runtime_host->release_climate_writeback(slot);

    flush_slots_to_map_keys(touched_slots);
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

Dictionary DCWorldExt::compute_runtime_climate_parity_hash(
        const Dictionary &fields) {
    Dictionary out;
    RuntimeClimateStore store;
    String error;
    Array missing;
    if (!build_climate_store_from_fields(fields, store, error, &missing)) {
        out["ok"] = false;
        // 缺字段与"字段有问题"是两种不同的 code：前者调用方能直接读出缺哪几条，
        // 后者要看 field 里的 name(dtype|size)。
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["cell_count"] = static_cast<int64_t>(store.cell_count);
    // 用与 worker 完全相同的那一个归约函数。两侧"按约定各算一遍"是这条对拍最早的
    // 失效方式，所以这里刻意不复制哈希逻辑。
    out["parity_hash"] =
        static_cast<int64_t>(runtime_climate_parity_hash(store));
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["fields_hashed"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    return out;
}

Dictionary DCWorldExt::publish_runtime_climate_reference_state(
        int64_t day, const Dictionary &fields) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (day < 0) {
        out["ok"] = false;
        out["code"] = "climate_trace_reference_invalid";
        return out;
    }
    auto store = std::make_shared<RuntimeClimateStore>();
    String error;
    Array missing;
    if (!build_climate_store_from_fields(fields, *store, error, &missing)) {
        out["ok"] = false;
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
        return out;
    }
    // 哈希在这里从 state 派生，所以两者不可能互相矛盾 —— 这正是这个绑定存在的理由
    // （另一个只收哈希的版本做不到按字段/格子定位分叉）。
    const uint64_t state_hash = runtime_climate_parity_hash(*store);

    RuntimeClimateReferencePublish publish;
    publish.reference_store = store;
    publish.round_input = _production_round_input;
    publish.round_ran = static_cast<bool>(_production_round_input);
    publish.round_scalars = &_production_round_scalars;
    publish.round_scalar_mask = _production_round_scalar_mask;
    publish.pass_b = _production_pass_b;
    publish.sea_ice = _production_sea_ice;
    publish.wind_surface = _production_wind_surface;
    publish.ocean_water = _production_ocean_water;
    publish.wind_air = _production_wind_air;
    publish.albedo = _production_albedo;
    publish.vegetation = _production_vegetation;
    publish.feedback = _production_feedback;
    publish.weather = _production_weather;
    publish.hydrology = _production_hydrology;
    publish.weather_distribute = _production_weather_distribute;
    publish.production_stage_mask = _production_stage_mask;
    publish.seasonal_feedback_ran = _production_seasonal_feedback_ran;
    publish.seasonal_feedback_decay = _production_seasonal_feedback_decay;
    publish.season_refresh_ran = _production_season_refresh_ran;

    std::string host_error;
    const bool ok = _runtime_host->publish_climate_reference(
        day, state_hash, host_error, publish);

    // 节拍诊断：配错一天会表现成"算法分叉"，所以前若干天照实把 round_ran 与 stage
    // mask 打出来。这比从分叉矩阵反推直接得多。
    if (_publish_cadence_reports_left > 0) {
        --_publish_cadence_reports_left;
        UtilityFunctions::print(vformat(
            "[climate][publish] day=%d round_ran=%d prod_stage=0x%x "
            "scalar_mask=0x%x alb=%d veg=%d fb=%d weather=%d sr=%d ok=%d",
            static_cast<int64_t>(day), publish.round_ran ? 1 : 0,
            publish.production_stage_mask, publish.round_scalar_mask,
            publish.albedo.ran ? 1 : 0,
            static_cast<bool>(publish.vegetation) ? 1 : 0,
            static_cast<bool>(publish.feedback) ? 1 : 0,
            static_cast<bool>(publish.weather) ? 1 : 0,
            publish.season_refresh_ran ? 1 : 0, ok ? 1 : 0));
    }

    // 全部 per-day 记录在这里复位。少了这一步，"生产这一天没跑某个 stage"会继承上
    // 一天的记录，而那正是这些字段用来区分的两种情况之一。
    _last_published_climate_reference = store;
    _production_round_input.reset();
    _production_round_scalar_mask = 0;
    _production_pass_b.reset();
    _production_sea_ice.reset();
    _production_wind_surface.reset();
    _production_ocean_water.reset();
    _production_wind_air.reset();
    _production_albedo = pk_async_climate::ClimateAlbedoKnobs{};
    _production_vegetation.reset();
    _production_feedback.reset();
    _production_weather.reset();
    _production_hydrology.reset();
    _production_weather_distribute.reset();
    _production_stage_mask = 0;
    _production_seasonal_feedback_ran = false;
    _production_seasonal_feedback_decay = 1.0f;
    _production_season_refresh_ran = false;

    if (!ok) {
        out["ok"] = false;
        out["code"] = String(host_error.c_str());
        out["day"] = day;
        out["parity_hash"] = static_cast<int64_t>(state_hash);
        return out;
    }
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    out["day"] = day;
    // 键名是 parity_hash：调用方（map_generator.gd:2548）按它取值，取到 0 会判成
    // "归约什么都没算出来"并把这一天整个作废。
    out["parity_hash"] = static_cast<int64_t>(state_hash);
    out["cell_count"] = static_cast<int64_t>(store->cell_count);
    return out;
}

Array DCWorldExt::get_runtime_climate_parity_divergence() const {
    Array out;
    if (!_runtime_host) return out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const auto st = _runtime_host->climate_parity_field_status(i);
        // 没比过的字段也要出现在表里：缺行和"零分叉"是两件事，而分叉矩阵是用来
        // 排迁移顺序的，一行的缺席会被读成"这个 stage 已经对齐了"。
        Dictionary row;
        row["name"] = String(table[i].name);
        row["stage"] = static_cast<int>(table[i].stage);
        row["stage_name"] = String(runtime_climate_stage_name(table[i].stage));
        // 与 get_runtime_climate_parity_fields 同一口径：字符串而不是枚举序号。
        row["tolerance"] = String(pk_parity_tolerance_name(table[i].tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(table[i].tolerance);
        row["comparability"] =
            String(pk_parity_comparability_name(table[i].comparability));
        row["compared_days"] = static_cast<int64_t>(st.compared_days);
        row["diverged_days"] = static_cast<int64_t>(st.diverged_days);
        row["diverged_cells"] = static_cast<int64_t>(st.diverged_cells);
        row["out_of_band_days"] = static_cast<int64_t>(st.out_of_band_days);
        row["out_of_band_cells"] = static_cast<int64_t>(st.out_of_band_cells);
        row["first_diverged_day"] = st.first_diverged_day;
        row["first_out_of_band_day"] = st.first_out_of_band_day;
        row["first_cell"] = static_cast<int64_t>(st.first_cell);
        row["last_diverged_cells"] =
            static_cast<int64_t>(st.last_diverged_cells);
        row["last_out_of_band_cells"] =
            static_cast<int64_t>(st.last_out_of_band_cells);
        row["max_abs_delta"] = st.max_abs_delta;
        row["max_out_of_band_delta"] = st.max_out_of_band_delta;
        row["first_reference_bits"] = String(st.first_reference_bits);
        row["first_worker_bits"] = String(st.first_worker_bits);
        out.push_back(row);
    }
    return out;
}

} // namespace pk
