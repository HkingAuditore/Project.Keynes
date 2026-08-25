#include "world_ext.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int32_t kBaseBudget = 42;
constexpr int32_t kMaxViewHeight = 32;
constexpr int32_t kBlurIterations = 2;

struct VisionResearchState {
    int32_t cell_count = 0;
    PackedInt32Array neighbors;
    PackedByteArray view_height;
    PackedByteArray view_block;
    PackedInt32Array signal_offsets;
    PackedInt32Array signal_ids;
    std::vector<int32_t> bit_to_signal = std::vector<int32_t>(32, -1);
    std::vector<uint8_t> eligibility;
};

VisionResearchState *vision_state(void *opaque) {
    return static_cast<VisionResearchState *>(opaque);
}

int32_t lowest_bit_index(uint32_t bits) {
    int32_t bit = 0;
    while ((bits & 1u) == 0u) {
        bits >>= 1u;
        ++bit;
    }
    return bit;
}

PackedByteArray packed_u8(const std::vector<uint8_t> &values) {
    PackedByteArray out;
    out.resize(static_cast<int64_t>(values.size()));
    if (!values.empty())
        std::memcpy(out.ptrw(), values.data(), values.size() * sizeof(uint8_t));
    return out;
}

PackedInt32Array packed_i32(const std::vector<int32_t> &values) {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(values.size()));
    if (!values.empty())
        std::memcpy(out.ptrw(), values.data(), values.size() * sizeof(int32_t));
    return out;
}

void blur_hex(const std::vector<float> &src, std::vector<float> &dst,
              const int32_t *neighbors, int32_t n) {
    dst.resize(static_cast<size_t>(n));
    for (int32_t cell = 0; cell < n; ++cell) {
        float sum = src[static_cast<size_t>(cell)] * 2.0f;
        float weight = 2.0f;
        const int32_t base = cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t next = neighbors[base + d];
            if (next < 0 || next >= n) continue;
            sum += src[static_cast<size_t>(next)];
            weight += 1.0f;
        }
        dst[static_cast<size_t>(cell)] = sum / weight;
    }
}

void append_observation(uint64_t key, std::vector<uint64_t> &keys) {
    keys.push_back(key);
}

void unpack_observations(std::vector<uint64_t> &keys, Dictionary &out) {
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    PackedInt32Array cells;
    PackedInt32Array signals;
    cells.resize(static_cast<int64_t>(keys.size()));
    signals.resize(static_cast<int64_t>(keys.size()));
    int32_t *cell_ptr = cells.ptrw();
    int32_t *signal_ptr = signals.ptrw();
    for (size_t i = 0; i < keys.size(); ++i) {
        signal_ptr[i] = int32_t(keys[i] >> 32u);
        cell_ptr[i] = int32_t(keys[i] & 0xffffffffu);
    }
    out["observation_cells"] = cells;
    out["observation_signals"] = signals;
    out["observation_count"] = static_cast<int64_t>(keys.size());
}

} // namespace

void destroy_vision_research_state(void *state) {
    delete vision_state(state);
}

Dictionary DCWorldExt::configure_vision_research(const Dictionary &config) {
    Dictionary out;
    out["ok"] = false;
    const int32_t n = int32_t(config.get("cell_count", 0));
    const PackedInt32Array neighbors = config.get("neighbor_indices", PackedInt32Array());
    const PackedByteArray height = config.get("view_height", PackedByteArray());
    const PackedByteArray block = config.get("view_block", PackedByteArray());
    const PackedInt32Array offsets = config.get("signal_offsets", PackedInt32Array());
    const PackedInt32Array signal_ids = config.get("signal_ids", PackedInt32Array());
    const PackedInt32Array bio_bits = config.get("bio_bits", PackedInt32Array());
    const PackedInt32Array bio_signals = config.get("bio_signals", PackedInt32Array());
    if (n <= 0 || neighbors.size() != int64_t(n) * 6 || height.size() != n ||
        block.size() != n || offsets.size() != int64_t(n) + 1 ||
        offsets[n] != signal_ids.size() || bio_bits.size() != bio_signals.size()) {
        out["reason"] = "vision_research_config_shape_invalid";
        return out;
    }
    auto *state = new VisionResearchState();
    state->cell_count = n;
    state->neighbors = neighbors;
    state->view_height = height;
    state->view_block = block;
    state->signal_offsets = offsets;
    state->signal_ids = signal_ids;
    for (int32_t i = 0; i < bio_bits.size(); ++i) {
        const int32_t bit = bio_bits[i];
        if (bit < 0 || bit >= 32 || state->bit_to_signal[size_t(bit)] >= 0) {
            delete state;
            out["reason"] = "vision_research_bio_bit_invalid";
            return out;
        }
        state->bit_to_signal[size_t(bit)] = bio_signals[i];
    }
    state->eligibility.assign(static_cast<size_t>(n), 0u);
    if (_vision_research_state != nullptr)
        destroy_vision_research_state(_vision_research_state);
    _vision_research_state = state;
    out["ok"] = true;
    out["cells"] = n;
    return out;
}

