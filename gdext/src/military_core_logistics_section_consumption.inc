namespace {
int32_t ema_3day(int32_t previous_q16, int64_t sample_q16) {
    const int64_t sample = std::min<int64_t>(std::max<int64_t>(sample_q16, 0), MILITARY_Q16);
    if (previous_q16 <= 0) return static_cast<int32_t>(sample);
    const int64_t blended =
        (static_cast<int64_t>(previous_q16) * (MILITARY_Q16 - RATION_EMA_WEIGHT_Q16) +
         sample * RATION_EMA_WEIGHT_Q16) >>
        16;
    return static_cast<int32_t>(std::min<int64_t>(std::max<int64_t>(blended, 0), MILITARY_Q16));
}
// One holder's daily use: garrison cell or army slot.
struct HolderUse {
    int32_t country_slot = -1;
    uint8_t holder_kind = 0;
    int32_t holder = -1;
    int32_t cell = -1;
    uint8_t in_combat = 0;
    int64_t heads[MILITARY_MAX_UNIT_TYPES] = {};
    int64_t need[MILITARY_MAX_SUPPLY_CLASSES] = {};     // need units per class
    int64_t satisfied[MILITARY_MAX_SUPPLY_CLASSES] = {}; // need units actually met
};
} // namespace
void MilitaryCore::run_consumption(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    const int32_t capacity = digest.country_capacity;
    if (cells <= 0 || capacity <= 0) return;
    const int32_t unit_count = std::min<int32_t>(static_cast<int32_t>(_catalog.units.size()),
                                                 MILITARY_MAX_UNIT_TYPES);
    const size_t lot_count = _lots.active.size();
    // --- Group lots into holders (deterministic: first-appearance order).
    static thread_local std::vector<HolderUse> holders;
    static thread_local std::vector<int32_t> holder_bucket;   // +1 packed holder row
    holders.clear();
    // Open-addressed (kind, location, slot) -> holder row. A linear scan here
    // is O(lots x holders), which dominates the stage at 100k cells with two
    // thousand field armies; the table keeps grouping O(lots).
    size_t bucket_count = 64;
    while (bucket_count < lot_count * 2 + 16) bucket_count <<= 1;
    holder_bucket.assign(bucket_count, 0);
    const size_t bucket_mask = bucket_count - 1;
    const auto holder_key = [](uint8_t kind, int32_t location, int32_t slot) {
        uint64_t k = (uint64_t)kind << 56;
        k ^= (uint64_t)(uint32_t)location * 0x9e3779b97f4a7c15ull;
        k ^= (uint64_t)(uint32_t)slot * 0xc2b2ae3d27d4eb4full;
        return mil::splitmix_final(k);
    };
    for (size_t i = 0; i < lot_count; ++i) {
        if (_lots.active[i] == 0) continue;
        const int32_t unit = _lots.unit_type[i];
        if (unit < 0 || unit >= unit_count) continue;
        const int32_t slot = _lots.country_slot[i];
        if (slot < 0 || slot >= capacity) continue;
        const int64_t count = _lots.count[i];
        if (count <= 0) continue;
        const uint8_t kind = _lots.location_kind[i];
        const int32_t location = _lots.location[i];
        int32_t cell = location;
        if (kind == MILITARY_LOT_ARMY) {
            if (location < 0 || location >= static_cast<int32_t>(_armies.active.size())) continue;
            if (_armies.active[static_cast<size_t>(location)] == 0) continue;
            cell = _armies.cell[static_cast<size_t>(location)];
        }
        const uint64_t key = holder_key(kind, location, slot);
        size_t at = (size_t)key & bucket_mask;
        int32_t found = -1;
        for (;;) {
            const int32_t packed = holder_bucket[at];
            if (packed == 0) break;
            const int32_t row = packed - 1;
            if (row >= 0 && (size_t)row < holders.size() &&
                holders[(size_t)row].holder_kind == kind &&
                holders[(size_t)row].holder == location &&
                holders[(size_t)row].country_slot == slot) {
                found = row;
                break;
            }
            at = (at + 1) & bucket_mask;
        }
        if (found < 0) {
            HolderUse use;
            use.country_slot = slot;
            use.holder_kind = kind;
            use.holder = location;
            use.cell = cell;
            use.in_combat = (kind == MILITARY_LOT_ARMY && _armies.engagement[static_cast<size_t>(location)] >= 0)
                                ? 1
                                : 0;
            holders.push_back(use);
            found = static_cast<int32_t>(holders.size()) - 1;
            holder_bucket[at] = found + 1;
        }
        holders[static_cast<size_t>(found)].heads[unit] += count;
    }
    // --- Compute needs per holder.
    for (size_t h = 0; h < holders.size(); ++h) {
        HolderUse &use = holders[h];
        if (use.cell < 0 || use.cell >= cells) continue;
        const int32_t landform = terrain_of_cell(_terrain, use.cell);
        const int64_t terrain_mult = landform_supply_mult_q16(_catalog, landform);
        const int64_t consume_mult = stat_or(digest, use.country_slot, MSTAT_SUPPLY_CONSUMPTION);
        const int32_t scale = static_cast<int32_t>(
            clamp_q16((terrain_mult * consume_mult) >> 16, 1, 8 * MILITARY_Q16));
        const int32_t ration_per_head =
            _catalog.ration_need_per_head_q16 > 0 ? _catalog.ration_need_per_head_q16
                                                  : MILITARY_Q16;
        for (int32_t unit = 0; unit < unit_count; ++unit) {
            const int64_t heads = use.heads[unit];
            if (heads <= 0) continue;
            const MilitaryUnitType &type = _catalog.units[static_cast<size_t>(unit)];
            // Ration: need units, combat day x1.25 (sec 9.2).
            int64_t per_head = ration_per_head;
            if (use.in_combat != 0) per_head = (per_head * 5) >> 2;
            int64_t ration = mul_q16(heads, static_cast<int32_t>(per_head));
            ration = mul_q16(ration, scale);
            use.need[MILITARY_SUPPLY_RATION] += ration;
            for (int32_t cls = MILITARY_SUPPLY_FODDER; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                int64_t per_100 = type.idle_per_100_day[static_cast<size_t>(cls)];
                if (use.in_combat != 0) {
                    per_100 += type.combat_per_100_day[static_cast<size_t>(cls)];
                }
                if (per_100 <= 0) continue;
                int64_t goods = (heads * per_100) / (100 * MILITARY_GOODS_SCALE);
                if (goods <= 0) goods = 0;
                goods = mul_q16(goods, scale);
                // Same quantity, expressed in need units for the ration ratio.
                use.need[static_cast<size_t>(cls)] += goods * MILITARY_GOODS_SCALE;
            }
        }
    }
    // --- Consume from stock (highest yield first) and emit the treasury
    // consumption intents that keep the sec 9.7 ledger exact.
    for (size_t h = 0; h < holders.size(); ++h) {
        HolderUse &use = holders[h];
        if (use.cell < 0 || use.cell >= cells) continue;
        for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
            if (cls == STOCK_CLASS_EQUIPMENT) continue;
            int64_t want_units = use.need[static_cast<size_t>(cls)];
            if (want_units <= 0) continue;
            const std::vector<int32_t> &goods = _catalog.supply_goods[static_cast<size_t>(cls)];
            const std::vector<int32_t> &yields = _catalog.supply_yield_q16[static_cast<size_t>(cls)];
            // Preference: higher yield per good first (better nutrition).
            size_t order[MILITARY_MAX_SUPPLY_CLASSES * 2] = {};
            size_t order_len = 0;
            for (size_t g = 0; g < goods.size() && order_len < sizeof(order) / sizeof(order[0]);
                 ++g) {
                order[order_len++] = g;
            }
            for (size_t a = 1; a < order_len; ++a) {
                const size_t key = order[a];
                const int32_t key_yield = key < yields.size() ? yields[key] : MILITARY_Q16;
                size_t b = a;
                while (b > 0) {
                    const int32_t prev_yield =
                        order[b - 1] < yields.size() ? yields[order[b - 1]] : MILITARY_Q16;
                    if (prev_yield >= key_yield) break;
                    order[b] = order[b - 1];
                    --b;
                }
                order[b] = key;
            }
            for (size_t k = 0; k < order_len && want_units > 0; ++k) {
                const int32_t good = goods[order[k]];
                const int64_t held = stock_get(use.holder_kind, use.holder, use.country_slot, good);
                if (held <= 0) continue;
                const int32_t y = order[k] < yields.size() ? yields[order[k]] : MILITARY_Q16;
                const int64_t unit_yield = y > 0 ? y : MILITARY_Q16;
                int64_t goods_needed = (want_units * MILITARY_Q16 + unit_yield - 1) / unit_yield;
                if (goods_needed <= 0) goods_needed = 1;
                const int64_t take = std::min(held, goods_needed);
                if (take <= 0) continue;
                stock_add(use.holder_kind, use.holder, use.country_slot, good, -take);
                const int64_t met = mul_q16(take, static_cast<int32_t>(unit_yield));
                use.satisfied[static_cast<size_t>(cls)] += std::min(met, want_units);
                want_units -= std::min(met, want_units);
                _ledger_consumed += take;
                MilitaryIntent consume;
                consume.kind = MILITARY_INTENT_CONSUME_TREASURY_GOOD;
                consume.cell = use.cell;
                consume.good = good;
                consume.country_a = country_handle_for(digest, use.country_slot);
                consume.count = take;
                consume.source_id = (static_cast<uint64_t>(use.holder_kind) << 32) |
                                    static_cast<uint32_t>(use.holder);
                out.push_back(consume);
                ++_report.intents_emitted;
            }
        }
        // --- Ration ratio EMA on the army (sec 10 morale input).
        if (use.holder_kind == MILITARY_LOT_ARMY) {
            const int32_t army = use.holder;
            if (army < 0 || army >= static_cast<int32_t>(_armies.active.size())) continue;
            if (_armies.active[static_cast<size_t>(army)] == 0) continue;
            const int64_t need = use.need[MILITARY_SUPPLY_RATION];
            const int64_t sample_q16 = need > 0
                                           ? (use.satisfied[MILITARY_SUPPLY_RATION] * MILITARY_Q16) / need
                                           : MILITARY_Q16;
            _armies.ration_ratio_q16[static_cast<size_t>(army)] =
                ema_3day(_armies.ration_ratio_q16[static_cast<size_t>(army)], sample_q16);
            int64_t need_total = 0;
            int64_t met_total = 0;
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                need_total += use.need[static_cast<size_t>(cls)];
                met_total += use.satisfied[static_cast<size_t>(cls)];
            }
            const int64_t supply_q16 =
                need_total > 0 ? (met_total * MILITARY_Q16) / need_total : MILITARY_Q16;
            _armies.supply_ratio_q16[static_cast<size_t>(army)] =
                ema_3day(_armies.supply_ratio_q16[static_cast<size_t>(army)], supply_q16);
        }
    }
    // Equipment condition decay / recovery moved to `run_maintenance` (physical
    // maintenance design §3): condition now reads the REPAIR RECIPE ratio only.
    // The old block here used the aggregate supply ratio, so a full ration, fuel
    // and ammunition store kept equipment "maintained" while no repair material
    // ever arrived - the exact coupling this refactor removes. Applying both
    // would double the daily wear/recovery, so this is a move, not a copy.
}
