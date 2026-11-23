#include "world_ext.h"
#include "world_ext_internal.h"
#include "runtime_climate_passes.h"
#include "runtime_climate_pass_math.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <vector>

namespace pk {

using namespace godot;

// ─── plan/weather-refresh-cpp-all: cyclone wake step ─────────────────────
//
// 1:1 移植 scripts/weather/front_advect.gd::tick_cyclone_wake。维护
// _cyclone_perturbations（跨 tick 存活）。
//
// 算法（与 GDScript 严格 bit-equal）：
//   1) 衰减/淘汰：每个 entry days_left -= 1，<=0 删除；否则
//      vec = vec_init * float(days_left) / float(max(init_days, 1))
//   2) 注入：遍历 fronts_from_summary（Array[Dictionary]），仅
//      type == STORM (knobs["cyclone_storm_type_id"]) && intensity >= 0.8,
//      warm water + active precip/cloud + convective/convergence forcing
//      且中心 cell 是水面（is_water_lut[terrain]）时注入：
//        wind = velocity；若 length_sq < 1e-4 则 wind = (1,0)
//        tangent = (-wind.y, wind.x).normalized()
//        perturb = tangent * intensity * 0.6
//        key = cell.q * 10000 + cell.r
//      若同 key 已存在则覆盖（与 GDScript Dictionary 同语义）。
//
// 知识库笔记（front_advect.gd 注释）：扰动 key 必须用 q*10000+r，不是
// summary_qr_to_idx 的 (q<<32)^r 编码，否则 GDScript 镜像 bit-not-equal。
void DCWorldExt::_advance_and_stamp_cyclones(
        const Dictionary &knobs, int n_cells, const int32_t *neighbors,
        const Vector2 *positions, const uint8_t *terrain, const float *temp,
        const float *wind_x, const float *wind_y, const float *wind_speed,
        const float *vapor, const float *instability,
        const float *lat_norm) {
    const bool enabled = bool(knobs.get("native_tropical_cyclone_enabled",
        _native_runtime_config.get("native_tropical_cyclone_enabled", false)));
    if (!enabled || n_cells <= 0 || neighbors == nullptr || positions == nullptr ||
        terrain == nullptr || temp == nullptr || wind_x == nullptr || wind_y == nullptr ||
        wind_speed == nullptr || vapor == nullptr || instability == nullptr) return;
    if (_cyclone_force_tag.size() != static_cast<size_t>(n_cells)) {
        _cyclone_force_tag.assign(static_cast<size_t>(n_cells), 0u);
        _cyclone_visit_tag.assign(static_cast<size_t>(n_cells), 0u);
        _cyclone_force_x.assign(static_cast<size_t>(n_cells), 0.0f);
        _cyclone_force_y.assign(static_cast<size_t>(n_cells), 0.0f);
        _cyclone_force_lift.assign(static_cast<size_t>(n_cells), 0.0f);
    }
    if (++_cyclone_force_generation == 0u) {
        std::fill(_cyclone_force_tag.begin(), _cyclone_force_tag.end(), 0u);
        std::fill(_cyclone_visit_tag.begin(), _cyclone_visit_tag.end(), 0u);
        _cyclone_force_generation = 1u;
    }
    _cyclone_last_touched_cells = 0;
    const float dt_total = dc_clampf(float(knobs.get("weather_transition_dt_days", 1.0)), 0.0f, 30.0f);
    const int steps = std::max(1, int(std::ceil(dt_total)));
    const float dt = dt_total / float(steps);
    const float wb_y = float(knobs.get("world_bounds_pos_y", 0.0));
    const float wb_h = std::max(0.001f, float(knobs.get("world_bounds_size_y", 1.0)));
    const float wrap_x = std::max(0.0f, float(knobs.get("weather_wrap_width_x", 0.0)));
    const int max_radius = std::clamp(int(knobs.get("tropical_cyclone_max_radius_cells",
        _native_runtime_config.get("tropical_cyclone_max_radius_cells", 5))), 2, 6);
    for (CycloneWakeEntry &e : _cyclone_perturbations) {
        for (int step = 0; step < steps; ++step) {
            const int i = e.cell_idx;
            if (i < 0 || i >= n_cells) { e.intensity = 0.0f; break; }
            const float ny = dc_clampf((positions[i].y - wb_y) / wb_h, 0.0f, 1.0f);
            const float signed_lat = (ny - 0.5f) * 2.0f;
            float shear = 0.0f;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0) continue;
                const float dx = wind_x[ni] - wind_x[i], dy = wind_y[ni] - wind_y[i];
                shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
            }
            const bool on_water = wf_is_water_terrain(terrain[i]);
            const float inward = wf_cyclone_inward_wind(i, neighbors, wind_x, wind_y, wind_speed,
                [&](int from, int to, float &dx, float &dy) {
                    wf_wrapped_delta(positions[from].x, positions[from].y,
                        positions[to].x, positions[to].y, wrap_x, dx, dy);
                });
            const float potential = wf_smoothstep(0.54f, 0.76f, temp[i])
                * wf_smoothstep(0.42f, 0.72f, vapor[i])
                * (0.35f + 0.65f * std::max(instability[i], inward))
                * (1.0f - dc_clampf(shear, 0.0f, 1.0f)) * (on_water ? 1.0f : 0.15f);
            e.intensity += (potential - e.intensity) * (on_water ? 0.16f : 0.38f) * dt;
            if (temp[i] < 0.50f) e.intensity -= (0.50f - temp[i]) * 0.35f * dt;
            e.intensity = dc_clampf(e.intensity, 0.0f, 1.0f);
            e.age_days += dt;
            Vector2 guide(wind_x[i] - 0.12f * std::abs(signed_lat), wind_y[i]);
            if (guide.length_squared() > 1e-5f) guide = guide.normalized();
            else guide = e.steering.length_squared() > 1e-5f ? e.steering.normalized() : Vector2(-1.0f, 0.0f);
            e.steering = e.steering.lerp(guide, 0.35f).normalized();
            e.move_progress += dt * (0.25f + dc_clampf(wind_speed[i], 0.0f, 1.5f) * 0.35f);
            if (e.move_progress >= 1.0f) {
                int best = -1; float best_dot = 0.10f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = neighbors[i * 6 + d]; if (ni < 0) continue;
                    float dx = positions[ni].x - positions[i].x;
                    if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
                    const float dy = positions[ni].y - positions[i].y;
                    const float len2 = dx * dx + dy * dy; if (len2 <= 1e-6f) continue;
                    const float dot = (dx * e.steering.x + dy * e.steering.y) / std::sqrt(len2);
                    if (dot > best_dot) { best_dot = dot; best = ni; }
                }
                if (best >= 0) e.cell_idx = best;
                e.move_progress -= 1.0f;
            }
        }
        e.radius_cells = dc_clampf(2.0f + e.intensity * float(max_radius - 2), 2.0f, float(max_radius));
        e.days_left = std::max(0, int(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
    }
    const size_t before = _cyclone_perturbations.size();
    _cyclone_perturbations.erase(std::remove_if(_cyclone_perturbations.begin(), _cyclone_perturbations.end(),
        [](const CycloneWakeEntry &e) { return e.intensity < 0.075f || e.age_days > 32.0f; }),
        _cyclone_perturbations.end());
    _cyclone_total_decay += int(before - _cyclone_perturbations.size());
    std::vector<int32_t> queue;
    std::vector<int8_t> distance;
    queue.reserve(256); distance.reserve(256);
    uint32_t visit_generation = _cyclone_force_generation;
    for (const CycloneWakeEntry &e : _cyclone_perturbations) {
        if (e.cell_idx < 0 || e.cell_idx >= n_cells) continue;
        if (++visit_generation == 0u) { std::fill(_cyclone_visit_tag.begin(), _cyclone_visit_tag.end(), 0u); visit_generation = 1u; }
        queue.clear(); distance.clear(); queue.push_back(e.cell_idx); distance.push_back(0);
        _cyclone_visit_tag[static_cast<size_t>(e.cell_idx)] = visit_generation;
        const int radius = std::clamp(int(std::ceil(e.radius_cells)), 2, max_radius);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int i = queue[head], dist = int(distance[head]);
            const float falloff = 1.0f - float(dist) / float(radius + 1);
            if (_cyclone_force_tag[static_cast<size_t>(i)] != _cyclone_force_generation) {
                _cyclone_force_tag[static_cast<size_t>(i)] = _cyclone_force_generation;
                _cyclone_force_x[static_cast<size_t>(i)] = 0.0f;
                _cyclone_force_y[static_cast<size_t>(i)] = 0.0f;
                _cyclone_force_lift[static_cast<size_t>(i)] = 0.0f;
                ++_cyclone_last_touched_cells;
            }
            float dx = positions[i].x - positions[e.cell_idx].x;
            if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
            const float dy = positions[i].y - positions[e.cell_idx].y;
            Vector2 tangent;
            if (dx * dx + dy * dy > 1e-6f) {
                const float ny = dc_clampf((positions[e.cell_idx].y - wb_y) / wb_h, 0.0f, 1.0f);
                const float hemi = ny < 0.5f ? 1.0f : -1.0f;
                tangent = Vector2(-dy * hemi, dx * hemi).normalized();
            } else tangent = Vector2(-e.steering.y, e.steering.x);
            const float force = e.intensity * falloff * 0.62f;
            _cyclone_force_x[static_cast<size_t>(i)] += tangent.x * force;
            _cyclone_force_y[static_cast<size_t>(i)] += tangent.y * force;
            _cyclone_force_lift[static_cast<size_t>(i)] = std::max(_cyclone_force_lift[static_cast<size_t>(i)], e.intensity * falloff);
            if (dist >= radius) continue;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0 || _cyclone_visit_tag[static_cast<size_t>(ni)] == visit_generation) continue;
                _cyclone_visit_tag[static_cast<size_t>(ni)] = visit_generation;
                queue.push_back(ni); distance.push_back(int8_t(dist + 1));
            }
        }
    }
    for (CycloneWakeEntry &e : _cyclone_perturbations) { e.vec = e.steering * e.intensity; e.vec_init = e.vec; }
    (void)lat_norm;
}

