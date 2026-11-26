#include "economy_runtime_colonization_kit_includes.inc"

namespace pk {

bool NativeEconomyRuntime::adjust_market_stock(
        int32_t cell, int32_t good_id, int64_t delta, std::string &error) {
    if (cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= market_store().good_count.get()) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get()) {
        error = "colonization_kit_market_invalid";
        return false;
    }
    const int64_t index = market_store().index(market, good_id);
    const int64_t next = market_store().stock[index] + delta;
    if (next < 0) {
        error = "colonization_kit_materials_short";
        return false;
    }
    audit_touch_market_lane(static_cast<size_t>(index));
    market_store().stock.write_scalar(index, next, market_mutation_sink());
    return true;
}

void NativeEconomyRuntime::collect_family_expedition_reserved_stock(
        int32_t expedition, std::vector<int64_t> &reserved) const {
    reserved.assign(_good_ids.size(), 0);
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) return;
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        static_cast<uint32_t>(family_expedition_cargo().size()),
        begin + family_expeditions_store().cargo_count[expedition]);
    int64_t sat = 0;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionCargoLine &line = family_expedition_cargo()[i];
        if (line.good_id < 0 ||
            line.good_id >= static_cast<int32_t>(reserved.size())) continue;
        reserved[static_cast<size_t>(line.good_id)] = saturating_add(
            reserved[static_cast<size_t>(line.good_id)], line.quantity, sat);
    }
}

void NativeEconomyRuntime::note_family_expedition_procurement_rejection(
        int32_t expedition, int32_t good, uint8_t cargo_flags, int64_t day,
        const std::string &reason) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size())) return;
    FamilyExpeditionProcurementRejection &note =
        _family_expedition_procurement_rejections[expedition];
    note.generation = family_expeditions_store().generation[expedition];
    note.good = good;
    note.cargo_flags = cargo_flags;
    note.day = day;
    note.reason = reason.empty() ? "colonization_treasury_purchase_failed"
                                 : reason;
}

