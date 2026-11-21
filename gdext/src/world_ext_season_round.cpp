#include "world_ext.h"
#include "world_ext_internal.h"
#include "world_ext_season_stage.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <memory>

namespace pk {

using namespace godot;

namespace {

struct SeasonRoundData : SeasonRoundState {
    void clear_inputs() {
        input_knobs = Dictionary();
        soil_moisture_arr.clear();
        veg_growth_pressure_arr.clear();
    }
};

} // namespace

void destroy_season_round_state(void *state) {
    delete static_cast<SeasonRoundData *>(state);
}

int season_kernel_stage(int round_stage) {
    switch (round_stage) {
        case 0:  return 0;
        case 1:  return 1;
        case 2:  return 2;
        case 3:  return 3;
        case 4:  return 4;
        case 5:  return 5;
        case 6:  return 6;
        case 7:  return 7;
        case 8:  return 9;   // swamp
        case 9:  return 8;   // sync
        case 10: return -1;  // atlas: SKIP（GDScript 处理）
        case 11: return 10;  // feedback decay
        default: return -1;
    }
}

godot::Dictionary DCWorldExt::start_season_round(godot::Dictionary round_knobs) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["handle"] = -1;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] start_season_round: ", why,
                                       " - fallback to GDScript 12-stage path");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!round_knobs.has("n_cells")) return fail("missing required knob: n_cells");
    const int n_cells = int(round_knobs["n_cells"]);
    if (n_cells <= 0) return fail("n_cells <= 0");

    // 已存在活跃 round：先 abort 旧的，避免泄漏（fast-restart 容错）。
    // generation 单调递增保证：把旧 generation +=1 后赋给新 SeasonRoundData，
    // 让悬挂的旧 handle 自然失效。
    int next_generation = 1;
    if (_season_round != nullptr) {
        SeasonRoundData *old = static_cast<SeasonRoundData *>(_season_round);
        if (old->active) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] start_season_round: previous round still active "
                "(generation=", old->generation, ", round_stage=", old->round_stage,
                ") - aborting and starting fresh");
        }
        next_generation = old->generation == std::numeric_limits<int>::max()
            ? 1 : old->generation + 1;
    }

    auto st = std::make_unique<SeasonRoundData>();
    st->generation       = next_generation;
    st->active           = true;
    st->round_stage      = 0;
    st->stages_done      = 0;
    st->slices_used      = 0;
    st->total_native_ms  = 0.0;
    st->input_knobs      = round_knobs;  // 浅拷贝；PackedArray CoW 共享
    // 缓存 in/out PackedFloat32Array（stage 11 需要）
    if (round_knobs.has("soil_moisture_arr")) {
        st->soil_moisture_arr = round_knobs["soil_moisture_arr"];
    }
    if (round_knobs.has("veg_growth_pressure_arr")) {
        st->veg_growth_pressure_arr = round_knobs["veg_growth_pressure_arr"];
    }
    out["handle"] = st->generation;
    out["fallback"] = false;
    destroy_season_round_state(_season_round);
    _season_round = st.release();
    return out;
}