double DCWorldExt::cyclone_wake_step(Dictionary &knobs,
                                     const Array &fronts_from_summary) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase B.2 细粒度遥测计数 ────────────────────────────────────────
    int n_decayed  = 0;  // Phase 1 衰减后仍活
    int n_evicted  = 0;  // Phase 1 淘汰
    int n_replaced = 0;  // Phase 2 覆盖已有 key
    int n_injected = 0;  // Phase 2 新增 entry
    double phase1_ms = 0.0;
    double phase2_ms = 0.0;

    // helper: 早期 return 前统一写回遥测字段，确保 caller 总能拿到完整 6 字段。
    auto write_back_stats = [&]() {
        knobs["cyclone_phase1_decay_ms"]  = phase1_ms;
        knobs["cyclone_phase2_inject_ms"] = phase2_ms;
        knobs["cyclone_n_decayed"]  = n_decayed;
        knobs["cyclone_n_evicted"]  = n_evicted;
        knobs["cyclone_n_replaced"] = n_replaced;
        knobs["cyclone_n_injected"] = n_injected;
    };

    // ─── knobs ──────────────────────────────────────────────────────────
    if (!knobs.has("hex_size") || !knobs.has("cyclone_wake_days") ||
        !knobs.has("cyclone_storm_type_id") || !knobs.has("water_terrain_ids") ||
        !knobs.has("cell_q_arr") || !knobs.has("cell_r_arr") ||
        !knobs.has("n_cells")) {
        // 缺 key 则只做衰减/淘汰（不注入），保持 best-effort
        // 但发出一次 warning 便于排查
        UtilityFunctions::push_warning(
            "[DCWorldExt] cyclone_wake_step: missing knob (need hex_size/"
            "cyclone_wake_days/cyclone_storm_type_id/water_terrain_ids/"
            "cell_q_arr/cell_r_arr/n_cells)");
    }
    const float hex_size = float(knobs.get("hex_size", 1.0f));
    const int cyclone_wake_days = int(knobs.get("cyclone_wake_days", 7));
    const int storm_type_id = int(knobs.get("cyclone_storm_type_id", -1));
    const int n_cells = int(knobs.get("n_cells", 0));
    const bool native_entity_enabled = bool(knobs.get("native_tropical_cyclone_enabled",
        _native_runtime_config.get("native_tropical_cyclone_enabled", false)));
    const int cyclone_capacity = std::clamp(int(knobs.get("tropical_cyclone_capacity",
        _native_runtime_config.get("tropical_cyclone_capacity", 24))), 1, 64);
    const int births_per_commit = std::clamp(int(knobs.get("tropical_cyclone_births_per_commit",
        _native_runtime_config.get("tropical_cyclone_births_per_commit", 2))), 1, 4);
    const float min_temp = dc_clampf(float(knobs.get("tropical_cyclone_min_temp",
        _native_runtime_config.get("tropical_cyclone_min_temp", 0.58))), 0.0f, 1.0f);
    const float min_instability = dc_clampf(float(knobs.get("tropical_cyclone_min_instability",
        _native_runtime_config.get("tropical_cyclone_min_instability", 0.40))), 0.0f, 1.0f);
    const float max_shear = dc_clampf(float(knobs.get("tropical_cyclone_max_shear",
        _native_runtime_config.get("tropical_cyclone_max_shear", 0.42))), 0.0f, 1.0f);
    const float min_lat = dc_clampf(float(knobs.get("tropical_cyclone_min_lat",
        _native_runtime_config.get("tropical_cyclone_min_lat", 0.06))), 0.0f, 1.0f);
    const float max_lat = dc_clampf(float(knobs.get("tropical_cyclone_max_lat",
        _native_runtime_config.get("tropical_cyclone_max_lat", 0.40))), min_lat, 1.0f);
    const float wb_y = float(knobs.get("world_bounds_pos_y", 0.0));
    const float wb_h = std::max(0.001f, float(knobs.get("world_bounds_size_y", 1.0)));
    PackedByteArray  water_ids = knobs.get("water_terrain_ids", PackedByteArray());
    PackedInt32Array cell_q    = knobs.get("cell_q_arr", PackedInt32Array());
    PackedInt32Array cell_r    = knobs.get("cell_r_arr", PackedInt32Array());
    PackedInt32Array neighbor_idx = knobs.get("neighbor_indices", PackedInt32Array());

    // ─── Phase 1: 衰减 / 淘汰 ───────────────────────────────────────────
    // 等价 GDScript: days_left -= 1；<=0 删除；否则 vec = vec_init * days_left/init_days
    if (!native_entity_enabled) {
        auto t_p1_0 = std::chrono::high_resolution_clock::now();
        size_t write = 0;
        for (size_t read = 0; read < _cyclone_perturbations.size(); ++read) {
            CycloneWakeEntry &e = _cyclone_perturbations[read];
            const int new_days = e.days_left - 1;
            if (new_days <= 0) {
                ++n_evicted;
                continue; // 淘汰
            }
            e.days_left = new_days;
            const int denom = std::max(e.init_days, 1);
            const float scale = float(new_days) / float(denom);
            e.vec = e.vec_init * scale;
            if (write != read) {
                _cyclone_perturbations[write] = e;
            }
            ++write;
            ++n_decayed;
        }
        _cyclone_perturbations.resize(write);
        auto t_p1_1 = std::chrono::high_resolution_clock::now();
        phase1_ms = std::chrono::duration<double, std::milli>(t_p1_1 - t_p1_0).count();
    }

    // ─── Phase 2: 注入 ──────────────────────────────────────────────────
    // 前置：需要 fronts 列表 + cell terrain SoA + q/r 反查 + water LUT。
    // 任一缺失则跳过注入（衰减/淘汰仍生效）。
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_w_inst = component_id(StringName("cell_weather_instability"));
    const int sid_w_precip = component_id(StringName("cell_weather_precip"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_wspd = component_id(StringName("cell_wind_speed"));
    const int sid_wx = component_id(StringName("cell_wind_x"));
    const int sid_wy = component_id(StringName("cell_wind_y"));
    if (sid_terrain < 0 || n_cells <= 0 || water_ids.size() <= 0 ||
        cell_q.size() < n_cells || cell_r.size() < n_cells ||
        storm_type_id < 0 || cyclone_wake_days <= 0 ||
        sid_temp < 0 || sid_w_inst < 0 || sid_w_precip < 0 ||
        sid_w_cloud < 0) {
        write_back_stats();
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_w_inst = _slots.write[sid_w_inst];
    Slot &s_w_precip = _slots.write[sid_w_precip];
    Slot &s_w_cloud = _slots.write[sid_w_cloud];
    Slot *s_wspd = sid_wspd >= 0 ? &_slots.write[sid_wspd] : nullptr;
    Slot *s_wx = sid_wx >= 0 ? &_slots.write[sid_wx] : nullptr;
    Slot *s_wy = sid_wy >= 0 ? &_slots.write[sid_wy] : nullptr;
    if (int(s_terrain.arr_u8.size()) < n_cells ||
        int(s_temp.arr_f32.size()) < n_cells ||
        int(s_w_inst.arr_f32.size()) < n_cells ||
        int(s_w_precip.arr_f32.size()) < n_cells ||
        int(s_w_cloud.arr_f32.size()) < n_cells) {
        write_back_stats();
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    const uint8_t * const TERR = s_terrain.arr_u8.ptr();
    const float * const T = s_temp.arr_f32.ptr();
    const float * const W_INST = s_w_inst.arr_f32.ptr();
    const float * const W_PRECIP = s_w_precip.arr_f32.ptr();
    const float * const W_CLOUD = s_w_cloud.arr_f32.ptr();
    const float * const WSPD = s_wspd != nullptr && s_wspd->arr_f32.size() >= n_cells
        ? s_wspd->arr_f32.ptr() : nullptr;
    const float * const WIND_X = s_wx != nullptr && s_wx->arr_f32.size() >= n_cells ? s_wx->arr_f32.ptr() : nullptr;
    const float * const WIND_Y = s_wy != nullptr && s_wy->arr_f32.size() >= n_cells ? s_wy->arr_f32.ptr() : nullptr;
    const int32_t * const NB_GEN = neighbor_idx.size() >= n_cells * 6 ? neighbor_idx.ptr() : nullptr;

    // is_water LUT（与 summary / sea_ice / wind 同模式）
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < water_ids.size(); ++k) {
        const int wid = int(water_ids[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    // 复用 _summary_qr_to_idx（summary pass 已 lazy 填好）；若 size 不匹配
    // 则跳过注入（与 summary pass 同一防御）。
    const bool qr_idx_ready = (_summary_qr_to_idx_size == n_cells &&
                               !_summary_qr_to_idx.empty());

    // 与 summary pass 的 world_to_cube 严格 1:1（含 _cube_round）
    const double SQRT3 = 1.7320508075688772;
    auto world_to_qr = [&](Vector2 p, int &out_q, int &out_r) -> bool {
        if (hex_size <= 0.0f) return false;
        const double q_f = (SQRT3 / 3.0 * double(p.x) - 1.0 / 3.0 * double(p.y)) / double(hex_size);
        const double r_f = (2.0 / 3.0 * double(p.y)) / double(hex_size);
        const double s_f = -q_f - r_f;
        int rq = int(std::lround(q_f));
        int rr = int(std::lround(r_f));
        int rs = int(std::lround(s_f));
        const double dq = std::abs(double(rq) - q_f);
        const double dr = std::abs(double(rr) - r_f);
        const double ds = std::abs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        out_q = rq;
        out_r = rr;
        return true;
    };

    auto qr_to_cell_idx = [&](int q, int r) -> int {
        if (!qr_idx_ready) return -1;
        const int64_t key = (int64_t(q) << 32) ^ (uint32_t(r) & 0xFFFFFFFFu);
        auto it = _summary_qr_to_idx.find(key);
        return (it == _summary_qr_to_idx.end()) ? -1 : it->second;
    };

    // 注入遍历
    const int n_fronts = fronts_from_summary.size();
    {
        auto t_p2_0 = std::chrono::high_resolution_clock::now();
        for (int fi = 0; fi < n_fronts; ++fi) {
            if (native_entity_enabled && n_injected >= births_per_commit) break;
            const Dictionary f = fronts_from_summary[fi];
            const int ftype = int(f.get("type", -1));
            if (ftype != storm_type_id) continue;
            const float intensity = float(f.get("intensity", 0.0f));
            if (intensity < 0.8f) continue;
            const Vector2 center = f.get("center", Vector2());

            int q = 0, r = 0;
            if (!world_to_qr(center, q, r)) continue;
            const int idx = qr_to_cell_idx(q, r);
            if (idx < 0 || idx >= n_cells) continue;
            if (!is_water_lut[TERR[idx]]) continue;

            const float abs_lat = std::abs((center.y - wb_y) / wb_h * 2.0f - 1.0f);
            if (native_entity_enabled && (abs_lat < min_lat || abs_lat > max_lat)) continue;
            if (native_entity_enabled && WIND_X != nullptr && WIND_Y != nullptr && NB_GEN != nullptr) {
                float shear = 0.0f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB_GEN[idx * 6 + d];
                    if (ni < 0) continue;
                    const float dx = WIND_X[ni] - WIND_X[idx], dy = WIND_Y[ni] - WIND_Y[idx];
                    shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
                }
                if (shear > max_shear) continue;
            }

            Vector2 wind = f.get("velocity", Vector2());
            const float front_speed_norm = wind.length() / std::max(hex_size, 0.001f);
            if (T[idx] < (native_entity_enabled ? min_temp : 0.56f)) continue;
            if (W_PRECIP[idx] < 0.05f) continue;
            if (W_CLOUD[idx] < 0.22f) continue;
            if (W_INST[idx] < (native_entity_enabled ? min_instability : 0.48f)) {
                const float wrap_width_x = float(knobs.get("weather_wrap_width_x", 0.0f));
                const float inward = (WIND_X && WIND_Y && NB_GEN)
                    ? wf_cyclone_inward_wind(idx, NB_GEN, WIND_X, WIND_Y, WSPD,
                        [&](int from, int to, float &dx, float &dy) {
                            const float dr = float(cell_r[to] - cell_r[from]);
                            dx = float(SQRT3) * hex_size * (float(cell_q[to] - cell_q[from]) + dr * 0.5f);
                            if (wrap_width_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_width_x);
                            dy = hex_size * 1.5f * dr;
                        }) : 0.0f;
                if (inward < 0.30f) continue;
            }
            if (front_speed_norm < 0.16f && intensity < 0.82f) continue;
            if (wind.length_squared() < 1e-4f) {
                wind = Vector2(1.0f, 0.0f);
            }
            Vector2 tangent = Vector2(-wind.y, wind.x).normalized();
            const Vector2 perturb = tangent * intensity * 0.6f;

            const int64_t key_gd = int64_t(cell_q[idx]) * 10000LL + int64_t(cell_r[idx]);

            // 若 key 已存在则覆盖（与 GDScript Dictionary 赋值同语义）
            bool replaced = false;
            for (auto &e : _cyclone_perturbations) {
                if (e.key == key_gd) {
                    e.cell_idx  = idx;
                    e.vec       = perturb;
                    e.vec_init  = perturb;
                    e.days_left = cyclone_wake_days;
                    e.init_days = cyclone_wake_days;
                    if (native_entity_enabled) {
                        e.steering = wind.normalized();
                        e.intensity = std::max(e.intensity, intensity);
                        e.radius_cells = 2.0f + intensity * 3.0f;
                    }
                    replaced = true;
                    break;
                }
            }
            if (replaced) {
                ++n_replaced;
            } else {
                if (native_entity_enabled && int(_cyclone_perturbations.size()) >= cyclone_capacity) continue;
                CycloneWakeEntry ne;
                ne.stable_id = _cyclone_next_stable_id++;
                ne.key       = key_gd;
                ne.cell_idx  = idx;
                ne.vec       = perturb;
                ne.vec_init  = perturb;
                ne.days_left = cyclone_wake_days;
                ne.init_days = cyclone_wake_days;
                if (native_entity_enabled) {
                    ne.steering = wind.normalized();
                    ne.intensity = intensity;
                    ne.radius_cells = 2.0f + intensity * 3.0f;
                    ne.age_days = 0.0f;
                    ne.move_progress = 0.0f;
                    ne.days_left = 32;
                    ne.init_days = 32;
                }
                _cyclone_perturbations.push_back(ne);
                ++n_injected;
                if (native_entity_enabled) ++_cyclone_total_genesis;
            }
        }
        auto t_p2_1 = std::chrono::high_resolution_clock::now();
        phase2_ms = std::chrono::duration<double, std::milli>(t_p2_1 - t_p2_0).count();
    }

    write_back_stats();
    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── plan/weather-refresh-cpp-all: cyclone perturbations 镜像导出 ────────
std::vector<uint8_t> DCWorldExt::runtime_cyclone_state_blob() const {
    // Vector2 → 标量是唯一的信息搬运；stable_id / key 原样保留，worker 沿用它做
    // 确定性身份，genesis 侧仍由主线程发号。
    std::vector<pk_async_climate::CycloneEntry> entries;
    entries.reserve(_cyclone_perturbations.size());
    for (const CycloneWakeEntry &src : _cyclone_perturbations) {
        pk_async_climate::CycloneEntry dst;
        dst.stable_id = src.stable_id;
        dst.key = src.key;
        dst.cell_idx = src.cell_idx;
        dst.steering_x = src.steering.x;
        dst.steering_y = src.steering.y;
        dst.vec_x = src.vec.x;
        dst.vec_y = src.vec.y;
        dst.vec_init_x = src.vec_init.x;
        dst.vec_init_y = src.vec_init.y;
        dst.intensity = src.intensity;
        dst.radius_cells = src.radius_cells;
        dst.age_days = src.age_days;
        dst.move_progress = src.move_progress;
        dst.days_left = src.days_left;
        dst.init_days = src.init_days;
        entries.push_back(dst);
    }
    return pk_async_climate::cyclone_state_encode(entries, _cyclone_next_stable_id);
}



} // namespace pk
