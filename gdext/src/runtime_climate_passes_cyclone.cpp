#include "runtime_climate_passes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace pk {
namespace pk_async_climate {

// ─── B8-2：tropical cyclone 推进 + stamp（生产/worker 共用）─────────────────
//
// 这份实现逐行来自 DCWorldExt::_advance_and_stamp_cyclones，只做两类等价改写：
//   1. godot::Vector2 → 标量对（steering_x/y、vec_x/y、vec_init_x/y、pos_x/pos_y）；
//   2. knobs Dictionary → CycloneAdvanceKnobs POD；条目表指向调用方的 vector。
// 没有改动任何公式、阈值、顺序或迭代步数 —— 任何"顺手优化"都会让它不再可对拍。
namespace {

void cyc_append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 8u) & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 16u) & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 24u) & 0xFFu));
}

void cyc_append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        out.push_back(static_cast<uint8_t>((value >> (8u * i)) & 0xFFu));
    }
}

void cyc_append_f32(std::vector<uint8_t> &out, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    cyc_append_u32(out, bits);
}

bool cyc_read_u32(const std::vector<uint8_t> &in, size_t &cursor, uint32_t &out) {
    if (cursor + 4u > in.size()) return false;
    out = static_cast<uint32_t>(in[cursor]) |
          (static_cast<uint32_t>(in[cursor + 1u]) << 8u) |
          (static_cast<uint32_t>(in[cursor + 2u]) << 16u) |
          (static_cast<uint32_t>(in[cursor + 3u]) << 24u);
    cursor += 4u;
    return true;
}

bool cyc_read_u64(const std::vector<uint8_t> &in, size_t &cursor, uint64_t &out) {
    if (cursor + 8u > in.size()) return false;
    out = 0;
    for (int i = 0; i < 8; ++i) {
        out |= static_cast<uint64_t>(in[cursor + static_cast<size_t>(i)]) << (8u * i);
    }
    cursor += 8u;
    return true;
}

bool cyc_read_f32(const std::vector<uint8_t> &in, size_t &cursor, float &out) {
    uint32_t bits = 0;
    if (!cyc_read_u32(in, cursor, bits)) return false;
    std::memcpy(&out, &bits, sizeof(out));
    return true;
}

void cyc_normalize(float &x, float &y) {
    const float len2 = x * x + y * y;
    if (len2 <= 1e-12f) {
        x = 0.0f;
        y = 0.0f;
        return;
    }
    const float inv = 1.0f / std::sqrt(len2);
    x *= inv;
    y *= inv;
}

} // namespace