bool NativeEconomyRuntime::reserve_preparing_family_expedition_cargo(
        int32_t expedition, ColonizationKitPlan &kit,
        std::string &error, int64_t day) {
    ensure_epoch_colonization_budget(static_cast<uint64_t>(
        family_expeditions_store().country_handle[expedition]));
    const int32_t source_cell = family_expeditions_store().source_cell[expedition];
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t count = family_expeditions_store().cargo_count[expedition];
    if (static_cast<size_t>(begin) + count > family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    // The planner already counted the escrow as available stock, so every kit
    // line states the total the party must hold. Only the difference moves:
    // surplus goes back to the source market first so the top-up can spend it.
    // Cargo can contain duplicate rows after a kit is re-planned.  Treat the
    // escrow as a multiset; looking only at the first row loses stock when the
    // market delta is calculated and eventually breaks goods conservation.
    auto quantity_for = [](const std::vector<FamilyExpeditionCargoLine> &rows,
            int32_t good, uint8_t flags) -> int64_t {
        int64_t total = 0;
        int64_t saturation = 0;
        for (const FamilyExpeditionCargoLine &line : rows)
            if (line.good_id == good && line.flags == flags)
                total = NativeEconomyRuntime::saturating_add(
                    total, line.quantity, saturation);
        return total;
    };
    std::vector<FamilyExpeditionCargoLine> old_cargo;
    old_cargo.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
        old_cargo.push_back(family_expedition_cargo()[begin + i]);
    auto store_cargo = [&](const std::vector<FamilyExpeditionCargoLine> &rows) {
        uint32_t stored_begin =
            family_expeditions_store().cargo_begin[expedition];
        uint32_t stored_count =
            family_expeditions_store().cargo_count[expedition];
        if (rows.size() <= stored_count &&
            static_cast<size_t>(stored_begin) + stored_count <=
                family_expedition_cargo().size()) {
            for (size_t i = 0; i < rows.size(); ++i)
                family_expedition_cargo().write_record(stored_begin + i, rows[i], market_mutation_sink());
        } else {
            stored_begin = static_cast<uint32_t>(
                family_expedition_cargo().size());
            family_expedition_cargo().insert(family_expedition_cargo().end(),
                rows.begin(), rows.end());
        }
        stored_count = static_cast<uint32_t>(rows.size());
        family_expeditions_store().cargo_begin.write_scalar(expedition, stored_begin, market_mutation_sink());
        family_expeditions_store().cargo_count.write_scalar(expedition, stored_count, market_mutation_sink());
        note_family_expedition_audit_invalidation();
    };
    std::vector<std::pair<int32_t, int64_t>> applied;
    auto move_stock = [&](int32_t good, int64_t delta,
                          uint8_t cargo_flags) -> bool {
        if (delta == 0) return true;
        if (delta < 0) {
            // The kit only launches once every line is bought, so a line that
            // costs more than the remaining daily reserve can never be a
            // terminal rejection: the party would wait forever at "kit
            // complete" with nobody able to pay. Buy what today's allowance
            // covers and let tomorrow's replan top up the difference.
            int64_t quantity = -delta;
            const int32_t market = market_store().cell_to_market[source_cell];
            const int64_t price = market >= 0 && market < market_store().market_count.get()
                ? std::max<int64_t>(0, market_store().price[
                    market_store().index(market, good)]) : 0;
            int64_t cash = goods_cost(quantity, price, _saturation_count);
            FamilyExpeditionProcurementContinuation &continuation =
                _family_expedition_procurement_continuation;
            bool purchased = false;
            if (continuation.active) {
                if (continuation.expedition != expedition ||
                    continuation.good != good ||
                    continuation.cargo_flags != cargo_flags ||
                    continuation.quantity != quantity) {
                    error = "colonization_treasury_peer_busy";
                    return false;
                }
                purchased = advance_family_expedition_procurement(
                    continuation, error);
            } else {
                // National procurement policy caps the daily colonization
                // reserve spend (allowance refills per day, max one epoch).
                const uint64_t payer = static_cast<uint64_t>(
                    family_expeditions_store().country_handle[expedition]);
                const int64_t allowance =
                    colonization_procurement_allowance(payer, day);
                if (allowance >= 0 && cash > allowance) {
                    const int64_t affordable = allowance > 0 && price > 0
                        ? mul_div_sat(allowance, GOODS_SCALE, price,
                            _saturation_count)
                        : 0;
                    quantity = std::min(quantity, std::max<int64_t>(0, affordable));
                    // goods_cost rounds up, so trim until the partial line fits.
                    while (quantity > 0 &&
                           goods_cost(quantity, price, _saturation_count) > allowance)
                        quantity = std::max<int64_t>(0, quantity - 1);
                    if (quantity <= 0) {
                        error = "colonization_procurement_budget_exhausted";
                        return false;
                    }
                    cash = goods_cost(quantity, price, _saturation_count);
                }
                consume_colonization_procurement_allowance(payer, cash);
                purchased = start_family_expedition_procurement(
                    continuation, expedition, source_cell, market, good,
                    cargo_flags, quantity, cash, error);
            }
            if (!purchased) {
                if (error.empty()) error = "colonization_treasury_purchase_failed";
                return false;
            }
            // This line finally went through: a previous terminal rejection for
            // it is history and must stop rendering as a live blocker.
            const auto rejection =
                _family_expedition_procurement_rejections.find(expedition);
            if (rejection != _family_expedition_procurement_rejections.end() &&
                rejection->second.good == good &&
                rejection->second.cargo_flags == cargo_flags)
                _family_expedition_procurement_rejections.erase(rejection);
            auto acquired = std::find_if(old_cargo.begin(), old_cargo.end(),
                [&](const FamilyExpeditionCargoLine &held) {
                    return held.good_id == good && held.flags == cargo_flags;
                });
            if (acquired == old_cargo.end()) {
                old_cargo.push_back({good, quantity, cargo_flags});
            } else {
                acquired->quantity = saturating_add(acquired->quantity,
                    quantity, _saturation_count);
            }
            std::sort(old_cargo.begin(), old_cargo.end(),
                [](const FamilyExpeditionCargoLine &a,
                   const FamilyExpeditionCargoLine &b) {
                    return std::tie(a.flags, a.good_id) <
                        std::tie(b.flags, b.good_id);
                });
            store_cargo(old_cargo);
            // The purchase is also a non-household demand event.  Keep the
            // market pressure path identical to construction procurement.
            const int32_t signal = ensure_market_signal_index(source_cell, good);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())) {
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], quantity,
                    _saturation_count);
                _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
                    _market_signals.business_demand_ema[signal], quantity,
                    _saturation_count), market_mutation_sink());
                _market_signals.realized_withdrawal_ema.write_scalar(signal, saturating_add(
                    _market_signals.realized_withdrawal_ema[signal], quantity,
                    _saturation_count), market_mutation_sink());
            }
            return true;
        }
        if (!adjust_market_stock(source_cell, good, delta, error)) {
            for (auto it = applied.rbegin(); it != applied.rend(); ++it) {
                std::string ignored;
                adjust_market_stock(source_cell, it->first, -it->second,
                    ignored);
            }
            return false;
        }
        applied.push_back({good, delta});
        return true;
    };
    for (size_t old_index = 0; old_index < old_cargo.size(); ++old_index) {
        const FamilyExpeditionCargoLine &held = old_cargo[old_index];
        bool seen = false;
        for (size_t j = 0; j < old_index; ++j)
            if (old_cargo[j].good_id == held.good_id &&
                old_cargo[j].flags == held.flags) {
                seen = true;
                break;
            }
        if (seen) continue;
        const int64_t held_total = quantity_for(old_cargo, held.good_id, held.flags);
        const int64_t net_surplus = held_total -
            quantity_for(kit.cargo, held.good_id, held.flags);
        // Returning already purchased cargo would require a matching merchant
        // refund. Keep the escrow monotonic during preparation; the planner's
        // reserve-aware quote prevents unnecessary top-ups.
        if (net_surplus > 0) continue;
    }
    // Only one purchase can be in flight. A line the Country side rejected
    // must not starve every later line, so a terminal rejection is recorded
    // and the next line is tried; a line rejected earlier today waits.
    int32_t skip_good = -1;
    uint8_t skip_flags = 0;
    {
        const auto rejection = _family_expedition_procurement_rejections.find(
            expedition);
        if (day >= 0 &&
            rejection != _family_expedition_procurement_rejections.end() &&
            rejection->second.generation ==
                family_expeditions_store().generation[expedition] &&
            rejection->second.day == day) {
            skip_good = rejection->second.good;
            skip_flags = rejection->second.cargo_flags;
        }
    }
    bool short_lines = false;
    bool bought_today = false;
    for (size_t kit_index = 0; kit_index < kit.cargo.size(); ++kit_index) {
        const FamilyExpeditionCargoLine &line = kit.cargo[kit_index];
        bool seen = false;
        for (size_t j = 0; j < kit_index; ++j)
            if (kit.cargo[j].good_id == line.good_id &&
                kit.cargo[j].flags == line.flags) {
                seen = true;
                break;
            }
        if (seen) continue;
        const int64_t net_shortfall = quantity_for(kit.cargo, line.good_id,
            line.flags) - quantity_for(old_cargo, line.good_id, line.flags);
        if (net_shortfall <= 0) continue;
        if (skip_good == line.good_id && skip_flags == line.flags) {
            short_lines = true;
            continue;
        }
        if (move_stock(line.good_id, -net_shortfall, line.flags)) {
            bought_today = true;
            continue;
        }
        const FamilyExpeditionProcurementContinuation &continuation =
            _family_expedition_procurement_continuation;
        if (continuation.active) return false;
        // A line refused after another line already spent today's allowance is
        // not a stop the player has to act on: tomorrow's refill resumes it.
        // Only a day that bought nothing keeps a refusal note to explain why.
        if (!bought_today) {
            note_family_expedition_procurement_rejection(expedition,
                line.good_id, line.flags, day, error);
        }
        error.clear();
        short_lines = true;
    }
    if (short_lines) {
        error = "colonization_procurement_short";
        return false;
    }
    // The planner's quote is a target, not the authoritative escrow. A quote
    // can shrink when market stock or a substitute changes; never overwrite
    // goods already purchased by earlier preparation days. Merge by key and
    // keep the larger quantity, then append any old key omitted by the quote.
    std::vector<FamilyExpeditionCargoLine> merged = kit.cargo;
    for (const FamilyExpeditionCargoLine &old_line : old_cargo) {
        auto found = std::find_if(merged.begin(), merged.end(),
            [&](const FamilyExpeditionCargoLine &line) {
                return line.good_id == old_line.good_id &&
                    line.flags == old_line.flags;
            });
        if (found == merged.end()) {
            merged.push_back(old_line);
        } else if (found->quantity < old_line.quantity) {
            found->quantity = old_line.quantity;
        }
    }
    kit.cargo.swap(merged);
    store_cargo(kit.cargo);
    return true;
}