godot::Dictionary DCWorldExt::run_season_round_slice(int handle, int max_usec) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["done"] = false;
    out["stage"] = -1;
    out["stages_done"] = 0;
    out["stages_done_this_slice"] = 0;
    out["elapsed_ms"] = 0.0;
    out["fallback"] = true;
    out["reason"] = String();

    SeasonRoundData *st = _season_round != nullptr
        ? static_cast<SeasonRoundData *>(_season_round)
        : nullptr;
    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        out["stages_done"] = st != nullptr ? st->stages_done : 0;
        return out;
    };

    if (!_bound) return fail("not bound");
    if (st == nullptr) return fail("no active round (call start_season_round first)");
    if (!st->active) return fail("round inactive");
    if (handle != st->generation) return fail("stale handle (generation mismatch)");


    if (max_usec <= 0) max_usec = 550;  // 默认 SUS slice budget
    // 用 steady_clock 算 deadline，与文件其余 perf 计时保持一致，避免引入
    // godot-cpp <classes/os.hpp> 依赖（OS::get_singleton 在本 TU 未 include）。
    auto t_slice0 = std::chrono::steady_clock::now();
    const auto t_deadline = t_slice0 + std::chrono::microseconds(int64_t(max_usec));
    int stages_done_this_slice = 0;
    String last_stage_reason;

    // b1 粒度：每 stage 边界查一次 deadline；不在 stage 内 cursor 切片
    while (st->round_stage < 12) {
        const int round_stage = st->round_stage;
        const int cpp_stage = season_kernel_stage(round_stage);

        if (cpp_stage < 0) {
            // SKIP（atlas_queue / unknown）：直接前进
            st->round_stage += 1;
            st->stages_done += 1;
            stages_done_this_slice += 1;
            continue;
        }

        // 浅拷贝 input_knobs + 改写 stage 字段；不污染 round 级 input_knobs
        Dictionary stage_knobs = st->input_knobs.duplicate(false);
        stage_knobs["stage"] = cpp_stage;
        // stage 11 (=cpp 10) 是 in/out array；C++ stage 10 内会 ptrw 写回，
        // 我们持有的 st->soil_moisture_arr 也会同步看到新值（CoW 引用共享）。
        if (round_stage == 11) {
            stage_knobs["soil_moisture_arr"] = st->soil_moisture_arr;
            stage_knobs["veg_growth_pressure_arr"] = st->veg_growth_pressure_arr;
        }

        Dictionary stage_res = run_season_refresh_stage(stage_knobs);
        const bool stage_fb = bool(stage_res.get("fallback", true));
        const double stage_ms = double(stage_res.get("elapsed_ms", -1.0));
        if (stage_fb || stage_ms < 0.0) {
            // 单 stage fallback：整个 round 标记 fallback，由 GDScript 端
            // abort 后走 12-stage 兜底路径。不在 C++ 内自动 retry。
            last_stage_reason = String(stage_res.get("reason", "stage_fallback"));
            out["stage"] = round_stage;
            out["stages_done"] = st->stages_done;
            out["stages_done_this_slice"] = stages_done_this_slice;
            out["fallback"] = true;
            out["reason"] = String("round_stage_") + String::num_int64(round_stage)
                          + String(": ") + last_stage_reason;
            // 注意：不在这里 abort/清空 _season_round，让 caller 看到具体
            // round_stage 后调 abort_season_round 显式清理。
            auto t_slice1 = std::chrono::steady_clock::now();
            out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
                                    t_slice1 - t_slice0).count();
            return out;
        }

        // stage 11 写回（C++ 端在 stage 10 内通过 knobs["soil_moisture_arr"] = soil_arr;
        // 把 decayed 值写回 stage_knobs，但我们持有的 st->soil_moisture_arr 是
        // 旧 ref——重新拉回来）
        if (round_stage == 11) {
            if (stage_knobs.has("soil_moisture_arr")) {
                st->soil_moisture_arr = stage_knobs["soil_moisture_arr"];
            }
            if (stage_knobs.has("veg_growth_pressure_arr")) {
                st->veg_growth_pressure_arr = stage_knobs["veg_growth_pressure_arr"];
            }
        }

        st->total_native_ms += stage_ms;
        st->round_stage += 1;
        st->stages_done += 1;
        stages_done_this_slice += 1;

        // stage 边界查 deadline（b1 粒度）
        if (std::chrono::steady_clock::now() >= t_deadline) {
            break;
        }
    }

    st->slices_used += 1;
    auto t_slice1 = std::chrono::steady_clock::now();
    const double slice_ms = std::chrono::duration<double, std::milli>(
                                t_slice1 - t_slice0).count();
    const bool round_done = st->round_stage >= 12;

    out["done"] = round_done;
    out["stage"] = st->round_stage;
    // Keep the round-level contract aligned with the GDScript facade.  The
    // stage cursor is monotonic and represents the total number of completed
    // round stages, including skipped stages; callers use it to advance their
    // own state machine when a fast map finishes all stages in one slice.
    out["stages_done"] = st->stages_done;
    out["stages_done_this_slice"] = stages_done_this_slice;
    out["elapsed_ms"] = slice_ms;
    out["fallback"] = false;
    out["reason"] = String();
    return out;
}

godot::Dictionary DCWorldExt::finish_season_round(int handle) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["total_native_ms"] = 0.0;
    out["slices_used"] = 0;
    out["stages_done"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        // The caller must be able to distinguish a genuinely empty round
        // from a failed finish after some stages already completed.  Keep the
        // same monotonic progress contract as run_season_round_slice().
        SeasonRoundData *st = _season_round != nullptr
            ? static_cast<SeasonRoundData *>(_season_round)
            : nullptr;
        out["stages_done"] = st != nullptr ? st->stages_done : 0;
        return out;
    };

    if (_season_round == nullptr) return fail("no active round");
    SeasonRoundData *st = static_cast<SeasonRoundData *>(_season_round);
    if (handle != st->generation) return fail("stale handle (generation mismatch)");
    if (!st->active) return fail("round inactive");

    out["total_native_ms"] = st->total_native_ms;
    out["slices_used"] = st->slices_used;
    out["stages_done"] = st->stages_done;
    // 把 stage 11 (feedback_decay) 的 decayed in/out array 回传给 GDScript caller
    out["soil_moisture_arr"] = st->soil_moisture_arr;
    out["veg_growth_pressure_arr"] = st->veg_growth_pressure_arr;
    out["fallback"] = false;
    out["reason"] = String();

    st->active = false;
    st->clear_inputs();
    return out;
}

void DCWorldExt::abort_season_round() {
    if (_season_round == nullptr) return;
    SeasonRoundData *st = static_cast<SeasonRoundData *>(_season_round);
    st->active = false;
    // The math owns raw views into this candidate until it publishes ready.
    st->clear_inputs();
}


} // namespace pk
