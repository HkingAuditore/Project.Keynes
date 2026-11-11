// Private implementation of military_core_logistics.cpp; included once inside
// namespace pk. Physical maintenance (design §2/§3, plan S2/S3).
//
// One day does exactly this, in this order:
//   1. REBUILD  - the maintenance objects that exist today, from the committed
//                 economy ledger (state buildings) and the live lots
//                 (equipment). Nothing is invented locally: a demolished
//                 building simply stops producing a row, and its unspent
//                 demand dies with it (design §2 last bullet).
//   2. DEMAND   - each recipe component grows by `rate * units` in q32 and only
//                 the whole part becomes milli-goods. The remainder is carried,
//                 so a 1-man lot is not truncated to zero and nobody is forced
//                 to consume at least one item per day.
//   3. CONSUME  - the completion ratio is the MINIMUM over the components (they
//                 are mutually necessary), and only `need * ratio` is drawn.
//                 Leftovers stay in stock.
//   4. EFFECT   - buildings settle a 5-day window (< 50% -> disrepair, which is
//                 what halves the fort and war-college bonuses); equipment
//                 updates the lot condition from the recipe ratio ONLY, so a
//                 full ration store can never hide a repair shortage.
//   5. BUY      - cover below 5 days tops up to 10, cheapest reachable market
//                 first, within the maintenance share of the envelope. The order
//                 is an intention: `settle_purchase` is still the only place
//                 that credits stock or charges the treasury.
namespace {

// Consumption scale of a loan/terrain pair (same inputs the supply pass uses, so
// equipment maintenance reacts to terrain and the national supply multiplier
// exactly like everything else).
int32_t maintenance_scale_q16(const MilitaryCore &core, const MilitaryWorldDigest &digest,
                              int32_t slot, int32_t cell) {
    const int32_t landform = terrain_of_cell(core.terrain(), cell);
    const int64_t terrain_mult = landform_supply_mult_q16(core.catalog(), landform);
    const int64_t consume_mult = stat_or(digest, slot, MSTAT_SUPPLY_CONSUMPTION);
    return (int32_t)clamp_q16((terrain_mult * consume_mult) >> 16, 1, 8 * MILITARY_Q16);
}

const std::vector<MilitaryRepairMaterial> *repair_recipe_of(const MilitaryCore &core,
                                                            const MilitaryMaintenanceRow &row) {
    if (row.object_id < 0) return nullptr;
    if (row.kind == 0) {
        if (row.object_id >= (int32_t)core.catalog().state_buildings.size()) return nullptr;
        return &core.catalog().state_buildings[(size_t)row.object_id].repair_materials;
    }
    if (row.object_id >= (int32_t)core.catalog().units.size()) return nullptr;
    return &core.catalog().units[(size_t)row.object_id].repair_materials;
}

int32_t state_building_index(const MilitaryCatalog &catalog, uint8_t role, int32_t tier) {
    for (size_t i = 0; i < catalog.state_buildings.size(); ++i) {
        const MilitaryStateBuilding &b = catalog.state_buildings[i];
        if (b.role == role && (int32_t)b.tier == tier) return (int32_t)i;
    }
    return -1;
}

bool maint_key_less(const MilitaryMaintenanceRow &a, const MilitaryMaintenanceRow &b) {
    if (a.country_slot != b.country_slot) return a.country_slot < b.country_slot;
    if (a.kind != b.kind) return a.kind < b.kind;
    if (a.holder_kind != b.holder_kind) return a.holder_kind < b.holder_kind;
    if (a.holder != b.holder) return a.holder < b.holder;
    return a.object_id < b.object_id;
}

bool maint_key_equal(const MilitaryMaintenanceRow &a, const MilitaryMaintenanceRow &b) {
    return a.country_slot == b.country_slot && a.kind == b.kind &&
           a.holder_kind == b.holder_kind && a.holder == b.holder &&
           a.object_id == b.object_id;
}

} // namespace