bool NativeEconomyRuntime::advance_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &c, std::string &error) {
    error.clear();
    if (!c.active) return true;
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        c.last_error = "colonization_treasury_peer_unavailable";
        c.active = false;
        error = c.last_error;
        return false;
    }
    if (c.phase == 1) {
        if (c.pending_request_id != 0) {
            RuntimeEconomyAssetResult terminal;
            if (!_simulation_host ||
                !_simulation_host->country_economy_asset_terminal_result(
                    c.pending_request_id, terminal)) {
                error = "colonization_treasury_peer_pending";
                return false;
            }
            if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
                terminal.operation != RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
                c.last_error = terminal.reason[0] != '\0'
                    ? terminal.reason.data()
                    : "colonization_treasury_peer_rejected";
                _simulation_host->acknowledge_country_economy_asset_consumed(
                    c.pending_request_id);
                c.active = false;
                c.pending_request_id = 0;
                error = c.last_error;
                return false;
            }
            if (_simulation_host->domain_is_worker_authoritative(
                    RuntimeDomainId::ECONOMY)) {
                if (!_simulation_host->finish_worker_country_asset(
                        c.pending_request_id, terminal, error)) {
                    return false;
                }
            } else if (!_simulation_host->flush_country_economy_asset_commits(
                           error, c.pending_request_id) ||
                       !_simulation_host->publish_country_worker_snapshot(
                           RUNTIME_DIRTY_COUNTRY_STATE, error)) {
                return false;
            } else {
                _simulation_host->acknowledge_country_economy_asset_consumed(
                    c.pending_request_id);
            }
            c.transaction_id = c.pending_request_id;
            c.session_epoch = terminal.session_epoch;
            c.country_generation = terminal.country_generation;
            c.peer_generation = _committed_generation;
            c.pending_request_id = 0;
            c.host_peer = true;
            // The worker-side GOOD_FROM_MARKET service already removed the
            // market stock. Only the sync path applies that mutation below.
            c.market_applied = true;
            c.phase = 4;
        } else {
            error = "colonization_treasury_peer_pending";
            return false;
        }
    }
    if (c.phase == 4) {
        if (!c.market_applied) {
            const size_t lane = market_store().index(c.market, c.good);
            if (lane >= market_store().stock.size() ||
                market_store().stock[lane] < c.quantity) {
                c.active = false;
                error = "colonization_treasury_peer_market_stock_drift";
                return false;
            }
            audit_touch_market_lane(lane);
            market_store().stock.write_scalar(lane, market_store().stock[lane] - (c.quantity), market_mutation_sink());
            c.market_applied = true;
        }
        if (!credit_family_expedition_procurement_merchants(c, error)) {
            c.active = false;
            return false;
        }
        if (!c.host_peer) {
            const godot::Dictionary applied =
                country_api::fiscal_return_port(*_country_runtime).applied(
                    {c.transaction_id, c.session_epoch, c.country_generation, c.peer_generation},
                    true, "");
            if (!static_cast<bool>(applied.get("ok", false)) ||
                godot::String(applied.get("status_name", "")) != "completed") {
                c.phase = 6;
                error = "colonization_treasury_peer_apply_ack_failed";
                return false;
            }
        }
        // The market purchase has put the goods into the Country treasury.
        // Move the same quantity out of that treasury before the caller adds
        // it to the expedition cargo, preserving the goods ledger.
        c.host_peer = false;
        c.pending_request_id = 0;
        const std::vector<int32_t> ids{c.good};
        const std::vector<int64_t> treasury{c.quantity};
        const auto route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(CountryApi::ECONOMY_ASSET_TREASURY_SPEND),
            static_cast<uint64_t>(family_expeditions_store().country_handle[c.expedition]),
            0, c.quantity, ids, treasury, error, &c.pending_request_id);
        if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
            _simulation_host->defer_country_economy_asset_settlement(
                c.pending_request_id);
            c.host_peer = true;
            c.phase = 5;
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
            // The market -> Country leg has already committed at this point.
            // Country worker backpressure (including a temporarily closed
            // operation gate) must not discard that completed leg: doing so
            // leaves cash and market goods debited while the expedition cargo
            // is still empty, which later trips the global conservation audit.
            // Keep the continuation at phase 4 and retry the treasury ->
            // expedition transfer on the next pulse.
            c.host_peer = false;
            c.phase = 4;
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        const godot::PackedInt32Array packed_ids = [&]() {
            godot::PackedInt32Array out; out.resize(1); out.set(0, c.good); return out;
        }();
        const godot::PackedInt64Array packed_qty = [&]() {
            godot::PackedInt64Array out; out.resize(1); out.set(0, c.quantity); return out;
        }();
        const godot::Dictionary begun = country_api::fiscal_return_port(*_country_runtime).submit_spend(country_api::fiscal_return_port(*_country_runtime).spend_intent(
            static_cast<int64_t>(family_expeditions_store().country_handle[c.expedition]),
            packed_ids, packed_qty, 0, _epoch_id.get(), static_cast<int32_t>(_stage)));
        if (!static_cast<bool>(begun.get("ok", false))) {
            c.active = false;
            error = godot::String(begun.get(
                "code", "colonization_treasury_transfer_rejected")).utf8().get_data();
            return false;
        }
        c.transaction_id = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("transaction_id", 0)));
        c.session_epoch = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("session_epoch", 0)));
        c.country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        c.peer_generation = _committed_generation;
        const godot::Dictionary prepared =
            country_api::fiscal_return_port(*_country_runtime).prepared(
                    {c.transaction_id, c.session_epoch, c.country_generation, c.peer_generation},
                    true, "");
        if (!static_cast<bool>(prepared.get("ok", false))) {
            c.active = false; error = "colonization_treasury_transfer_prepare_failed";
            return false;
        }
        const godot::Dictionary committed =
            country_api::fiscal_return_port(*_country_runtime).apply(c.transaction_id);
        if (!static_cast<bool>(committed.get("ok", false))) {
            c.active = false; error = "colonization_treasury_transfer_commit_failed";
            return false;
        }
        const godot::Dictionary applied =
            country_api::fiscal_return_port(*_country_runtime).applied(
                    {c.transaction_id, c.session_epoch, c.country_generation, c.peer_generation},
                    true, "");
        if (!static_cast<bool>(applied.get("ok", false)) ||
            godot::String(applied.get("status_name", "")) != "completed") {
            c.active = false; error = "colonization_treasury_transfer_ack_failed";
            return false;
        }
        c.active = false;
        return true;
    }
    if (c.phase == 6) {
        const godot::Dictionary applied =
            country_api::fiscal_return_port(*_country_runtime).applied(
                    {c.transaction_id, c.session_epoch, c.country_generation, c.peer_generation},
                    true, "");
        if (!static_cast<bool>(applied.get("ok", false)) ||
            godot::String(applied.get("status_name", "")) != "completed") {
            error = "colonization_treasury_peer_apply_ack_failed";
            return false;
        }
        c.active = false;
        return true;
    }
    if (c.phase == 5) {
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host || !_simulation_host->country_economy_asset_terminal_result(
                c.pending_request_id, terminal)) {
            error = "colonization_treasury_transfer_pending";
            return false;
        }
        if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
            terminal.operation != RuntimeEconomyAssetOperation::TREASURY_SPEND) {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
            c.active = false;
            error = terminal.reason[0] != '\0' ? terminal.reason.data()
                : "colonization_treasury_transfer_rejected";
            return false;
        }
        if (_simulation_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY)) {
            if (!_simulation_host->finish_worker_country_asset(
                    c.pending_request_id, terminal, error)) {
                return false;
            }
        } else if (!_simulation_host->flush_country_economy_asset_commits(
                       error, c.pending_request_id) ||
                   !_simulation_host->publish_country_worker_snapshot(
                       RUNTIME_DIRTY_COUNTRY_STATE, error)) {
            return false;
        } else {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
        }
        c.active = false;
        return true;
    }
    error = "colonization_treasury_peer_phase_invalid";
    c.active = false;
    return false;
}