void cyclone_genesis_pure(int n_cells,
                          const CycloneGenesisKnobs &knobs,
                          const CycloneGenesisLanes &lanes,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id,
                          CycloneGenesisStats &stats) {
    stats = CycloneGenesisStats{};
    stats.alive = static_cast<int32_t>(entries.size());
    if (!knobs.enabled || n_cells <= 0 || knobs.storm_type_id < 0) return;
    if (lanes.terrain == nullptr || lanes.water_lut == nullptr ||
        lanes.weather_type == nullptr || lanes.weather_intensity == nullptr ||
        lanes.temp == nullptr || lanes.precip == nullptr ||
        lanes.cloud == nullptr || lanes.instability == nullptr ||
        lanes.convergence == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.pos_y == nullptr ||
        lanes.neighbors == nullptr) {
        return;
    }
    const float wb_h = std::max(0.001f, knobs.world_bounds_size_y);
    const uint8_t storm_id = static_cast<uint8_t>(knobs.storm_type_id);
    for (int i = 0; i < n_cells; ++i) {
        const bool on_water = lanes.water_lut[lanes.terrain[i]] != 0u;
        if (!on_water) continue;
        if (lanes.is_water != nullptr && lanes.is_water[i] == 0u) continue;
        ++stats.cand_water;
        if (lanes.weather_intensity[i] > stats.max_intensity) {
            stats.max_intensity = lanes.weather_intensity[i];
        }
        const float ny = dc_clampf(
            (lanes.pos_y[i] - knobs.world_bounds_pos_y) / wb_h, 0.0f, 1.0f);
        const float abs_lat = (lanes.lat_norm != nullptr)
            ? std::abs((dc_clampf(lanes.lat_norm[i], 0.0f, 1.0f) - 0.5f) * 2.0f)
            : std::abs((ny - 0.5f) * 2.0f);
        if (abs_lat < knobs.min_lat || abs_lat > knobs.max_lat) continue;
        ++stats.cand_lat;
        if (lanes.weather_type[i] == storm_id) ++stats.type_storm;
        stats.max_precip = std::max(stats.max_precip, lanes.precip[i]);
        stats.max_cloud = std::max(stats.max_cloud, lanes.cloud[i]);
        stats.max_instability = std::max(stats.max_instability, lanes.instability[i]);
        stats.max_convergence = std::max(stats.max_convergence, lanes.convergence[i]);
        if (lanes.temp[i] < knobs.min_temp) { ++stats.fail_temp; continue; }
        if (lanes.precip[i] < knobs.precip_gate) { ++stats.fail_precip; continue; }
        if (lanes.cloud[i] < knobs.cloud_gate) { ++stats.fail_cloud; continue; }
        if (lanes.instability[i] < knobs.min_instability &&
            lanes.convergence[i] < 0.30f) {
            ++stats.fail_instability;
            continue;
        }
        ++stats.cand_physical;
        // 生产 genesis 的"前沿等价物"是 summary 段给出的 WeatherFront：type == STORM
        // 且 intensity ≥ 0.8。worker 里没有 front 对象，直接等价映射到 field solve
        // 写出的 intensity lane（front 的 intensity 本来就是从这个 lane 派生的），
        // 否则 type 只有在已有 cyclone stamp 之后才会变成 STORM —— 新气旋永远
        // 生不出来（闭锁）。require_storm_type 只用于 A/B 复现旧闭锁路径。
        if (knobs.require_storm_type && lanes.weather_type[i] != storm_id) {
            continue;
        }
        if (lanes.weather_intensity[i] < knobs.intensity_gate) continue;
        ++stats.cand_intensity;
        float shear = 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int ni = lanes.neighbors[i * 6 + d];
            if (ni < 0) continue;
            const float dx = lanes.wind_x[ni] - lanes.wind_x[i];
            const float dy = lanes.wind_y[ni] - lanes.wind_y[i];
            shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
        }
        if (shear > knobs.max_shear) continue;
        ++stats.cand_shear;
        float wind_x = lanes.wind_x[i];
        float wind_y = lanes.wind_y[i];
        if (wind_x * wind_x + wind_y * wind_y < 1e-4f) {
            wind_x = 1.0f;
            wind_y = 0.0f;
        }
        float tangent_x = -wind_y;
        float tangent_y = wind_x;
        cyc_normalize(tangent_x, tangent_y);
        const float perturb_scale = lanes.weather_intensity[i] * 0.6f;
        float steering_x = wind_x;
        float steering_y = wind_y;
        cyc_normalize(steering_x, steering_y);
        bool replaced = false;
        for (CycloneEntry &e : entries) {
            if (e.key != static_cast<int64_t>(i)) continue;
            e.cell_idx = i;
            e.vec_x = tangent_x * perturb_scale;
            e.vec_y = tangent_y * perturb_scale;
            e.vec_init_x = e.vec_x;
            e.vec_init_y = e.vec_y;
            e.steering_x = steering_x;
            e.steering_y = steering_y;
            e.intensity = std::max(e.intensity, lanes.weather_intensity[i]);
            e.radius_cells = 2.0f + lanes.weather_intensity[i] * 3.0f;
            e.days_left = static_cast<int32_t>(knobs.wake_days);
            e.init_days = static_cast<int32_t>(knobs.wake_days);
            replaced = true;
            break;
        }
        if (replaced) {
            ++stats.replaced;
            continue;
        }
        // 出生预算只约束"新条目"：刷新同一条已是气旋的前沿（replaced）不吃预算，
        // 否则 births_per_commit 会在已有条目上被白白耗尽、丢掉当天真实的新气旋。
        if (static_cast<int32_t>(entries.size()) >= knobs.capacity) break;
        if (stats.injected >= knobs.births_per_commit) break;
        CycloneEntry entry;
        entry.stable_id = next_stable_id++;
        entry.key = static_cast<int64_t>(i);
        entry.cell_idx = i;
        entry.steering_x = steering_x;
        entry.steering_y = steering_y;
        entry.vec_x = tangent_x * perturb_scale;
        entry.vec_y = tangent_y * perturb_scale;
        entry.vec_init_x = entry.vec_x;
        entry.vec_init_y = entry.vec_y;
        entry.intensity = lanes.weather_intensity[i];
        entry.radius_cells = 2.0f + lanes.weather_intensity[i] * 3.0f;
        entry.age_days = 0.0f;
        entry.move_progress = 0.0f;
        entry.days_left = static_cast<int32_t>(knobs.wake_days);
        entry.init_days = static_cast<int32_t>(knobs.wake_days);
        entries.push_back(entry);
        ++stats.injected;
    }
    stats.alive = static_cast<int32_t>(entries.size());
}

