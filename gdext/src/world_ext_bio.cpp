#include "world_ext.h"
#include "economy_runtime.h"
#include "country_runtime.h"
#include "parallel_dispatcher.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <queue>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int32_t kLfMountain = 7;
constexpr int32_t kLfPeak = 8;
constexpr int32_t kLfDelta = 9;
constexpr int32_t kLfBadlands = 10;
constexpr int32_t kLfSaltFlat = 11;
constexpr int32_t kLfVolcano = 12;
constexpr int32_t kLfPlateau = 13;
constexpr float kCarrierEps = 0.0001f;
constexpr float kDiffusionKeep = 0.15f;
constexpr float kPersistClimateMargin = 0.12f;

constexpr int32_t kFlagNeedWetlandOrRiver = 1;
constexpr int32_t kFlagNeedHighland = 2;
constexpr int32_t kFlagForbidTropicalForest = 4;
constexpr int32_t kFlagNeedArid = 8;
constexpr int32_t kFlagNeedDryOrHighland = 16;
constexpr int32_t kFlagForbidArid = 32;
constexpr int32_t kFlagForbidWarm = 64;
constexpr int32_t kFlagForbidCold = 128;
constexpr int32_t kFlagNeedWetland = 256;

uint32_t bio_hash(uint32_t seed, uint32_t a, uint32_t b) {
    uint32_t h = seed ^ (a * 0x9e3779b9u) ^ (b * 0x85ebca6bu);
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return h;
}

float bio_unit(uint32_t h) {
    return float(h >> 8) * (1.0f / 16777216.0f);
}

bool veg_allowed(uint8_t veg, uint32_t mask0, uint32_t mask1) {
    if (mask0 == 0u && mask1 == 0u) return true;
    if (veg < 32u) return (mask0 & (1u << veg)) != 0u;
    if (veg < 64u) return (mask1 & (1u << (veg - 32u))) != 0u;
    return false;
}

bool veg_tropical_forest(uint8_t veg) {
    return veg == 12 || veg == 14 || veg == 15 || veg == 24 || veg == 25;
}

bool veg_wetland(uint8_t veg) {
    return veg == 19 || veg == 20 || veg == 21 || veg == 27;
}

bool veg_monsoon_forest(uint8_t veg) {
    return veg == 25;
}

bool veg_arid(uint8_t veg) {
    return veg == 10 || veg == 16 || veg == 17;
}

bool lf_highland(uint8_t lf, float elev) {
    return elev >= 0.40f || lf == 6 || lf == kLfMountain || lf == kLfPeak || lf == kLfPlateau;
}

bool lf_arid(uint8_t lf) {
    return lf == kLfBadlands || lf == kLfSaltFlat;
}

int32_t traversal_cost(uint8_t lf, uint8_t veg, uint8_t water) {
    if (water != 0) return 999;
    if (lf == kLfMountain || lf == kLfPeak || lf == kLfVolcano) return 8;
    if (lf == kLfBadlands || lf == kLfSaltFlat || veg_arid(veg)) return 3;
    if (lf == 6 || lf == kLfPlateau || lf == 15) return 2; // hill / plateau / canyon
    return 1;
}

struct SpeciesView {
    int32_t count = 0;
    std::vector<int32_t> signal_ids;
    std::vector<int32_t> bits;
    std::vector<int32_t> carrier;
    std::vector<int32_t> carrier_alt;
    std::vector<float> temp_lo;
    std::vector<float> temp_hi;
    std::vector<float> moist_lo;
    std::vector<float> moist_hi;
    std::vector<float> elev_lo;
    std::vector<float> elev_hi;
    std::vector<int32_t> veg0;
    std::vector<int32_t> veg1;
    std::vector<int32_t> flags;
    std::vector<int32_t> max_cost;
    std::vector<float> fill_keep;
    std::vector<int32_t> origin_policy;
    std::vector<int32_t> guild;
    std::vector<int32_t> habitat_class;
    std::array<int8_t, 32> bit_to_species{};
};

// One immutable catalog/topology cache per bound map. Component IDs are
// resolved once here so daily passes never parse stable strings or rebuild
// reserve columns across the GDScript boundary.
struct BioNativeConfigState {
    int32_t cell_count = 0;
    SpeciesView species;
    PackedInt32Array neighbors;
    std::vector<int32_t> reserve_slot_ids;
    int32_t water_slot = -1;
    int32_t vegetation_slot = -1;
    int32_t landform_slot = -1;
    int32_t river_slot = -1;
    int32_t temperature_slot = -1;
    int32_t moisture_slot = -1;
    int32_t elevation_slot = -1;
    int32_t province_slot = -1;
    int32_t occupancy_slot = -1;
};

template <typename T, typename Packed>
void copy_packed(const Packed &src, std::vector<T> &dst) {
    dst.resize(size_t(src.size()));
    if (!dst.empty()) std::memcpy(dst.data(), src.ptr(), dst.size() * sizeof(T));
}