bool NativeEconomyRuntime::credit_family_expedition_procurement_merchants(
        FamilyExpeditionProcurementContinuation &c, std::string &error) {
    while (c.merchant_cursor < c.living_merchants.size()) {
        const size_t index = c.merchant_cursor++;
        const int32_t slot = c.living_merchants[index];
        c.merchant_population_prefix = saturating_add(
            c.merchant_population_prefix,
            c.merchant_weights[index], _saturation_count);
        const int64_t next = mul_div_sat(
            c.cash, c.merchant_population_prefix,
            c.merchant_population, _saturation_count);
        const int64_t share = std::max<int64_t>(
            0, next - c.merchant_distributed);
        c.merchant_distributed = next;
        audit_touch_population_lane(slot);
        touch_accounting_slot(slot);
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot], share, _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(c.source_cell,
            population_store().handle_for_slot(slot),
            CASHFLOW_MERCHANT_BUSINESS, share, 0);
    }
    if (c.merchant_distributed != c.cash) {
        error = "colonization_treasury_peer_distribution_drift";
        return false;
    }
    // 开拓派遣的采购同样是国库支出：现金付给本地商人换取远征货物，货进国库后
    // 再随商队带出（那一腿只有货物、没有现金）。它也不是税种，所以要单独记进
    // 非税支出，否则国库现金在掉而「支出」里看不到它。
    // 相位 4 可能因 country 转账背压被重试，用 cash_booked 保证只记一次。
    if (c.cash > 0 && !c.cash_booked) {
        // 付款方按 generation-safe handle 记：这次结账可能发生在两批之间的空闲
        // 边界，那时 epoch 国家索引已经不可靠。
        uint64_t payer = c.expedition >= 0 && c.expedition <
                static_cast<int32_t>(family_expeditions_store().country_handle.size())
            ? static_cast<uint64_t>(
                  family_expeditions_store().country_handle[c.expedition]) : 0;
        if (payer == 0 && c.source_cell >= 0 &&
            c.source_cell < static_cast<int32_t>(_epoch_cell_country.size())) {
            const int32_t source_country =
                _epoch_cell_country[static_cast<size_t>(c.source_cell)];
            if (source_country >= 0 && source_country <
                    static_cast<int32_t>(_epoch_country_handles.size())) {
                payer = _epoch_country_handles[static_cast<size_t>(source_country)];
            }
        }
        note_non_tax_outflow(payer, NON_TAX_EXPEDITION_PROCUREMENT, c.cash);
        note_procurement_cash(payer, 2, c.cash);
        c.cash_booked = true;
    }
    return true;
}