void MilitaryCore::rebuild_maintenance_rows(const MilitaryWorldDigest &digest) {
    std::vector<MilitaryMaintenanceRow> next;
    // ---- state buildings: the ledger is the count of record -----------------
    for (const MilitaryCellState &st : _cell_states) {
        if (st.cell < 0 || st.cell >= _terrain.cell_count) continue;
        if ((size_t)st.cell >= digest.cell_owner_slot.size()) continue;
        const int32_t slot = digest.cell_owner_slot[(size_t)st.cell];
        if (slot < 0) continue;
        for (int32_t tier = 0; tier < MILITARY_STATE_BARRACKS_TIERS; ++tier) {
            const int32_t count = st.barracks_count[tier];
            if (count <= 0) continue;
            const int32_t index = state_building_index(_catalog, (uint8_t)MILITARY_STATE_BARRACKS, tier);
            if (index < 0) continue;
            MilitaryMaintenanceRow row;
            row.country_slot = slot;
            row.cell = st.cell;
            row.kind = 0;
            row.object_id = index;
            row.holder_kind = MILITARY_LOT_MAINTENANCE;
            row.holder = maintenance_holder_for(st.cell, index);
            row.units = count;
            next.push_back(row);
        }
        const struct { int32_t tier; uint8_t role; } fixed[2] = {
            {st.fort_tier, (uint8_t)MILITARY_STATE_FORTIFICATION},
            {st.college_tier, (uint8_t)MILITARY_STATE_WAR_COLLEGE},
        };
        for (const auto &f : fixed) {
            if (f.tier < 0) continue;
            const int32_t index = state_building_index(_catalog, f.role, f.tier);
            if (index < 0) continue;
            MilitaryMaintenanceRow row;
            row.country_slot = slot;
            row.cell = st.cell;
            row.kind = 0;
            row.object_id = index;
            row.holder_kind = MILITARY_LOT_MAINTENANCE;
            row.holder = maintenance_holder_for(st.cell, index);
            row.units = 1;
            next.push_back(row);
        }
    }
    // ---- equipment: aggregate the live lots by (holder, unit type) ----------
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0 || _lots.count[i] <= 0) continue;
        const int32_t unit_type = _lots.unit_type[i];
        if (unit_type < 0 || unit_type >= (int32_t)_catalog.units.size()) continue;
        if (_catalog.units[(size_t)unit_type].repair_materials.empty()) continue;
        const uint8_t loc_kind = _lots.location_kind[i];
        const int32_t loc = _lots.location[i];
        if (loc_kind == (uint8_t)MILITARY_LOT_ARMY) {
            if (!army_alive(_armies, loc)) continue;
        } else if (loc_kind != (uint8_t)MILITARY_LOT_GARRISON) {
            continue;
        }
        if (loc < 0) continue;
        // Linear probe over the (few) equipment rows of this holder; the table
        // holds one row per holder and unit type, never one per lot.
        bool merged = false;
        for (MilitaryMaintenanceRow &row : next) {
            if (row.kind != 1 || row.holder_kind != loc_kind || row.holder != loc ||
                row.object_id != unit_type || row.country_slot != _lots.country_slot[i])
                continue;
            row.units += (int32_t)std::min<int64_t>(_lots.count[i], INT32_MAX);
            merged = true;
            break;
        }
        if (merged) continue;
        MilitaryMaintenanceRow row;
        row.country_slot = _lots.country_slot[i];
        row.cell = loc_kind == (uint8_t)MILITARY_LOT_ARMY ? _armies.cell[(size_t)loc] : loc;
        row.kind = 1;
        row.object_id = unit_type;
        row.holder_kind = loc_kind;
        row.holder = loc;
        row.units = (int32_t)std::min<int64_t>(_lots.count[i], INT32_MAX);
        next.push_back(row);
    }
    std::sort(next.begin(), next.end(), maint_key_less);
    // ---- carry the persistent fields over by key ---------------------------
    // `_maint_rows` is sorted by the same key, so this is a linear merge. A row
    // that is not in `next` anymore (demolished, disbanded, ceded) is dropped
    // with its remainder and window: the design forbids inheriting unfinished
    // maintenance demand.
    size_t old = 0;
    for (MilitaryMaintenanceRow &row : next) {
        while (old < _maint_rows.size() && maint_key_less(_maint_rows[old], row)) ++old;
        if (old >= _maint_rows.size() || !maint_key_equal(_maint_rows[old], row)) continue;
        const MilitaryMaintenanceRow &prev = _maint_rows[old];
        for (int32_t m = 0; m < MILITARY_MAX_REPAIR_MATERIALS; ++m)
            row.acc_q32[m] = prev.acc_q32[m];
        row.window_need = prev.window_need;
        row.window_met = prev.window_met;
        row.window_days = prev.window_days;
        row.ratio_bp = prev.ratio_bp;
        row.disrepair = prev.disrepair;
    }
    _maint_rows.swap(next);
}