bool load_species(const Dictionary &knobs, SpeciesView &sp, String &reason) {
    const PackedInt32Array bits = knobs.get("species_occupancy_bits", PackedInt32Array());
    const PackedInt32Array signals = knobs.get("species_signal_ids", PackedInt32Array());
    const PackedInt32Array carrier = knobs.get("species_carrier_index", PackedInt32Array());
    const PackedInt32Array carrier_alt = knobs.get("species_carrier_alt_index", PackedInt32Array());
    const PackedFloat32Array temp_lo = knobs.get("species_temp_lo", PackedFloat32Array());
    const PackedFloat32Array temp_hi = knobs.get("species_temp_hi", PackedFloat32Array());
    const PackedFloat32Array moist_lo = knobs.get("species_moist_lo", PackedFloat32Array());
    const PackedFloat32Array moist_hi = knobs.get("species_moist_hi", PackedFloat32Array());
    const PackedFloat32Array elev_lo = knobs.get("species_elev_lo", PackedFloat32Array());
    const PackedFloat32Array elev_hi = knobs.get("species_elev_hi", PackedFloat32Array());
    const PackedInt32Array veg0 = knobs.get("species_veg_mask0", PackedInt32Array());
    const PackedInt32Array veg1 = knobs.get("species_veg_mask1", PackedInt32Array());
    const PackedInt32Array flags = knobs.get("species_flags", PackedInt32Array());
    const PackedInt32Array max_cost = knobs.get("species_max_cost", PackedInt32Array());
    const PackedFloat32Array fill_keep = knobs.get("species_fill_keep", PackedFloat32Array());
    const int32_t n = bits.size();
    if (n <= 0 || n > 32 || signals.size() != n || carrier.size() != n ||
        carrier_alt.size() != n || temp_lo.size() != n || temp_hi.size() != n ||
        moist_lo.size() != n || moist_hi.size() != n || elev_lo.size() != n ||
        elev_hi.size() != n || veg0.size() != n || veg1.size() != n ||
        flags.size() != n || max_cost.size() != n || fill_keep.size() != n) {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    sp.count = n;
    sp.bit_to_species.fill(-1);
    copy_packed(signals, sp.signal_ids);
    copy_packed(bits, sp.bits);
    copy_packed(carrier, sp.carrier);
    copy_packed(carrier_alt, sp.carrier_alt);
    copy_packed(temp_lo, sp.temp_lo);
    copy_packed(temp_hi, sp.temp_hi);
    copy_packed(moist_lo, sp.moist_lo);
    copy_packed(moist_hi, sp.moist_hi);
    copy_packed(elev_lo, sp.elev_lo);
    copy_packed(elev_hi, sp.elev_hi);
    copy_packed(veg0, sp.veg0);
    copy_packed(veg1, sp.veg1);
    copy_packed(flags, sp.flags);
    copy_packed(max_cost, sp.max_cost);
    copy_packed(fill_keep, sp.fill_keep);
    for (int32_t species = 0; species < n; ++species) {
        const int32_t bit = sp.bits[size_t(species)];
        if (bit < 0 || bit >= 32 || sp.bit_to_species[size_t(bit)] >= 0) {
            reason = String("bio_species_bit_invalid_or_duplicate");
            return false;
        }
        sp.bit_to_species[size_t(bit)] = int8_t(species);
    }
    const PackedInt32Array origin_policy = knobs.get("species_origin_policy", PackedInt32Array());
    const PackedInt32Array guild = knobs.get("species_guild", PackedInt32Array());
    const PackedInt32Array habitat_class = knobs.get("species_habitat_class", PackedInt32Array());
    if (origin_policy.size() == n) {
        copy_packed(origin_policy, sp.origin_policy);
    } else if (origin_policy.size() == 0) {
        sp.origin_policy.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    if (guild.size() == n) {
        copy_packed(guild, sp.guild);
    } else if (guild.size() == 0) {
        sp.guild.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    if (habitat_class.size() == n) {
        copy_packed(habitat_class, sp.habitat_class);
    } else if (habitat_class.size() == 0) {
        sp.habitat_class.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    return true;
}

bool load_reserve_columns(const Dictionary &knobs, int n, int species_count,
                          const SpeciesView &sp,
                          std::vector<PackedFloat32Array> &columns,
                          String &reason) {
    const Array raw = knobs.get("carrier_reserves", Array());
    columns.clear();
    columns.resize(size_t(raw.size()));
    for (int i = 0; i < raw.size(); ++i) {
        const PackedFloat32Array col = raw[i];
        if (col.size() != n) {
            reason = String("bio_carrier_reserve_shape_invalid");
            return false;
        }
        columns[size_t(i)] = col;
    }
    for (int s = 0; s < species_count; ++s) {
        if (sp.carrier[s] >= int32_t(columns.size()) ||
            sp.carrier_alt[s] >= int32_t(columns.size())) {
            reason = String("bio_carrier_index_out_of_range");
            return false;
        }
    }
    return true;
}

// Daily occupancy continuation state.  All members are transient staging;
// MapData and the CELL_BIO_OCCUPANCY_BITS slot are touched only by the
// GDScript caller after `done=true` is returned from the final phase.
struct BioOccupancySliceState {
    int n = 0;
    int seed = 0;
    int day_index = 0;
    bool run_diffusion = false;
    bool slot_mode = false;
    int32_t occupancy_slot_id = -1;
    int phase = 0; // 0=persist, 1=diffusion, 2=merge, 3=publish
    int cursor = 0;
    double bridge_ms = 0.0;
    PackedByteArray water;
    PackedByteArray veg;
    PackedByteArray lf;
    PackedByteArray river;
    PackedFloat32Array temp;
    PackedFloat32Array moist;
    PackedFloat32Array elev;
    PackedInt32Array province;
    PackedInt32Array neighbors;
    PackedInt32Array introduce_cells;
    PackedInt32Array introduce_bits;
    SpeciesView species;
    std::vector<PackedFloat32Array> reserves;
    std::vector<int32_t> staging;
    std::vector<int32_t> previous;
    std::vector<int32_t> additions;
    std::vector<int32_t> output;
    std::vector<int32_t> newly_cells;
    std::vector<int32_t> newly_signals;
};

struct BioDiscoveryEmit {
    std::vector<int32_t> cells;
    std::vector<int32_t> signals;

    void merge_into(BioDiscoveryEmit &dst) const {
        dst.cells.insert(dst.cells.end(), cells.begin(), cells.end());
        dst.signals.insert(dst.signals.end(), signals.begin(), signals.end());
    }
};

bool envelope_ok(int cell, int species, const SpeciesView &sp,
                 const uint8_t *water, const uint8_t *veg, const uint8_t *lf,
                 const uint8_t *river, const float *temp, const float *moist,
                 const float *elev) {
    if (water[cell] != 0) return false;
    const float t = temp[cell];
    const float m = moist[cell];
    const float e = elev[cell];
    if (t < sp.temp_lo[species] || t > sp.temp_hi[species]) return false;
    if (m < sp.moist_lo[species] || m > sp.moist_hi[species]) return false;
    if (e < sp.elev_lo[species] || e > sp.elev_hi[species]) return false;
    if (!veg_allowed(veg[cell], uint32_t(sp.veg0[species]), uint32_t(sp.veg1[species])))
        return false;
    const int32_t flags = sp.flags[species];
    if ((flags & kFlagNeedWetlandOrRiver) != 0) {
        if (river[cell] == 0 && !veg_wetland(veg[cell]) && lf[cell] != kLfDelta)
            return false;
    }
    if ((flags & kFlagNeedWetland) != 0) {
        if (!veg_wetland(veg[cell]) && lf[cell] != kLfDelta && !veg_monsoon_forest(veg[cell]))
            return false;
    }
    if ((flags & kFlagNeedHighland) != 0 && !lf_highland(lf[cell], e))
        return false;
    if ((flags & kFlagForbidTropicalForest) != 0 && veg_tropical_forest(veg[cell]))
        return false;
    if ((flags & kFlagNeedArid) != 0 && !veg_arid(veg[cell]) && !lf_arid(lf[cell]) &&
        m > 0.38f)
        return false;
    if ((flags & kFlagNeedDryOrHighland) != 0 && m > 0.38f && !lf_highland(lf[cell], e))
        return false;
    if ((flags & kFlagForbidArid) != 0 && (veg_arid(veg[cell]) || lf_arid(lf[cell])))
        return false;
    if ((flags & kFlagForbidWarm) != 0 && t >= 0.62f) return false;
    if ((flags & kFlagForbidCold) != 0 && t <= 0.34f) return false;
    return true;
}

// Established stands: climate with margin only. Vegetation masks, habitat flags,
// and carrier reserves still gate seed / diffusion / introduce, not persistence.
bool persist_ok(int cell, int species, const SpeciesView &sp,
                const uint8_t *water, const float *temp, const float *moist,
                const float *elev) {
    if (water[cell] != 0) return false;
    const float t = temp[cell];
    const float m = moist[cell];
    const float e = elev[cell];
    if (t < sp.temp_lo[species] - kPersistClimateMargin ||
        t > sp.temp_hi[species] + kPersistClimateMargin)
        return false;
    if (m < sp.moist_lo[species] - kPersistClimateMargin ||
        m > sp.moist_hi[species] + kPersistClimateMargin)
        return false;
    if (e < sp.elev_lo[species] - 0.08f || e > sp.elev_hi[species] + 0.08f)
        return false;
    return true;
}

bool carrier_ok(int cell, int species, const SpeciesView &sp,
                const std::vector<PackedFloat32Array> &columns) {
    const int32_t primary = sp.carrier[species];
    if (primary < 0) return true;
    if (primary < int32_t(columns.size()) && columns[size_t(primary)][cell] > kCarrierEps)
        return true;
    const int32_t alt = sp.carrier_alt[species];
    if (alt >= 0 && alt < int32_t(columns.size()) &&
        columns[size_t(alt)][cell] > kCarrierEps)
        return true;
    return false;
}

int32_t species_index_for_bit(const SpeciesView &sp, int32_t bit) {
    return bit >= 0 && bit < 32 ? int32_t(sp.bit_to_species[size_t(bit)]) : -1;
}

int32_t lowest_bit_index(uint32_t bits) {
    int32_t bit = 0;
    while ((bits & 1u) == 0u) {
        bits >>= 1u;
        ++bit;
    }
    return bit;
}

constexpr int32_t kOriginHearth = 0;
constexpr int32_t kOriginCosmopolitan = 1;
constexpr int32_t kGuildFood = 1;
constexpr int32_t kGuildGrazer = 2;
constexpr int32_t kGuildFiber = 3;
constexpr int32_t kGuildSpecialty = 4;
constexpr int32_t kMaxNewOccupancyPerCell = 3;
constexpr int32_t kMinOriginEnvelope = 8;
constexpr int32_t kHabitatClassMax = 11;
constexpr int32_t kMinContinentCells = 8;
constexpr float kMinContinentShare = 0.18f;

void cell_cube(int cell, int width, int &q, int &r, int &s) {
    const int col = cell % width;
    const int row = cell / width;
    q = col - (row - (row & 1)) / 2;
    r = row;
    s = -q - r;
}

int hex_dist(int a, int b, int width, int n) {
    if (width <= 0 || n <= 0 || (n % width) != 0) {
        return std::abs(a - b);
    }
    int qa = 0, ra = 0, sa = 0, qb = 0, rb = 0, sb = 0;
    cell_cube(a, width, qa, ra, sa);
    cell_cube(b, width, qb, rb, sb);
    const int dq = qa - qb;
    const int dr = ra - rb;
    const int ds = sa - sb;
    const int d0 = (std::abs(dq) + std::abs(dr) + std::abs(ds)) / 2;
    const int d1 = (std::abs(dq - width) + std::abs(dr) + std::abs(ds + width)) / 2;
    const int d2 = (std::abs(dq + width) + std::abs(dr) + std::abs(ds - width)) / 2;
    return std::min(d0, std::min(d1, d2));
}

int32_t occupancy_count(int32_t bits) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_popcount(static_cast<uint32_t>(bits));
#else
    uint32_t value = static_cast<uint32_t>(bits);
    int32_t count = 0;
    while (value != 0u) {
        value &= value - 1u;
        ++count;
    }
    return count;
#endif
}

bool is_exclusive_natural_guild(int32_t guild) {
    return guild == kGuildFood || guild == kGuildGrazer ||
           guild == kGuildFiber || guild == kGuildSpecialty;
}

bool guild_slot_free(int cell, int species, const SpeciesView &sp, const int32_t *occ) {
    const int32_t guild = sp.guild[species];
    if (!is_exclusive_natural_guild(guild)) return true;
    const int32_t bits = occ[cell];
    if (bits == 0) return true;
    for (int s = 0; s < sp.count; ++s) {
        if (s == species || sp.guild[s] != guild) continue;
        const int32_t bit = sp.bits[s];
        if (bit < 0 || bit >= 32) continue;
        if ((bits & (1 << bit)) != 0) return false;
    }
    return true;
}

bool natural_slot_free(int cell, int species, const SpeciesView &sp,
                       const int32_t *occ) {
    const int32_t bit = sp.bits[species];
    const int32_t bits = occ[cell];
    if (bit >= 0 && bit < 32 &&
        (static_cast<uint32_t>(bits) & (uint32_t(1) << bit)) != 0u)
        return true;
    return occupancy_count(bits) < kMaxNewOccupancyPerCell &&
           guild_slot_free(cell, species, sp, occ);
}

int32_t merge_natural_candidates(int32_t cell, int32_t current,
                                 int32_t candidates, const SpeciesView &sp,
                                 int32_t seed, int32_t day_index) {
    uint32_t accepted = static_cast<uint32_t>(current);
    uint32_t pending = static_cast<uint32_t>(candidates) & ~accepted;
    while (pending != 0u && occupancy_count(int32_t(accepted)) < kMaxNewOccupancyPerCell) {
        int32_t selected_species = -1;
        int32_t selected_guild = std::numeric_limits<int32_t>::max();
        uint32_t selected_priority = std::numeric_limits<uint32_t>::max();
        uint32_t scan = pending;
        while (scan != 0u) {
            const int32_t bit = lowest_bit_index(scan);
            scan &= scan - 1u;
            const int32_t species = species_index_for_bit(sp, bit);
            if (species < 0) continue;
            const int32_t guild = sp.guild[size_t(species)];
            bool guild_free = true;
            if (is_exclusive_natural_guild(guild)) {
                for (int32_t other = 0; other < sp.count; ++other) {
                    if (other == species || sp.guild[size_t(other)] != guild) continue;
                    const int32_t other_bit = sp.bits[size_t(other)];
                    if ((accepted & (uint32_t(1) << other_bit)) != 0u) {
                        guild_free = false;
                        break;
                    }
                }
            }
            if (!guild_free) continue;
            const uint32_t priority = bio_hash(
                uint32_t(seed), uint32_t(day_index * 37 + species + 1), uint32_t(cell));
            if (guild < selected_guild ||
                (guild == selected_guild && priority < selected_priority) ||
                (guild == selected_guild && priority == selected_priority &&
                 species < selected_species)) {
                selected_species = species;
                selected_guild = guild;
                selected_priority = priority;
            }
        }
        if (selected_species < 0) break;
        const int32_t selected_bit = sp.bits[size_t(selected_species)];
        accepted |= uint32_t(1) << selected_bit;
        pending &= ~(uint32_t(1) << selected_bit);
        if (is_exclusive_natural_guild(selected_guild)) {
            uint32_t remove = pending;
            while (remove != 0u) {
                const int32_t bit = lowest_bit_index(remove);
                remove &= remove - 1u;
                const int32_t species = species_index_for_bit(sp, bit);
                if (species >= 0 && sp.guild[size_t(species)] == selected_guild)
                    pending &= ~(uint32_t(1) << bit);
            }
        }
    }
    return int32_t(accepted);
}

int pick_origin_cell(int species, int lid, int preferred, int n, int width,
                     const SpeciesView &sp, const int32_t *landmass,
                     const uint8_t *water, const uint8_t *veg, const uint8_t *lf,
                     const uint8_t *river, const float *temp, const float *moist,
                     const float *elev, const std::vector<PackedFloat32Array> &reserves,
                     const int32_t *occ) {
    if (preferred >= 0 && preferred < n && landmass[preferred] == lid &&
        envelope_ok(preferred, species, sp, water, veg, lf, river, temp, moist, elev) &&
        carrier_ok(preferred, species, sp, reserves) &&
        natural_slot_free(preferred, species, sp, occ)) {
        return preferred;
    }
    int best = -1;
    int best_d = 1 << 30;
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] != lid) continue;
        if (!envelope_ok(cell, species, sp, water, veg, lf, river, temp, moist, elev))
            continue;
        if (!carrier_ok(cell, species, sp, reserves)) continue;
        if (!natural_slot_free(cell, species, sp, occ)) continue;
        const int d = (preferred >= 0) ? hex_dist(cell, preferred, width, n) : 0;
        if (d < best_d) {
            best_d = d;
            best = cell;
        }
    }
    return best;
}

