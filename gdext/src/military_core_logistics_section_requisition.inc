void MilitaryCore::run_requisition(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    const int32_t cells = _terrain.cell_count;
    if (cells <= 0) return;
    if (static_cast<int32_t>(_cell_controller.size()) < cells) {
        _cell_controller.resize(static_cast<size_t>(cells), -1);
    }
    // Requisition is available to armies that lost their supply connection and
    // sit on an occupied (foreign-owned) cell (sec 9.7). Disconnection is the
    // design 9.3 test: no market cell of the same country inside the ring. The
    // probe needs the market rows, so the day scope is built here; the ring is
    // precomputed once per topology.
    MarketDayScope day(*this);
    const int32_t unit_count = static_cast<int32_t>(_catalog.units.size());
    for (size_t a = 0; a < _armies.active.size(); ++a) {
        if (_armies.active[a] == 0) continue;
        const int32_t slot = _armies.owner_slot[a];
        if (slot < 0) continue;
        const int32_t cell = _armies.cell[a];
        if (cell < 0 || cell >= cells) continue;
        // Occupied cell only: controller is us, owner is someone else.
        int64_t owner = -1;
        if (cell < static_cast<int32_t>(digest.cell_owner_slot.size())) {
            owner = digest.cell_owner_slot[static_cast<size_t>(cell)];
        }
        if (owner < 0 || owner == slot) continue;
        const int32_t controller = controller_of_cell(*this, digest, cell);
        if (controller != slot) continue;
        day.ensure(digest);
        if (military_supply_connected(*this, digest, slot, cell)) continue;
        // Daily demand of the army, per unit type, from the lot index.
        int64_t unit_heads[MILITARY_MAX_UNIT_TYPES] = {};
        bool any = false;
        military_for_each_lot(*this, (uint8_t)MILITARY_LOT_ARMY, static_cast<int32_t>(a),
                              [&](int32_t i) {
                                  if (_lots.count[(size_t)i] <= 0) return;
                                  const int32_t unit = _lots.unit_type[(size_t)i];
                                  if (unit < 0 || unit >= unit_count) return;
                                  unit_heads[unit] += _lots.count[(size_t)i];
                                  any = true;
                              });
        if (!any) continue;
        const int32_t landform = terrain_of_cell(_terrain, cell);
        const int64_t terrain_mult = landform_supply_mult_q16(_catalog, landform);
        const int32_t scale = static_cast<int32_t>(clamp_q16(terrain_mult, 1, 8 * MILITARY_Q16));
        const bool combat = _armies.engagement[a] >= 0;
        bool emitted = false;
        for (int32_t unit = 0; unit < unit_count; ++unit) {
            if (unit_heads[unit] <= 0) continue;
            const MilitaryUnitType &type = _catalog.units[static_cast<size_t>(unit)];
            for (int32_t cls = 0; cls < MILITARY_MAX_SUPPLY_CLASSES; ++cls) {
                if (cls == STOCK_CLASS_EQUIPMENT) continue;
                int64_t per_100 = type.idle_per_100_day[static_cast<size_t>(cls)];
                if (combat) per_100 += type.combat_per_100_day[static_cast<size_t>(cls)];
                if (per_100 <= 0) continue;
                int64_t demand = (unit_heads[unit] * per_100) / (100 * MILITARY_GOODS_SCALE);
                if (demand <= 0) demand = 1;
                demand = mul_q16(demand, scale);
                int64_t remaining = demand;
                const std::vector<int32_t> &goods = _catalog.supply_goods[static_cast<size_t>(cls)];
                for (size_t g = 0; g < goods.size() && remaining > 0; ++g) {
                    // The market of the occupied cell itself (no scan).
                    const int32_t slot_good = market_good_slot(digest, goods[g]);
                    if (slot_good < 0) continue;
                    for (int32_t k = _md_cell_off[(size_t)cell]; k < _md_cell_off[(size_t)cell + 1]; ++k) {
                        const int32_t row = _md_cell_rows[(size_t)k];
                        if (_md_row_good[(size_t)row] != slot_good) continue;
                        const int64_t stock = _md_row_sellable[(size_t)row];
                        if (stock <= 0) break;
                        const int64_t cap = (stock * REQUISITION_STOCK_BP) / 10000;
                        const int64_t qty = std::min(cap, remaining);
                        if (qty <= 0) break;
                        MilitaryIntent req;
                        req.kind = MILITARY_INTENT_REQUISITION;
                        req.cell = cell;
                        req.good = goods[g];
                        req.country_a = country_handle_for(digest, slot);
                        req.count = qty;
                        req.amount = 0;
                        req.source_id = army_handle(static_cast<int32_t>(a));
                        out.push_back(req);
                        ++_report.intents_emitted;
                        remaining -= qty;
                        emitted = true;
                        break;
                    }
                }
            }
        }
        if (!emitted) continue;
        // Requisition penalty on the cell (sec 9.7): 30-day consumption penalty.
        MilitaryCellState *state = cell_state(cell, true);
        if (state != nullptr) {
            state->requisition_until_day = digest.day + REQUISITION_PENALTY_DAYS;
        }
    }
}
// ================================================================== ledger
int64_t MilitaryCore::ledger_stock_total() const {
    int64_t total = 0;
    for (size_t i = 0; i < _stocks.size(); ++i) {
        if (_stocks[i].qty > 0) total += _stocks[i].qty;
    }
    return total;
}
int64_t MilitaryCore::ledger_transit_total() const {
    int64_t total = 0;
    for (size_t i = 0; i < _shipments.size(); ++i) {
        if (_shipments[i].qty > 0) total += _shipments[i].qty;
    }
    return total;
}
// Daily sec 9.7 check. reconcile_delta is the residual of
//   received ? stock + transit + consumed + intercepted_out - intercepted_in + returned
// and must stay 0: every term is written by the stage that moves goods, so a
// non-zero residual means a path moved a quantity without booking it.
void MilitaryCore::reconcile_ledger() {
    _ledger_stock = ledger_stock_total();
    _ledger_transit = ledger_transit_total();
    const int64_t right = _ledger_stock + _ledger_transit + _ledger_consumed +
                          _ledger_intercepted_out - _ledger_intercepted_in + _ledger_returned;
    _report.reconcile_delta = _ledger_received - right;
}
