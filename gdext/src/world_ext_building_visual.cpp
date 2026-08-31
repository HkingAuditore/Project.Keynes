#include "world_ext.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_set>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int kArchetypeCount = 6;
constexpr int kVisualProfileCount = 3;
constexpr int kNearCap[3] = {8, 16, 24};
constexpr double kPi = 3.1415926535897932384626433832795;
// Settlement density ladder. One authoritative per-cell building total drives
// compound count, compound size and cluster radius through a single normalised
// value, so the three cannot disagree about how big a settlement is. See the
// anchor table above COMPOUND_VISUAL_SCALE in building_visual_layer.gd; every
// constant here must stay in sync with that file.
constexpr double kDensityLadderTop = 100000.0;
constexpr int kCompoundCountMax = 24;
constexpr double kCompoundScaleMin = 0.60;
constexpr double kCompoundScaleMax = 1.125;
constexpr double kCompoundSpreadMin = 0.16;
constexpr double kCompoundSpreadMax = 1.15;

double settlement_density(int64_t total) {
    if (total <= 0) {
        return 0.0;
    }
    const double span = std::log2(1.0 + kDensityLadderTop);
    const double value = std::log2(1.0 + double(total)) / span;
    return value < 0.0 ? 0.0 : (value > 1.0 ? 1.0 : value);
}

struct VisualInstance {
    int32_t cell = -1;
    int32_t archetype = 0;
    int32_t local_rank = 0;
    int64_t importance = 0;
    float px = 0.0f;
    float py = 0.0f;
    float size = 0.0f;
    float rotation = 0.0f;
    float style = 0.0f;
    float seed = 0.0f;
    float profile = 0.0f;
};

static uint32_t stable_hash(int32_t cell, int32_t archetype,
        int32_t rank, int32_t salt, int32_t layout_seed) {
    // Match BuildingVisualLayer._stable_hash while avoiding signed overflow UB.
    uint64_t value = static_cast<uint64_t>(static_cast<uint32_t>(cell)) * 1103515245ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(archetype)) * 374761393ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(rank)) * 668265263ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(salt)) * 2246822519ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(layout_seed)) * 3266489917ULL;
    uint32_t result = static_cast<uint32_t>(value) & 0x7fffffffU;
    result = static_cast<uint32_t>((static_cast<uint64_t>(result ^ (result >> 13)) *
            1274126177ULL) & 0x7fffffffU);
    return result ^ (result >> 16);
}

static int64_t saturating_add_i64(int64_t lhs, int64_t rhs) {
    if (rhs > 0 && lhs > std::numeric_limits<int64_t>::max() - rhs) {
        return std::numeric_limits<int64_t>::max();
    }
    return lhs + rhs;
}

static double clampd(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

} // namespace