void cyclone_advance_and_stamp_pure(int n_cells,
                                    const CycloneAdvanceKnobs &knobs,
                                    const CycloneLanes &lanes,
                                    std::vector<CycloneEntry> &entries,
                                    CycloneStamp &stamp,
                                    CycloneStats &stats) {
    stats = CycloneStats{};
    for (const CycloneEntry &e : entries) {
        stats.entry_intensity_max_before =
            std::max(stats.entry_intensity_max_before, e.intensity);
    }
    if (!knobs.enabled || n_cells <= 0) return;
    if (lanes.neighbors == nullptr || lanes.pos_x == nullptr ||
        lanes.pos_y == nullptr || lanes.terrain == nullptr ||
        lanes.temp == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.vapor == nullptr || lanes.instability == nullptr ||
        lanes.convergence == nullptr) {
        return;
    }
    if (stamp.force_tag == nullptr || stamp.visit_tag == nullptr ||
        stamp.force_x == nullptr || stamp.force_y == nullptr ||
        stamp.lift == nullptr) {
        return;
    }
    const int32_t * const neighbors = lanes.neighbors;
    const float * const positions_x = lanes.pos_x;
    const float * const positions_y = lanes.pos_y;
    const uint8_t * const terrain = lanes.terrain;
    const float dt_total = dc_clampf(knobs.dt_days, 0.0f, 30.0f);
    const int steps = std::max(1, static_cast<int>(std::ceil(dt_total)));
    const float dt = dt_total / static_cast<float>(steps);
    const float wb_y = knobs.world_bounds_pos_y;
    const float wb_h = std::max(0.001f, knobs.world_bounds_size_y);
    const float wrap_x = std::max(0.0f, knobs.wrap_width_x);
    const int max_radius = std::clamp(knobs.max_radius_cells, 2, 6);

    for (CycloneEntry &e : entries) {
        for (int step = 0; step < steps; ++step) {
            const int i = e.cell_idx;
            if (i < 0 || i >= n_cells) { e.intensity = 0.0f; break; }
            const float ny = dc_clampf((positions_y[i] - wb_y) / wb_h, 0.0f, 1.0f);
            const float signed_lat = (lanes.lat_norm != nullptr)
                ? (dc_clampf(lanes.lat_norm[i], 0.0f, 1.0f) - 0.5f) * 2.0f
                : (ny - 0.5f) * 2.0f;
            float shear = 0.0f;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0) continue;
                const float dx = lanes.wind_x[ni] - lanes.wind_x[i];
                const float dy = lanes.wind_y[ni] - lanes.wind_y[i];
                shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
            }
            const bool on_water = wf_is_water_terrain(terrain[i]);
            const float potential = wf_smoothstep(0.54f, 0.76f, lanes.temp[i]) *
                wf_smoothstep(0.42f, 0.72f, lanes.vapor[i]) *
                (0.35f + 0.65f * std::max(lanes.instability[i], lanes.convergence[i])) *
                (1.0f - dc_clampf(shear, 0.0f, 1.0f)) * (on_water ? 1.0f : 0.15f);
            e.intensity += (potential - e.intensity) * (on_water ? 0.16f : 0.38f) * dt;
            if (lanes.temp[i] < 0.50f) {
                e.intensity -= (0.50f - lanes.temp[i]) * 0.35f * dt;
            }
            e.intensity = dc_clampf(e.intensity, 0.0f, 1.0f);
            e.age_days += dt;
            float guide_x = lanes.wind_x[i] - 0.12f * std::abs(signed_lat);
            float guide_y = lanes.wind_y[i];
            const float guide_len2 = guide_x * guide_x + guide_y * guide_y;
            if (guide_len2 > 1e-5f) {
                cyc_normalize(guide_x, guide_y);
            } else {
                const float steer_len2 = e.steering_x * e.steering_x +
                    e.steering_y * e.steering_y;
                if (steer_len2 > 1e-5f) {
                    cyc_normalize(e.steering_x, e.steering_y);
                    guide_x = e.steering_x;
                    guide_y = e.steering_y;
                } else {
                    guide_x = -1.0f;
                    guide_y = 0.0f;
                }
            }
            e.steering_x = e.steering_x + (guide_x - e.steering_x) * 0.35f;
            e.steering_y = e.steering_y + (guide_y - e.steering_y) * 0.35f;
            cyc_normalize(e.steering_x, e.steering_y);
            e.move_progress += dt *
                (0.25f + dc_clampf(lanes.wind_speed[i], 0.0f, 1.5f) * 0.35f);
            if (e.move_progress >= 1.0f) {
                int best = -1;
                float best_dot = 0.10f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = neighbors[i * 6 + d];
                    if (ni < 0) continue;
                    float dx = positions_x[ni] - positions_x[i];
                    if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
                    const float dy = positions_y[ni] - positions_y[i];
                    const float len2 = dx * dx + dy * dy;
                    if (len2 <= 1e-6f) continue;
                    const float dot = (dx * e.steering_x + dy * e.steering_y) /
                        std::sqrt(len2);
                    if (dot > best_dot) {
                        best_dot = dot;
                        best = ni;
                    }
                }
                if (best >= 0) e.cell_idx = best;
                e.move_progress -= 1.0f;
            }
        }
        e.radius_cells = dc_clampf(2.0f + e.intensity *
            static_cast<float>(max_radius - 2), 2.0f,
            static_cast<float>(max_radius));
        e.days_left = std::max(0, static_cast<int>(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
    }
    const size_t before = entries.size();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
        [](const CycloneEntry &e) {
            return e.intensity < 0.075f || e.age_days > 32.0f;
        }), entries.end());
    stats.decayed = static_cast<int32_t>(before - entries.size());
    stats.alive = static_cast<int32_t>(entries.size());
    for (const CycloneEntry &e : entries) {
        stats.entry_intensity_max_after =
            std::max(stats.entry_intensity_max_after, e.intensity);
    }

    for (const CycloneEntry &e : entries) {
        if (e.cell_idx < 0 || e.cell_idx >= n_cells) continue;
        stamp.visit_generation += 1u;
        if (stamp.visit_generation == 0u) {
            std::fill(stamp.visit_tag, stamp.visit_tag + n_cells, 0u);
            stamp.visit_generation = 1u;
        }
        std::vector<int32_t> queue;
        std::vector<int8_t> distance;
        queue.reserve(256);
        distance.reserve(256);
        queue.push_back(e.cell_idx);
        distance.push_back(0);
        stamp.visit_tag[static_cast<size_t>(e.cell_idx)] = stamp.visit_generation;
        const int radius = std::clamp(static_cast<int>(std::ceil(e.radius_cells)),
                                      2, max_radius);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int i = queue[head];
            const int dist = static_cast<int>(distance[head]);
            const float falloff = 1.0f - static_cast<float>(dist) /
                static_cast<float>(radius + 1);
            if (stamp.force_tag[static_cast<size_t>(i)] != stamp.force_generation) {
                stamp.force_tag[static_cast<size_t>(i)] = stamp.force_generation;
                stamp.force_x[static_cast<size_t>(i)] = 0.0f;
                stamp.force_y[static_cast<size_t>(i)] = 0.0f;
                stamp.lift[static_cast<size_t>(i)] = 0.0f;
                ++stats.touched_cells;
            }
            float dx = positions_x[i] - positions_x[e.cell_idx];
            if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
            const float dy = positions_y[i] - positions_y[e.cell_idx];
            float tangent_x = 0.0f;
            float tangent_y = 0.0f;
            if (dx * dx + dy * dy > 1e-6f) {
                const float ny = dc_clampf(
                    (positions_y[e.cell_idx] - wb_y) / wb_h, 0.0f, 1.0f);
                const float hemi = ny < 0.5f ? 1.0f : -1.0f;
                tangent_x = -dy * hemi;
                tangent_y = dx * hemi;
                cyc_normalize(tangent_x, tangent_y);
            } else {
                tangent_x = -e.steering_y;
                tangent_y = e.steering_x;
            }
            const float force = e.intensity * falloff * 0.62f;
            stamp.force_x[static_cast<size_t>(i)] += tangent_x * force;
            stamp.force_y[static_cast<size_t>(i)] += tangent_y * force;
            stamp.lift[static_cast<size_t>(i)] = std::max(
                stamp.lift[static_cast<size_t>(i)], e.intensity * falloff);
            if (dist >= radius) continue;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0 || stamp.visit_tag[static_cast<size_t>(ni)] ==
                              stamp.visit_generation) {
                    continue;
                }
                stamp.visit_tag[static_cast<size_t>(ni)] = stamp.visit_generation;
                queue.push_back(ni);
                distance.push_back(static_cast<int8_t>(dist + 1));
            }
        }
    }
    for (CycloneEntry &e : entries) {
        e.vec_x = e.steering_x * e.intensity;
        e.vec_y = e.steering_y * e.intensity;
        e.vec_init_x = e.vec_x;
        e.vec_init_y = e.vec_y;
    }
}

