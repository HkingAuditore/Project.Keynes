// Plans every cell independently: blockers and the RNG are per cell, so a
// cell's output depends only on its own row and the static tables. Bodies of
// each cell leave sorted by importance with `rank` set; grounds by order.
void plan_cells(const PlanInputs &in, PlanOutputs &po) {
    const int K = in.K;
    const int32_t *CELL = in.cells;
    const float *POS_X = in.pos_x;
    const float *POS_Y = in.pos_y;
    const int32_t *OFFSETS = in.offsets;
    const int32_t *TYPES = in.types;
    const int64_t *COUNTS = in.counts;
    const int32_t *ERAS = in.eras;
    const uint8_t *WATER = in.water;
    const uint8_t *ARCH = in.arch;
    const int type_count = in.type_count;
    const int quality = in.quality;
    const int instance_cap = in.instance_cap;
    const double hex_size = in.hex_size;
    const int cell_count = in.cell_count;
    const int layout_seed = in.layout_seed;
    const double river_threshold = in.river_threshold;
    const bool flow_valid = flow_input_valid(in);
    const float *FLOW = in.flow;
    const int flow_w = in.flow_w;
    const int flow_h = in.flow_h;
    const double flow_origin_x = in.flow_origin_x;
    const double flow_origin_y = in.flow_origin_y;
    const double flow_size_x = in.flow_size_x;
    const double flow_size_y = in.flow_size_y;
    const double flow_wrap_x = in.flow_wrap_x;

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
    auto type_family = [&](int type) -> int {
        const int tabled = in.family == nullptr ? kFamilyCount : int(in.family[type]);
        if (tabled < kFamilyCount) return tabled;
        const int archetype = int(ARCH[type]);
        return archetype >= 0 && archetype < kArchetypeCount ? kFallbackFamily[archetype] : -1;
    };

    const double unit = hex_size / kReferenceHexSize;
    const double inradius = hex_size * 0.86602540378;
    const double hex_limit = inradius * 0.93;

    std::vector<BodyInstance> &bodies = po.bodies;
    std::vector<GroundInstance> &grounds = po.grounds;
    bodies.reserve(bodies.size() + static_cast<size_t>(K) * 48U);
    grounds.reserve(grounds.size() + static_cast<size_t>(K) * 12U);
    std::vector<Obb> &blockers = po.blockers;
    std::vector<SlotRequest> &slots = po.slots;
    std::vector<int> &cursor_order = po.cursor_order;
    int &candidate_count = po.candidate_count;
    int &river_rejected = po.river_rejected;

    // When the chunk cap cannot hold every planned settlement, each cell stops
    // planning past twice its fair share; the global importance sort then
    // trims the rest. Slots run civic-first, so the share keeps town cores.
    int active_cells = 0;
    for (int i = 0; i < K; ++i) {
        if (CELL[i] < 0 || CELL[i] >= cell_count || WATER[i] != 0) continue;
        const bool has_types = OFFSETS[i + 1] > OFFSETS[i];
        if (has_types || cell_tier(in, i, 0) >= 1) ++active_cells;
    }
    const size_t cell_body_budget = active_cells > 0
            ? static_cast<size_t>(std::max(8, int((2 * int64_t(instance_cap) + active_cells - 1) /
                    active_cells)))
            : 0;

    for (int i = 0; i < K; ++i) {
        if (CELL[i] < 0 || CELL[i] >= cell_count || WATER[i] != 0) {
            continue;
        }
        const int begin = OFFSETS[i];
        const int end = OFFSETS[i + 1];
        std::array<double, kFamilyCount> weight{};
        std::array<int64_t, kFamilyCount> family_count{};
        std::array<int, kFamilyCount> family_grade;
        family_grade.fill(-1);
        int64_t total = 0;
        for (int edge = begin; edge < end; ++edge) {
            const int type = TYPES[edge];
            if (type < 0 || type >= type_count || COUNTS[edge] <= 0) {
                continue;
            }
            const int family = type_family(type);
            if (family < 0) {
                continue;
            }
            const double scale = in.scale == nullptr ? 8.0 : std::max(8.0, double(in.scale[type]));
            weight[static_cast<size_t>(family)] += double(COUNTS[edge]) * scale / 8.0;
            family_count[static_cast<size_t>(family)] = saturating_add_i64(
                    family_count[static_cast<size_t>(family)], COUNTS[edge]);
            const int grade = in.grade == nullptr ? 3 : std::min(3, int(in.grade[type]));
            family_grade[static_cast<size_t>(family)] = std::max(
                    family_grade[static_cast<size_t>(family)], grade);
            total = saturating_add_i64(total, COUNTS[edge]);
        }
        const int tier = cell_tier(in, i, total);
        if (total <= 0 && tier < 1) {
            continue;
        }
        const int living_raw = in.living == nullptr ? kUnknownBand : int(in.living[i]);
        const int rich_raw = in.rich == nullptr ? kUnknownBand : int(in.rich[i]);
        const int poor_raw = in.poor == nullptr ? kUnknownBand : int(in.poor[i]);
        const double wealth = (living_raw <= 6 ? double(living_raw) : 3.0) / 6.0;

        const int era = std::max(0, std::min(10, ERAS[i]));
        Rng plan(stable_hash(CELL[i], 0, 0, 101, layout_seed));
        Settlement st;
        st.era = era;
        st.band = era_band(era);
        st.tier = tier;
        st.wealth = wealth;
        st.village_roof = village_roof_for(st.band, plan);
        st.tall = st.band >= kAtomic ? 1.0 + 0.35 * double(std::max(0, tier - 3)) : 1.0;
        const double inequality = st.band <= kAgrarian ? 0.35 : 1.0;
        const double rich_share = (rich_raw <= 3 ? double(rich_raw) : 1.0) / 3.0 * inequality;
        const double poor_share = (poor_raw <= 3 ? double(poor_raw) : 1.0) / 3.0 * inequality;
        const float style = float(era * kArchetypeCount) / 65.0f;
        const double home_x = double(POS_X[i]);
        const double home_y = double(POS_Y[i]);

        // Settlement centre: jittered off the cell centre, away from river water.
        double cx = home_x;
        double cy = home_y;
        for (int attempt = 0; attempt < 6; ++attempt) {
            const double radius = attempt == 5 ? 0.0 : plan.range(0.0, 0.14) * inradius;
            const double angle = plan.range(0.0, kTau);
            const double tx = home_x + std::cos(angle) * radius;
            const double ty = home_y + std::sin(angle) * radius;
            if (sample_flow(tx, ty) < river_threshold * 0.8) {
                cx = tx;
                cy = ty;
                break;
            }
        }

        // --- Slots: industry by family weight, housing by tier and wealth ---
        slots.clear();
        double weight_total = 0.0;
        for (double w : weight) weight_total += w;
        const int lot_count = weight_total > 0.0
            ? std::max(1, std::min(kIndustryLotCap[quality], int(std::lround(
                double(kIndustryLotMax) * std::log2(1.0 + weight_total) /
                std::log2(1.0 + kIndustryWeightTop)))))
            : 0;
        std::array<int, kFamilyCount> quota{};
        if (lot_count > 0) {
            double share_total = 0.0;
            std::array<double, kFamilyCount> shares{};
            for (int f = 0; f < kFamilyCount; ++f) {
                shares[static_cast<size_t>(f)] = weight[static_cast<size_t>(f)] > 0.0
                    ? std::pow(weight[static_cast<size_t>(f)], 0.75) : 0.0;
                share_total += shares[static_cast<size_t>(f)];
            }
            struct Remainder { int family; double value; };
            std::array<Remainder, kFamilyCount> remainders{};
            int assigned = 0;
            for (int f = 0; f < kFamilyCount; ++f) {
                const double exact = double(lot_count) * shares[static_cast<size_t>(f)] /
                        std::max(share_total, 1.0e-12);
                const int whole = int(std::floor(exact));
                quota[static_cast<size_t>(f)] = whole;
                assigned += whole;
                remainders[static_cast<size_t>(f)] = Remainder{f, exact - double(whole)};
            }
            std::sort(remainders.begin(), remainders.end(),
                [](const Remainder &lhs, const Remainder &rhs) {
                if (std::fabs(lhs.value - rhs.value) > 1.0e-12) {
                    return lhs.value > rhs.value;
                }
                return lhs.family < rhs.family;
            });
            for (int j = 0; j < lot_count - assigned && j < kFamilyCount; ++j) {
                if (remainders[static_cast<size_t>(j)].value <= 0.0) break;
                ++quota[static_cast<size_t>(remainders[static_cast<size_t>(j)].family)];
            }
        }
        for (int f = 0; f < kFamilyCount; ++f) {
            const int q = quota[static_cast<size_t>(f)];
            if (q <= 0) continue;
            const double w = weight[static_cast<size_t>(f)];
            const double avg_scale = w / std::max(1.0, double(family_count[static_cast<size_t>(f)]));
            const double per_lot = w / double(q);
            const double hscale = clampd(0.8 + 0.12 * avg_scale +
                    0.05 * std::log2(std::max(1.0, per_lot)), 0.85, 1.9);
            const int grade = family_grade[static_cast<size_t>(f)];
            const int band = std::min(st.band, grade_band_cap(grade < 0 ? 3 : grade));
            const int ring = family_ring(f);
            for (int rank = 0; rank < q; ++rank) {
                SlotRequest request;
                request.kind = kSlotLot;
                request.family = f;
                request.local_rank = rank;
                request.ring = ring;
                request.frac = (double(rank) + 0.5) / double(q);
                request.importance = ring == 0
                    ? (int64_t(1) << 50) - rank
                    : int64_t(w / weight_total * 1.0e6 / double(1 + rank));
                request.wealth = wealth;
                request.hscale = hscale;
                request.band = band;
                request.era = std::min(era, kBandLastEra[band]);
                slots.push_back(request);
            }
        }
        const int house_count = std::min(kHouseCount[tier], kHouseCap[quality]);
        for (int k = 0; k < house_count; ++k) {
            Rng house_rng(stable_hash(CELL[i], 40, k, 53, layout_seed));
            SlotRequest request;
            request.kind = kSlotHouse;
            request.local_rank = k;
            request.ring = 2;
            request.frac = (double(k) + 0.5) / double(house_count);
            request.importance = int64_t(0.5e6 / double(1 + k));
            request.wealth = clampd(wealth + (house_rng.next() - 0.5) * 0.3, 0.0, 1.0);
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        const int villa_count = tier >= 1 ? std::min(kVillaCap,
                int(std::lround(rich_share * (1.0 + double(tier) / 3.0)))) : 0;
        for (int k = 0; k < villa_count; ++k) {
            SlotRequest request;
            request.kind = kSlotVilla;
            request.local_rank = k;
            request.ring = 1;
            request.frac = (double(k) + 0.5) / double(villa_count);
            request.importance = int64_t(0.4e6 / double(1 + k));
            request.wealth = 1.0;
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        const int shanty_count = tier >= 1 ? std::min(kShantyCap,
                int(std::lround(poor_share * (1.0 + double(tier) / 2.0)))) : 0;
        for (int k = 0; k < shanty_count; ++k) {
            SlotRequest request;
            request.kind = kSlotShanty;
            request.local_rank = k;
            request.ring = 4;
            request.frac = (double(k) + 0.5) / double(shanty_count);
            request.importance = int64_t(0.2e6 / double(1 + k));
            request.wealth = 0.0;
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        std::stable_sort(slots.begin(), slots.end(), [](const SlotRequest &a, const SlotRequest &b) {
            if (a.ring != b.ring) return a.ring < b.ring;
            if (a.frac != b.frac) return a.frac < b.frac;
            if (a.kind != b.kind) return a.kind < b.kind;
            if (a.family != b.family) return a.family < b.family;
            return a.local_rank < b.local_rank;
        });

        // --- Skeleton: the tier sets street count, plaza size and exits ---
        blockers.clear();
        const bool ring_mode = st.band == kStoneAge;
        const double plaza_r = (ring_mode ? 0.95 : 0.65 + 0.22 * double(tier)) * unit;
        const double theta0 = plan.range(0.0, kTau);
        int arms = tier <= 1 ? 1 : (tier == 2 ? 2 : (tier == 3 ? 3 : 4));
        if (ring_mode) arms = 0;
        std::array<double, 4> arm_ux{}, arm_uy{}, arm_reach{};
        for (int k = 0; k < arms; ++k) {
            double theta = theta0 + double(k) * kTau / double(arms);
            theta += arms == 2 && k == 1 ? plan.range(-0.30, 0.30) : plan.range(-0.22, 0.22);
            arm_ux[static_cast<size_t>(k)] = std::cos(theta);
            arm_uy[static_cast<size_t>(k)] = std::sin(theta);
            arm_reach[static_cast<size_t>(k)] = 0.0;
        }
        // Rice paddies and fishing lots follow the street toward the river.
        double water_ux = 0.0, water_uy = 0.0;
        bool has_water_dir = false;
        {
            double best = 0.15;
            for (int k = 0; k < 6; ++k) {
                const double angle = theta0 + double(k) * kTau / 6.0;
                const double f = sample_flow(cx + std::cos(angle) * 0.7 * inradius,
                        cy + std::sin(angle) * 0.7 * inradius);
                if (f > best) {
                    best = f;
                    water_ux = std::cos(angle);
                    water_uy = std::sin(angle);
                    has_water_dir = true;
                }
            }
        }
        const double road_hw = (st.band <= kAgrarian ? 0.22 : st.band <= kEarlyModern ? 0.30
                : st.band == kIndustrial ? 0.36 : 0.44) * unit;
        const double setback = (st.band <= kAgrarian ? 0.35 : st.band <= kIndustrial ? 0.22 : 0.40) * unit;
        const double pad = 0.14 * unit;

        Obb plaza_box;
        plaza_box.cx = cx;
        plaza_box.cy = cy;
        plaza_box.ax = std::cos(theta0);
        plaza_box.ay = std::sin(theta0);
        plaza_box.hx = plaza_box.hy = plaza_r * 0.85;
        blockers.push_back(plaza_box);
        for (int k = 0; k < arms; ++k) {
            const double ux = arm_ux[static_cast<size_t>(k)];
            const double uy = arm_uy[static_cast<size_t>(k)];
            Obb road;
            road.cx = cx + ux * inradius * 0.5;
            road.cy = cy + uy * inradius * 0.5;
            road.ax = ux;
            road.ay = uy;
            road.hx = inradius * 0.5;
            road.hy = road_hw;
            blockers.push_back(road);
        }

        // Frontage cursors (street mode) or ring sites (stone age).
        struct Cursor { int arm; double side; int row; double t; bool closed; };
        std::vector<Cursor> cursors;
        struct RingSite { double ox, oy, rx, ry; bool used; };
        std::vector<RingSite> ring_sites;
        if (ring_mode) {
            const double phase = plan.range(0.0, kTau);
            for (int ring = 0; ring < 4; ++ring) {
                const double radius = plaza_r + (0.55 + 2.4 * double(ring)) * unit;
                const int count = std::max(5, int(std::floor(kTau * radius / (2.6 * unit))));
                for (int j = 0; j < count; ++j) {
                    const double angle = phase + double(ring) * 0.37 +
                            kTau * double(j) / double(count) + plan.range(-0.12, 0.12);
                    const double rx = std::cos(angle);
                    const double ry = std::sin(angle);
                    ring_sites.push_back(RingSite{cx + rx * radius, cy + ry * radius, rx, ry, false});
                }
            }
        } else {
            for (int k = 0; k < arms; ++k) {
                for (int row = 0; row < 2; ++row) {
                    for (double side : {1.0, -1.0}) {
                        cursors.push_back(Cursor{k, side, row, plaza_r + 0.25 * unit, false});
                    }
                }
            }
        }

        const size_t cell_body_start = bodies.size();
        const size_t cell_ground_start = grounds.size();
        int fail_streak = 0;
        for (size_t slot_index = 0; slot_index < slots.size(); ++slot_index) {
            if (bodies.size() - cell_body_start >= cell_body_budget) {
                break;
            }
            const SlotRequest &slot = slots[slot_index];
            const int salt_family = slot.kind == kSlotLot ? slot.family : 32 + slot.kind;
            Rng lot_rng(stable_hash(CELL[i], salt_family, slot.local_rank, 31, layout_seed));
            Settlement ls = st;
            ls.band = slot.band;
            ls.era = slot.era;
            ls.wealth = slot.wealth;
            Lot lot;
            int archetype = kService;
            switch (slot.kind) {
            case kSlotHouse: build_house(ls, lot_rng, slot.wealth, lot); break;
            case kSlotVilla: build_villa(ls, lot_rng, lot); break;
            case kSlotShanty: build_shanty(ls, lot_rng, lot); break;
            default:
                build_family(ls, slot.family, lot_rng, lot);
                archetype = family_archetype(slot.family);
                break;
            }
            lot.finalize(unit, slot.hscale);
            if (lot.part_count == 0 && lot.ground_count == 0) {
                continue;
            }
            const float seed = float(stable_hash(CELL[i], salt_family, slot.local_rank, 7,
                    layout_seed) & 0xffffU) / 65535.0f;
            const float slot_style = float(slot.era * kArchetypeCount + archetype) / 65.0f;

            // Try a placement frame; on success commit parts to blockers/instances.
            auto try_frame = [&](double ox, double oy, double ux, double uy, double vx, double vy) -> bool {
                ++candidate_count;
                Lot work = lot;
                std::array<Obb, 8> part_boxes{};
                for (int p = 0; p < work.part_count; ++p) {
                    const Part &part = work.parts[static_cast<size_t>(p)];
                    Obb box;
                    box.cx = ox + ux * part.u + vx * part.v;
                    box.cy = oy + uy * part.u + vy * part.v;
                    box.ax = part.across ? vx : ux;
                    box.ay = part.across ? vy : uy;
                    const double reach = part.form == kWindmill ? 2.2 : 1.0;
                    box.hx = part.hl * reach;
                    box.hy = part.hw * reach;
                    for (int corner = 0; corner < 5; ++corner) {
                        const double sx = corner == 4 ? 0.0 : (corner & 1 ? 1.0 : -1.0);
                        const double sy = corner == 4 ? 0.0 : (corner & 2 ? 1.0 : -1.0);
                        const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                        const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                        if (corner < 4 && !inside_hex(wx - home_x, wy - home_y, hex_limit)) {
                            return false;
                        }
                        if (sample_flow(wx, wy) >= river_threshold) {
                            ++river_rejected;
                            return false;
                        }
                    }
                    for (const Obb &other : blockers) {
                        if (obb_overlap(box, other, pad)) {
                            return false;
                        }
                    }
                    part_boxes[static_cast<size_t>(p)] = box;
                }
                std::array<Obb, 4> ground_boxes{};
                std::array<bool, 4> ground_ok{};
                for (int g = 0; g < work.ground_count; ++g) {
                    GroundPart &ground = work.grounds[static_cast<size_t>(g)];
                    ground_ok[static_cast<size_t>(g)] = false;
                    // Fields, paddies and quays may run down to the bank.
                    const bool bank = ground.kind == kField || ground.kind == kPaddy ||
                            ground.kind == kQuay;
                    for (int shrink = 0; shrink < 2; ++shrink) {
                        const double v_front = ground.v - (ground.across ? ground.hl : ground.hw);
                        Obb box;
                        box.ax = ground.across ? vx : ux;
                        box.ay = ground.across ? vy : uy;
                        box.hx = ground.hl;
                        box.hy = ground.hw;
                        const double v_center = v_front + (ground.across ? box.hx : box.hy);
                        box.cx = ox + ux * ground.u + vx * v_center;
                        box.cy = oy + uy * ground.u + vy * v_center;
                        bool fits = true;
                        for (int corner = 0; corner < 4 && fits; ++corner) {
                            const double sx = corner & 1 ? 1.0 : -1.0;
                            const double sy = corner & 2 ? 1.0 : -1.0;
                            const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                            const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                            fits = inside_hex(wx - home_x, wy - home_y, hex_limit);
                        }
                        if (fits && !bank && sample_flow(box.cx, box.cy) >= river_threshold) {
                            fits = false;
                        }
                        for (size_t b = 0; fits && b < blockers.size(); ++b) {
                            if (obb_overlap(box, blockers[b], pad * 0.5)) {
                                fits = false;
                            }
                        }
                        for (int p = 0; fits && p < work.part_count; ++p) {
                            if (obb_overlap(box, part_boxes[static_cast<size_t>(p)], 0.0)) {
                                fits = false;
                            }
                        }
                        if (fits) {
                            ground_boxes[static_cast<size_t>(g)] = box;
                            ground_ok[static_cast<size_t>(g)] = true;
                            break;
                        }
                        if (!ground.soft) {
                            return false;
                        }
                        if (ground.across) {
                            ground.hl *= 0.6;
                        } else {
                            ground.hw *= 0.6;
                        }
                        ground.v = v_front + (ground.across ? ground.hl : ground.hw);
                    }
                    if (!ground_ok[static_cast<size_t>(g)] && !ground.soft) {
                        return false;
                    }
                }
                for (int p = 0; p < work.part_count; ++p) {
                    const Part &part = work.parts[static_cast<size_t>(p)];
                    const Obb &box = part_boxes[static_cast<size_t>(p)];
                    blockers.push_back(box);
                    BodyInstance body;
                    body.importance = slot.importance * 8 + (7 - p);
                    body.cell = CELL[i];
                    body.order = int(slot_index) * 8 + p;
                    body.px = float(box.cx);
                    body.py = float(box.cy);
                    body.ax = float(box.ax);
                    body.ay = float(box.ay);
                    body.hl = float(part.hl);
                    body.hw = float(part.hw);
                    body.he = float(part.he);
                    body.hr = float(part.hr);
                    body.form = part.form;
                    body.material = part.material;
                    body.style = slot_style;
                    body.seed = std::fmod(seed + 0.618034f * float(p), 1.0f);
                    bodies.push_back(body);
                }
                for (int g = 0; g < work.ground_count; ++g) {
                    if (!ground_ok[static_cast<size_t>(g)]) continue;
                    const GroundPart &ground = work.grounds[static_cast<size_t>(g)];
                    const Obb &box = ground_boxes[static_cast<size_t>(g)];
                    blockers.push_back(box);
                    GroundInstance gi;
                    gi.importance = slot.importance * 8 + (3 - g);
                    gi.cell = CELL[i];
                    gi.order = int(slot_index) * 8 + 4 + g;
                    gi.px = float(box.cx);
                    gi.py = float(box.cy);
                    gi.ax = float(box.ax);
                    gi.ay = float(box.ay);
                    gi.hl = float(box.hx);
                    gi.hw = float(box.hy);
                    gi.kind = ground.kind;
                    gi.param = float(ground.param);
                    gi.flag = float(ground.flag);
                    gi.style = slot_style;
                    gi.seed = std::fmod(seed + 0.381966f * float(g + 1), 1.0f);
                    grounds.push_back(gi);
                }
                return true;
            };

            bool placed = false;
            if (ring_mode) {
                for (RingSite &site : ring_sites) {
                    if (site.used) continue;
                    // u runs along the ring, v points away from the plaza.
                    if (try_frame(site.ox, site.oy, -site.ry, site.rx, site.rx, site.ry)) {
                        site.used = true;
                        placed = true;
                        break;
                    }
                }
            } else {
                // Visit open cursors nearest-first and probe a few steps along
                // each. A lot that fits nowhere must not push every street
                // outward, so a cursor only advances one step after all of its
                // probes fail.
                const bool wet = has_water_dir && slot.kind == kSlotLot &&
                        (slot.family == kFamPaddy || slot.family == kFamFishery);
                auto cursor_key = [&](int c) {
                    const Cursor &cursor = cursors[static_cast<size_t>(c)];
                    double key = cursor.t + double(cursor.row) * 3.2 * unit;
                    if (wet) {
                        const double along = arm_ux[static_cast<size_t>(cursor.arm)] * water_ux +
                                arm_uy[static_cast<size_t>(cursor.arm)] * water_uy;
                        key += (1.0 - along) * inradius;
                    }
                    return key;
                };
                cursor_order.clear();
                for (size_t c = 0; c < cursors.size(); ++c) {
                    if (!cursors[c].closed) cursor_order.push_back(int(c));
                }
                std::sort(cursor_order.begin(), cursor_order.end(), [&](int a, int b) {
                    const double ka = cursor_key(a);
                    const double kb = cursor_key(b);
                    return ka != kb ? ka < kb : a < b;
                });
                int attempts = 0;
                for (int c : cursor_order) {
                    if (placed || attempts >= 48) break;
                    Cursor &cursor = cursors[static_cast<size_t>(c)];
                    const double ux = arm_ux[static_cast<size_t>(cursor.arm)];
                    const double uy = arm_uy[static_cast<size_t>(cursor.arm)];
                    const double vx = -uy * cursor.side;
                    const double vy = ux * cursor.side;
                    const double v0 = road_hw + setback + double(cursor.row) * 3.4 * unit;
                    for (int probe = 0; probe < 4 && attempts < 48; ++probe, ++attempts) {
                        const double start = cursor.t + double(probe) * 0.9 * unit;
                        if (start > inradius) break;
                        const double center_t = start + lot.half_width;
                        const double ox = cx + ux * center_t + vx * v0;
                        const double oy = cy + uy * center_t + vy * v0;
                        if (try_frame(ox, oy, ux, uy, vx, vy)) {
                            placed = true;
                            cursor.t = center_t + lot.half_width + 0.30 * unit;
                            double &reach = arm_reach[static_cast<size_t>(cursor.arm)];
                            reach = std::max(reach, center_t + lot.half_width);
                            break;
                        }
                    }
                    if (!placed) {
                        cursor.t += 0.9 * unit;
                    }
                    if (cursor.t > inradius) {
                        cursor.closed = true;
                    }
                }
            }
            if (!placed) {
                // A saturated hex fails every remaining lot at full probe cost.
                if (++fail_streak >= 4) break;
            } else {
                fail_streak = 0;
                switch (slot.kind) {
                case kSlotHouse: ++po.house_total; break;
                case kSlotVilla: ++po.villa_total; break;
                case kSlotShanty: ++po.shanty_total; break;
                default:
                    ++po.lot_total;
                    ++po.family_lots[static_cast<size_t>(slot.family)];
                    break;
                }
            }
        }

        // --- Farmland in the outer ring, sized by the agricultural share ---
        const double agri_weight = weight[kFamField] + weight[kFamPaddy] +
                weight[kFamPlantation] + weight[kFamPasture] + weight[kFamForage];
        if (agri_weight > 0.0 && kFieldFillCap[quality] > 0) {
            const double share = agri_weight / weight_total;
            const int wanted = int(std::lround(double(kFieldFillCap[quality]) * std::sqrt(share) *
                    std::min(1.0, std::log2(1.0 + agri_weight) / 8.0)));
            Rng fill(stable_hash(CELL[i], 0, 0, 211, layout_seed));
            int placed_fields = 0;
            for (int attempt = 0; attempt < wanted * 4 && placed_fields < wanted; ++attempt) {
                double pick = fill.next() * agri_weight;
                int family = kFamField;
                for (int f = kFamField; f <= kFamForage; ++f) {
                    pick -= weight[static_cast<size_t>(f)];
                    if (pick <= 0.0 && weight[static_cast<size_t>(f)] > 0.0) {
                        family = f;
                        break;
                    }
                }
                const int grade = family_grade[static_cast<size_t>(family)];
                const int band = std::min(st.band, grade_band_cap(grade < 0 ? 3 : grade));
                const int kind = family == kFamPaddy ? kPaddy
                        : family == kFamPlantation || family == kFamForage ? kOrchard
                        : family == kFamPasture ? kPasture : kField;
                const double flag = family == kFamForage ? 1.0
                        : (kind == kField || kind == kPasture) && band >= kClassical ? 1.0 : 0.0;
                const double grow = band >= kIndustrial ? 1.3 : 1.0;
                const double angle = fill.range(0.0, kTau);
                const double radius = fill.range(0.55, 0.92) * inradius;
                Obb box;
                box.cx = home_x + std::cos(angle) * radius;
                box.cy = home_y + std::sin(angle) * radius;
                box.ax = -std::sin(angle);
                box.ay = std::cos(angle);
                box.hx = fill.range(1.3, 2.3) * unit * grow;
                box.hy = fill.range(0.65, 0.95) * unit * grow;
                const double param = fill.next();
                bool fits = kind == kPaddy || sample_flow(box.cx, box.cy) < river_threshold;
                for (int corner = 0; corner < 4 && fits; ++corner) {
                    const double sx = corner & 1 ? 1.0 : -1.0;
                    const double sy = corner & 2 ? 1.0 : -1.0;
                    const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                    const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                    fits = inside_hex(wx - home_x, wy - home_y, hex_limit);
                }
                for (size_t b = 0; fits && b < blockers.size(); ++b) {
                    if (obb_overlap(box, blockers[b], pad * 0.5)) {
                        fits = false;
                    }
                }
                if (!fits) continue;
                blockers.push_back(box);
                GroundInstance gi;
                gi.importance = int64_t(share * 1.0e5) - placed_fields;
                gi.cell = CELL[i];
                gi.order = 100000 + placed_fields;
                gi.px = float(box.cx);
                gi.py = float(box.cy);
                gi.ax = float(box.ax);
                gi.ay = float(box.ay);
                gi.hl = float(box.hx);
                gi.hw = float(box.hy);
                gi.kind = kind;
                gi.param = float(param);
                gi.flag = float(flag);
                gi.style = float(std::min(era, kBandLastEra[band]) * kArchetypeCount +
                        kAgriculture) / 65.0f;
                gi.seed = float(stable_hash(CELL[i], placed_fields, 0, 212, layout_seed) &
                        0xffffU) / 65535.0f;
                grounds.push_back(gi);
                ++placed_fields;
            }
            po.field_total += placed_fields;
        }

        // Plaza and street surfaces carry the cell's wealth: dirt for the poor,
        // paving and a centrepiece for the rich.
        const int64_t civic_importance = std::numeric_limits<int64_t>::max() / 2;
        GroundInstance plaza;
        plaza.importance = civic_importance;
        plaza.cell = CELL[i];
        plaza.order = -8;
        plaza.px = float(cx);
        plaza.py = float(cy);
        plaza.ax = float(std::cos(theta0));
        plaza.ay = float(std::sin(theta0));
        plaza.hl = plaza.hw = float(plaza_r * 1.25);
        plaza.kind = kPlaza;
        plaza.param = float(wealth);
        plaza.flag = st.band <= kAgrarian ? 1.0f : 0.0f;
        plaza.style = style;
        plaza.seed = float(stable_hash(CELL[i], 0, 0, 77, layout_seed) & 0xffffU) / 65535.0f;
        grounds.push_back(plaza);
        for (int k = 0; k < arms; ++k) {
            const double ux = arm_ux[static_cast<size_t>(k)];
            const double uy = arm_uy[static_cast<size_t>(k)];
            const bool exit = k == 0 || (arms == 2 && k == 1) || tier >= 5;
            const double reach = arm_reach[static_cast<size_t>(k)];
            if (!exit && reach <= 0.0) continue;
            const double length = exit
                ? ray_hex_exit(cx - home_x, cy - home_y, ux, uy, inradius) * 0.985
                : reach + 0.35 * unit;
            if (length <= plaza_r) continue;
            GroundInstance road;
            road.importance = civic_importance - 1 - k;
            road.cell = CELL[i];
            road.order = -7 + k;
            road.px = float(cx + ux * length * 0.5);
            road.py = float(cy + uy * length * 0.5);
            road.ax = float(ux);
            road.ay = float(uy);
            road.hl = float(length * 0.5 + road_hw);
            road.hw = float(road_hw);
            road.kind = kRoad;
            road.param = float(wealth);
            road.flag = exit ? 1.0f : 0.0f;
            road.style = style;
            road.seed = float(stable_hash(CELL[i], k, 0, 78, layout_seed) & 0xffffU) / 65535.0f;
            grounds.push_back(road);
        }

        // Importance order doubles as draw order and LOD order: within one lot
        // the main roof always precedes its attached chimney or tower.
        std::sort(bodies.begin() + static_cast<std::ptrdiff_t>(cell_body_start), bodies.end(),
                [](const BodyInstance &lhs, const BodyInstance &rhs) {
                    if (lhs.importance != rhs.importance) {
                        return lhs.importance > rhs.importance;
                    }
                    return lhs.order < rhs.order;
                });
        const size_t cell_bodies = bodies.size() - cell_body_start;
        for (size_t n = 0; n < cell_bodies; ++n) {
            bodies[cell_body_start + n].rank = float((double(n) + 0.5) / double(cell_bodies));
        }
        std::sort(grounds.begin() + static_cast<std::ptrdiff_t>(cell_ground_start), grounds.end(),
                [](const GroundInstance &lhs, const GroundInstance &rhs) {
                    return lhs.order < rhs.order;
                });
    }
}
