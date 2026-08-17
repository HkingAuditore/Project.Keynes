#include "world_ext.h"
#include "economy_runtime.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
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
    const PackedInt32Array origin_policy = knobs.get("species_origin_policy", PackedInt32Array());
    const PackedInt32Array guild = knobs.get("species_guild", PackedInt32Array());
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
    for (int s = 0; s < sp.count; ++s) {
        if (sp.bits[s] == bit) return s;
    }
    return -1;
}

constexpr int32_t kOriginHearth = 0;
constexpr int32_t kOriginCosmopolitan = 1;
constexpr int32_t kGuildFood = 1;
constexpr int32_t kGuildGrazer = 2;
constexpr int32_t kGuildFiber = 3;
constexpr int32_t kMinOriginEnvelope = 8;
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

bool guild_slot_free(int cell, int species, const SpeciesView &sp, const int32_t *occ) {
    const int32_t guild = sp.guild[species];
    if (guild != kGuildFood && guild != kGuildGrazer) return true;
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

int pick_origin_cell(int species, int lid, int preferred, int n, int width,
                     const SpeciesView &sp, const int32_t *landmass,
                     const uint8_t *water, const uint8_t *veg, const uint8_t *lf,
                     const uint8_t *river, const float *temp, const float *moist,
                     const float *elev, const std::vector<PackedFloat32Array> &reserves,
                     const int32_t *occ) {
    if (preferred >= 0 && preferred < n && landmass[preferred] == lid &&
        envelope_ok(preferred, species, sp, water, veg, lf, river, temp, moist, elev) &&
        carrier_ok(preferred, species, sp, reserves) &&
        guild_slot_free(preferred, species, sp, occ)) {
        return preferred;
    }
    int best = -1;
    int best_d = 1 << 30;
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] != lid) continue;
        if (!envelope_ok(cell, species, sp, water, veg, lf, river, temp, moist, elev))
            continue;
        if (!carrier_ok(cell, species, sp, reserves)) continue;
        if (!guild_slot_free(cell, species, sp, occ)) continue;
        const int d = (preferred >= 0) ? hex_dist(cell, preferred, width, n) : 0;
        if (d < best_d) {
            best_d = d;
            best = cell;
        }
    }
    return best;
}

int32_t fill_hearth(int species, int origin, int lid, int n, int seed,
                    const SpeciesView &sp, const int32_t *landmass,
                    const int32_t *nb, const uint8_t *water, const uint8_t *veg,
                    const uint8_t *lf, const uint8_t *river, const float *temp,
                    const float *moist, const float *elev,
                    const std::vector<PackedFloat32Array> &reserves,
                    int32_t *occ, int32_t cost_cap = -1) {
    const int32_t bit = sp.bits[species];
    if (bit < 0 || bit >= 32 || origin < 0 || origin >= n) return 0;
    const int32_t cap = cost_cap > 0 ? cost_cap : std::max(1, sp.max_cost[species]);
    std::vector<int32_t> best(size_t(n), 1 << 29);
    using Node = std::pair<int32_t, int32_t>;
    std::priority_queue<Node, std::vector<Node>, std::greater<Node>> pq;
    best[size_t(origin)] = 0;
    pq.push(Node(0, origin));
    int32_t occupied = 0;
    while (!pq.empty()) {
        const Node cur = pq.top();
        pq.pop();
        const int32_t cost = cur.first;
        const int cell = cur.second;
        if (cost != best[size_t(cell)]) continue;
        if (cost > cap) continue;
        const float decay = 1.0f - 0.35f * float(cost) / float(cap);
        const float keep = sp.fill_keep[species] * std::max(0.15f, decay);
        const bool keep_cell = cell == origin ||
            bio_unit(bio_hash(uint32_t(seed), uint32_t(species + 17), uint32_t(cell))) < keep;
        if (keep_cell && guild_slot_free(cell, species, sp, occ)) {
            if ((occ[cell] & (1 << bit)) == 0) {
                occ[cell] |= (1 << bit);
                occupied += 1;
            }
        }
        const int32_t base = cell * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nxt = nb[base + d];
            if (nxt < 0 || nxt >= n) continue;
            if (landmass[nxt] != lid) continue;
            if (!envelope_ok(nxt, species, sp, water, veg, lf, river, temp, moist, elev))
                continue;
            if (!carrier_ok(nxt, species, sp, reserves)) continue;
            const int32_t step = traversal_cost(lf[nxt], veg[nxt], water[nxt]);
            const int32_t nc = cost + std::max(1, step);
            if (nc <= cap && nc < best[size_t(nxt)]) {
                best[size_t(nxt)] = nc;
                pq.push(Node(nc, nxt));
            }
        }
    }
    return occupied;
}

