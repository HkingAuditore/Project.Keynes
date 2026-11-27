struct BioOccupancyRound {
    int n = 0;
    int seed = 0;
    int day_index = 0;
    bool run_diffusion = false;
    int phase = 0; // 0=persist, 1=diffusion, 2=merge, 3=publish
    int cursor = 0;
    int32_t diffused_cells = 0;
    SpeciesView species;
    std::vector<int32_t> staging;
    std::vector<int32_t> previous;
    std::vector<int32_t> additions;
    std::vector<int32_t> output;
    std::vector<int32_t> newly_cells;
    std::vector<int32_t> newly_signals;

    void begin() {
        phase = 0;
        cursor = 0;
        diffused_cells = 0;
        staging = previous;
        additions.assign(static_cast<size_t>(n), 0);
        output.resize(static_cast<size_t>(n));
        newly_cells.clear();
        newly_signals.clear();
    }
};

// The existing standalone sliced API pins its inputs until it finishes.
struct BioOccupancySliceState : BioOccupancyRound {
    bool slot_mode = false;
    int32_t occupancy_slot_id = -1;
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
    std::vector<PackedFloat32Array> reserves;
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

template <typename Column>
bool carrier_ok(int cell, int species, const SpeciesView &sp,
                const std::vector<Column> &columns) {
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
