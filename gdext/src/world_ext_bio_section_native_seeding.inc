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

    // Seed at most one relict for an absent species. Use the daily climate
    // limits and the same occupancy rules as normal natural seeding.
    if (bool(knobs.get("seed_missing_species", false))) {
        for (int s = 0; s < sp.count; ++s) {
            const int32_t bit = sp.bits[s];
            if (occupied_n[s] != 0 || bit < 0 || bit >= 32) continue;
            int best = -1;
            float best_distance = std::numeric_limits<float>::infinity();
            for (int cell = 0; cell < n; ++cell) {
                if (landmass[cell] <= 0 || !persist_ok(cell, s, sp, water, temp, moist, elev) ||
                    !natural_slot_free(cell, s, sp, occ)) continue;
                const float distance = std::abs(temp[cell] - 0.5f * (sp.temp_lo[s] + sp.temp_hi[s])) +
                    std::abs(moist[cell] - 0.5f * (sp.moist_lo[s] + sp.moist_hi[s])) +
                    std::abs(elev[cell] - 0.5f * (sp.elev_lo[s] + sp.elev_hi[s]));
                if (distance >= best_distance) continue;
                best_distance = distance;
                best = cell;
            }
            if (best < 0) continue;
            occ[best] = int32_t(uint32_t(occ[best]) | (uint32_t{1} << bit));
            origin_ids[s] = landmass[best];
            occupied_n[s] = hearth_n[s] = seeded_n[s] = 1;
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