bool NativeEconomyRuntime::settle_family_expedition_procurement_orphans(
        std::string &error) {
    error.clear();
    auto &orphans = _family_expedition_procurement_orphans;
    if (orphans.empty() || _simulation_host == nullptr) return true;
    size_t kept = 0;
    for (size_t i = 0; i < orphans.size(); ++i) {
        FamilyExpeditionProcurementContinuation &c = orphans[i];
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host->country_economy_asset_terminal_result(
                c.pending_request_id, terminal)) {
            if (kept != i) orphans[kept] = std::move(c);
            ++kept;
            continue;
        }
        const RuntimeEconomyAssetOperation expected = c.phase == 1
            ? RuntimeEconomyAssetOperation::GOOD_FROM_MARKET
            : RuntimeEconomyAssetOperation::TREASURY_SPEND;
        if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
            terminal.operation != expected) {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
            continue;
        }
        if (_simulation_host->domain_is_worker_authoritative(
                RuntimeDomainId::ECONOMY)) {
            if (!_simulation_host->finish_worker_country_asset(
                    c.pending_request_id, terminal, error))
                return false;
        } else if (!_simulation_host->flush_country_economy_asset_commits(
                       error, c.pending_request_id) ||
                   !_simulation_host->publish_country_worker_snapshot(
                       RUNTIME_DIRTY_COUNTRY_STATE, error)) {
            return false;
        } else {
            _simulation_host->acknowledge_country_economy_asset_consumed(
                c.pending_request_id);
        }
        // A completed market purchase leaves the goods in the Country
        // treasury; a completed treasury transfer has nowhere to go but back
        // to the source market, as cancelled cargo does.
        if (c.phase == 1) {
            if (!credit_family_expedition_procurement_merchants(c, error))
                return false;
        } else if (!adjust_market_stock(c.source_cell, c.good, c.quantity,
                                        error)) {
            return false;
        }
    }
    orphans.resize(kept);
    return true;
}

