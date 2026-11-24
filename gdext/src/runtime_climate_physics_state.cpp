#include "runtime_climate_physics.h"

#include <cmath>
#include <cstring>

namespace pk::pk_async_physics {

namespace {
using PhysicsLane = std::vector<float> RuntimeClimatePhysicsState::*;
constexpr PhysicsLane saved_physics_lanes[] = {
    &RuntimeClimatePhysicsState::slp, &RuntimeClimatePhysicsState::slp_prev,
    &RuntimeClimatePhysicsState::wind_x, &RuntimeClimatePhysicsState::wind_y,
    &RuntimeClimatePhysicsState::wind_speed,
    &RuntimeClimatePhysicsState::ocean_current_x, &RuntimeClimatePhysicsState::ocean_current_y,
    &RuntimeClimatePhysicsState::ocean_psi, &RuntimeClimatePhysicsState::ocean_psi_prev,
    &RuntimeClimatePhysicsState::upwelling, &RuntimeClimatePhysicsState::wind_stress_curl,
    &RuntimeClimatePhysicsState::ocean_thermal_anomaly,
    &RuntimeClimatePhysicsState::synoptic_psi, &RuntimeClimatePhysicsState::synoptic_psi_prev,
    &RuntimeClimatePhysicsState::monsoon_thermal,
    // CHP1 v2 起追加；v1 blob 只有上面 15 条。
    &RuntimeClimatePhysicsState::temp_transport_anomaly,
};
constexpr size_t kPhysicsLanesV1 = 15;
constexpr size_t kPhysicsLanesV2 = sizeof(saved_physics_lanes) / sizeof(saved_physics_lanes[0]);
constexpr uint32_t kPhysicsFlagTtaSeeded = 8u;
}

void RuntimeClimatePhysicsState::note_wind_solve(int64_t day) {
    last_wind_day = day;
    wind_display_signature.reset();
}

bool RuntimeClimatePhysicsState::validate_values(std::string &error,
                                                MapOverlayInputSignature *wind_signature) const {
    for (auto member : saved_physics_lanes) {
        for (float v : this->*member) {
            if (!std::isfinite(v)) { error = "physics_non_finite"; return false; }
        }
    }
    if (committed_day < -1 || committed_day > INT32_MAX ||
        daily_due_seq > static_cast<uint64_t>(committed_day + 1) ||
        (!synoptic_seeded && synoptic_tick != 0) ||
        last_daily_day < -1 || last_slp_day < -1 ||
        last_wind_day < -1 || last_ocean_day < -1 || synoptic_tick < 0 ||
        last_daily_day > committed_day || last_slp_day > committed_day ||
        last_wind_day > committed_day || last_ocean_day > committed_day ||
        (initialized && (!ready || daily_due_seq == 0 || last_daily_day < 0 ||
                         last_slp_day < 0 || last_wind_day < 0 || last_ocean_day < 0))) {
        error = "physics_cadence_invalid"; return false;
    }
    for (int i = 0; i < cell_count; ++i) {
        const float x = wind_x[i], y = wind_y[i], speed = wind_speed[i];
        if (std::abs(x) > 1.0f || std::abs(y) > 1.0f ||
            speed < 0.0f || std::abs(ocean_current_x[i]) > 1.0f ||
            std::abs(ocean_current_y[i]) > 1.0f || std::abs(upwelling[i]) > 1.0f ||
            std::abs(synoptic_psi[i]) > 1.0f || std::abs(synoptic_psi_prev[i]) > 1.0f ||
            std::abs(monsoon_thermal[i]) > 1.0f) {
            error = "physics_lane_bounds"; return false;
        }
        if (wind_signature) {
            wind_signature->add(x);
            wind_signature->add(y);
            wind_signature->add(speed);
        }
    }
    if (topo_valid) {
        for (int i = 0; i < cell_count; ++i) {
            const int w = cell_to_water[i];
            if (w < -1 || w >= n_water || (w >= 0 && water_to_cell[w] != i)) {
                error = "physics_csr_inverse"; return false;
            }
        }
        for (int w = 0; w < n_water; ++w) {
            const int i = water_to_cell[w];
            if (i < 0 || i >= cell_count || cell_to_water[i] != w) {
                error = "physics_csr_cell"; return false;
            }
        }
        for (int32_t w : nb_w) if (w < -1 || w >= n_water) {
            error = "physics_csr_neighbor"; return false;
        }
    }
    if (wind_traj_valid) {
        for (int i = 0; i < cell_count; ++i) {
            float sum = 0.0f;
            for (int j = 0; j < 3; ++j) {
                const size_t k = static_cast<size_t>(i) * 3 + j;
                if (wind_traj_idx[k] < 0 || wind_traj_idx[k] >= cell_count ||
                    !std::isfinite(wind_traj_w[k]) || wind_traj_w[k] < 0.0f || wind_traj_w[k] > 1.0f) {
                    error = "physics_traj_bounds"; return false;
                }
                sum += wind_traj_w[k];
            }
            if (std::abs(sum - 1.0f) > 0.00001f) { error = "physics_traj_sum"; return false; }
        }
    }
    error.clear();
    return true;
}

bool serialize_physics_state(RuntimeClimatePhysicsState &s,
                             std::vector<uint8_t> &blob, std::string &error) {
    // The required validation already visits the final corrected wind. A
    // solve invalidates the key even when it produces identical values.
    MapOverlayInputSignature wind_signature;
    const bool needs_wind_signature = s.last_wind_day >= 0 && !s.wind_display_signature;
    if (!s.validate(error, needs_wind_signature ? &wind_signature : nullptr)) return false;
    // 校验通过后无其他失败点；复用胶囊容量，避免每天分配并逐字节 push_back。
    std::vector<uint8_t> &out = blob;
    out.resize(120u + static_cast<size_t>(s.cell_count) * 4u * kPhysicsLanesV2);
    size_t offset = 0;
    auto put = [&out, &offset](uint64_t v, int bytes) {
        for (int i = 0; i < bytes; ++i) out[offset++] = static_cast<uint8_t>(v >> (8 * i));
    };
    put(0x31504843u, 4); // CHP1，小端显式字段，不序列化结构 padding/指针/缓存。
    put(2, 4); put(static_cast<uint32_t>(s.cell_count), 4);
    put((s.ready ? 1u : 0u) | (s.initialized ? 2u : 0u) | (s.synoptic_seeded ? 4u : 0u) |
        (s.tta_seeded ? kPhysicsFlagTtaSeeded : 0u), 4);
    put(s.generation, 8); put(s.input_generation, 8); put(static_cast<uint64_t>(s.committed_day), 8);
    put(static_cast<uint64_t>(s.last_daily_day), 8); put(static_cast<uint64_t>(s.last_slp_day), 8);
    put(static_cast<uint64_t>(s.last_wind_day), 8); put(static_cast<uint64_t>(s.last_ocean_day), 8);
    put(s.daily_due_seq, 8); put(static_cast<uint32_t>(s.synoptic_tick), 4);
    put(s.wind_traj_generation, 4);
    put(s.cyclone_total_injected, 8); put(s.cyclone_total_replaced, 8); put(s.cyclone_total_decayed, 8);
    put(s.state_hash(), 8);
    const uint16_t endian = 1;
    const bool little_endian = *reinterpret_cast<const uint8_t *>(&endian) == 1;
    for (auto member : saved_physics_lanes) {
        const auto &lane = s.*member;
        if (little_endian) {
            const size_t bytes = lane.size() * sizeof(float);
            std::memcpy(out.data() + offset, lane.data(), bytes);
            offset += bytes;
        } else {
            for (float v : lane) {
                uint32_t bits; std::memcpy(&bits, &v, sizeof(bits)); put(bits, 4);
            }
        }
    }
    if (needs_wind_signature) s.wind_display_signature = wind_signature;
    error.clear();
    return true;
}

void copy_committed_physics_fields(const RuntimeClimatePhysicsState &source,
                                  RuntimeClimatePhysicsState &out) {
    out.cell_count = source.cell_count;
    out.ready = source.ready;
    out.initialized = source.initialized;
    out.synoptic_seeded = source.synoptic_seeded;
    out.tta_seeded = source.tta_seeded;
    out.generation = source.generation;
    out.input_generation = source.input_generation;
    out.committed_day = source.committed_day;
    out.last_daily_day = source.last_daily_day;
    out.last_slp_day = source.last_slp_day;
    out.last_wind_day = source.last_wind_day;
    out.wind_display_signature = source.wind_display_signature;
    out.last_ocean_day = source.last_ocean_day;
    out.daily_due_seq = source.daily_due_seq;
    out.synoptic_tick = source.synoptic_tick;
    out.wind_traj_generation = source.wind_traj_generation;
    out.cyclone_total_injected = source.cyclone_total_injected;
    out.cyclone_total_replaced = source.cyclone_total_replaced;
    out.cyclone_total_decayed = source.cyclone_total_decayed;
    for (const auto field : saved_physics_lanes) out.*field = source.*field;
}

bool restore_physics_state(const uint8_t *data, size_t size,
                           RuntimeClimatePhysicsState &state, std::string &error) {
    if (size == 0) { state = RuntimeClimatePhysicsState{}; error.clear(); return true; }
    if (!data || size < 120u) { error = "physics_blob_truncated"; return false; }
    size_t offset = 0;
    auto get = [&](int bytes) {
        uint64_t v = 0;
        for (int i = 0; i < bytes; ++i) v |= uint64_t(data[offset++]) << (8 * i);
        return v;
    };
    if (get(4) != 0x31504843u) {
        error = "physics_blob_version"; return false;
    }
    const uint64_t version = get(4);
    if (version != 1u && version != 2u) {
        error = "physics_blob_version"; return false;
    }
    const size_t lane_count = version == 1u ? kPhysicsLanesV1 : kPhysicsLanesV2;
    const uint64_t max_flags = version == 1u ? 7u : 15u;
    const uint64_t n = get(4), flags = get(4);
    if (n == 0 || n > 10000000u || flags > max_flags ||
        size != 120u + n * 4u * lane_count) {
        error = "physics_blob_shape"; return false;
    }
    RuntimeClimatePhysicsState s;
    s.resize(static_cast<int>(n));
    s.ready = (flags & 1u) != 0; s.initialized = (flags & 2u) != 0;
    s.synoptic_seeded = (flags & 4u) != 0;
    s.tta_seeded = (flags & kPhysicsFlagTtaSeeded) != 0;
    s.generation = get(8); s.input_generation = get(8); s.committed_day = static_cast<int64_t>(get(8));
    s.last_daily_day = static_cast<int64_t>(get(8)); s.last_slp_day = static_cast<int64_t>(get(8));
    s.last_wind_day = static_cast<int64_t>(get(8)); s.last_ocean_day = static_cast<int64_t>(get(8));
    s.daily_due_seq = get(8); s.synoptic_tick = static_cast<int32_t>(get(4));
    s.wind_traj_generation = static_cast<uint32_t>(get(4));
    s.cyclone_total_injected = get(8); s.cyclone_total_replaced = get(8); s.cyclone_total_decayed = get(8);
    const uint64_t hash = get(8);
    for (size_t k = 0; k < lane_count; ++k) for (float &v : s.*saved_physics_lanes[k]) {
        const uint32_t bits = static_cast<uint32_t>(get(4)); std::memcpy(&v, &bits, sizeof(v));
    }
    s.wind_speed_out = s.wind_speed;
    if (!s.validate(error)) return false;
    if (s.state_hash() != hash) { error = "physics_blob_hash"; return false; }
    state = std::move(s);
    error.clear();
    return true;
}

} // namespace pk::pk_async_physics