std::vector<uint8_t> cyclone_state_encode(const std::vector<CycloneEntry> &entries,
                                          uint64_t next_stable_id) {
    std::vector<uint8_t> out;
    out.reserve(16u + entries.size() * 68u);
    cyc_append_u32(out, 0x31435943u);  // "CYC1"
    cyc_append_u32(out, 1u);
    cyc_append_u32(out, static_cast<uint32_t>(
        std::min<size_t>(entries.size(), 0xFFFFFFFFu)));
    cyc_append_u64(out, next_stable_id);
    for (const CycloneEntry &e : entries) {
        cyc_append_u64(out, e.stable_id);
        cyc_append_u64(out, static_cast<uint64_t>(e.key));
        cyc_append_u32(out, static_cast<uint32_t>(e.cell_idx));
        cyc_append_f32(out, e.steering_x);
        cyc_append_f32(out, e.steering_y);
        cyc_append_f32(out, e.vec_x);
        cyc_append_f32(out, e.vec_y);
        cyc_append_f32(out, e.vec_init_x);
        cyc_append_f32(out, e.vec_init_y);
        cyc_append_f32(out, e.intensity);
        cyc_append_f32(out, e.radius_cells);
        cyc_append_f32(out, e.age_days);
        cyc_append_f32(out, e.move_progress);
        cyc_append_u32(out, static_cast<uint32_t>(e.days_left));
        cyc_append_u32(out, static_cast<uint32_t>(e.init_days));
    }
    return out;
}