int32_t fill_landmass_envelope(int species, int lid, int n, int width, int seed,
                               const SpeciesView &sp, const int32_t *landmass,
                               const uint8_t *water, const uint8_t *veg,
                               const uint8_t *lf, const uint8_t *river,
                               const float *temp, const float *moist,
                               const float *elev,
                               const std::vector<PackedFloat32Array> &reserves,
                               const int32_t *neighbors, int origin,
                               int32_t *occ) {
    const int32_t bit = sp.bits[species];
    if (bit < 0 || bit >= 32) return 0;
    const uint32_t mask = uint32_t(1) << bit;
    std::vector<int32_t> eligible;
    eligible.reserve(256);
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] != lid) continue;
        if (!envelope_ok(cell, species, sp, water, veg, lf, river, temp, moist, elev))
            continue;
        if (!carrier_ok(cell, species, sp, reserves)) continue;
        if (!natural_slot_free(cell, species, sp, occ)) continue;
        eligible.push_back(cell);
    }
    if (eligible.empty()) return 0;

    const int32_t target = std::max<int32_t>(1, std::min<int32_t>(
        eligible.size(), int32_t(std::lround(
            float(eligible.size()) * std::clamp(sp.fill_keep[species], 0.0f, 1.0f)))));
    const int32_t radius = std::max(1, sp.max_cost[species]);
    // Cost-weighted patches can be narrow river/highland corridors rather than
    // full hex disks. Derive the core count from the requested fill quota and
    // propagation radius so those corridors still receive more than one
    // deterministic hearth, while retaining the hard 1..8 bound.
    const int32_t core_count = std::clamp<int32_t>(
        (target + radius - 1) / radius, 1, 8);

    std::vector<int32_t> cores;
    cores.reserve(size_t(core_count));
    if (origin < 0 || origin >= n || landmass[origin] != lid ||
        !natural_slot_free(origin, species, sp, occ))
        origin = eligible.front();
    cores.push_back(origin);
    while (int32_t(cores.size()) < core_count) {
        int32_t best = -1;
        int32_t best_distance = -1;
        uint32_t best_tie = 0u;
        for (int32_t cell : eligible) {
            int32_t nearest = std::numeric_limits<int32_t>::max();
            for (int32_t core : cores)
                nearest = std::min(nearest, hex_dist(cell, core, width, n));
            const uint32_t tie = bio_hash(uint32_t(seed), uint32_t(species + 1),
                                          uint32_t(cell));
            if (nearest > best_distance ||
                (nearest == best_distance && (best < 0 || tie > best_tie))) {
                best = cell;
                best_distance = nearest;
                best_tie = tie;
            }
        }
        if (best < 0 || std::find(cores.begin(), cores.end(), best) != cores.end()) break;
        cores.push_back(best);
    }

    struct PatchNode { int32_t cell; int32_t cost; uint32_t tie; };
    struct PatchNodeGreater {
        bool operator()(const PatchNode &a, const PatchNode &b) const {
            if (a.cost != b.cost) return a.cost > b.cost;
            if (a.tie != b.tie) return a.tie > b.tie;
            return a.cell > b.cell;
        }
    };
    std::priority_queue<PatchNode, std::vector<PatchNode>, PatchNodeGreater> queue;
    std::vector<int32_t> best_cost(size_t(n), std::numeric_limits<int32_t>::max());
    for (int32_t core : cores) {
        best_cost[size_t(core)] = 0;
        queue.push(PatchNode{core, 0,
            bio_hash(uint32_t(seed), uint32_t(species + 31), uint32_t(core))});
    }
    int32_t occupied = 0;
    while (!queue.empty() && occupied < target) {
        const PatchNode node = queue.top();
        queue.pop();
        if (node.cost != best_cost[size_t(node.cell)] || node.cost > radius) continue;
        if (landmass[node.cell] != lid ||
            !envelope_ok(node.cell, species, sp, water, veg, lf, river, temp, moist, elev) ||
            !carrier_ok(node.cell, species, sp, reserves))
            continue;
        if ((static_cast<uint32_t>(occ[node.cell]) & mask) == 0u) {
            if (!natural_slot_free(node.cell, species, sp, occ)) continue;
            occ[node.cell] = int32_t(static_cast<uint32_t>(occ[node.cell]) | mask);
            ++occupied;
        }
        const int32_t base = node.cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t next = neighbors[base + d];
            if (next < 0 || next >= n || landmass[next] != lid) continue;
            const int32_t richness = std::min(3, occupancy_count(occ[next]));
            const int32_t next_cost = node.cost + traversal_cost(lf[next], veg[next], water[next]) + richness;
            if (next_cost > radius || next_cost >= best_cost[size_t(next)]) continue;
            best_cost[size_t(next)] = next_cost;
            queue.push(PatchNode{next, next_cost,
                bio_hash(uint32_t(seed), uint32_t(species + 31), uint32_t(next))});
        }
    }
    return occupied;
}

bool landmass_has_guild(int lid, int guild, int n, const SpeciesView &sp,
                        const int32_t *landmass, const int32_t *occ) {
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] != lid) continue;
        const int32_t bits = occ[cell];
        if (bits == 0) continue;
        for (int s = 0; s < sp.count; ++s) {
            if (sp.guild[s] != guild) continue;
            const int32_t bit = sp.bits[s];
            if (bit >= 0 && bit < 32 && (bits & (1 << bit)) != 0) return true;
        }
    }
    return false;
}

bool landmass_has_species(int lid, int species, int n, const SpeciesView &sp,
                          const int32_t *landmass, const int32_t *occ) {
    const int32_t bit = sp.bits[species];
    if (bit < 0 || bit >= 32) return false;
    const int32_t mask = 1 << bit;
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] == lid && (occ[cell] & mask) != 0) return true;
    }
    return false;
}

int32_t habitat_class_of(const SpeciesView &sp, int species) {
    if (species < 0 || species >= sp.count || sp.habitat_class.empty()) return 0;
    const int32_t h = sp.habitat_class[size_t(species)];
    if (h <= 0 || h > kHabitatClassMax) return 0;
    return h;
}

} // namespace

void destroy_bio_occupancy_slice_state(void *state) {
    delete static_cast<BioOccupancySliceState *>(state);
}

void destroy_bio_native_config_state(void *state) {
    delete static_cast<BioNativeConfigState *>(state);
}

Dictionary DCWorldExt::_queue_bio_observations(
        int64_t country_handle, int64_t effective_day,
        const PackedInt32Array &cells, const PackedInt32Array &signals) {
    Dictionary out;
    out["ok"] = false;
    if (_country_runtime == nullptr || country_handle == 0 || effective_day < 0) {
        out["reason"] = String("bio_observation_country_unavailable");
        return out;
    }
    const Dictionary filtered = filter_bio_research_observations(cells, signals);
    if (!bool(filtered.get("ok", false))) return filtered;
    const PackedInt32Array eligible_cells = filtered.get(
        "observation_cells", PackedInt32Array());
    const PackedInt32Array eligible_signals = filtered.get(
        "observation_signals", PackedInt32Array());
    if (eligible_cells.is_empty()) {
        out["ok"] = true;
        out["submitted"] = 0;
        return out;
    }
    return static_cast<NativeCountryRuntime *>(_country_runtime)
        ->submit_observation_batch(country_handle, eligible_cells,
                                   eligible_signals, effective_day);
}

Dictionary DCWorldExt::configure_bio_occupancy(const Dictionary &config) {
    Dictionary out;
    out["ok"] = false;
    const int32_t n = int32_t(config.get("cell_count", 0));
    const PackedInt32Array neighbors = config.get(
        "neighbor_indices", PackedInt32Array());
    if (n <= 0 || n > 1000000 || neighbors.size() != int64_t(n) * 6) {
        out["reason"] = String("bio_config_shape_invalid");
        return out;
    }
    auto *next = new BioNativeConfigState();
    next->cell_count = n;
    next->neighbors = neighbors;
    String reason;
    if (!load_species(config, next->species, reason)) {
        delete next;
        out["reason"] = reason;
        return out;
    }
    const PackedStringArray reserve_names = config.get(
        "carrier_slot_names", PackedStringArray());
    next->reserve_slot_ids.reserve(size_t(reserve_names.size()));
    for (int32_t i = 0; i < reserve_names.size(); ++i) {
        const int32_t slot_id = component_id(StringName(reserve_names[i]));
        if (slot_id < 0 || slot_id >= _slots.size() ||
            _slots[slot_id].dtype != SlotDType::F32) {
            delete next;
            out["reason"] = String("bio_config_carrier_slot_missing");
            out["carrier_slot"] = reserve_names[i];
            return out;
        }
        next->reserve_slot_ids.push_back(slot_id);
    }
    for (int32_t s = 0; s < next->species.count; ++s) {
        if (next->species.carrier[size_t(s)] >= int32_t(next->reserve_slot_ids.size()) ||
            next->species.carrier_alt[size_t(s)] >= int32_t(next->reserve_slot_ids.size())) {
            delete next;
            out["reason"] = String("bio_config_carrier_index_out_of_range");
            return out;
        }
    }
    auto resolve = [&](const char *name, SlotDType dtype) -> int32_t {
        const int32_t id = component_id(StringName(name));
        if (id < 0 || id >= _slots.size() || _slots[id].dtype != dtype) return -1;
        return id;
    };
    next->water_slot = resolve("cell_is_water", SlotDType::U8);
    next->vegetation_slot = resolve("cell_vegetation", SlotDType::U8);
    next->landform_slot = resolve("cell_landform", SlotDType::U8);
    next->river_slot = resolve("cell_has_river", SlotDType::U8);
    next->temperature_slot = resolve("cell_temp_30d", SlotDType::F32);
    if (next->temperature_slot < 0)
        next->temperature_slot = resolve("cell_temp", SlotDType::F32);
    next->moisture_slot = resolve("cell_moisture", SlotDType::F32);
    next->elevation_slot = resolve("cell_elevation", SlotDType::F32);
    next->province_slot = resolve("cell_province_id", SlotDType::I32);
    next->occupancy_slot = resolve("cell_bio_occupancy_bits", SlotDType::I32);
    const std::array<int32_t, 9> required = {
        next->water_slot, next->vegetation_slot, next->landform_slot,
        next->river_slot, next->temperature_slot, next->moisture_slot,
        next->elevation_slot, next->province_slot, next->occupancy_slot};
    for (int32_t id : required) {
        if (id < 0) {
            delete next;
            out["reason"] = String("bio_config_core_slot_missing");
            return out;
        }
    }
    if (_bio_occupancy_slice_state != nullptr) {
        destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
        _bio_occupancy_slice_state = nullptr;
    }
    if (_bio_native_config_state != nullptr)
        destroy_bio_native_config_state(_bio_native_config_state);
    _bio_native_config_state = next;
    out["ok"] = true;
    out["cell_count"] = n;
    out["species_count"] = next->species.count;
    out["carrier_slot_count"] = int32_t(next->reserve_slot_ids.size());
    return out;
}

