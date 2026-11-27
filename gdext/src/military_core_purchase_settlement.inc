// Purchase identity, receipt handling and custody transfer for procurement and maintenance.

// ============================================================= purchase settle
// Physical-maintenance design §3 / D1 / D6.
//
// `run_procurement` (and, from S2 on, the maintenance pass) only RECORDS an
// intention to buy. This pair is the only place a purchase turns into custody:
//   queue_purchase  -> a pending order with a stable request id, nothing else
//   settle_purchase -> the real filled quantity, credited as stock (same cell)
//                      or as a convoy (other cell); the real paid amount is the
//                      only money that enters the procurement/maintenance spend.
// A receipt that names an unknown id is a duplicate (or a save that already
// settled it) and is a no-op: a repeated fill must never credit twice.
void MilitaryCore::queue_purchase(MilitaryIntent intent,
                                  const MilitaryPurchaseOrder &destination,
                                  std::vector<MilitaryIntent> &out) {
    MilitaryPurchaseOrder order = destination;
    order.intent = intent;
    if (_next_purchase_id <= 0) _next_purchase_id = 1;
    // The stable identity travels in `source_id`: the bridge copies it to the
    // pending row and back into the receipt (world_ext_military.cpp:1592/2167).
    order.intent.source_id = static_cast<uint64_t>(_next_purchase_id++);
    _purchase_orders.push_back(order);
    out.push_back(order.intent);
}

void MilitaryCore::settle_purchase(const MilitaryIntentReceipt &receipt) {
    const uint64_t request_id = receipt.source_id;
    if (request_id == 0) return;
    size_t index = _purchase_orders.size();
    for (size_t i = 0; i < _purchase_orders.size(); ++i) {
        if (_purchase_orders[i].intent.source_id == request_id) {
            index = i;
            break;
        }
    }
    if (index == _purchase_orders.size()) return;   // duplicate / already settled
    const MilitaryPurchaseOrder order = _purchase_orders[index];
    _purchase_orders.erase(_purchase_orders.begin() + static_cast<std::ptrdiff_t>(index));
    const int32_t slot = ensure_country_slot(order.intent.country_a);
    const int64_t requested = std::max<int64_t>(0, order.intent.count);
    // Only a real fill counts. A row can be acknowledged with a zero fill
    // (out of stock, no merchant, treasury empty) and that is not a delivery.
    int64_t filled = receipt.ok ? std::min<int64_t>(receipt.committed_count, requested) : 0;
    int64_t paid = receipt.ok ? std::max<int64_t>(0, std::min<int64_t>(receipt.committed_amount,
                                                                      order.intent.amount))
                              : 0;
    if (filled <= 0) {
        // Keep the shortfall visible as unmet demand; it is re-detected from the
        // stock level on the next procurement pass, so it is never lost.
        ++_report.unmet_procurement_holders;
        _report.unmet_procurement_units += requested;
        if (slot >= 0) {
            if ((int32_t)_unmet_procure_units.size() < slot + 1) {
                _unmet_procure_units.resize(static_cast<size_t>(slot + 1), 0);
            }
            _unmet_procure_units[static_cast<size_t>(slot)] += requested;
        }
        return;
    }
    // Paid money that the treasury actually moved. The maintenance channel books
    // it as maintenance spend; the general channel keeps its own rolling term.
    if (slot >= 0 && static_cast<size_t>(slot) < _policies.size()) {
        MilitaryCountryPolicy &p = _policies[static_cast<size_t>(slot)];
        if (order.channel == 1) {
            p.spend_upkeep_30 = p.spend_upkeep_30 - p.spend_upkeep_30 / 6 + paid;
            _report.maintenance_spend += paid;
        } else {
            p.spend_procurement_30 = p.spend_procurement_30 - p.spend_procurement_30 / 30 + paid;
        }
    }
    // Handover: the goods are now in military custody, so `_ledger_received` must
    // move at exactly this point. A same-cell purchase is inventory today; a
    // farther one is a real convoy, and the reconciliation identity
    // (received = stock + transit + consumed + ...) stays exact either way.
    const int32_t market_cell = order.intent.cell;
    if (order.dest_kind == MILITARY_LOT_ARMY) {
        int32_t army = -1;
        if (!resolve_army(order.dest, army)) {
            // The formation died while the purchase was in flight. The goods were
            // really bought (the market lost them and the treasury paid), so they
            // enter custody and leave it again in the same step: booking ONLY the
            // return term would break the goods identity
            // (received = stock + transit + consumed + ... + returned) by exactly
            // the refunded quantity, which is what the war scenario caught.
            _ledger_received += filled;
            _ledger_returned += filled;
            return;
        }
    }
    if (market_cell >= 0 && market_cell == order.destination_cell) {
        stock_add(order.dest_kind, order.dest, slot, order.stock_good, filled);
        _ledger_received += filled;
        if (order.dest_kind == MILITARY_LOT_TRAINING && order.quality > 0) {
            note_training_delivery(_training, _catalog, order.dest_handle,
                                   order.category, static_cast<int32_t>(order.quality));
        }
        return;
    }
    MilitaryShipment shipment;
    shipment.id = _next_id++;
    shipment.country_slot = slot;
    shipment.dest_kind = order.dest_kind;
    shipment.dest = order.dest;
    shipment.dest_handle = order.dest_handle;
    shipment.origin_cell = market_cell;
    shipment.current_cell = market_cell;
    shipment.good = order.stock_good;
    shipment.real_good = order.real_good;
    shipment.quality = order.quality;
    shipment.qty = filled;
    shipment.value = paid;
    shipment.departure_day = _last_day;
    shipment.eta_day = _last_day + std::max(1, order.days);
    shipment.route_cost_q16 = order.route_cost_q16;
    shipment.progress_q16 = 0;
    shipment.blocked_days = 0;
    _shipments.push_back(shipment);
    _ledger_received += filled;
}