godot::Dictionary DCWorldExt::bake_building_visual_chunk(godot::Dictionary knobs) {
    const auto begin_time = std::chrono::high_resolution_clock::now();
    Dictionary out;
    out["ok"] = false;
    out["fallback"] = true;
    out["path"] = String("gdscript");
    out["instance_count"] = 0;
    out["decal_instance_count"] = 0;
    out["candidate_count"] = 0;
    out["river_rejected"] = 0;
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *reason) -> Dictionary {
        out["reason"] = String(reason);
        const auto end_time = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(end_time - begin_time).count();
        return out;
    };

    const int quality = std::max(0, std::min(2, int(knobs.get("quality", 1))));
    const int instance_cap = int(knobs.get("instance_cap", 0));
    const double hex_size = double(knobs.get("hex_size", 22.0));
    const int cell_count = int(knobs.get("cell_count", 0));
    const int layout_seed = int(knobs.get("layout_seed", 0));
    if (hex_size <= 0.0 || cell_count <= 0 || instance_cap < 0) {
        return fail("building_visual_bad_numeric_knob");
    }

    PackedInt32Array cell_indices = knobs.get("cell_indices", PackedInt32Array());
    PackedFloat32Array cell_pos_x = knobs.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array cell_pos_y = knobs.get("cell_pos_y", PackedFloat32Array());
    PackedInt32Array type_offsets = knobs.get("type_offsets", PackedInt32Array());
    PackedInt32Array type_indices = knobs.get("type_indices", PackedInt32Array());
    PackedInt64Array type_counts = knobs.get("type_counts", PackedInt64Array());
    PackedInt32Array era_indices = knobs.get("era_indices", PackedInt32Array());
    PackedByteArray type_to_archetype = knobs.get("type_to_archetype", PackedByteArray());
    PackedByteArray type_to_visual_profile = knobs.get(
            "type_to_visual_profile", PackedByteArray());
    PackedByteArray is_water = knobs.get("is_water", PackedByteArray());
    if (cell_indices.is_empty() || cell_pos_x.size() < cell_indices.size() ||
            cell_pos_y.size() < cell_indices.size() || era_indices.size() < cell_indices.size() ||
            is_water.size() < cell_indices.size() || type_offsets.size() != cell_indices.size() + 1 ||
            type_indices.size() != type_counts.size() || type_offsets.is_empty() ||
            type_offsets[0] != 0 ||
            type_offsets[type_offsets.size() - 1] != type_indices.size() ||
            (!type_to_visual_profile.is_empty() &&
                    type_to_visual_profile.size() != type_to_archetype.size())) {
        return fail("building_visual_chunk_input_shape_invalid");
    }

    const int K = cell_indices.size();
    const int32_t *offset_data = type_offsets.ptr();
    for (int i = 0; i < K; ++i) {
        if (offset_data[i] < 0 || offset_data[i] > offset_data[i + 1]) {
            return fail("building_visual_chunk_offsets_not_monotonic");
        }
    }
    const int32_t *CELL = cell_indices.ptr();
    const float *POS_X = cell_pos_x.ptr();
    const float *POS_Y = cell_pos_y.ptr();
    const int32_t *OFFSETS = type_offsets.ptr();
    const int32_t *TYPES = type_indices.ptr();
    const int64_t *COUNTS = type_counts.ptr();
    const int32_t *ERAS = era_indices.ptr();
    const uint8_t *ARCH = type_to_archetype.ptr();
    const uint8_t *PROFILE = type_to_visual_profile.is_empty()
            ? nullptr : type_to_visual_profile.ptr();
    const uint8_t *WATER = is_water.ptr();

    PackedFloat32Array flow_buffer = knobs.get("flow_buffer", PackedFloat32Array());
    const int flow_w = int(knobs.get("flow_w", 0));
    const int flow_h = int(knobs.get("flow_h", 0));
    const double flow_origin_x = double(knobs.get("flow_origin_x", 0.0));
    const double flow_origin_y = double(knobs.get("flow_origin_y", 0.0));
    const double flow_size_x = double(knobs.get("flow_size_x", 0.0));
    const double flow_size_y = double(knobs.get("flow_size_y", 0.0));
    const double flow_wrap_x = double(knobs.get("flow_wrap_period_x", 0.0));
    const double river_threshold = double(knobs.get("river_clear_threshold", 0.42));
    const bool flow_valid = !flow_buffer.is_empty() && flow_w > 0 && flow_h > 0 &&
            flow_size_x > 1.0e-6 && flow_size_y > 1.0e-6 &&
            flow_buffer.size() >= flow_w * flow_h;
    const float *FLOW = flow_valid ? flow_buffer.ptr() : nullptr;

    auto sample_flow = [&](double world_x, double world_y) -> double {
        if (!flow_valid) {
            return 0.0;
        }
        double sample_x = world_x;
        if (flow_wrap_x > 1.0e-6) {
            sample_x = std::fmod(sample_x, flow_wrap_x);
            if (sample_x < 0.0) {
                sample_x += flow_wrap_x;
            }
        }
        const double u = clampd((sample_x - flow_origin_x) / flow_size_x, 0.0, 1.0);
        const double v = clampd((world_y - flow_origin_y) / flow_size_y, 0.0, 1.0);
        const double fx = u * double(flow_w - 1);
        const double fy = v * double(flow_h - 1);
        const int x0 = std::max(0, std::min(flow_w - 1, int(std::floor(fx))));
        const int y0 = std::max(0, std::min(flow_h - 1, int(std::floor(fy))));
        const int x1 = std::min(flow_w - 1, x0 + 1);
        const int y1 = std::min(flow_h - 1, y0 + 1);
        const double tx = fx - double(x0);
        const double ty = fy - double(y0);
        const double v00 = FLOW[y0 * flow_w + x0];
        const double v10 = FLOW[y0 * flow_w + x1];
        const double v01 = FLOW[y1 * flow_w + x0];
        const double v11 = FLOW[y1 * flow_w + x1];
        const double a = v00 + (v10 - v00) * tx;
        const double b = v01 + (v11 - v01) * tx;
        return a + (b - a) * ty;
    };

    std::vector<VisualInstance> instances;
    instances.reserve(static_cast<size_t>(K * kNearCap[quality]));
    int candidate_count = 0;
    int river_rejected = 0;
    const int near_cap = kNearCap[quality];

    for (int i = 0; i < K; ++i) {
        if (CELL[i] < 0 || CELL[i] >= cell_count || WATER[i] != 0) {
            continue;
        }
        const int begin = OFFSETS[i];
        const int end = OFFSETS[i + 1];
        int64_t archetype_counts[kArchetypeCount] = {0, 0, 0, 0, 0, 0};
        int64_t profile_counts[kArchetypeCount][kVisualProfileCount] = {};
        int64_t total = 0;
        for (int edge = begin; edge < end; ++edge) {
            const int type = TYPES[edge];
            if (type < 0 || type >= type_to_archetype.size() || COUNTS[edge] <= 0) {
                continue;
            }
            const int archetype = int(ARCH[type]);
            if (archetype < 0 || archetype >= kArchetypeCount) {
                continue;
            }
            archetype_counts[archetype] = saturating_add_i64(archetype_counts[archetype], COUNTS[edge]);
            const int profile = PROFILE == nullptr
                    ? 0 : std::max(0, std::min(kVisualProfileCount - 1, int(PROFILE[type])));
            profile_counts[archetype][profile] = saturating_add_i64(
                    profile_counts[archetype][profile], COUNTS[edge]);
            total = saturating_add_i64(total, COUNTS[edge]);
        }
        if (total <= 0) {
            continue;
        }

        // Rounding rather than ceiling keeps the compound count from ever
        // exceeding the authoritative total, so a two-building hamlet cannot
        // draw three compounds.
        const double density = settlement_density(total);
        const int raw = int(std::lround(double(kCompoundCountMax) * density));
        const int slots = std::max(1, std::min(near_cap, raw));
        const float cell_scale = float(hex_size * (kCompoundScaleMin +
                (kCompoundScaleMax - kCompoundScaleMin) * density));
        const double spread_scale = kCompoundSpreadMin +
                (kCompoundSpreadMax - kCompoundSpreadMin) * density;
        std::array<int, kArchetypeCount> active{};
        int active_count = 0;
        for (int archetype = 0; archetype < kArchetypeCount; ++archetype) {
            if (archetype_counts[archetype] > 0) {
                active[static_cast<size_t>(active_count++)] = archetype;
            }
        }
        std::sort(active.begin(), active.begin() + active_count, [&](int lhs, int rhs) {
            if (archetype_counts[lhs] != archetype_counts[rhs]) {
                return archetype_counts[lhs] > archetype_counts[rhs];
            }
            return lhs < rhs;
        });
        int quota[kArchetypeCount] = {0, 0, 0, 0, 0, 0};
        int remaining = slots;
        for (int active_index = 0; active_index < active_count; ++active_index) {
            const int archetype = active[static_cast<size_t>(active_index)];
            if (remaining <= 0) {
                break;
            }
            ++quota[archetype];
            --remaining;
        }
        if (remaining > 0 && active_count > 0) {
            double weight_total = 0.0;
            double weights[kArchetypeCount] = {0, 0, 0, 0, 0, 0};
            for (int active_index = 0; active_index < active_count; ++active_index) {
                const int archetype = active[static_cast<size_t>(active_index)];
                weights[archetype] = std::log2(1.0 + double(archetype_counts[archetype]));
                weight_total += weights[archetype];
            }
            struct Remainder { int archetype; double value; };
            std::array<Remainder, kArchetypeCount> remainders{};
            int assigned = 0;
            for (int active_index = 0; active_index < active_count; ++active_index) {
                const int archetype = active[static_cast<size_t>(active_index)];
                const double exact = double(remaining) * weights[archetype] /
                        std::max(weight_total, 1.0e-9);
                const int whole = int(std::floor(exact));
                quota[archetype] += whole;
                assigned += whole;
                remainders[static_cast<size_t>(active_index)] =
                    Remainder{archetype, exact - double(whole)};
            }
            std::sort(remainders.begin(), remainders.begin() + active_count,
                [](const Remainder &lhs, const Remainder &rhs) {
                if (std::fabs(lhs.value - rhs.value) > 1.0e-12) {
                    return lhs.value > rhs.value;
                }
                return lhs.archetype < rhs.archetype;
            });
            for (int j = 0; j < remaining - assigned; ++j) {
                quota[remainders[static_cast<size_t>(j) %
                        static_cast<size_t>(active_count)].archetype] += 1;
            }
        }

        std::array<std::pair<float, float>, 12> accepted{};
        int accepted_count = 0;
        int rank = 0;
        for (int archetype = 0; archetype < kArchetypeCount; ++archetype) {
            int profile_assigned[kVisualProfileCount] = {0, 0, 0};
            for (int local_rank = 0; local_rank < quota[archetype]; ++local_rank) {
                int visual_profile = 0;
                long double best_profile_score = -1.0L;
                for (int profile = 0; profile < kVisualProfileCount; ++profile) {
                    if (profile_counts[archetype][profile] <= 0) {
                        continue;
                    }
                    const long double score = std::log2(
                            1.0L + static_cast<long double>(
                                    profile_counts[archetype][profile])) /
                            static_cast<long double>(profile_assigned[profile] + 1);
                    if (score > best_profile_score + 1.0e-15L) {
                        best_profile_score = score;
                        visual_profile = profile;
                    }
                }
                ++profile_assigned[visual_profile];
                float best_x = std::numeric_limits<float>::infinity();
                float best_y = std::numeric_limits<float>::infinity();
                double best_score = -std::numeric_limits<double>::infinity();
                double radial_min = 0.08;
                double radial_max = 0.34;
                if (archetype == 0 || archetype == 1) {
                    radial_min = 0.24;
                    radial_max = 0.54;
                } else if (archetype == 2 || archetype == 3) {
                    radial_min = 0.16;
                    radial_max = 0.46;
                } else if (archetype == 4 || archetype == 5) {
                    radial_min = 0.08;
                    radial_max = 0.34;
                }
                if (slots == 1) {
                    radial_min = 0.0;
                    radial_max = 0.0;
                }
                for (int candidate = 0; candidate < 8; ++candidate) {
                    ++candidate_count;
                    const uint32_t hash = stable_hash(CELL[i], archetype, rank,
                            candidate, layout_seed);
                    const double angle = double(hash % 6U) * kPi / 3.0 +
                            (double((hash >> 5U) % 7U) - 3.0) * 0.025;
                    const double radius = (radial_min + (radial_max - radial_min) *
                            (double((hash >> 9U) & 0xffffU) / 65535.0)) * hex_size *
                            spread_scale;
                    const float offset_x = float(std::cos(angle) * radius);
                    const float offset_y = float(std::sin(angle) * radius);
                    if (flow_valid && sample_flow(double(POS_X[i]) + offset_x,
                            double(POS_Y[i]) + offset_y) >= river_threshold) {
                        ++river_rejected;
                        continue;
                    }
                // sqrt is unnecessary for a best-candidate comparison. Keeping
                // squared distances also makes the 16x16 worst-case bake less
                // sensitive to scalar libm latency across desktop CPUs.
                const double hex_size_sq = hex_size * hex_size;
                double nearest_sq = hex_size_sq;
                for (int prior_index = 0; prior_index < accepted_count; ++prior_index) {
                    const auto &prior = accepted[static_cast<size_t>(prior_index)];
                    const double dx = double(offset_x) - double(prior.first);
                    const double dy = double(offset_y) - double(prior.second);
                    nearest_sq = std::min(nearest_sq, dx * dx + dy * dy);
                }
                if (nearest_sq > best_score) {
                    best_score = nearest_sq;
                        best_x = offset_x;
                        best_y = offset_y;
                    }
                }
                if (!std::isfinite(best_x)) {
                    ++rank;
                    continue;
                }
                accepted[static_cast<size_t>(accepted_count++)] =
                    std::make_pair(best_x, best_y);
                const float scale = cell_scale;
                const uint32_t seed_hash = stable_hash(CELL[i], archetype,
                        local_rank, 7, layout_seed);
                const float seed = float(seed_hash & 0xffffU) / 65535.0f;
                // The foundation must remain at the bottom of the sprite.
                // Buildings use one authored orientation; only their stable
                // positions and category modules vary.
                const float rotation = 0.0f;
                const int era = std::max(0, std::min(10, ERAS[i]));
                instances.push_back(VisualInstance{
                    CELL[i], archetype, local_rank,
                    archetype_counts[archetype] >
                            std::numeric_limits<int64_t>::max() / 16
                        ? std::numeric_limits<int64_t>::max()
                        : archetype_counts[archetype] * 16 - local_rank,
                    float(POS_X[i]) + best_x, float(POS_Y[i]) + best_y,
                    scale, rotation, float(era * kArchetypeCount + archetype) / 65.0f,
                    seed, float(visual_profile) / float(kVisualProfileCount - 1)});
                ++rank;
            }
        }
    }

    std::sort(instances.begin(), instances.end(), [](const VisualInstance &lhs, const VisualInstance &rhs) {
        if (lhs.importance != rhs.importance) {
            return lhs.importance > rhs.importance;
        }
        if (lhs.cell != rhs.cell) {
            return lhs.cell < rhs.cell;
        }
        if (lhs.archetype != rhs.archetype) {
            return lhs.archetype < rhs.archetype;
        }
        return lhs.local_rank < rhs.local_rank;
    });
    const int keep = std::min(instance_cap, static_cast<int>(instances.size()));
    instances.resize(static_cast<size_t>(std::max(0, keep)));

    PackedFloat32Array buffer;
    buffer.resize(static_cast<int64_t>(instances.size()) * 16);
    float *BUF = buffer.ptrw();
    for (size_t i = 0; i < instances.size(); ++i) {
        const VisualInstance &instance = instances[i];
        const double cs = std::cos(double(instance.rotation)) * double(instance.size);
        const double sn = std::sin(double(instance.rotation)) * double(instance.size);
        const int64_t base = static_cast<int64_t>(i) * 16;
        BUF[base + 0] = float(cs);
        BUF[base + 1] = float(-sn);
        BUF[base + 2] = 0.0f;
        BUF[base + 3] = instance.px;
        BUF[base + 4] = float(sn);
        BUF[base + 5] = float(cs);
        BUF[base + 6] = 0.0f;
        BUF[base + 7] = instance.py;
        BUF[base + 8] = 1.0f;
        BUF[base + 9] = 1.0f;
        BUF[base + 10] = 1.0f;
        BUF[base + 11] = 1.0f;
        BUF[base + 12] = instance.style;
        BUF[base + 13] = instance.seed;
        BUF[base + 14] = float(instance.cell) / float(std::max(1, cell_count - 1));
        BUF[base + 15] = instance.profile;
    }

    // Decals are a strict subset of the already sorted body instances. This
    // preserves the q1-per-cell / q2-per-archetype policy without another pass
    // over authoritative rows on the Godot side.
    PackedFloat32Array decal_buffer;
    std::unordered_set<int64_t> decal_seen;
    decal_seen.reserve(instances.size());
    const bool make_decals = quality > 0;
    for (size_t i = 0; make_decals && i < instances.size(); ++i) {
        const VisualInstance &instance = instances[i];
        const int64_t key = quality == 1
                ? int64_t(instance.cell)
                : int64_t(instance.cell) * kArchetypeCount + instance.archetype;
        if (!decal_seen.insert(key).second) {
            continue;
        }
        const int64_t src = static_cast<int64_t>(i) * 16;
        const int64_t dst = decal_buffer.size();
        decal_buffer.resize(dst + 16);
        float *DECAL = decal_buffer.ptrw();
        for (int k = 0; k < 16; ++k) {
            DECAL[dst + k] = BUF[src + k];
        }
    }

    const auto end_time = std::chrono::high_resolution_clock::now();
    out["ok"] = true;
    out["fallback"] = false;
    out["path"] = String("gdext_building_visual");
    out["instance_count"] = static_cast<int>(instances.size());
    out["decal_instance_count"] = decal_buffer.size() / 16;
    out["candidate_count"] = candidate_count;
    out["river_rejected"] = river_rejected;
    out["buffer"] = buffer;
    out["decal_buffer"] = decal_buffer;
    out["far_count"] = static_cast<int>(instances.size());
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(end_time - begin_time).count();
    return out;
}

} // namespace pk