Dictionary DCWorldExt::run_bio_province_pass(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    const int width = int(knobs.get("width", 0));
    const int height = int(knobs.get("height", 0));
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (width <= 0 || height <= 0 || n64 <= 0 || n64 > 1000000) {
        out["reason"] = String("bio_province_dimensions_invalid");
        return out;
    }
    const int n = int(n64);
    const PackedByteArray water_arr = knobs.get("is_water", PackedByteArray());
    const PackedByteArray landform_arr = knobs.get("landform", PackedByteArray());
    const PackedByteArray vegetation_arr = knobs.get("vegetation", PackedByteArray());
    const PackedInt32Array neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    if (water_arr.size() != n || landform_arr.size() != n || vegetation_arr.size() != n ||
        neighbors.size() != n * 6) {
        out["reason"] = String("bio_province_input_shape_invalid");
        return out;
    }
    const uint8_t *water = water_arr.ptr();
    const uint8_t *lf = landform_arr.ptr();
    const uint8_t *veg = vegetation_arr.ptr();
    const int32_t *nb = neighbors.ptr();

    PackedInt32Array landmass;
    PackedInt32Array province;
    landmass.resize(n);
    province.resize(n);
    int32_t *lm = landmass.ptrw();
    int32_t *pv = province.ptrw();
    std::memset(lm, 0, size_t(n) * sizeof(int32_t));
    std::memset(pv, 0, size_t(n) * sizeof(int32_t));

    int32_t landmass_count = 0;
    std::vector<int32_t> stack;
    stack.reserve(size_t(n));
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || lm[cell] != 0) continue;
        ++landmass_count;
        stack.clear();
        stack.push_back(cell);
        lm[cell] = landmass_count;
        while (!stack.empty()) {
            const int32_t cur = stack.back();
            stack.pop_back();
            const int32_t base = cur * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nxt = nb[base + d];
                if (nxt < 0 || nxt >= n || water[nxt] != 0 || lm[nxt] != 0) continue;
                lm[nxt] = landmass_count;
                stack.push_back(nxt);
            }
        }
    }

    int32_t province_count = 0;
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || pv[cell] != 0) continue;
        if (traversal_cost(lf[cell], veg[cell], water[cell]) >= 8) continue;
        ++province_count;
        stack.clear();
        stack.push_back(cell);
        pv[cell] = province_count;
        while (!stack.empty()) {
            const int32_t cur = stack.back();
            stack.pop_back();
            const int32_t base = cur * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nxt = nb[base + d];
                if (nxt < 0 || nxt >= n || water[nxt] != 0 || pv[nxt] != 0) continue;
                if (lm[nxt] != lm[cur]) continue;
                if (traversal_cost(lf[nxt], veg[nxt], water[nxt]) >= 8) continue;
                pv[nxt] = province_count;
                stack.push_back(nxt);
            }
        }
    }

    std::queue<int32_t> q;
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) q.push(cell);
    }
    while (!q.empty()) {
        const int32_t cur = q.front();
        q.pop();
        const int32_t base = cur * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nxt = nb[base + d];
            if (nxt < 0 || nxt >= n || water[nxt] != 0 || pv[nxt] != 0) continue;
            if (lm[nxt] != lm[cur]) continue;
            pv[nxt] = pv[cur];
            q.push(nxt);
        }
    }
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || pv[cell] != 0) continue;
        ++province_count;
        pv[cell] = province_count;
    }

    std::vector<int32_t> parent(size_t(province_count + 1), 0);
    for (int32_t i = 1; i <= province_count; ++i) parent[size_t(i)] = i;
    auto find = [&](int32_t x) {
        while (parent[size_t(x)] != x) {
            parent[size_t(x)] = parent[size_t(parent[size_t(x)])];
            x = parent[size_t(x)];
        }
        return x;
    };
    auto unite = [&](int32_t a, int32_t b) {
        a = find(a);
        b = find(b);
        if (a != b) parent[size_t(a)] = b;
    };

    std::vector<int32_t> sizes(size_t(province_count + 1), 0);
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) sizes[size_t(pv[cell])] += 1;
    }
    std::vector<int32_t> border_count(size_t(province_count + 1) * size_t(province_count + 1), 0);
    for (int cell = 0; cell < n; ++cell) {
        const int32_t p = pv[cell];
        if (p <= 0) continue;
        const int32_t base = cell * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nxt = nb[base + d];
            if (nxt < 0 || nxt >= n) continue;
            const int32_t qid = pv[nxt];
            if (qid <= 0 || qid == p) continue;
            border_count[size_t(p) * size_t(province_count + 1) + size_t(qid)] += 1;
        }
    }
    std::vector<int32_t> best_neighbor(size_t(province_count + 1), 0);
    for (int32_t p = 1; p <= province_count; ++p) {
        int32_t best = 0;
        int32_t best_c = 0;
        for (int32_t qid = 1; qid <= province_count; ++qid) {
            if (qid == p) continue;
            const int32_t c = border_count[size_t(p) * size_t(province_count + 1) + size_t(qid)];
            if (c > best_c) {
                best_c = c;
                best = qid;
            }
        }
        best_neighbor[size_t(p)] = best;
    }
    constexpr int32_t kMinProvince = 8;
    for (int32_t p = 1; p <= province_count; ++p) {
        if (sizes[size_t(p)] >= kMinProvince) continue;
        const int32_t nb_p = best_neighbor[size_t(p)];
        if (nb_p > 0) unite(p, nb_p);
    }
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) pv[cell] = find(pv[cell]);
    }
    std::vector<int32_t> remap(size_t(province_count + 1), 0);
    int32_t compact = 0;
    for (int cell = 0; cell < n; ++cell) {
        const int32_t p = pv[cell];
        if (p <= 0) continue;
        if (remap[size_t(p)] == 0) remap[size_t(p)] = ++compact;
        pv[cell] = remap[size_t(p)];
    }

    out["ok"] = true;
    out["path"] = String("gdext");
    out["landmass_ids"] = landmass;
    out["province_ids"] = province;
    out["landmass_count"] = landmass_count;
    out["province_count"] = compact;
    return out;
}

Dictionary DCWorldExt::run_bio_bootstrap_pass(const Dictionary &knobs) {
    // Keep the generation-only topology arrays native between the two stages.
    // The legacy stage entry points remain available for PROBE parity and rollback.
    Dictionary province = run_bio_province_pass(knobs);
    if (!bool(province.get("ok", false))) return province;

    Dictionary seed_knobs = knobs.duplicate(false);
    seed_knobs["landmass_ids"] = province.get("landmass_ids", PackedInt32Array());
    seed_knobs["province_ids"] = province.get("province_ids", PackedInt32Array());
    Dictionary out = run_bio_seed_pass(seed_knobs);
    if (!bool(out.get("ok", false))) return out;

    out["landmass_ids"] = province.get("landmass_ids", PackedInt32Array());
    out["province_ids"] = province.get("province_ids", PackedInt32Array());
    out["landmass_count"] = province.get("landmass_count", 0);
    out["province_count"] = province.get("province_count", 0);
    out["path"] = String("gdext_fused_bootstrap");
    return out;
}