void MilitaryCore::run_maintenance(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    const auto started = std::chrono::steady_clock::now();
    rebuild_maintenance_rows(digest);
    // The verdict these rows publish for the fort / war-college effects is
    // derived, so it is cleared before the rows fill it in again.
    for (MilitaryCellState &st : _cell_states) st.disrepair = 0;
    // Pending maintenance purchases are part of the coverage the reorder test
    // reads, so a country never orders the same good twice for one row.
    _report.maintenance_backlog = 0;
    for (const MilitaryPurchaseOrder &order : _purchase_orders) {
        if (order.channel == 1) _report.maintenance_backlog += order.intent.count;
    }
    _report.maintenance_rows = (int32_t)_maint_rows.size();
    _report.maintenance_disrepair_rows = 0;

    MarketDayScope day(*this);
    bool day_ready = false;
    for (size_t row_index_consume = 0; row_index_consume < _maint_rows.size();
         ++row_index_consume) {
        MilitaryMaintenanceRow &row = _maint_rows[row_index_consume];
        const std::vector<MilitaryRepairMaterial> *recipe = repair_recipe_of(*this, row);
        if (recipe == nullptr || recipe->empty()) continue;
        const int32_t count = (int32_t)std::min<size_t>(recipe->size(),
                                                        (size_t)MILITARY_MAX_REPAIR_MATERIALS);
        int32_t scale = MILITARY_Q16;
        if (row.kind == 1) scale = maintenance_scale_q16(*this, digest, row.country_slot, row.cell);
        int64_t need[MILITARY_MAX_REPAIR_MATERIALS] = {};
        int64_t avail[MILITARY_MAX_REPAIR_MATERIALS] = {};
        int64_t need_total = 0;
        for (int32_t m = 0; m < count; ++m) {
            const MilitaryRepairMaterial &mat = (*recipe)[(size_t)m];
            if (mat.good < 0 || mat.rate_q32 <= 0) continue;
            // per day: building = rate * count, equipment = rate * heads / 100.
            int64_t per_day = row.kind == 0
                                  ? mat.rate_q32 * (int64_t)std::max(0, row.units)
                                  : (mat.rate_q32 * (int64_t)std::max(0, row.units)) / 100;
            if (row.kind == 1) per_day = mul_q16(per_day, scale);
            int64_t acc = row.acc_q32[m] + per_day;
            need[m] = acc >> 32;
            row.acc_q32[m] = acc & 0xFFFFFFFFll;
            if (need[m] <= 0) continue;
            need_total += need[m];
            avail[m] = std::max<int64_t>(0, stock_get(row.holder_kind, row.holder,
                                                      row.country_slot, mat.good));
        }
        // Completion ratio = MIN over the components. They are mutually
        // necessary, so a full store of two of three materials completes nothing.
        int64_t ratio_q16 = MILITARY_Q16;
        for (int32_t m = 0; m < count; ++m) {
            if (need[m] <= 0) continue;
            const int64_t r = std::min<int64_t>(MILITARY_Q16,
                                                (avail[m] * MILITARY_Q16) / need[m]);
            if (r < ratio_q16) ratio_q16 = r;
        }
        int64_t met_total = 0;
        for (int32_t m = 0; m < count; ++m) {
            if (need[m] <= 0) continue;
            const MilitaryRepairMaterial &mat = (*recipe)[(size_t)m];
            const int64_t take = (need[m] * ratio_q16) >> 16;
            if (take <= 0) continue;
            stock_add(row.holder_kind, row.holder, row.country_slot, mat.good, -take);
            _ledger_consumed += take;
            met_total += take;
        }
        // Coverage for the refill order (design S4-3), measured here so the buy
        // pass needs no second stock lookup: stock still on hand against the
        // row's daily recipe demand.
        {
            int64_t daily_milli = 0;
            int64_t stock_milli = 0;
            for (int32_t m = 0; m < count; ++m) {
                if (need[m] <= 0) continue;
                const MilitaryRepairMaterial &mat = (*recipe)[(size_t)m];
                const int64_t per_day = row.kind == 0
                                            ? mat.rate_q32 * (int64_t)std::max(0, row.units)
                                            : (mat.rate_q32 * (int64_t)std::max(0, row.units)) / 100;
                daily_milli += per_day >> 32;
                stock_milli += avail[m];
            }
            if (daily_milli > 0 && (size_t)row_index_consume < _maint_cover_x1000.size())
                _maint_cover_x1000[row_index_consume] = (stock_milli * 1000) / daily_milli;
        }
        _report.maintenance_need_goods += need_total;
        _report.maintenance_met_goods += met_total;
        row.ratio_bp = (int32_t)((ratio_q16 * 10000) >> 16);
        if (row.kind == 1) {
            // Equipment condition reads the recipe ratio ONLY (design §3): a full
            // ration/fuel/ammo store can no longer mask a repair shortage. The
            // lots are updated in ONE pass after this loop (binary search per
            // lot), because a per-row scan of every lot is O(rows x lots) and was
            // measurable on the 2400-cell bench.
            continue;
        }
        // Buildings settle on a 5-day window (design §2): the verdict is not a
        // one-day blip, and it is per building group, never per country.
        row.window_need += need_total;
        row.window_met += met_total;
        if (++row.window_days < 5) continue;
        const bool poor = row.window_need > 0 && row.window_met * 2 < row.window_need;
        row.disrepair = poor ? 1 : 0;
        row.window_need = 0;
        row.window_met = 0;
        row.window_days = 0;
        if (row.disrepair) {
            const MilitaryStateBuilding &b = _catalog.state_buildings[(size_t)row.object_id];
            // Only the two effects the design names are halved, and they are read
            // through the per-cell flag the war and training paths already use.
            if (b.role == (uint8_t)MILITARY_STATE_FORTIFICATION ||
                b.role == (uint8_t)MILITARY_STATE_WAR_COLLEGE) {
                for (MilitaryCellState &st : _cell_states) {
                    if (st.cell == row.cell) { st.disrepair = 1; break; }
                }
            }
        }
    }

    // ---- equipment condition, one pass over the lots ----------------------
    // Every live lot that carries a repair recipe resolves its maintenance row by
    // binary search and takes that row's verdict for the day. This is O(lots log
    // rows) instead of O(rows x lots).
    for (size_t i = 0; i < _lots.active.size(); ++i) {
        if (_lots.active[i] == 0 || _lots.count[i] <= 0) continue;
        const int32_t unit_type = _lots.unit_type[i];
        if (unit_type < 0 || unit_type >= (int32_t)_catalog.units.size()) continue;
        if (_catalog.units[(size_t)unit_type].repair_materials.empty()) continue;
        MilitaryMaintenanceRow probe;
        probe.country_slot = _lots.country_slot[i];
        probe.kind = 1;
        probe.holder_kind = _lots.location_kind[i];
        probe.holder = _lots.location[i];
        probe.object_id = unit_type;
        const auto it = std::lower_bound(_maint_rows.begin(), _maint_rows.end(), probe,
                                         maint_key_less);
        if (it == _maint_rows.end() || !maint_key_equal(*it, probe)) continue;
        const bool maintained = it->ratio_bp * 2 >= 10000;
        int32_t condition = _lots.condition_q16[i];
        if (condition <= 0) condition = MILITARY_Q16;
        condition += maintained ? CONDITION_RECOVER_Q16 : -CONDITION_DECAY_Q16;
        if (condition < CONDITION_FLOOR_Q16) condition = CONDITION_FLOOR_Q16;
        if (condition > MILITARY_Q16) condition = MILITARY_Q16;
        _lots.condition_q16[i] = condition;
    }

    // ---- maintenance purchase pass ----------------------------------------
    // Cover below 5 days tops the row up to 10 days worth of every component.
    // The order is placed against the MAINTENANCE share of the envelope; when a
    // country has no envelope the maintenance channel buys against cash exactly
    // like the general one, so AI countries keep behaving as before.
    std::vector<int64_t> cash_left((size_t)std::max(0, digest.country_capacity), 0);
    std::vector<int64_t> quota_left((size_t)std::max(0, digest.country_capacity), -1);
    for (int32_t slot = 0; slot < digest.country_capacity; ++slot) {
        int64_t cash = (size_t)slot < digest.country_cash.size()
                           ? std::max<int64_t>(0, digest.country_cash[(size_t)slot]) : 0;
        // 军饷 is reserved first (design S4-1): what is left is the pool the
        // maintenance channel may promise.
        if ((size_t)slot < _policies.size())
            cash = std::max<int64_t>(0, cash - _policies[(size_t)slot].wage_planned_today);
        cash_left[(size_t)slot] = cash;
        if ((size_t)slot < _policies.size() && _policies[(size_t)slot].budget_share_bp > 0) {
            const MilitaryBudgetSplit split = budget_split(slot, cash);
            if (split.enabled) {
                quota_left[(size_t)slot] = std::max<int64_t>(0, split.upkeep_ceiling);
                cash_left[(size_t)slot] = std::min(cash_left[(size_t)slot], quota_left[(size_t)slot]);
            }
        }
    }
    for (size_t slot = 0; slot < _policies.size(); ++slot)
        _policies[slot].maintenance_planned_today = 0;
    _maint_forecast.clear();
    _maint_buy_state.assign(_maint_rows.size(), 0);
    _maint_cover_x1000.assign(_maint_rows.size(), std::numeric_limits<int64_t>::max());
    // Refill order (design S4-3): the objects closest to running dry are served
    // first, ties broken by the stable object order (the row index, because
    // `_maint_rows` is sorted by (country, kind, holder, object)). A row with no
    // demand sorts last: there is nothing to buy for it.
    std::vector<std::pair<int64_t, int32_t>> buy_order;
    buy_order.reserve(_maint_rows.size());
    for (size_t row_index = 0; row_index < _maint_rows.size(); ++row_index) {
        const int64_t cover = row_index < _maint_cover_x1000.size()
                                  ? _maint_cover_x1000[row_index]
                                  : std::numeric_limits<int64_t>::max();
        buy_order.emplace_back(cover, static_cast<int32_t>(row_index));
    }
    std::sort(buy_order.begin(), buy_order.end());
    for (const auto &buy_entry : buy_order) {
        const size_t row_index = static_cast<size_t>(buy_entry.second);
        MilitaryMaintenanceRow &row = _maint_rows[row_index];
        if (row.country_slot < 0 || (size_t)row.country_slot >= cash_left.size()) {
            _maint_buy_state[row_index] = 1;
            continue;
        }
        if (cash_left[(size_t)row.country_slot] <= 0) {
            _maint_buy_state[row_index] = 1;
            continue;
        }
        const std::vector<MilitaryRepairMaterial> *recipe = repair_recipe_of(*this, row);
        if (recipe == nullptr || recipe->empty()) {
            _maint_buy_state[row_index] = 2;
            continue;
        }
        const int32_t count = (int32_t)std::min<size_t>(recipe->size(),
                                                        (size_t)MILITARY_MAX_REPAIR_MATERIALS);
        for (int32_t m = 0; m < count; ++m) {
            const MilitaryRepairMaterial &mat = (*recipe)[(size_t)m];
            if (mat.good < 0 || mat.rate_q32 <= 0) continue;
            const int64_t daily = row.kind == 0
                                      ? mat.rate_q32 * (int64_t)std::max(0, row.units)
                                      : (mat.rate_q32 * (int64_t)std::max(0, row.units)) / 100;
            if (daily <= 0) continue;
            const int64_t target = (daily * MILITARY_MAINT_TARGET_DAYS) >> 32;
            if (target <= 0) {
                _maint_buy_state[row_index] = 3;
                continue;
            }
            int64_t have = std::max<int64_t>(0, stock_get(row.holder_kind, row.holder,
                                                          row.country_slot, mat.good));
            for (const MilitaryShipment &shipment : _shipments) {
                if (shipment.dest_kind != row.holder_kind || shipment.dest != row.holder ||
                    shipment.country_slot != row.country_slot || shipment.good != mat.good)
                    continue;
                have += std::max<int64_t>(0, shipment.qty);
            }
            for (const MilitaryPurchaseOrder &order : _purchase_orders) {
                if (order.channel != 1 || order.dest_kind != row.holder_kind ||
                    order.dest != row.holder || order.stock_good != mat.good)
                    continue;
                have += std::max<int64_t>(0, order.intent.count);
            }
            // Reorder floor and target are the shared 5/10-day policy.
            if (have * MILITARY_MAINT_REORDER_DAYS >= target * MILITARY_MAINT_REORDER_DAYS / 2) continue;
            int64_t missing = target - have;
            if (missing <= 0) continue;
            if (!day_ready) { day.ensure(digest); day_ready = true; }
            // Cheapest reachable market inside the supply ring, one market at a
            // time; the day quota is shared with the general procurement pass so
            // the two can never oversell the same row.
            const int32_t ring_begin = (size_t)row.cell + 1 < _ring_off.size()
                                           ? _ring_off[(size_t)row.cell] : 0;
            const int32_t ring_end = (size_t)row.cell + 1 < _ring_off.size()
                                         ? _ring_off[(size_t)row.cell + 1] : 0;
            int32_t best_row = -1;
            int64_t best_price = 0;
            for (int32_t r = ring_begin; r < ring_end && missing > 0; ++r) {
                const int32_t market_cell = _ring_cells[(size_t)r];
                if (!military_owns_cell(*this, digest, market_cell, row.country_slot)) continue;
                if ((size_t)market_cell + 1 >= _md_cell_off.size()) continue;
                for (int32_t k = _md_cell_off[(size_t)market_cell];
                     k < _md_cell_off[(size_t)market_cell + 1]; ++k) {
                    const int32_t market_row = _md_cell_rows[(size_t)k];
                    if (_md_row_good[(size_t)market_row] != mat.good) continue;
                    if (_md_row_sellable[(size_t)market_row] <= 0) continue;
                    const int64_t price = _md_row_price[(size_t)market_row];
                    if (price <= 0) continue;
                    if (best_row < 0 || price < best_price) {
                        best_row = market_row;
                        best_price = price;
                    }
                }
            }
            if (best_row < 0) {
                _maint_buy_state[row_index] = 4;
                continue;
            }
            const int64_t affordable = mul_div(cash_left[(size_t)row.country_slot],
                                               MILITARY_GOODS_SCALE, best_price);
            int64_t qty = std::min({missing, _md_row_sellable[(size_t)best_row], affordable});
            if (qty <= 0) continue;
            const int64_t cost = (best_price * qty) / MILITARY_GOODS_SCALE;
            _md_row_sellable[(size_t)best_row] -= qty;
            cash_left[(size_t)row.country_slot] -= cost;
            MilitaryIntent buy;
            buy.kind = MILITARY_INTENT_PROCURE_GOOD;
            buy.cell = _md_row_cell[(size_t)best_row];
            buy.good = mat.good;
            buy.country_a = country_handle_for(digest, row.country_slot);
            buy.count = qty;
            buy.amount = cost;
            MilitaryPurchaseOrder order;
            order.channel = 1;
            order.destination_cell = row.cell;
            order.dest_kind = row.holder_kind;
            order.dest = row.holder;
            order.dest_handle = static_cast<uint64_t>(row.holder);
            order.stock_good = mat.good;
            order.real_good = mat.good;
            order.category = -1;
            order.quality = 0;
            const int32_t distance = std::max(1, cell_distance(buy.cell, row.cell));
            order.route_cost_q16 = distance * MILITARY_Q16;
            const int32_t speed_q16 = stat_or(digest, row.country_slot, MSTAT_SUPPLY_TRANSPORT);
            int32_t days = (order.route_cost_q16 + speed_q16 - 1) / speed_q16;
            if (days < 1) days = 1;
            order.days = days;
            queue_purchase(buy, order, out);
            if ((size_t)row.country_slot < _policies.size())
                _policies[(size_t)row.country_slot].maintenance_planned_today += cost;
            _maint_buy_state[row_index] = 5;
            ++_report.intents_emitted;
        }
    }
    // ---- residual gap as a demand SIGNAL (design S4-4) --------------------
    // Whatever the maintenance channel could not buy today becomes a forecast row
    // (no custody, no cash, no sale). It rides the same opcode the general pass
    // uses, and is appended AFTER that pass's reset row so it survives it.
    for (size_t vector_index = 0; vector_index < _maint_rows.size(); ++vector_index) {
        const MilitaryMaintenanceRow &row = _maint_rows[vector_index];
        if (vector_index < _maint_buy_state.size() && _maint_buy_state[vector_index] == 5) continue;
        const std::vector<MilitaryRepairMaterial> *recipe = repair_recipe_of(*this, row);
        if (recipe == nullptr || recipe->empty()) continue;
        const int32_t count = (int32_t)std::min<size_t>(recipe->size(),
                                                        (size_t)MILITARY_MAX_REPAIR_MATERIALS);
        for (int32_t m = 0; m < count; ++m) {
            const MilitaryRepairMaterial &mat = (*recipe)[(size_t)m];
            if (mat.good < 0 || mat.rate_q32 <= 0) continue;
            const int64_t daily = row.kind == 0
                                      ? mat.rate_q32 * (int64_t)std::max(0, row.units)
                                      : (mat.rate_q32 * (int64_t)std::max(0, row.units)) / 100;
            if (daily <= 0) continue;
            const int64_t target = (daily * MILITARY_MAINT_TARGET_DAYS) >> 32;
            int64_t have = std::max<int64_t>(0, stock_get(row.holder_kind, row.holder,
                                                          row.country_slot, mat.good));
            for (const MilitaryPurchaseOrder &order : _purchase_orders) {
                if (order.channel != 1 || order.dest_kind != row.holder_kind ||
                    order.dest != row.holder || order.stock_good != mat.good)
                    continue;
                have += std::max<int64_t>(0, order.intent.count);
            }
            const int64_t missing = target - have;
            if (missing <= 0) continue;
            MilitaryIntent signal;
            signal.kind = MILITARY_INTENT_PROCUREMENT_DEMAND;
            signal.country_a = country_handle_for(digest, row.country_slot);
            signal.cell = row.cell;
            signal.good = mat.good;
            signal.count = missing;
            signal.amount = MILITARY_MAINT_TARGET_DAYS;
            _maint_forecast.push_back(signal);
        }
    }
    // Report the CURRENT number of disrepaired objects, not the number that
    // flipped today: the earlier "flip-only" counter read 0 on every day but the
    // 5-day settlement, which made a 5500-day run whose single barracks group
    // never received a single repair good look perfectly healthy.
    _report.maintenance_disrepair_rows = 0;
    for (const MilitaryMaintenanceRow &row : _maint_rows)
        if (row.disrepair) ++_report.maintenance_disrepair_rows;
    _report.maintenance_ms = static_cast<double>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count()) / 1000.0;
}