bool NativeEconomyRuntime::start_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &c,
        int32_t expedition, int32_t source_cell, int32_t market,
        int32_t good, uint8_t cargo_flags, int64_t quantity, int64_t cash,
        std::string &error) {
    c = NativeEconomyRuntime::FamilyExpeditionProcurementContinuation{};
    c.active = true;
    c.phase = 1;
    c.expedition = expedition;
    c.source_cell = source_cell;
    c.market = market;
    c.good = good;
    c.cargo_flags = cargo_flags;
    c.quantity = quantity;
    c.cash = cash;
    c.started_day = std::max<int64_t>(0, _current_day.get());
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t edge = _merchant_offsets[source_cell];
             edge < _merchant_offsets[source_cell + 1]; ++edge) {
            const int32_t slot = _merchant_slots[edge];
            if (is_merchant_slot(slot) && slot >= 0 &&
                slot < static_cast<int32_t>(population_store().population.size()) &&
                population_store().population[slot] > 0)
                c.living_merchants.push_back(slot);
        }
    }
    if (cash > 0 && c.living_merchants.empty()) {
        error = "country_treasury_peer_merchant_missing";
        c.active = false;
        return false;
    }
    c.merchant_weights.reserve(c.living_merchants.size());
    for (int32_t slot : c.living_merchants) {
        const int64_t weight = population_store().population[slot];
        c.merchant_weights.push_back(weight);
        c.merchant_population = saturating_add(
            c.merchant_population, weight, _saturation_count);
    }
    std::vector<int32_t> ids{good};
    std::vector<int64_t> goods{quantity};
    const auto route = block_or_enqueue_country_worker_asset(
        static_cast<uint16_t>(CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET),
        static_cast<uint64_t>(family_expeditions_store().country_handle[expedition]),
        cash, quantity, ids, goods, error, &c.pending_request_id, market);
    if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
        _simulation_host->defer_country_economy_asset_settlement(
            c.pending_request_id);
        error = "colonization_treasury_peer_pending";
        c.host_peer = true;
        return false;
    }
    if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
        c.active = false;
        return false;
    }
    const godot::Dictionary begun = country_api::procurement_port(*_country_runtime).submit({
        country_api::procurement_port(*_country_runtime).next_order_key(), static_cast<int64_t>(family_expeditions_store().country_handle[expedition]),
        good, quantity, _epoch_id.get(), static_cast<int32_t>(_stage), cash});
    if (!static_cast<bool>(begun.get("ok", false))) {
        error = godot::String(begun.get(
            "code", "colonization_treasury_peer_country_rejected")).utf8().get_data();
        c.active = false;
        return false;
    }
    c.transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("transaction_id", 0)));
    c.session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("session_epoch", 0)));
    c.country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("country_generation", 0)));
    c.peer_generation = _committed_generation;
    const int64_t prepared_quantity = static_cast<int64_t>(
        begun.get("prepared_quantity", 0));
    if (c.transaction_id == 0 || c.session_epoch == 0 ||
        c.country_generation == 0 || c.peer_generation == 0 ||
        prepared_quantity != quantity) {
        error = "colonization_treasury_peer_identity_invalid";
        c.active = false;
        return false;
    }
    const godot::Dictionary prepared =
        country_api::fiscal_return_port(*_country_runtime).prepared(
                    {c.transaction_id, c.session_epoch, c.country_generation, c.peer_generation},
                    true, "");
    if (!static_cast<bool>(prepared.get("ok", false))) {
        error = "colonization_treasury_peer_prepare_failed";
        c.active = false;
        return false;
    }
    const godot::Dictionary committed =
        country_api::fiscal_return_port(*_country_runtime).apply(c.transaction_id);
    if (!static_cast<bool>(committed.get("ok", false)) ||
        static_cast<int64_t>(committed.get("committed_quantity", 0)) != quantity ||
        static_cast<int64_t>(committed.get("committed_cash", cash)) != cash) {
        error = "colonization_treasury_peer_commit_failed";
        c.active = false;
        return false;
    }
    c.host_peer = false;
    c.phase = 4;
    return advance_family_expedition_procurement(c, error);
}


} // namespace pk