Dictionary DCWorldExt::run_bio_seed_pass(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    const int n = int(knobs.get("cell_count", 0));
    const int seed = int(knobs.get("seed", 0));
    if (n <= 0 || n > 1000000) {
        out["reason"] = String("bio_seed_cell_count_invalid");
        return out;
    }
    const PackedByteArray water_arr = knobs.get("is_water", PackedByteArray());
    const PackedByteArray veg_arr = knobs.get("vegetation", PackedByteArray());
    const PackedByteArray lf_arr = knobs.get("landform", PackedByteArray());
    const PackedByteArray river_arr = knobs.get("has_river", PackedByteArray());
    const PackedFloat32Array temp_arr = knobs.get("temperature", PackedFloat32Array());
    const PackedFloat32Array moist_arr = knobs.get("moisture", PackedFloat32Array());
    const PackedFloat32Array elev_arr = knobs.get("elevation", PackedFloat32Array());
    const PackedInt32Array province_arr = knobs.get("province_ids", PackedInt32Array());
    const PackedInt32Array landmass_arr = knobs.get("landmass_ids", PackedInt32Array());
    const PackedInt32Array neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    if (water_arr.size() != n || veg_arr.size() != n || lf_arr.size() != n ||
        river_arr.size() != n || temp_arr.size() != n || moist_arr.size() != n ||
        elev_arr.size() != n || province_arr.size() != n || landmass_arr.size() != n ||
        neighbors.size() != n * 6) {
        out["reason"] = String("bio_seed_input_shape_invalid");
        return out;
    }
    SpeciesView sp;
    String reason;
    if (!load_species(knobs, sp, reason)) {
        out["reason"] = reason;
        return out;
    }
    std::vector<PackedFloat32Array> reserves;
    if (!load_reserve_columns(knobs, n, sp.count, sp, reserves, reason)) {
        out["reason"] = reason;
        return out;
    }
    const uint8_t *water = water_arr.ptr();
    const uint8_t *veg = veg_arr.ptr();
    const uint8_t *lf = lf_arr.ptr();
    const uint8_t *river = river_arr.ptr();
    const float *temp = temp_arr.ptr();
    const float *moist = moist_arr.ptr();
    const float *elev = elev_arr.ptr();
    const int32_t *landmass = landmass_arr.ptr();
    const int width = int(knobs.get("width", 0));
    const int height = int(knobs.get("height", 0));
    const int hex_width = (width > 0 && height > 0 && width * height == n) ? width : 0;

    PackedInt32Array occupancy;
    occupancy.resize(n);
    int32_t *occ = occupancy.ptrw();
    std::memset(occ, 0, size_t(n) * sizeof(int32_t));

    int32_t max_landmass = 0;
    for (int cell = 0; cell < n; ++cell)
        max_landmass = std::max(max_landmass, landmass[cell]);

    std::vector<int32_t> landmass_size(size_t(max_landmass + 1), 0);
    for (int cell = 0; cell < n; ++cell) {
        const int32_t lid = landmass[cell];
        if (lid > 0) landmass_size[size_t(lid)] += 1;
    }
    int32_t largest_land = 0;
    for (int32_t lid = 1; lid <= max_landmass; ++lid)
        largest_land = std::max(largest_land, landmass_size[size_t(lid)]);
    const int32_t continent_floor = std::max(
        kMinContinentCells,
        int32_t(std::lround(float(largest_land) * kMinContinentShare)));

    std::vector<std::vector<int32_t>> weight(size_t(sp.count),
                                             std::vector<int32_t>(size_t(max_landmass + 1), 0));
    std::vector<std::vector<int32_t>> best_cell(size_t(sp.count),
                                                std::vector<int32_t>(size_t(max_landmass + 1), -1));
    PackedInt32Array envelope_counts;
    PackedInt32Array origin_envelope_counts;
    PackedInt32Array occupied_counts;
    PackedInt32Array origin_landmasses;
    PackedInt32Array seeded_landmass_counts;
    PackedInt32Array hearth_cell_counts;
    envelope_counts.resize(sp.count);
    origin_envelope_counts.resize(sp.count);
    occupied_counts.resize(sp.count);
    origin_landmasses.resize(sp.count);
    seeded_landmass_counts.resize(sp.count);
    hearth_cell_counts.resize(sp.count);
    int32_t *envelope_n = envelope_counts.ptrw();
    int32_t *origin_envelope_n = origin_envelope_counts.ptrw();
    int32_t *occupied_n = occupied_counts.ptrw();
    int32_t *origin_ids = origin_landmasses.ptrw();
    int32_t *seeded_n = seeded_landmass_counts.ptrw();
    int32_t *hearth_n = hearth_cell_counts.ptrw();
    std::memset(envelope_n, 0, size_t(sp.count) * sizeof(int32_t));
    std::memset(origin_envelope_n, 0, size_t(sp.count) * sizeof(int32_t));
    std::memset(occupied_n, 0, size_t(sp.count) * sizeof(int32_t));
    std::memset(origin_ids, 0, size_t(sp.count) * sizeof(int32_t));
    std::memset(seeded_n, 0, size_t(sp.count) * sizeof(int32_t));
    std::memset(hearth_n, 0, size_t(sp.count) * sizeof(int32_t));

    for (int s = 0; s < sp.count; ++s) {
        if (sp.bits[s] < 0 || sp.bits[s] >= 32) continue;
        int32_t env = 0;
        for (int cell = 0; cell < n; ++cell) {
            if (!envelope_ok(cell, s, sp, water, veg, lf, river, temp, moist, elev))
                continue;
            if (!carrier_ok(cell, s, sp, reserves)) continue;
            const int32_t lid = landmass[cell];
            if (lid <= 0) continue;
            env += 1;
            weight[size_t(s)][size_t(lid)] += 1;
            const int32_t prev = best_cell[size_t(s)][size_t(lid)];
            if (prev < 0) {
                best_cell[size_t(s)][size_t(lid)] = cell;
            } else {
                const float mid = 0.5f * (sp.temp_lo[s] + sp.temp_hi[s]);
                const float prev_fit = 1.0f - std::abs(temp[prev] - mid);
                const float cur_fit = 1.0f - std::abs(temp[cell] - mid);
                if (cur_fit > prev_fit) best_cell[size_t(s)][size_t(lid)] = cell;
            }
        }
        envelope_n[s] = env;
    }

    std::vector<int> order;
    order.reserve(size_t(sp.count));
    for (int s = 0; s < sp.count; ++s) order.push_back(s);
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        const bool ca = sp.origin_policy[a] == kOriginCosmopolitan;
        const bool cb = sp.origin_policy[b] == kOriginCosmopolitan;
        if (ca != cb) return !ca && cb;
        const float va = std::max(0.01f, sp.temp_hi[a] - sp.temp_lo[a]) *
                         std::max(0.01f, sp.moist_hi[a] - sp.moist_lo[a]) *
                         std::max(0.01f, sp.elev_hi[a] - sp.elev_lo[a]);
        const float vb = std::max(0.01f, sp.temp_hi[b] - sp.temp_lo[b]) *
                         std::max(0.01f, sp.moist_hi[b] - sp.moist_lo[b]) *
                         std::max(0.01f, sp.elev_hi[b] - sp.elev_lo[b]);
        if (va != vb) return va < vb;
        return a < b;
    });

    std::vector<std::vector<int32_t>> class_load(
        size_t(max_landmass + 1), std::vector<int32_t>(size_t(kHabitatClassMax + 1), 0));
    std::vector<int32_t> placed_core;
    std::vector<int32_t> placed_guild;
    std::vector<int32_t> placed_class;
    std::vector<int32_t> placed_lid;
    bool catalog_has_food = false;
    bool catalog_has_support = false;
    for (int s = 0; s < sp.count; ++s) {
        if (sp.guild[s] == kGuildFood) catalog_has_food = true;
        if (sp.guild[s] == kGuildGrazer || sp.guild[s] == kGuildFiber)
            catalog_has_support = true;
    }

    auto place_on_landmass = [&](int s, int32_t lid, bool secondary) {
        const int32_t w = weight[size_t(s)][size_t(lid)];
        const int preferred = best_cell[size_t(s)][size_t(lid)];
        if (w <= 0 || preferred < 0) return 0;
        const int origin = pick_origin_cell(s, lid, preferred, n, hex_width, sp, landmass,
                                            water, veg, lf, river, temp, moist, elev,
                                            reserves, occ);
        if (origin < 0) return 0;
        const int32_t added = fill_landmass_envelope(
            s, lid, n, hex_width, seed, sp, landmass, water, veg, lf, river, temp, moist,
            elev, reserves, neighbors.ptr(), origin, occ);
        if (added <= 0) return 0;
        occupied_n[s] += added;
        hearth_n[s] += added;
        seeded_n[s] += 1;
        const int32_t hclass = habitat_class_of(sp, s);
        if (hclass > 0) class_load[size_t(lid)][size_t(hclass)] += 1;
        placed_core.push_back(origin);
        placed_guild.push_back(sp.guild[s]);
        placed_class.push_back(hclass);
        placed_lid.push_back(lid);
        if (!secondary || origin_ids[s] == 0) {
            origin_ids[s] = lid;
            origin_envelope_n[s] = w;
        }
        return added;
    };

    int32_t secondary_hearths = 0;
    for (int s : order) {
        if (sp.bits[s] < 0 || sp.bits[s] >= 32) continue;
        if (sp.origin_policy[s] == kOriginCosmopolitan) {
            int32_t best_w = 0;
            for (int32_t lid = 1; lid <= max_landmass; ++lid)
                best_w = std::max(best_w, weight[size_t(s)][size_t(lid)]);
            if (best_w <= 0) continue;
            int32_t origin_landmass = 0;
            uint32_t tie_n = 0;
            for (int32_t lid = 1; lid <= max_landmass; ++lid) {
                if (weight[size_t(s)][size_t(lid)] == best_w) tie_n += 1;
            }
            const uint32_t pick = uint32_t(
                (uint64_t(bio_hash(uint32_t(seed), uint32_t(s + 1), 0xC0FFEEu)) *
                 uint64_t(std::max(1u, tie_n))) >> 32);
            uint32_t seen = 0;
            for (int32_t lid = 1; lid <= max_landmass; ++lid) {
                if (weight[size_t(s)][size_t(lid)] != best_w) continue;
                if (seen == pick) {
                    origin_landmass = lid;
                    break;
                }
                seen += 1;
            }
            origin_ids[s] = origin_landmass;
            origin_envelope_n[s] = weight[size_t(s)][size_t(origin_landmass)];
            int32_t occupied = 0;
            int32_t seeded = 0;
            const int32_t hclass = habitat_class_of(sp, s);
            for (int32_t lid = 1; lid <= max_landmass; ++lid) {
                const int32_t w = weight[size_t(s)][size_t(lid)];
                if (w <= 0) continue;
                const bool continent = landmass_size[size_t(lid)] >= continent_floor;
                const bool stand = w >= kMinOriginEnvelope;
                if (lid != origin_landmass && !(continent && stand)) continue;
                const int origin = best_cell[size_t(s)][size_t(lid)];
                occupied += fill_landmass_envelope(
                    s, lid, n, hex_width, seed, sp, landmass, water, veg, lf, river,
                    temp, moist, elev, reserves, neighbors.ptr(), origin, occ);
                seeded += 1;
                if (hclass > 0) class_load[size_t(lid)][size_t(hclass)] += 1;
            }
            occupied_n[s] = occupied;
            hearth_n[s] = occupied;
            seeded_n[s] = seeded;
            continue;
        }

        struct Cand {
            int32_t lid = 0;
            int core = -1;
            int32_t w = 0;
        };
        std::vector<Cand> cands;
        for (int32_t lid = 1; lid <= max_landmass; ++lid) {
            const int32_t w = weight[size_t(s)][size_t(lid)];
            if (w <= 0) continue;
            const bool continent = landmass_size[size_t(lid)] >= continent_floor;
            if (continent && w >= kMinOriginEnvelope) {
                cands.push_back(Cand{lid, best_cell[size_t(s)][size_t(lid)], w});
            }
        }
        if (cands.empty()) {
            int32_t best_w = 0;
            for (int32_t lid = 1; lid <= max_landmass; ++lid)
                best_w = std::max(best_w, weight[size_t(s)][size_t(lid)]);
            for (int32_t lid = 1; lid <= max_landmass; ++lid) {
                if (weight[size_t(s)][size_t(lid)] == best_w && best_w > 0) {
                    cands.push_back(Cand{lid, best_cell[size_t(s)][size_t(lid)],
                                         weight[size_t(s)][size_t(lid)]});
                }
            }
        }
        if (cands.empty()) continue;

        const int32_t hclass = habitat_class_of(sp, s);
        float best_score = -1.0e30f;
        int best_i = 0;
        for (int i = 0; i < int(cands.size()); ++i) {
            const Cand &c = cands[size_t(i)];
            float score = float(c.w);
            if (hclass > 0)
                score -= 80.0f * float(class_load[size_t(c.lid)][size_t(hclass)]);
            for (size_t p = 0; p < placed_core.size(); ++p) {
                const int d = std::max(1, hex_dist(c.core, placed_core[p], hex_width, n));
                float penalty = 48.0f / float(d);
                if (hclass > 0 && placed_class[p] == hclass) {
                    if (placed_lid[p] == c.lid) penalty *= 2.5f;
                    score -= penalty;
                } else if (placed_lid[p] == c.lid && placed_guild[p] != 0 &&
                           placed_guild[p] == sp.guild[s]) {
                    score -= penalty * 2.5f;
                }
            }
            const bool needs_food = catalog_has_food &&
                !landmass_has_guild(c.lid, kGuildFood, n, sp, landmass, occ);
            const bool needs_support = catalog_has_support &&
                !landmass_has_guild(c.lid, kGuildGrazer, n, sp, landmass, occ) &&
                !landmass_has_guild(c.lid, kGuildFiber, n, sp, landmass, occ);
            if (needs_food && sp.guild[s] == kGuildFood) score += 140.0f;
            if (needs_support && (sp.guild[s] == kGuildGrazer || sp.guild[s] == kGuildFiber))
                score += 90.0f;
            score += bio_unit(bio_hash(uint32_t(seed), uint32_t(s + 3), uint32_t(c.lid))) * 0.01f;
            if (score > best_score) {
                best_score = score;
                best_i = i;
            }
        }
        place_on_landmass(s, cands[size_t(best_i)].lid, false);
    }

    for (int32_t lid = 1; lid <= max_landmass; ++lid) {
        if (landmass_size[size_t(lid)] < continent_floor) continue;
        for (int32_t hclass = 1; hclass <= kHabitatClassMax; ++hclass) {
            if (class_load[size_t(lid)][size_t(hclass)] > 0) continue;
            int best_s = -1;
            int32_t best_w = 0;
            int best_unplaced = -1;
            for (int s = 0; s < sp.count; ++s) {
                if (habitat_class_of(sp, s) != hclass) continue;
                if (landmass_has_species(lid, s, n, sp, landmass, occ)) continue;
                const int32_t w = weight[size_t(s)][size_t(lid)];
                if (w < kMinOriginEnvelope) continue;
                const int unplaced = origin_ids[s] == 0 ? 1 : 0;
                if (unplaced > best_unplaced || (unplaced == best_unplaced && w > best_w)) {
                    best_unplaced = unplaced;
                    best_w = w;
                    best_s = s;
                }
            }
            if (best_s >= 0 && place_on_landmass(best_s, lid, true) > 0)
                secondary_hearths += 1;
        }
        if (catalog_has_food && !landmass_has_guild(lid, kGuildFood, n, sp, landmass, occ)) {
            int best_s = -1;
            int32_t best_w = 0;
            for (int s = 0; s < sp.count; ++s) {
                if (sp.guild[s] != kGuildFood) continue;
                if (landmass_has_species(lid, s, n, sp, landmass, occ)) continue;
                const int32_t w = weight[size_t(s)][size_t(lid)];
                if (w > best_w) {
                    best_w = w;
                    best_s = s;
                }
            }
            if (best_s >= 0 && place_on_landmass(best_s, lid, true) > 0)
                secondary_hearths += 1;
        }
        const bool has_support =
            landmass_has_guild(lid, kGuildGrazer, n, sp, landmass, occ) ||
            landmass_has_guild(lid, kGuildFiber, n, sp, landmass, occ);
        if (catalog_has_support && !has_support) {
            int best_s = -1;
            int32_t best_w = 0;
            for (int s = 0; s < sp.count; ++s) {
                if (sp.guild[s] != kGuildGrazer && sp.guild[s] != kGuildFiber) continue;
                if (landmass_has_species(lid, s, n, sp, landmass, occ)) continue;
                const int32_t w = weight[size_t(s)][size_t(lid)];
                if (w > best_w) {
                    best_w = w;
                    best_s = s;
                }
            }
            if (best_s >= 0 && place_on_landmass(best_s, lid, true) > 0)
                secondary_hearths += 1;
        }
    }

    out["ok"] = true;
    out["path"] = String("gdext");
    out["occupancy_bits"] = occupancy;
    out["envelope_cell_counts"] = envelope_counts;
    out["origin_envelope_cell_counts"] = origin_envelope_counts;
    out["occupied_cell_counts"] = occupied_counts;
    out["origin_landmass_ids"] = origin_landmasses;
    out["seeded_landmass_counts"] = seeded_landmass_counts;
    out["hearth_cell_counts"] = hearth_cell_counts;
    out["secondary_hearth_count"] = secondary_hearths;
    return out;
}