Dictionary DCWorldExt::run_vision_research_pass(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    if (_vision_research_state == nullptr) {
        out["reason"] = "vision_research_not_configured";
        return out;
    }
    const auto started = std::chrono::steady_clock::now();
    VisionResearchState *state = vision_state(_vision_research_state);
    const int32_t n = state->cell_count;
    const int32_t player_slot = int32_t(knobs.get("player_slot", -1));
    const bool remote = bool(knobs.get("remote_observation", false));
    const PackedInt32Array owners = knobs.get("country_slots", PackedInt32Array());
    const PackedByteArray previous_visible = knobs.get("visible", PackedByteArray());
    const PackedByteArray previous_explored = knobs.get("explored", PackedByteArray());
    const PackedByteArray previous_fog = knobs.get("fog_k", PackedByteArray());
    const PackedInt32Array occupancy = knobs.get("bio_occupancy_bits", PackedInt32Array());
    if (owners.size() != n || previous_explored.size() != n || occupancy.size() != n) {
        out["reason"] = "vision_research_input_shape_invalid";
        return out;
    }

    const int32_t *neighbors = state->neighbors.ptr();
    const uint8_t *height = state->view_height.ptr();
    const uint8_t *block = state->view_block.ptr();
    std::vector<int32_t> best(static_cast<size_t>(n), -1);
    std::vector<std::vector<int32_t>> buckets(size_t(kBaseBudget + kMaxViewHeight + 1));
    int32_t source_count = 0;
    for (int32_t cell = 0; cell < n; ++cell) {
        if (player_slot < 0 || owners[cell] != player_slot) continue;
        ++source_count;
        const int32_t budget = std::clamp(kBaseBudget + int32_t(height[cell]),
                                          0, kBaseBudget + kMaxViewHeight);
        if (budget > best[size_t(cell)]) {
            best[size_t(cell)] = budget;
            buckets[size_t(budget)].push_back(cell);
        }
    }
    std::vector<uint8_t> visible(static_cast<size_t>(n), 0u);
    for (int32_t budget = kBaseBudget + kMaxViewHeight; budget >= 0; --budget) {
        const std::vector<int32_t> &bucket = buckets[size_t(budget)];
        for (int32_t cell : bucket) {
            if (best[size_t(cell)] != budget) continue;
            visible[size_t(cell)] = 1u;
            const int32_t base = cell * 6;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t next = neighbors[base + d];
                if (next < 0 || next >= n) continue;
                const int32_t next_budget = budget - int32_t(block[next]);
                if (next_budget < 0 || next_budget <= best[size_t(next)]) continue;
                best[size_t(next)] = next_budget;
                buckets[size_t(next_budget)].push_back(next);
            }
        }
    }

    std::vector<uint8_t> explored(static_cast<size_t>(n));
    std::vector<float> vis_a(static_cast<size_t>(n));
    std::vector<float> exp_a(static_cast<size_t>(n));
    int32_t visible_count = 0;
    int32_t explored_count = 0;
    for (int32_t cell = 0; cell < n; ++cell) {
        explored[size_t(cell)] = previous_explored[cell] != 0 || visible[size_t(cell)] != 0;
        vis_a[size_t(cell)] = visible[size_t(cell)] != 0 ? 1.0f : 0.0f;
        exp_a[size_t(cell)] = explored[size_t(cell)] != 0 ? 1.0f : 0.0f;
        visible_count += visible[size_t(cell)];
        explored_count += explored[size_t(cell)];
    }
    std::vector<float> vis_b;
    std::vector<float> exp_b;
    for (int32_t iteration = 0; iteration < kBlurIterations; ++iteration) {
        blur_hex(vis_a, vis_b, neighbors, n);
        blur_hex(exp_a, exp_b, neighbors, n);
        vis_a.swap(vis_b);
        exp_a.swap(exp_b);
    }
    std::vector<uint8_t> fog(static_cast<size_t>(n));
    std::vector<int32_t> dirty;
    std::vector<uint64_t> observations;
    const int32_t *offsets = state->signal_offsets.ptr();
    const int32_t *signal_ids = state->signal_ids.ptr();
    for (int32_t cell = 0; cell < n; ++cell) {
        fog[size_t(cell)] = uint8_t(std::clamp<int32_t>(
            int32_t(std::lround((0.5f * exp_a[size_t(cell)] +
                                 0.5f * vis_a[size_t(cell)]) * 255.0f)), 0, 255));
        if ((previous_visible.size() == n && previous_visible[cell] != visible[size_t(cell)]) ||
            previous_explored[cell] != explored[size_t(cell)] ||
            (previous_fog.size() == n && previous_fog[cell] != fog[size_t(cell)]))
            dirty.push_back(cell);
        const uint8_t eligible = uint8_t(player_slot >= 0 && (
            owners[cell] == player_slot || (remote && visible[size_t(cell)] != 0)));
        if (eligible != 0 && state->eligibility[size_t(cell)] == 0) {
            for (int32_t edge = offsets[cell]; edge < offsets[cell + 1]; ++edge)
                append_observation((uint64_t(uint32_t(signal_ids[edge])) << 32u) |
                                   uint32_t(cell), observations);
            uint32_t bits = static_cast<uint32_t>(occupancy[cell]);
            while (bits != 0u) {
                const int32_t bit = lowest_bit_index(bits);
                bits &= bits - 1u;
                const int32_t signal = state->bit_to_signal[size_t(bit)];
                if (signal >= 0)
                    append_observation((uint64_t(uint32_t(signal)) << 32u) |
                                       uint32_t(cell), observations);
            }
        }
        state->eligibility[size_t(cell)] = eligible;
    }

    out["ok"] = true;
    out["path"] = "gdext";
    out["physical_visible"] = packed_u8(visible);
    out["explored_arr"] = packed_u8(explored);
    out["fog_k_arr"] = packed_u8(fog);
    out["fog_dirty_indices"] = packed_i32(dirty);
    out["visible"] = visible_count;
    out["explored"] = explored_count;
    out["sources"] = source_count;
    out["cells"] = n;
    unpack_observations(observations, out);
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary DCWorldExt::filter_bio_research_observations(
        const PackedInt32Array &cells, const PackedInt32Array &signals) const {
    Dictionary out;
    out["ok"] = false;
    if (_vision_research_state == nullptr || cells.size() != signals.size()) {
        out["reason"] = "vision_research_observation_shape_invalid";
        return out;
    }
    const VisionResearchState *state = vision_state(_vision_research_state);
    std::vector<uint64_t> observations;
    observations.reserve(static_cast<size_t>(cells.size()));
    for (int32_t i = 0; i < cells.size(); ++i) {
        const int32_t cell = cells[i];
        const int32_t signal = signals[i];
        if (cell < 0 || cell >= state->cell_count || signal < 0 ||
            state->eligibility[size_t(cell)] == 0)
            continue;
        observations.push_back((uint64_t(uint32_t(signal)) << 32u) | uint32_t(cell));
    }
    out["ok"] = true;
    unpack_observations(observations, out);
    return out;
}

} // namespace pk