int32_t fill_landmass_envelope(int species, int lid, int n, int seed, bool thin,
                               const SpeciesView &sp, const int32_t *landmass,
                               const uint8_t *water, const uint8_t *veg,
                               const uint8_t *lf, const uint8_t *river,
                               const float *temp, const float *moist,
                               const float *elev,
                               const std::vector<PackedFloat32Array> &reserves,
                               int origin, int32_t *occ) {
    const int32_t bit = sp.bits[species];
    if (bit < 0 || bit >= 32) return 0;
    int32_t occupied = 0;
    for (int cell = 0; cell < n; ++cell) {
        if (landmass[cell] != lid) continue;
        if (!envelope_ok(cell, species, sp, water, veg, lf, river, temp, moist, elev))
            continue;
        if (!carrier_ok(cell, species, sp, reserves)) continue;
        const bool keep_cell = !thin || cell == origin ||
            bio_unit(bio_hash(uint32_t(seed), uint32_t(species + 17), uint32_t(cell))) <
                sp.fill_keep[species];
        if (!keep_cell) continue;
        if (!guild_slot_free(cell, species, sp, occ)) continue;
        if ((occ[cell] & (1 << bit)) == 0) {
            occ[cell] |= (1 << bit);
            occupied += 1;
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

} // namespace

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
    const int32_t *nb = neighbors.ptr();
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

    std::vector<int32_t> landmass_load(size_t(max_landmass + 1), 0);
    std::vector<int32_t> placed_core;
    std::vector<int32_t> placed_guild;
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
        int32_t added = 0;
        if (w < kMinOriginEnvelope) {
            added = fill_landmass_envelope(s, lid, n, seed, false, sp, landmass, water, veg,
                                           lf, river, temp, moist, elev, reserves, origin, occ);
        } else {
            const int32_t cap = secondary
                ? std::max(1, sp.max_cost[s] / 2)
                : std::max(1, sp.max_cost[s]);
            added = fill_hearth(s, origin, lid, n, seed, sp, landmass, nb, water, veg, lf,
                                river, temp, moist, elev, reserves, occ, cap);
        }
        if (added <= 0) return 0;
        occupied_n[s] += added;
        hearth_n[s] += added;
        seeded_n[s] += 1;
        landmass_load[size_t(lid)] += 1;
        placed_core.push_back(origin);
        placed_guild.push_back(sp.guild[s]);
        placed_lid.push_back(lid);
        if (!secondary) {
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
            for (int32_t lid = 1; lid <= max_landmass; ++lid) {
                const int32_t w = weight[size_t(s)][size_t(lid)];
                if (w <= 0) continue;
                const bool continent = landmass_size[size_t(lid)] >= continent_floor;
                const bool stand = w >= kMinOriginEnvelope;
                if (lid != origin_landmass && !(continent && stand)) continue;
                const int origin = best_cell[size_t(s)][size_t(lid)];
                occupied += fill_landmass_envelope(s, lid, n, seed, stand, sp, landmass,
                                                   water, veg, lf, river, temp, moist, elev,
                                                   reserves, origin, occ);
                seeded += 1;
                landmass_load[size_t(lid)] += 1;
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

        float best_score = -1.0e30f;
        int best_i = 0;
        for (int i = 0; i < int(cands.size()); ++i) {
            const Cand &c = cands[size_t(i)];
            float score = float(c.w);
            score -= 80.0f * float(landmass_load[size_t(c.lid)]);
            for (size_t p = 0; p < placed_core.size(); ++p) {
                if (placed_lid[p] != c.lid) continue;
                const int d = std::max(1, hex_dist(c.core, placed_core[p], hex_width, n));
                float penalty = 48.0f / float(d);
                if (placed_guild[p] != 0 && placed_guild[p] == sp.guild[s])
                    penalty *= 2.5f;
                score -= penalty;
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

Dictionary DCWorldExt::run_bio_occupancy_pass(const Dictionary &knobs) {
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
    const PackedByteArray water_arr = knobs.get("is_water", PackedByteArray());
    const PackedByteArray veg_arr = knobs.get("vegetation", PackedByteArray());
    const PackedByteArray lf_arr = knobs.get("landform", PackedByteArray());
    const PackedByteArray river_arr = knobs.get("has_river", PackedByteArray());
    const PackedByteArray explored_arr = knobs.get("explored", PackedByteArray());
    const PackedFloat32Array temp_arr = knobs.get("temperature", PackedFloat32Array());
    const PackedFloat32Array moist_arr = knobs.get("moisture", PackedFloat32Array());
    const PackedFloat32Array elev_arr = knobs.get("elevation", PackedFloat32Array());
    const PackedInt32Array province_arr = knobs.get("province_ids", PackedInt32Array());
    const PackedInt32Array neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    PackedInt32Array occupancy = knobs.get("occupancy_bits", PackedInt32Array());
    if (water_arr.size() != n || veg_arr.size() != n || lf_arr.size() != n ||
        river_arr.size() != n || temp_arr.size() != n || moist_arr.size() != n ||
        elev_arr.size() != n || province_arr.size() != n || neighbors.size() != n * 6 ||
        occupancy.size() != n) {
        out["reason"] = String("bio_occupancy_input_shape_invalid");
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

    const uint8_t *water = water_arr.ptr();
    const uint8_t *veg = veg_arr.ptr();
    const uint8_t *lf = lf_arr.ptr();
    const uint8_t *river = river_arr.ptr();
    const uint8_t *explored = explored_arr.size() == n ? explored_arr.ptr() : nullptr;
    const float *temp = temp_arr.ptr();
    const float *moist = moist_arr.ptr();
    const float *elev = elev_arr.ptr();
    const int32_t *province = province_arr.ptr();
    const int32_t *nb = neighbors.ptr();
    std::vector<int32_t> bits_by_cell(size_t(n), 0);
    std::vector<int32_t> previous(size_t(n), 0);
    for (int cell = 0; cell < n; ++cell) {
        const int32_t value = occupancy[cell];
        bits_by_cell[size_t(cell)] = value;
        previous[size_t(cell)] = value;
    }

    for (int cell = 0; cell < n; ++cell) {
        int32_t bits = bits_by_cell[size_t(cell)];
        if (bits == 0) continue;
        for (int s = 0; s < sp.count; ++s) {
            const int32_t bit = sp.bits[s];
            if (bit < 0 || bit >= 32) continue;
            const int32_t mask = 1 << bit;
            if ((bits & mask) == 0) continue;
            if (!persist_ok(cell, s, sp, water, temp, moist, elev)) {
                bits &= ~mask;
            }
        }
        bits_by_cell[size_t(cell)] = bits;
    }

    for (int i = 0; i < intro_cells.size(); ++i) {
        const int32_t cell = intro_cells[i];
        const int32_t bit = intro_bits[i];
        if (cell < 0 || cell >= n || bit < 0 || bit >= 32) continue;
        const int32_t s = species_index_for_bit(sp, bit);
        if (s < 0) continue;
        if (!envelope_ok(cell, s, sp, water, veg, lf, river, temp, moist, elev)) continue;
        if (!carrier_ok(cell, s, sp, reserves)) continue;
        bits_by_cell[size_t(cell)] |= (1 << bit);
    }

    if (run_diffusion) {
        std::vector<int32_t> additions(size_t(n), 0);
        for (int cell = 0; cell < n; ++cell) {
            const int32_t bits = bits_by_cell[size_t(cell)];
            if (bits == 0) continue;
            const int32_t pid = province[cell];
            const int32_t base = cell * 6;
            for (int s = 0; s < sp.count; ++s) {
                const int32_t bit = sp.bits[s];
                if (bit < 0 || bit >= 32) continue;
                const int32_t mask = 1 << bit;
                if ((bits & mask) == 0) continue;
                for (int d = 0; d < 6; ++d) {
                    const int32_t nxt = nb[base + d];
                    if (nxt < 0 || nxt >= n) continue;
                    if ((bits_by_cell[size_t(nxt)] & mask) != 0) continue;
                    if (pid <= 0 || province[nxt] != pid) continue;
                    if (!envelope_ok(nxt, s, sp, water, veg, lf, river, temp, moist, elev))
                        continue;
                    if (!carrier_ok(nxt, s, sp, reserves)) continue;
                    if (bio_unit(bio_hash(uint32_t(seed), uint32_t(day_index * 17 + s + 3),
                                          uint32_t(nxt))) < kDiffusionKeep) {
                        additions[size_t(nxt)] |= mask;
                    }
                }
            }
        }
        for (int cell = 0; cell < n; ++cell) {
            bits_by_cell[size_t(cell)] |= additions[size_t(cell)];
        }
    }

    PackedInt32Array newly_cells;
    PackedInt32Array newly_signals;
    for (int cell = 0; cell < n; ++cell) {
        const int32_t added = bits_by_cell[size_t(cell)] & ~previous[size_t(cell)];
        occupancy[cell] = bits_by_cell[size_t(cell)];
        if (added == 0) continue;
        if (explored != nullptr && explored[cell] == 0) continue;
        for (int s = 0; s < sp.count; ++s) {
            const int32_t bit = sp.bits[s];
            if (bit < 0 || bit >= 32) continue;
            if ((added & (1 << bit)) == 0) continue;
            newly_cells.push_back(cell);
            newly_signals.push_back(sp.signal_ids[s]);
        }
    }

    out["ok"] = true;
    out["path"] = String("gdext");
    out["occupancy_bits"] = occupancy;
    out["newly_occupied_cells"] = newly_cells;
    out["newly_occupied_signal_ids"] = newly_signals;
    return out;
}

} // namespace pk