Dictionary DCWorldExt::run_bio_occupancy_slice(const Dictionary &knobs) {
    const auto total_started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [](const auto &started) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
    };
    Dictionary out;
    out["ok"] = false;
    const int n = int(knobs.get("cell_count", 0));
    const int seed = int(knobs.get("seed", 0));
    const int day_index = int(knobs.get("day_index", 0));
    const bool run_diffusion = bool(knobs.get("run_diffusion", false));
    const int requested_slice_cells = int(knobs.get("bio_slice_cells", 1024));
    const int slice_cells = std::clamp(requested_slice_cells, 64, 32768);
    auto fail = [&](const String &reason, const char *stage) {
        out["reason"] = reason;
        out["fallback_reason"] = reason;
        out["fail_stage"] = String(stage);
        out["path"] = String("gdext_sliced_failed");
        if (_bio_occupancy_slice_state != nullptr) {
            destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
            _bio_occupancy_slice_state = nullptr;
        }
        return out;
    };
    if (n <= 0 || n > 1000000)
        return fail(String("bio_occupancy_cell_count_invalid"), "validate");

    BioOccupancySliceState *state =
        static_cast<BioOccupancySliceState *>(_bio_occupancy_slice_state);
    const bool new_state = state == nullptr || state->n != n ||
        state->seed != seed || state->day_index != day_index ||
        state->run_diffusion != run_diffusion;
    const auto bridge_started = std::chrono::steady_clock::now();
    if (new_state) {
        if (state != nullptr) {
            destroy_bio_occupancy_slice_state(state);
            state = nullptr;
            _bio_occupancy_slice_state = nullptr;
        }
        state = new BioOccupancySliceState();
        state->n = n;
        state->seed = seed;
        state->day_index = day_index;
        state->run_diffusion = run_diffusion;
        BioNativeConfigState *native_config =
            static_cast<BioNativeConfigState *>(_bio_native_config_state);
        state->slot_mode = bool(knobs.get("use_configured_slots", false)) &&
            native_config != nullptr && native_config->cell_count == n;
        PackedInt32Array occupancy;
        if (state->slot_mode) {
            state->water = _slots[native_config->water_slot].arr_u8;
            state->veg = _slots[native_config->vegetation_slot].arr_u8;
            state->lf = _slots[native_config->landform_slot].arr_u8;
            state->river = _slots[native_config->river_slot].arr_u8;
            state->temp = _slots[native_config->temperature_slot].arr_f32;
            state->moist = _slots[native_config->moisture_slot].arr_f32;
            state->elev = _slots[native_config->elevation_slot].arr_f32;
            state->province = _slots[native_config->province_slot].arr_i32;
            state->neighbors = native_config->neighbors;
            state->occupancy_slot_id = native_config->occupancy_slot;
            occupancy = _slots[state->occupancy_slot_id].arr_i32;
            state->species = native_config->species;
            state->reserves.reserve(native_config->reserve_slot_ids.size());
            for (int32_t slot_id : native_config->reserve_slot_ids)
                state->reserves.push_back(_slots[slot_id].arr_f32);
        } else {
            state->water = knobs.get("is_water", PackedByteArray());
            state->veg = knobs.get("vegetation", PackedByteArray());
            state->lf = knobs.get("landform", PackedByteArray());
            state->river = knobs.get("has_river", PackedByteArray());
            state->temp = knobs.get("temperature", PackedFloat32Array());
            state->moist = knobs.get("moisture", PackedFloat32Array());
            state->elev = knobs.get("elevation", PackedFloat32Array());
            state->province = knobs.get("province_ids", PackedInt32Array());
            state->neighbors = knobs.get("neighbor_indices", PackedInt32Array());
            occupancy = knobs.get("occupancy_bits", PackedInt32Array());
        }
        if (state->water.size() != n || state->veg.size() != n ||
            state->lf.size() != n || state->river.size() != n ||
            state->temp.size() != n || state->moist.size() != n ||
            state->elev.size() != n || state->province.size() != n ||
            state->neighbors.size() != n * 6 || occupancy.size() != n) {
            return fail(String("bio_occupancy_input_shape_invalid"), "validate");
        }
        String reason;
        if (!state->slot_mode) {
            if (!load_species(knobs, state->species, reason))
                return fail(reason, "species");
            if (!load_reserve_columns(knobs, n, state->species.count,
                                      state->species, state->reserves, reason))
                return fail(reason, "reserve");
        } else {
            for (const PackedFloat32Array &reserve : state->reserves) {
                if (reserve.size() != n)
                    return fail(String("bio_configured_reserve_shape_invalid"), "reserve");
            }
        }
        state->introduce_cells = knobs.get("introduce_cells", PackedInt32Array());
        state->introduce_bits = knobs.get("introduce_bits", PackedInt32Array());
        if (_economy_runtime != nullptr) {
            PackedInt32Array extra_cells;
            PackedInt32Array extra_bits;
            static_cast<NativeEconomyRuntime *>(_economy_runtime)
                ->drain_bio_introduces(extra_cells, extra_bits);
            if (extra_cells.size() == extra_bits.size() && extra_cells.size() > 0) {
                const int32_t old = state->introduce_cells.size();
                state->introduce_cells.resize(old + extra_cells.size());
                state->introduce_bits.resize(old + extra_bits.size());
                int32_t *cell_ptr = state->introduce_cells.ptrw();
                int32_t *bit_ptr = state->introduce_bits.ptrw();
                for (int i = 0; i < extra_cells.size(); ++i) {
                    cell_ptr[old + i] = extra_cells[i];
                    bit_ptr[old + i] = extra_bits[i];
                }
            }
        }
        if (state->introduce_cells.size() != state->introduce_bits.size())
            return fail(String("bio_introduce_shape_invalid"), "validate");

        state->staging.resize(static_cast<size_t>(n));
        state->previous.resize(static_cast<size_t>(n));
        state->additions.assign(static_cast<size_t>(n), 0);
        state->output.assign(static_cast<size_t>(n), 0);
        const int32_t *occupancy_ptr = occupancy.ptr();
        for (int cell = 0; cell < n; ++cell) {
            state->staging[static_cast<size_t>(cell)] = occupancy_ptr[cell];
            state->previous[static_cast<size_t>(cell)] = occupancy_ptr[cell];
        }
        state->bridge_ms = elapsed_ms(bridge_started);
        _bio_occupancy_slice_state = state;
    }

    const auto compute_started = std::chrono::steady_clock::now();
    const uint8_t *water = state->water.ptr();
    const uint8_t *veg = state->veg.ptr();
    const uint8_t *lf = state->lf.ptr();
    const uint8_t *river = state->river.ptr();
    const float *temp = state->temp.ptr();
    const float *moist = state->moist.ptr();
    const float *elev = state->elev.ptr();
    const int32_t *province = state->province.ptr();
    const int32_t *nb = state->neighbors.ptr();
    const int start = state->cursor;
    const int end = std::min(n, start + slice_cells);

    if (state->phase == 0) {
        for (int cell = start; cell < end; ++cell) {
            int32_t bits = state->staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t species = species_index_for_bit(state->species, bit);
                if (species >= 0 && !persist_ok(
                        cell, species, state->species, water, temp, moist, elev))
                    bits = int32_t(static_cast<uint32_t>(bits) & ~(uint32_t(1) << bit));
            }
            state->staging[static_cast<size_t>(cell)] = bits;
        }
        state->cursor = end;
        if (state->cursor >= n) {
            // Introduction is intentionally after persistence, matching the
            // one-shot pass.  It is a bounded event list, not a cell scan.
            for (int i = 0; i < state->introduce_cells.size(); ++i) {
                const int32_t cell = state->introduce_cells[i];
                const int32_t bit = state->introduce_bits[i];
                if (cell < 0 || cell >= n || bit < 0 || bit >= 32) continue;
                const int32_t species = species_index_for_bit(state->species, bit);
                if (species < 0 || !envelope_ok(cell, species, state->species,
                        water, veg, lf, river, temp, moist, elev) ||
                    !carrier_ok(cell, species, state->species, state->reserves))
                    continue;
                const uint32_t mask = uint32_t(1) << bit;
                const int32_t current = state->staging[static_cast<size_t>(cell)];
                if ((static_cast<uint32_t>(current) & mask) != 0u ||
                    occupancy_count(current) < kMaxNewOccupancyPerCell)
                    state->staging[static_cast<size_t>(cell)] =
                        int32_t(static_cast<uint32_t>(current) | mask);
            }
            state->cursor = 0;
            state->phase = state->run_diffusion ? 1 : 3;
        }
    } else if (state->phase == 1) {
        for (int cell = start; cell < end; ++cell) {
            const int32_t bits = state->staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            const int32_t pid = province[cell];
            const int32_t base = cell * 6;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t s = species_index_for_bit(state->species, bit);
                if (s < 0) continue;
                const int32_t mask = int32_t(uint32_t(1) << bit);
                for (int d = 0; d < 6; ++d) {
                    const int32_t nxt = nb[base + d];
                    if (nxt < 0 || nxt >= n ||
                        (state->staging[static_cast<size_t>(nxt)] & mask) != 0 ||
                        pid <= 0 || province[nxt] != pid ||
                        !envelope_ok(nxt, s, state->species, water, veg, lf,
                                     river, temp, moist, elev) ||
                        !carrier_ok(nxt, s, state->species, state->reserves))
                        continue;
                    if (bio_unit(bio_hash(uint32_t(seed),
                            uint32_t(day_index * 17 + s + 3), uint32_t(nxt))) <
                        kDiffusionKeep)
                        state->additions[static_cast<size_t>(nxt)] |= mask;
                }
            }
        }
        state->cursor = end;
        if (state->cursor >= n) {
            state->cursor = 0;
            state->phase = 2;
        }
    } else if (state->phase == 2) {
        for (int cell = start; cell < end; ++cell)
            state->staging[static_cast<size_t>(cell)] = merge_natural_candidates(
                cell, state->staging[static_cast<size_t>(cell)],
                state->additions[static_cast<size_t>(cell)], state->species,
                state->seed, state->day_index);
        state->cursor = end;
        if (state->cursor >= n) {
            state->cursor = 0;
            state->phase = 3;
        }
    } else {
        for (int cell = start; cell < end; ++cell) {
            const int32_t next_bits = state->staging[static_cast<size_t>(cell)];
            state->output[static_cast<size_t>(cell)] = next_bits;
            const int32_t added = next_bits &
                ~state->previous[static_cast<size_t>(cell)];
            if (added == 0) continue;
            for (int s = 0; s < state->species.count; ++s) {
                const int32_t bit = state->species.bits[s];
                if (bit >= 0 && bit < 32 && (added & (1 << bit)) != 0) {
                    state->newly_cells.push_back(cell);
                    state->newly_signals.push_back(state->species.signal_ids[s]);
                }
            }
        }
        state->cursor = end;
    }

    const bool done = state->phase == 3 && state->cursor >= n;
    const double compute_ms = elapsed_ms(compute_started);
    out["ok"] = true;
    out["path"] = String("gdext_sliced");
    out["done"] = done;
    out["slice_done"] = done;
    out["slice_phase"] = state->phase;
    out["slice_cursor"] = state->cursor;
    out["slice_cursor_start"] = start;
    out["slice_cursor_end"] = end;
    out["slice_cursor_total"] = n;
    out["processed_cells"] = end - start;
    out["native_compute_ms"] = compute_ms;
    out["bio_slice_native_ms"] = compute_ms;
    out["bridge_ms"] = new_state ? state->bridge_ms : 0.0;
    out["publish_ms"] = 0.0;
    out["bio_slice_publish_ms"] = 0.0;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = false;
    out["slice_enabled"] = true;
    out["progress_ratio"] = done ? 1.0 :
        float(state->phase * n + state->cursor) / float(4 * n);
    if (!done) return out;

    const auto publish_started = std::chrono::steady_clock::now();
    PackedInt32Array occupancy_out;
    if (state->slot_mode) {
        int32_t *occupancy_slot_ptr =
            _slots.write[state->occupancy_slot_id].arr_i32.ptrw();
        std::memcpy(occupancy_slot_ptr, state->output.data(),
                    static_cast<size_t>(n) * sizeof(int32_t));
        _flush_slot_to_map(state->occupancy_slot_id);
    } else {
        occupancy_out.resize(n);
        std::memcpy(occupancy_out.ptrw(), state->output.data(),
                    static_cast<size_t>(n) * sizeof(int32_t));
    }
    PackedInt32Array newly_cells;
    PackedInt32Array newly_signals;
    newly_cells.resize(static_cast<int64_t>(state->newly_cells.size()));
    newly_signals.resize(static_cast<int64_t>(state->newly_signals.size()));
    for (size_t i = 0; i < state->newly_cells.size(); ++i) {
        newly_cells.ptrw()[i] = state->newly_cells[i];
        newly_signals.ptrw()[i] = state->newly_signals[i];
    }
    const double publish_ms = elapsed_ms(publish_started);
    if (!state->slot_mode) out["occupancy_bits"] = occupancy_out;
    out["newly_occupied_cells"] = newly_cells;
    out["newly_occupied_signal_ids"] = newly_signals;
    out["publish_ms"] = publish_ms;
    out["bio_slice_publish_ms"] = publish_ms;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = state->slot_mode;
    out["configured_slot_fastpath"] = state->slot_mode;
    const int64_t observation_handle = int64_t(
        knobs.get("observation_country_handle", int64_t(0)));
    if (observation_handle != 0) {
        const Dictionary evidence = _queue_bio_observations(
            observation_handle,
            int64_t(knobs.get("observation_effective_day", int64_t(0))),
            newly_cells, newly_signals);
        out["native_evidence_submission"] = bool(evidence.get("ok", false));
        out["native_evidence_submitted"] = int64_t(evidence.get("submitted", 0));
    }
    destroy_bio_occupancy_slice_state(state);
    _bio_occupancy_slice_state = nullptr;
    return out;
}