void cyclone_state_decode(const std::vector<uint8_t> &blob,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id) {
    entries.clear();
    next_stable_id = 1;
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, count = 0;
    if (!cyc_read_u32(blob, cursor, magic) || magic != 0x31435943u) return;
    if (!cyc_read_u32(blob, cursor, version) || version != 1u) return;
    if (!cyc_read_u32(blob, cursor, count)) return;
    if (!cyc_read_u64(blob, cursor, next_stable_id)) return;
    entries.reserve(count);
    for (uint32_t k = 0; k < count; ++k) {
        CycloneEntry e;
        uint64_t key_bits = 0;
        uint32_t value32 = 0;
        if (!cyc_read_u64(blob, cursor, e.stable_id)) return;
        if (!cyc_read_u64(blob, cursor, key_bits)) return;
        e.key = static_cast<int64_t>(key_bits);
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.cell_idx = static_cast<int32_t>(value32);
        if (!cyc_read_f32(blob, cursor, e.steering_x) ||
            !cyc_read_f32(blob, cursor, e.steering_y) ||
            !cyc_read_f32(blob, cursor, e.vec_x) ||
            !cyc_read_f32(blob, cursor, e.vec_y) ||
            !cyc_read_f32(blob, cursor, e.vec_init_x) ||
            !cyc_read_f32(blob, cursor, e.vec_init_y) ||
            !cyc_read_f32(blob, cursor, e.intensity) ||
            !cyc_read_f32(blob, cursor, e.radius_cells) ||
            !cyc_read_f32(blob, cursor, e.age_days) ||
            !cyc_read_f32(blob, cursor, e.move_progress)) {
            entries.clear();
            return;
        }
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.days_left = static_cast<int32_t>(value32);
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.init_days = static_cast<int32_t>(value32);
        entries.push_back(e);
    }
}

} // namespace pk_async_climate
} // namespace pk
