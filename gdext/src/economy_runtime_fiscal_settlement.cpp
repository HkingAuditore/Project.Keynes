#include "economy_runtime_fiscal_includes.inc"

namespace pk {

bool NativeEconomyRuntime::commit_fiscal(std::string &error) {
    if (_country_runtime == nullptr) {
        error = "country_runtime_required";
        return false;
    }
    const size_t summary_count = static_cast<size_t>(
        std::max(0, _epoch_country_count)) * CountryApi::TAX_KIND_COUNT;
    _fiscal_last_bases.assign(summary_count, 0);
    _fiscal_last_assessed.assign(summary_count, 0);
    _fiscal_last_collected.assign(summary_count, 0);
    _fiscal_last_requests.assign(summary_count, 0);
    _fiscal_last_reserved.assign(summary_count, 0);
    _fiscal_last_paid.assign(summary_count, 0);
    _fiscal_last_events.assign(summary_count, 0);
    _fiscal_last_unmet.assign(summary_count, 0);
    _fiscal_cumulative_bases.resize(summary_count, 0);
    _fiscal_cumulative_collected.resize(summary_count, 0);
    _fiscal_cumulative_requests.resize(summary_count, 0);
    _fiscal_cumulative_paid.resize(summary_count, 0);
    // Non-tax outflow lanes are country x kind, not country x tax kind.
    const size_t country_lane_count = static_cast<size_t>(
        std::max(0, _epoch_country_count));
    const size_t non_tax_lane_count =
        country_lane_count * static_cast<size_t>(NON_TAX_KIND_COUNT);
    _fiscal_last_non_tax_outflow.assign(non_tax_lane_count, 0);
    _fiscal_settlement_continuation = {};
    _fiscal_settlement_continuation.country_count = _epoch_country_count;
    _fiscal_settlement_continuation.day_index = _current_day.get();
    _fiscal_settlement_continuation.unused_by_country.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _fiscal_settlement_continuation.collected_by_country.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    const bool domestic_fiscal_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << CountryApi::TAX_INCOME) |
            (1U << CountryApi::TAX_CONSUMPTION) |
            (1U << CountryApi::TAX_BUSINESS))) != 0;
    const size_t tariff_lane_count = _tariff_epoch_cells.size();
    if (_tariff_epoch_kinds.size() != tariff_lane_count ||
        _tariff_epoch_bases.size() != tariff_lane_count ||
        _tariff_epoch_assessed.size() != tariff_lane_count ||
        _tariff_epoch_collected.size() != tariff_lane_count ||
        _tariff_epoch_requests.size() != tariff_lane_count ||
        _tariff_epoch_reserved.size() != tariff_lane_count ||
        _tariff_epoch_paid.size() != tariff_lane_count ||
        _tariff_epoch_events.size() != tariff_lane_count) {
        error = "tariff_epoch_lane_shape_invalid";
        return false;
    }
    for (size_t lane = 0; lane < tariff_lane_count; ++lane) {
        const int32_t cell = _tariff_epoch_cells[lane];
        const int32_t tariff_kind = _tariff_epoch_kinds[lane];
        if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            tariff_kind < 0 || tariff_kind >= 2) {
            error = "tariff_epoch_lane_key_invalid";
            return false;
        }
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) continue;
        const size_t summary = static_cast<size_t>(country) *
            CountryApi::TAX_KIND_COUNT +
            CountryApi::TAX_IMPORT + tariff_kind;
        _fiscal_last_bases.write_scalar(summary, saturating_add(
            _fiscal_last_bases[summary], _tariff_epoch_bases[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_assessed.write_scalar(summary, saturating_add(
            _fiscal_last_assessed[summary], _tariff_epoch_assessed[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_collected.write_scalar(summary, saturating_add(
            _fiscal_last_collected[summary], _tariff_epoch_collected[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_requests.write_scalar(summary, saturating_add(
            _fiscal_last_requests[summary], _tariff_epoch_requests[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_reserved.write_scalar(summary, saturating_add(
            _fiscal_last_reserved[summary], _tariff_epoch_reserved[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_paid.write_scalar(summary, saturating_add(
            _fiscal_last_paid[summary], _tariff_epoch_paid[lane],
            _saturation_count), market_mutation_sink());
        _fiscal_last_events.write_scalar(summary, saturating_add(
            _fiscal_last_events[summary], _tariff_epoch_events[lane],
            _saturation_count), market_mutation_sink());
    }
    // Build the tariff cash flow totals from the sparse endpoint lanes.  The
    // fiscal summary arrays below are presentation aggregates; using them as
    // the settlement amount can accidentally omit a lane that was outside the
    // rolling settlement workset or include a lane that was already folded.
    std::vector<int64_t> tariff_collected_by_country(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    for (size_t lane = 0; lane < tariff_lane_count; ++lane) {
        const int32_t cell = _tariff_epoch_cells[lane];
        if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()))
            continue;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) continue;
        tariff_collected_by_country[static_cast<size_t>(country)] = saturating_add(
            tariff_collected_by_country[static_cast<size_t>(country)],
            std::max<int64_t>(0, _tariff_epoch_collected[lane]),
            _saturation_count);
    }
    // Tax can settle on a cell outside this epoch's rolling workset, e.g. an
    // inter-cell trade dispatch taxed at its destination. Every lane is reset
    // at epoch open, so a lane not folded here leaves the payer debited with
    // no matching escrow. Keep one membership mask for both report folding and
    // cash reconciliation; outside lanes retain their request history.
    const int32_t fiscal_cell_count = std::min<int32_t>(
        _cell_count.get(), static_cast<int32_t>(_epoch_cell_country.size()));
    std::vector<uint8_t> in_settlement(
        static_cast<size_t>(std::max(0, fiscal_cell_count)), 0);
    for (const int32_t cell : _epoch_settlement_cells)
        if (cell >= 0 && cell < fiscal_cell_count)
            in_settlement[static_cast<size_t>(cell)] = 1;
    if (domestic_fiscal_active) {
        for (int32_t cell = 0; cell < fiscal_cell_count; ++cell) {
            if (in_settlement[static_cast<size_t>(cell)] != 0) continue;
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country < 0 || country >= _epoch_country_count) continue;
            for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
                const size_t lane = static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + kind;
                if (_fiscal_epoch_bases[lane] == 0 &&
                    _fiscal_epoch_assessed[lane] == 0 &&
                    _fiscal_epoch_collected[lane] == 0 &&
                    _fiscal_current_requests[lane] == 0 &&
                    _fiscal_epoch_paid[lane] == 0) continue;
                const size_t summary = static_cast<size_t>(country) *
                    CountryApi::TAX_KIND_COUNT + kind;
                _fiscal_last_bases.write_scalar(summary, saturating_add(
                    _fiscal_last_bases[summary], _fiscal_epoch_bases[lane],
                    _saturation_count), market_mutation_sink());
                _fiscal_last_assessed.write_scalar(summary, saturating_add(
                    _fiscal_last_assessed[summary], _fiscal_epoch_assessed[lane],
                    _saturation_count), market_mutation_sink());
                _fiscal_last_collected.write_scalar(summary, saturating_add(
                    _fiscal_last_collected[summary], _fiscal_epoch_collected[lane],
                    _saturation_count), market_mutation_sink());
                _fiscal_last_requests.write_scalar(summary, saturating_add(
                    _fiscal_last_requests[summary], _fiscal_current_requests[lane],
                    _saturation_count), market_mutation_sink());
                _fiscal_last_paid.write_scalar(summary, saturating_add(
                    _fiscal_last_paid[summary], _fiscal_epoch_paid[lane],
                    _saturation_count), market_mutation_sink());
            }
        }
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        int64_t collected_total = 0;
        int64_t unused_total = 0;
        for (int32_t kind = 0; domestic_fiscal_active &&
             kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            const size_t summary = static_cast<size_t>(country) *
                CountryApi::TAX_KIND_COUNT + kind;
            for (int32_t cell = 0; cell < fiscal_cell_count; ++cell) {
                if (cell < 0 || cell >= fiscal_cell_count ||
                    _epoch_cell_country[cell] != country) continue;
                const size_t lane = static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + kind;
                // Summary rows for non-settlement lanes were folded above.
                // Only add the settlement lanes here so the report remains
                // stable while the cash reconciliation below covers every
                // lane exactly once.
                if (in_settlement[static_cast<size_t>(cell)] != 0) {
                    _fiscal_last_bases.write_scalar(summary, saturating_add(
                        _fiscal_last_bases[summary], _fiscal_epoch_bases[lane],
                        _saturation_count), market_mutation_sink());
                    _fiscal_last_assessed.write_scalar(summary, saturating_add(
                        _fiscal_last_assessed[summary], _fiscal_epoch_assessed[lane],
                        _saturation_count), market_mutation_sink());
                    _fiscal_last_collected.write_scalar(summary, saturating_add(
                        _fiscal_last_collected[summary], _fiscal_epoch_collected[lane],
                        _saturation_count), market_mutation_sink());
                    _fiscal_last_requests.write_scalar(summary, saturating_add(
                        _fiscal_last_requests[summary], _fiscal_current_requests[lane],
                        _saturation_count), market_mutation_sink());
                    _fiscal_last_reserved.write_scalar(summary, saturating_add(
                        _fiscal_last_reserved[summary], _fiscal_budgets[lane],
                        _saturation_count), market_mutation_sink());
                    _fiscal_last_paid.write_scalar(summary, saturating_add(
                        _fiscal_last_paid[summary], _fiscal_epoch_paid[lane],
                        _saturation_count), market_mutation_sink());
                }
                // The escrow balance is a cash ledger, not a report aggregate:
                // reconcile every lane, including cells outside this epoch's
                // rolling workset.  The old settlement-cell-only sum could
                // leave withheld tax or unused subsidy cash unpaired and make
                // VERIFY stop the whole economy with money_conservation_failed.
                collected_total = saturating_add(
                    collected_total,
                    std::max<int64_t>(0, _fiscal_epoch_collected[lane]),
                    _saturation_count);
                unused_total = saturating_add(
                    unused_total, _fiscal_remaining[lane], _saturation_count);
                if (in_settlement[static_cast<size_t>(cell)] != 0)
                    _fiscal_previous_requests.write_scalar(
                        lane, _fiscal_current_requests[lane],
                        market_mutation_sink());
            }
            _fiscal_last_unmet.write_scalar(summary, std::max<int64_t>(
                0, _fiscal_last_requests[summary] - _fiscal_last_paid[summary]), market_mutation_sink());
            _fiscal_cumulative_bases.write_scalar(summary, saturating_add(
                _fiscal_cumulative_bases[summary], _fiscal_last_bases[summary],
                _saturation_count), market_mutation_sink());
            _fiscal_cumulative_collected.write_scalar(summary, saturating_add(
                _fiscal_cumulative_collected[summary],
                _fiscal_last_collected[summary], _saturation_count), market_mutation_sink());
            _fiscal_cumulative_requests.write_scalar(summary, saturating_add(
                _fiscal_cumulative_requests[summary],
                _fiscal_last_requests[summary], _saturation_count), market_mutation_sink());
            _fiscal_cumulative_paid.write_scalar(summary, saturating_add(
                _fiscal_cumulative_paid[summary], _fiscal_last_paid[summary],
                _saturation_count), market_mutation_sink());
        }
        // Tariff lanes are sparse cell x {import, export} and are folded into
        // the country x 5 fiscal summary only after all dispatches settle.
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const int32_t kind = CountryApi::TAX_IMPORT + tariff_kind;
            const size_t summary = static_cast<size_t>(country) *
                CountryApi::TAX_KIND_COUNT + kind;
            const size_t tariff_budget_index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            if (tariff_budget_index < _tariff_country_budgets.size()) {
                _fiscal_last_reserved.write_scalar(summary, saturating_add(
                    _fiscal_last_reserved[summary],
                    _tariff_country_budgets[tariff_budget_index],
                    _saturation_count), market_mutation_sink());
                if (tariff_budget_index < _tariff_country_remaining.size()) {
                    unused_total = saturating_add(
                        unused_total,
                        _tariff_country_remaining[tariff_budget_index],
                        _saturation_count);
                }
            }
            _fiscal_last_unmet.write_scalar(summary, std::max<int64_t>(
                0, _fiscal_last_requests[summary] - _fiscal_last_paid[summary]), market_mutation_sink());
            _fiscal_cumulative_bases.write_scalar(summary, saturating_add(
                _fiscal_cumulative_bases[summary], _fiscal_last_bases[summary],
                _saturation_count), market_mutation_sink());
            _fiscal_cumulative_collected.write_scalar(summary, saturating_add(
                _fiscal_cumulative_collected[summary],
                _fiscal_last_collected[summary], _saturation_count), market_mutation_sink());
            _fiscal_cumulative_requests.write_scalar(summary, saturating_add(
                _fiscal_cumulative_requests[summary],
                _fiscal_last_requests[summary], _saturation_count), market_mutation_sink());
            _fiscal_cumulative_paid.write_scalar(summary, saturating_add(
                _fiscal_cumulative_paid[summary], _fiscal_last_paid[summary],
                _saturation_count), market_mutation_sink());
        }
        if (static_cast<size_t>(country) < tariff_collected_by_country.size())
            collected_total = saturating_add(
                collected_total,
                tariff_collected_by_country[static_cast<size_t>(country)],
                _saturation_count);
        _fiscal_settlement_continuation.unused_by_country[
            static_cast<size_t>(country)] = unused_total;
        _fiscal_settlement_continuation.collected_by_country[
            static_cast<size_t>(country)] = collected_total;
        // Cell workers only mutate their own tax lanes. Reconcile their
        // withheld taxes and spent subsidies once, before Country transfers
        // validate/debit escrow; the opening reservation is no longer its
        // current balance.
        _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), saturating_add(unused_total, collected_total, _saturation_count), market_mutation_sink());
    }
    // Non-tax outflow. Research procurement, expedition cargo, construction and
    // canal materials all debit 国库 and pay the cash to local merchants, so the
    // batch summary must carry them on the expense side or 国库收支 reports a
    // net the treasury never saw. The buffer is drained here (not reset at epoch
    // begin) so an outflow booked at the idle day boundary — family expedition
    // procurement settles there — still reaches the batch it belongs to.
    size_t pending_kept = 0;
    for (size_t i = 0; i < _pending_non_tax_outflow.size(); ++i) {
        PendingNonTaxOutflow &entry = _pending_non_tax_outflow[i];
        const int32_t country = epoch_country_index(entry.country_handle);
        if (country < 0 || country >= _epoch_country_count) {
            // The payer is not in this batch's country set (founded or changed
            // while the economy was idle). Keep the cash pending for a later
            // batch instead of dropping a real treasury debit.
            if (pending_kept != i)
                _pending_non_tax_outflow[pending_kept] = entry;
            ++pending_kept;
            continue;
        }
        for (int32_t kind = 0; kind < NON_TAX_KIND_COUNT; ++kind) {
            const int64_t cash = entry.cash[static_cast<size_t>(kind)];
            if (cash <= 0) continue;
            const size_t lane = static_cast<size_t>(country) *
                static_cast<size_t>(NON_TAX_KIND_COUNT) +
                static_cast<size_t>(kind);
            _fiscal_last_non_tax_outflow.write_scalar(lane, saturating_add(
                _fiscal_last_non_tax_outflow[lane], cash, _saturation_count),
                market_mutation_sink());
        }
    }
    _pending_non_tax_outflow.resize(pending_kept);
    _fiscal_settlement_continuation.active = true;
    _fiscal_settlement_continuation.phase = 1;
    return true;
}

bool NativeEconomyRuntime::advance_fiscal_settlement(std::string &error) {
    error.clear();
    const auto settlement_started = std::chrono::steady_clock::now();
    struct SettlementTimer {
        double *slot = nullptr;
        std::chrono::steady_clock::time_point started;
        ~SettlementTimer() {
            if (slot == nullptr) return;
            *slot += std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
        }
    } settlement_timer{&_fiscal_settlement_ms, settlement_started};
    FiscalSettlementContinuation &continuation =
        _fiscal_settlement_continuation;
    if (!continuation.active) return true;
    if (continuation.phase != 1 || continuation.country_count < 0 ||
        continuation.unused_by_country.size() !=
            static_cast<size_t>(continuation.country_count) ||
        continuation.collected_by_country.size() !=
            static_cast<size_t>(continuation.country_count)) {
        continuation.phase = 3;
        continuation.last_error = "fiscal_settlement_continuation_invalid";
        continuation.active = false;
        error = continuation.last_error;
        return false;
    }
    if (continuation.country_cursor < continuation.country_count) {
        const int32_t country = continuation.country_cursor;
        const int64_t unused = continuation.unused_by_country[
            static_cast<size_t>(country)];
        const int64_t collected_total = continuation.collected_by_country[
            static_cast<size_t>(country)];
        if (!continuation.return_completed && unused > 0) {
            int64_t returned = 0;
            std::string transaction_error;
            if (!coordinate_country_fiscal_transaction(
                    country, CountryApi::ECONOMY_ASSET_FISCAL_RETURN,
                    unused, returned, transaction_error,
                    &continuation.pending_request_id)) {
                if (transaction_error == "country_economy_asset_host_pending")
                    return true;
                continuation.phase = 3;
                continuation.last_error = transaction_error.empty()
                    ? "fiscal_escrow_return_drift" : transaction_error;
                continuation.active = false;
                error = continuation.last_error;
                return false;
            }
            continuation.pending_request_id = 0;
            if (returned != unused) {
                continuation.phase = 3;
                continuation.last_error = transaction_error.empty()
                    ? "fiscal_escrow_return_drift" : transaction_error;
                continuation.active = false;
                error = continuation.last_error;
                return false;
            }
        }
        continuation.return_completed = true;
        if (collected_total > 0) {
            int64_t collected = 0;
            std::string transaction_error;
            if (!coordinate_country_fiscal_transaction(
                    country, CountryApi::ECONOMY_ASSET_FISCAL_COLLECT,
                    collected_total, collected, transaction_error,
                    &continuation.pending_request_id)) {
                if (transaction_error == "country_economy_asset_host_pending")
                    return true;
                continuation.phase = 3;
                continuation.last_error = transaction_error.empty()
                    ? "fiscal_tax_collection_drift" : transaction_error;
                continuation.active = false;
                error = continuation.last_error;
                return false;
            }
            continuation.pending_request_id = 0;
            if (collected != collected_total) {
                continuation.phase = 3;
                continuation.last_error = transaction_error.empty()
                    ? "fiscal_tax_collection_drift" : transaction_error;
                continuation.active = false;
                error = continuation.last_error;
                return false;
            }
        }
        if (collected_total > 0) {
            int64_t pending_sat = 0;
            _country_pending_credit = saturating_add(
                _country_pending_credit, collected_total, pending_sat);
        }
        _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), 0, market_mutation_sink());
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const size_t index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            if (index < _tariff_country_remaining.size())
                _tariff_country_remaining[index] = 0;
        }
        continuation.last_unused = unused;
        continuation.last_collected = collected_total;
        continuation.return_completed = false;
        ++continuation.country_cursor;
        return true;
    }
    for (size_t row = 0; row < _tariff_history.countries.size(); ++row) {
        _tariff_history.cumulative_bases.write_scalar(row, saturating_add(
            _tariff_history.cumulative_bases[row],
            std::max<int64_t>(0, _tariff_history.bases[row]),
            _saturation_count), market_mutation_sink());
        _tariff_history.cumulative_collected.write_scalar(row, saturating_add(
            _tariff_history.cumulative_collected[row],
            std::max<int64_t>(0, _tariff_history.collected[row]),
            _saturation_count), market_mutation_sink());
        _tariff_history.cumulative_requests.write_scalar(row, saturating_add(
            _tariff_history.cumulative_requests[row],
            std::max<int64_t>(0, _tariff_history.requests[row]),
            _saturation_count), market_mutation_sink());
        _tariff_history.cumulative_paid.write_scalar(row, saturating_add(
            _tariff_history.cumulative_paid[row],
            std::max<int64_t>(0, _tariff_history.paid[row]),
            _saturation_count), market_mutation_sink());
    }
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count.get()) continue;
        const int32_t country = _epoch_cell_country[cell];
        _fiscal_previous_country_handles.write_scalar(cell, country >= 0 && country < _epoch_country_count
            ? _epoch_country_handles[country] : 0, market_mutation_sink());
    }
    ++_country_trade_revision;
    continuation.phase = 2;
    continuation.active = false;
    return true;
}

bool NativeEconomyRuntime::run_fiscal_settlement_drain(std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("fiscal_settlement"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage != Stage::FISCAL_SETTLEMENT) {
        return true;
    }
    _executed_stage = Stage::FISCAL_SETTLEMENT;
    constexpr int kMaxSteps = 1 << 16;
    for (int step = 0; step < kMaxSteps && _stage == Stage::FISCAL_SETTLEMENT &&
                       !_fatal;
         ++step) {
        // StageOps BUILDING_COMMIT → fiscal drain never enters compact
        // run_slice_internal, so Country-origin poll must run here or a
        // prepared fiscal request parks forever without a terminal (calendar
        // soft-stalls into climate_input_capacity_day_barrier).
        const auto peer_started = std::chrono::steady_clock::now();
        const bool peer_ok = service_country_economy_asset_peer(64, error);
        _fiscal_settlement_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - peer_started).count();
        if (!peer_ok) {
            if (runtime_country_asset_pending_reason(error)) {
                error = "fiscal_settlement_peer_pending";
                _executed_substage = "country_asset_peer_pending";
                return false;
            }
            fail(error.empty() ? "country_economy_fiscal_peer_failed" : error);
            return false;
        }
        _executed_substage = _fiscal_settlement_continuation.active
                                 ? "country_transactions"
                                 : "finalize";
        if (!advance_fiscal_settlement(error)) {
            fail(error.empty() ? "fiscal_settlement_failed" : error);
            return false;
        }
        if (_fiscal_settlement_continuation.active) {
            // Compact-slice yields here. Drain keeps advancing countries in
            // this call unless a Country-peer request is parked.
            if (_fiscal_settlement_continuation.pending_request_id != 0) {
                error = "fiscal_settlement_peer_pending";
                return false;
            }
            continue;
        }
        _stage = Stage::FAMILY_COMMIT;
        return true;
    }
    if (_fatal) {
        error = error.empty() ? "fiscal_settlement_fatal" : error;
        return false;
    }
    error = "fiscal_settlement_drain_exhausted";
    fail(error);
    return false;
}