Dictionary DCWorldExt::run_bio_occupancy_pass(const Dictionary &knobs) {
    if (_bio_occupancy_slice_state != nullptr) {
        destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
        _bio_occupancy_slice_state = nullptr;
    }
    const auto total_started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [](const auto &started) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
    };
    const auto bridge_started = std::chrono::steady_clock::now();
    Dictionary out;
    out["ok"] = false;
    const int n = int(knobs.get("cell_count", 0));
    const int seed = int(knobs.get("seed", 0));
    const int day_index = int(knobs.get("day_index", 0));
    const bool run_diffusion = bool(knobs.get("run_diffusion", false));
    if (n <= 0 || n > 1000000) {
        out["reason"] = String("bio_occupancy_cell_count_invalid");
        return out;
    }
    BioNativeConfigState *native_config =
        static_cast<BioNativeConfigState *>(_bio_native_config_state);
    const bool slot_mode = bool(knobs.get("use_configured_slots", false)) &&
        native_config != nullptr && native_config->cell_count == n;
    PackedByteArray water_arr;
    PackedByteArray veg_arr;
    PackedByteArray lf_arr;
    PackedByteArray river_arr;
    PackedFloat32Array temp_arr;
    PackedFloat32Array moist_arr;
    PackedFloat32Array elev_arr;
    PackedInt32Array province_arr;
    PackedInt32Array neighbors;
    PackedInt32Array occupancy;
    SpeciesView legacy_species;
    const SpeciesView *species_view = nullptr;
    std::vector<PackedFloat32Array> reserves;
    int32_t occupancy_slot_id = -1;
    if (slot_mode) {
        water_arr = _slots[native_config->water_slot].arr_u8;
        veg_arr = _slots[native_config->vegetation_slot].arr_u8;
        lf_arr = _slots[native_config->landform_slot].arr_u8;
        river_arr = _slots[native_config->river_slot].arr_u8;
        temp_arr = _slots[native_config->temperature_slot].arr_f32;
        moist_arr = _slots[native_config->moisture_slot].arr_f32;
        elev_arr = _slots[native_config->elevation_slot].arr_f32;
        province_arr = _slots[native_config->province_slot].arr_i32;
        neighbors = native_config->neighbors;
        occupancy_slot_id = native_config->occupancy_slot;
        occupancy = _slots[occupancy_slot_id].arr_i32;
        species_view = &native_config->species;
        reserves.reserve(native_config->reserve_slot_ids.size());
        for (int32_t slot_id : native_config->reserve_slot_ids)
            reserves.push_back(_slots[slot_id].arr_f32);
    } else {
        water_arr = knobs.get("is_water", PackedByteArray());
        veg_arr = knobs.get("vegetation", PackedByteArray());
        lf_arr = knobs.get("landform", PackedByteArray());
        river_arr = knobs.get("has_river", PackedByteArray());
        temp_arr = knobs.get("temperature", PackedFloat32Array());
        moist_arr = knobs.get("moisture", PackedFloat32Array());
        elev_arr = knobs.get("elevation", PackedFloat32Array());
        province_arr = knobs.get("province_ids", PackedInt32Array());
        neighbors = knobs.get("neighbor_indices", PackedInt32Array());
        occupancy = knobs.get("occupancy_bits", PackedInt32Array());
    }
    if (water_arr.size() != n || veg_arr.size() != n || lf_arr.size() != n ||
        river_arr.size() != n || temp_arr.size() != n || moist_arr.size() != n ||
        elev_arr.size() != n || province_arr.size() != n || neighbors.size() != n * 6 ||
        occupancy.size() != n) {
        out["reason"] = String("bio_occupancy_input_shape_invalid");
        return out;
    }
    String reason;
    if (!slot_mode) {
        if (!load_species(knobs, legacy_species, reason)) {
            out["reason"] = reason;
            return out;
        }
        species_view = &legacy_species;
        if (!load_reserve_columns(knobs, n, legacy_species.count,
                                  legacy_species, reserves, reason)) {
            out["reason"] = reason;
            return out;
        }
    } else {
        for (const PackedFloat32Array &reserve : reserves) {
            if (reserve.size() != n) {
                out["reason"] = String("bio_configured_reserve_shape_invalid");
                return out;
            }
        }
    }
    const SpeciesView &sp = *species_view;
    PackedInt32Array intro_cells = knobs.get("introduce_cells", PackedInt32Array());
    PackedInt32Array intro_bits = knobs.get("introduce_bits", PackedInt32Array());
    if (_economy_runtime != nullptr) {
        PackedInt32Array extra_cells;
        PackedInt32Array extra_bits;
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->drain_bio_introduces(extra_cells, extra_bits);
        if (extra_cells.size() == extra_bits.size() && extra_cells.size() > 0) {
            const int32_t old = intro_cells.size();
            intro_cells.resize(old + extra_cells.size());
            intro_bits.resize(old + extra_bits.size());
            int32_t *intro_cell_ptr = intro_cells.ptrw();
            int32_t *intro_bit_ptr = intro_bits.ptrw();
            const int32_t *extra_cell_ptr = extra_cells.ptr();
            const int32_t *extra_bit_ptr = extra_bits.ptr();
            for (int i = 0; i < extra_cells.size(); ++i) {
                intro_cell_ptr[old + i] = extra_cell_ptr[i];
                intro_bit_ptr[old + i] = extra_bit_ptr[i];
            }
        }
    }
    if (intro_cells.size() != intro_bits.size()) {
        out["reason"] = String("bio_introduce_shape_invalid");
        return out;
    }

    const double bridge_ms = elapsed_ms(bridge_started);

    const uint8_t *water = water_arr.ptr();
    const uint8_t *veg = veg_arr.ptr();
    const uint8_t *lf = lf_arr.ptr();
    const uint8_t *river = river_arr.ptr();
    const float *temp = temp_arr.ptr();
    const float *moist = moist_arr.ptr();
    const float *elev = elev_arr.ptr();
    const int32_t *province = province_arr.ptr();
    const int32_t *nb = neighbors.ptr();
    const auto compute_started = std::chrono::steady_clock::now();
    _bio_occupancy_bits_staging.resize(static_cast<size_t>(n));
    _bio_occupancy_previous.resize(static_cast<size_t>(n));
    for (int cell = 0; cell < n; ++cell) {
        const int32_t value = occupancy[cell];
        _bio_occupancy_bits_staging[static_cast<size_t>(cell)] = value;
        _bio_occupancy_previous[static_cast<size_t>(cell)] = value;
    }

    auto persistence_range = [&](int begin, int end) {
        for (int cell = begin; cell < end; ++cell) {
            int32_t bits = _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t species = species_index_for_bit(sp, bit);
                if (species >= 0 && !persist_ok(
                        cell, species, sp, water, temp, moist, elev))
                    bits = int32_t(static_cast<uint32_t>(bits) &
                                   ~(uint32_t(1) << bit));
            }
            _bio_occupancy_bits_staging[static_cast<size_t>(cell)] = bits;
        }
    };
    parallel_for_range("pk_bio_persistence", n, 0, 16384, persistence_range);

    for (int i = 0; i < intro_cells.size(); ++i) {
        const int32_t cell = intro_cells[i];
        const int32_t bit = intro_bits[i];
        if (cell < 0 || cell >= n || bit < 0 || bit >= 32) continue;
        const int32_t s = species_index_for_bit(sp, bit);
        if (s < 0) continue;
        if (!envelope_ok(cell, s, sp, water, veg, lf, river, temp, moist, elev)) continue;
        if (!carrier_ok(cell, s, sp, reserves)) continue;
        const uint32_t mask = uint32_t(1) << bit;
        const int32_t current = _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
        if ((static_cast<uint32_t>(current) & mask) != 0u ||
            occupancy_count(current) < kMaxNewOccupancyPerCell)
            _bio_occupancy_bits_staging[static_cast<size_t>(cell)] =
                int32_t(static_cast<uint32_t>(current) | mask);
    }

    if (run_diffusion) {
        _bio_occupancy_additions.resize(static_cast<size_t>(n));
        std::fill(_bio_occupancy_additions.begin(),
                  _bio_occupancy_additions.end(), 0);
        // Target-owned proposal lanes avoid atomic OR and thread-local n-cell
        // buffers: every worker reads the frozen persistence result and writes
        // exactly one additions[target] lane.
        auto proposal_range = [&](int begin, int end) {
            for (int target = begin; target < end; ++target) {
                const int32_t pid = province[target];
                if (pid <= 0) continue;
                uint32_t candidates = 0u;
                const uint32_t current = static_cast<uint32_t>(
                    _bio_occupancy_bits_staging[static_cast<size_t>(target)]);
                const int32_t base = target * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t source = nb[base + d];
                    if (source < 0 || source >= n || province[source] != pid) continue;
                    uint32_t scan = static_cast<uint32_t>(
                        _bio_occupancy_bits_staging[static_cast<size_t>(source)]);
                    while (scan != 0u) {
                        const int32_t bit = lowest_bit_index(scan);
                        scan &= scan - 1u;
                        const uint32_t mask = uint32_t(1) << bit;
                        if ((current & mask) != 0u || (candidates & mask) != 0u) continue;
                        const int32_t s = species_index_for_bit(sp, bit);
                        if (s < 0 || !envelope_ok(target, s, sp, water, veg, lf,
                                river, temp, moist, elev) ||
                            !carrier_ok(target, s, sp, reserves))
                            continue;
                        if (bio_unit(bio_hash(uint32_t(seed),
                                uint32_t(day_index * 17 + s + 3),
                                uint32_t(target))) < kDiffusionKeep)
                            candidates |= mask;
                    }
                }
                _bio_occupancy_additions[static_cast<size_t>(target)] =
                    int32_t(candidates);
            }
        };
        parallel_for_range("pk_bio_proposals", n, 0, 16384, proposal_range);
        auto merge_range = [&](int begin, int end) {
            for (int cell = begin; cell < end; ++cell) {
                _bio_occupancy_bits_staging[static_cast<size_t>(cell)] =
                    merge_natural_candidates(
                        cell, _bio_occupancy_bits_staging[static_cast<size_t>(cell)],
                        _bio_occupancy_additions[static_cast<size_t>(cell)], sp,
                        seed, day_index);
            }
        };
        parallel_for_range("pk_bio_merge", n, 0, 16384, merge_range);
    }

    const double native_compute_ms = elapsed_ms(compute_started);
    const auto publish_started = std::chrono::steady_clock::now();
    PackedInt32Array occupancy_out;
    int32_t *occupancy_out_ptr = nullptr;
    if (slot_mode) {
        occupancy_out_ptr = _slots.write[occupancy_slot_id].arr_i32.ptrw();
    } else {
        occupancy_out.resize(n);
        occupancy_out_ptr = occupancy_out.ptrw();
    }
    BioDiscoveryEmit discoveries;
    auto publish_range = [&](int begin, int end, BioDiscoveryEmit &local) {
        for (int cell = begin; cell < end; ++cell) {
            const int32_t next_bits =
                _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
            const uint32_t added = static_cast<uint32_t>(next_bits) &
                ~static_cast<uint32_t>(
                    _bio_occupancy_previous[static_cast<size_t>(cell)]);
            occupancy_out_ptr[cell] = next_bits;
            uint32_t scan = added;
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t s = species_index_for_bit(sp, bit);
                if (s < 0) continue;
                local.cells.push_back(cell);
                local.signals.push_back(sp.signal_ids[size_t(s)]);
            }
        }
    };
    parallel_for_range_with_emit<BioDiscoveryEmit>(
        "pk_bio_publish", n, 0, 16384, discoveries, publish_range);
    _bio_newly_occupied_cells.resize(int64_t(discoveries.cells.size()));
    _bio_newly_occupied_signals.resize(int64_t(discoveries.signals.size()));
    for (size_t i = 0; i < discoveries.cells.size(); ++i) {
        _bio_newly_occupied_cells.ptrw()[i] = discoveries.cells[i];
        _bio_newly_occupied_signals.ptrw()[i] = discoveries.signals[i];
    }

    const double publish_ms = elapsed_ms(publish_started);
    out["ok"] = true;
    out["path"] = String("gdext");
    if (slot_mode) {
        _flush_slot_to_map(occupancy_slot_id);
    } else {
        out["occupancy_bits"] = occupancy_out;
    }
    out["newly_occupied_cells"] = _bio_newly_occupied_cells;
    out["newly_occupied_signal_ids"] = _bio_newly_occupied_signals;
    out["processed_cells"] = n;
    out["native_compute_ms"] = native_compute_ms;
    out["bio_slice_native_ms"] = native_compute_ms;
    out["bridge_ms"] = bridge_ms;
    out["publish_ms"] = publish_ms;
    out["bio_slice_publish_ms"] = publish_ms;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = slot_mode;
    out["configured_slot_fastpath"] = slot_mode;
    const int64_t observation_handle = int64_t(
        knobs.get("observation_country_handle", int64_t(0)));
    if (observation_handle != 0) {
        const Dictionary evidence = _queue_bio_observations(
            observation_handle,
            int64_t(knobs.get("observation_effective_day", int64_t(0))),
            _bio_newly_occupied_cells, _bio_newly_occupied_signals);
        out["native_evidence_submission"] = bool(evidence.get("ok", false));
        out["native_evidence_submitted"] = int64_t(evidence.get("submitted", 0));
    }
    out["slice_enabled"] = bool(knobs.get("slice_enabled", false));
    out["slice_done"] = true;
    out["slice_cursor"] = n;
    return out;
}

} // namespace pk