int64_t NativeEconomyRuntime::pay_building_wage_amount(
        int32_t cell, int32_t owner_slot, int32_t profession_id,
        int64_t filled_jobs, int64_t due, int64_t payment_cap,
        int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    if (filled_jobs <= 0 || due <= 0 || payment_cap <= 0 || owner_slot < 0) return 0;
    const bool trace_detail = trace_detail_for_cell(cell);
    const int64_t owner_handle = static_cast<int64_t>(population_store().handle_for_slot(owner_slot));
    const int64_t owner_funds_before = population_store().funds[owner_slot];
    const int64_t owner_expense_before = population_store().epoch_expense[owner_slot];
    thread_local std::vector<int32_t> trace_slots;
    thread_local std::vector<int64_t> trace_funds;
    thread_local std::vector<int64_t> trace_income;
    trace_slots.clear(); trace_funds.clear(); trace_income.clear();
    int64_t total_employed = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (_signatures[signature].profession_id == profession_id) {
            total_employed = saturating_add(total_employed,
                population_store().employee_employed[slot], _saturation_count);
            if (trace_detail && population_store().employee_employed[slot] > 0) {
                trace_slots.push_back(slot);
                trace_funds.push_back(population_store().funds[slot]);
                trace_income.push_back(population_store().epoch_income[slot]);
            }
        }
    });
    if (total_employed <= 0) {
        trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                     cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                     filled_jobs, due, 0, due, nullptr);
        return 0;
    }
    const int64_t paid = std::min(
        std::min(due, payment_cap), std::max<int64_t>(0, population_store().funds[owner_slot]));
    touch_accounting_slot(owner_slot);
    population_store().funds.write_scalar(owner_slot, population_store().funds[owner_slot] - (paid), market_mutation_sink());
    population_store().epoch_expense.write_scalar(owner_slot, saturating_add(
        population_store().epoch_expense[owner_slot], paid, _saturation_count), market_mutation_sink());
    trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                          CASHFLOW_OWNER_WAGES, 0, paid);
    int64_t prefix = 0;
    int64_t distributed = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (_signatures[signature].profession_id != profession_id ||
            population_store().employee_employed[slot] <= 0) return;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, population_store().employee_employed[slot],
                                _saturation_count);
        const int64_t next = mul_div_sat(paid, prefix, total_employed, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        int64_t income_tax = 0;
        if ((_epoch_active_tax_mask & static_cast<uint8_t>(
                1U << CountryApi::TAX_INCOME)) != 0) {
            const int32_t income_rate = frozen_tax_rate(
                cell, CountryApi::TAX_INCOME, profession_id);
            const int32_t income_mode = frozen_tax_mode(
                cell, CountryApi::TAX_INCOME, profession_id);
            if (income_mode == CountryApi::TAX_MODE_ABSOLUTE) {
                // Settled in settle_absolute_daily_taxes_for_cell.
            } else if (income_rate < 0) {
                if (slot >= 0 && slot < static_cast<int32_t>(
                        _income_taxable_base_by_slot.size())) {
                    _income_taxable_base_by_slot[slot] = saturating_add(
                        _income_taxable_base_by_slot[slot], share,
                        _saturation_count);
                }
            } else {
                income_tax = apply_fiscal_tax(
                    cell, CountryApi::TAX_INCOME, share, income_rate,
                    income_mode, _saturation_count);
                record_cohort_fiscal(slot, income_tax);
            }
        }
        const int64_t net_share = saturating_sub(
            share, income_tax, _saturation_count);
        population_store().funds.write_scalar(slot, saturating_add(population_store().funds[slot], net_share,
                                                 _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(cell, population_store().handle_for_slot(slot),
                              CASHFLOW_WAGES, share, 0);
        if (income_tax > 0)
            trace_record_cashflow(cell, population_store().handle_for_slot(slot),
                                  CASHFLOW_INCOME_TAX, 0, income_tax);
        else if (income_tax < 0)
            trace_record_cashflow(cell, population_store().handle_for_slot(slot),
                                  CASHFLOW_INCOME_SUBSIDY, -income_tax, 0);
    });
    std::vector<EventLeg> legs;
    if (trace_detail) {
        if (owner_funds_before != population_store().funds[owner_slot]) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, owner_handle, -1,
                            owner_funds_before, population_store().funds[owner_slot]});
        }
        if (owner_expense_before != population_store().epoch_expense[owner_slot]) {
            legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, owner_handle, -1,
                            owner_expense_before, population_store().epoch_expense[owner_slot]});
        }
        for (size_t i = 0; i < trace_slots.size(); ++i) {
            const int32_t worker_slot = trace_slots[i];
            const int64_t handle = static_cast<int64_t>(population_store().handle_for_slot(worker_slot));
            if (trace_funds[i] != population_store().funds[worker_slot]) {
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                                trace_funds[i], population_store().funds[worker_slot]});
            }
            if (trace_income[i] != population_store().epoch_income[worker_slot]) {
                legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                                trace_income[i], population_store().epoch_income[worker_slot]});
            }
        }
    }
    trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                 cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                 filled_jobs, due, distributed, due - distributed,
                 legs.empty() ? nullptr : &legs);
    return distributed;
}

int64_t NativeEconomyRuntime::projected_employee_tax_retention_q16(
        BuildingGroupConstRef group, int64_t &sat) const {
    if ((_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) == 0)
        return Q16_ONE;
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    int64_t weighted_take_home = 0;
    int64_t weighted_gross = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t role_index = group.employee_fill_begin + r;
        const int64_t gross_wage = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? _building_role_contract_wage[role_index]
            : 0;
        const int64_t take_home = expected_after_tax_income(
            group.cell, role.profession_id, gross_wage, sat);
        const int64_t slots = std::max<int64_t>(0,
            role.slots_per_building);
        weighted_take_home = saturating_add(
            weighted_take_home, saturating_mul(take_home, slots, sat), sat);
        weighted_gross = saturating_add(
            weighted_gross, saturating_mul(gross_wage, slots, sat), sat);
    }
    if (weighted_gross <= 0) return Q16_ONE;
    return mul_div_sat(weighted_take_home, Q16_ONE, weighted_gross, sat);
}

} // namespace pk
