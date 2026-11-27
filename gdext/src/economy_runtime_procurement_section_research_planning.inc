using namespace variant_helpers;

bool NativeEconomyRuntime::advance_country_research_procurement(
        CountryResearchProcurementContinuation &continuation,
        std::string &error) {
    error.clear();
    if (!continuation.active) return true;
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        continuation.phase = 7;
        continuation.last_error = "country_research_peer_unavailable";
        continuation.active = false;
        error = continuation.last_error;
        return false;
    }
    const auto fail_fault = [&](const char *reason) {
        continuation.phase = 7;
        continuation.last_error = reason;
        continuation.active = false;
        error = reason;
        return false;
    };
    const auto reject_prepare = [&](const char *reason) {
        if (!continuation.host_peer && continuation.transaction_id != 0) {
            country_api::fiscal_return_port(*_country_runtime).prepared(
                {continuation.transaction_id, continuation.session_epoch, continuation.country_generation, continuation.peer_generation},
                false, reason);
        }
        continuation.phase = 6;
        continuation.last_error = reason;
        continuation.active = false;
        continuation.pending_request_id = 0;
        return true;
    };
    const auto preflight_market_merchants = [&](const char *&reject_reason) -> bool {
        reject_reason = nullptr;
        const size_t market_index = market_store().index(
            continuation.market, continuation.good);
        if (market_index >= market_store().stock.size() ||
            market_store().stock[market_index] < continuation.quantity) {
            reject_reason = "country_research_peer_market_stock_changed";
            return false;
        }
        if (continuation.living_merchants.empty()) {
            reject_reason = "country_research_peer_merchant_missing";
            return false;
        }
        continuation.merchant_population = 0;
        continuation.merchant_weights.clear();
        continuation.merchant_weights.reserve(continuation.living_merchants.size());
        for (const int32_t merchant : continuation.living_merchants) {
            if (!is_merchant_slot(merchant) || merchant < 0 ||
                merchant >= static_cast<int32_t>(population_store().population.size()) ||
                population_store().population[merchant] <= 0) {
                reject_reason = "country_research_peer_merchant_changed";
                return false;
            }
            continuation.merchant_weights.push_back(
                population_store().population[merchant]);
            continuation.merchant_population = saturating_add(
                continuation.merchant_population,
                population_store().population[merchant], _saturation_count);
        }
        if (continuation.merchant_population <= 0) {
            reject_reason = "country_research_peer_merchant_empty";
            return false;
        }
        int64_t prefix = 0;
        int64_t distributed = 0;
        for (const int32_t merchant : continuation.living_merchants) {
            prefix = saturating_add(prefix, population_store().population[merchant],
                                    _saturation_count);
            const int64_t next = mul_div_sat(
                continuation.cash, prefix, continuation.merchant_population,
                _saturation_count);
            const int64_t share = std::max<int64_t>(0, next - distributed);
            distributed = next;
            if (population_store().funds[merchant] >
                    std::numeric_limits<int64_t>::max() - share ||
                population_store().epoch_income[merchant] >
                    std::numeric_limits<int64_t>::max() - share) {
                reject_reason = "country_research_peer_credit_overflow";
                return false;
            }
        }
        if (distributed != continuation.cash) {
            reject_reason = "country_research_peer_credit_distribution_drift";
            return false;
        }
        return true;
    };

    if (continuation.phase == 1) {
        if (continuation.country < 0 ||
            continuation.country >= _epoch_country_count ||
            continuation.country >= static_cast<int32_t>(
                _epoch_country_handles.size()) ||
            continuation.market < 0 ||
            continuation.market >= market_store().market_count.get() ||
            continuation.good < 0 || continuation.good >= market_store().good_count.get() ||
            continuation.quantity <= 0 || continuation.cash <= 0)
            return fail_fault("country_research_procurement_continuation_invalid");
        const int64_t research_handle = static_cast<int64_t>(
            _epoch_country_handles[static_cast<size_t>(continuation.country)]);

        // Country unique-writer: Host peer path (same shape as fiscal reserve).
        if (_simulation_host != nullptr &&
            (country_reads().sync_store_writes_forbidden() ||
             _simulation_host->domain_is_worker_authoritative(
                 RuntimeDomainId::COUNTRY))) {
            if (continuation.pending_request_id != 0) {
                RuntimeEconomyAssetResult terminal;
                if (_simulation_host->country_economy_asset_terminal_result(
                        continuation.pending_request_id, terminal)) {
                    if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
                        terminal.operation !=
                            RuntimeEconomyAssetOperation::RESEARCH_PURCHASE) {
                        // Drop the parked wire id; Country flush will retire
                        // the rejected terminal without debiting treasury.
                        _simulation_host->acknowledge_country_economy_asset_consumed(
                            continuation.pending_request_id);
                        continuation.pending_request_id = 0;
                        return reject_prepare(
                            terminal.reason[0] != '\0'
                                ? terminal.reason.data()
                                : "country_economy_asset_host_terminal_rejected");
                    }
                    if (_simulation_host->domain_is_worker_authoritative(
                            RuntimeDomainId::ECONOMY)) {
                        if (!_simulation_host->finish_worker_country_asset(
                                continuation.pending_request_id, terminal,
                                error))
                            return fail_fault(error.empty()
                                ? "country_research_host_finish_failed"
                                : error.c_str());
                    } else if (!_simulation_host->flush_country_economy_asset_commits(
                                   error,
                                   continuation.pending_request_id) ||
                               !_simulation_host->publish_country_worker_snapshot(
                                   RUNTIME_DIRTY_COUNTRY_STATE, error)) {
                        // Country ACTIVE + Economy sync: settle this wire id
                        // only (generic flush skips COMPLETED research) so
                        // treasury debit and merchant credit share one advance.
                        return fail_fault(error.empty()
                            ? "country_research_host_flush_failed"
                            : error.c_str());
                    } else {
                        _simulation_host->acknowledge_country_economy_asset_consumed(
                            continuation.pending_request_id);
                    }
                    const int64_t committed_qty = terminal.committed_quantity > 0
                        ? terminal.committed_quantity : continuation.quantity;
                    const int64_t committed_cash = terminal.committed_cash > 0
                        ? terminal.committed_cash : continuation.cash;
                    if (committed_qty != continuation.quantity ||
                        committed_cash != continuation.cash)
                        return fail_fault(
                            "country_research_host_commit_quantity_drift");
                    continuation.host_peer = true;
                    continuation.transaction_id = continuation.pending_request_id;
                    continuation.session_epoch = terminal.session_epoch;
                    continuation.country_generation = terminal.country_generation;
                    continuation.peer_generation = _committed_generation;
                    continuation.pending_request_id = 0;
                    continuation.merchant_cursor = 0;
                    continuation.merchant_population_prefix = 0;
                    continuation.merchant_distributed = 0;
                    continuation.market_applied = false;
                    // Country already committed. Apply market/merchant in this
                    // same advance so money conservation never observes a
                    // treasury debit without the matching merchant credit.
                    continuation.phase = 4;
                } else {
                    error = "country_economy_asset_host_pending";
                    return true;
                }
            }

            if (continuation.phase == 1) {
            const char *preflight_reason = nullptr;
            if (!preflight_market_merchants(preflight_reason))
                return reject_prepare(preflight_reason != nullptr
                    ? preflight_reason
                    : "country_research_peer_market_stock_changed");
            if (country_reads().cash_for_slot(continuation.country) <
                continuation.cash)
                return reject_prepare(
                    "country_research_purchase_async_resources_insufficient");

            const CountryWorkerAssetRoute route =
                block_or_enqueue_country_worker_asset(
                    static_cast<uint16_t>(
                        CountryApi::ECONOMY_ASSET_RESEARCH_PURCHASE),
                    research_handle, continuation.cash, continuation.quantity,
                    continuation.good, error, &continuation.pending_request_id);
            if (route == CountryWorkerAssetRoute::GATE_SOFT_UNAVAILABLE)
                return reject_prepare("country_economy_operation_gate_closed");
            if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
                continuation.host_peer = true;
                error = "country_economy_asset_host_pending";
                return true;
            }
            if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
                continuation.phase = 7;
                continuation.last_error = error.empty()
                    ? "country_research_worker_route_unexpected" : error;
                continuation.active = false;
                return false;
            }
            // Fall through to sync begin when Country is not unique-writer.
            }
        }

        if (continuation.phase == 1) {
        const godot::Dictionary begun =
            country_api::fiscal_return_port(*_country_runtime).submit_research(country_api::fiscal_return_port(*_country_runtime).research_intent(
                research_handle,
                continuation.quantity, continuation.cash, _epoch_id.get(),
                static_cast<int32_t>(_stage)));
        if (!static_cast<bool>(begun.get("ok", false))) {
            continuation.phase = 6;
            continuation.last_error = String(begun.get(
                "code", "country_research_peer_country_rejected")).utf8().get_data();
            continuation.active = false;
            return true;
        }
        continuation.transaction_id = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("transaction_id", 0)));
        continuation.session_epoch = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("session_epoch", 0)));
        continuation.country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        continuation.peer_generation = _committed_generation;
        if (continuation.transaction_id == 0 ||
            continuation.session_epoch == 0 ||
            continuation.country_generation == 0 ||
            continuation.peer_generation == 0)
            return fail_fault("country_research_procurement_identity_invalid");
        continuation.phase = 2;
        return true;
        }
    }

    if (continuation.phase == 2) {
        if (continuation.host_peer)
            return fail_fault("country_research_host_peer_phase_invalid");
        const char *preflight_reason = nullptr;
        if (!preflight_market_merchants(preflight_reason))
            return reject_prepare(preflight_reason != nullptr
                ? preflight_reason
                : "country_research_peer_market_stock_changed");
        const godot::Dictionary prepared =
            country_api::fiscal_return_port(*_country_runtime).prepared(
                {continuation.transaction_id, continuation.session_epoch, continuation.country_generation, continuation.peer_generation},
                true, "");
        if (!static_cast<bool>(prepared.get("ok", false)))
            return fail_fault("country_research_peer_prepare_failed");
        continuation.phase = 3;
        return true;
    }

    if (continuation.phase == 3) {
        if (continuation.host_peer)
            return fail_fault("country_research_host_peer_phase_invalid");
        const godot::Dictionary committed =
            country_api::fiscal_return_port(*_country_runtime).apply(
                continuation.transaction_id);
        if (!static_cast<bool>(committed.get("ok", false)))
            return fail_fault(String(committed.get(
                "code", "country_research_peer_commit_failed")).utf8().get_data());
        const int64_t quantity = static_cast<int64_t>(
            committed.get("committed_quantity", continuation.quantity));
        if (quantity != continuation.quantity)
            return fail_fault("country_research_peer_commit_quantity_drift");
        continuation.merchant_cursor = 0;
        continuation.merchant_population_prefix = 0;
        continuation.merchant_distributed = 0;
        continuation.market_applied = false;
        continuation.phase = 4;
        return true;
    }

    if (continuation.phase == 4) {
        if (!continuation.market_applied) {
            const size_t market_index = market_store().index(
                continuation.market, continuation.good);
            if (market_index >= market_store().stock.size() ||
                market_store().stock[market_index] < continuation.quantity)
                return fail_fault("country_research_peer_market_apply_drift");
            audit_touch_market_lane(market_index);
            market_store().stock.write_scalar(market_index, market_store().stock[market_index] - (continuation.quantity), market_mutation_sink());
            const int32_t signal = market_signal_index(
                continuation.market, continuation.good);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size()))
                    _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[signal],
                        continuation.quantity, _saturation_count);
                const int64_t daily = continuation.quantity /
                    std::max(1, _epoch_days.get());
                const int64_t alpha = std::min<int64_t>(
                    Q16_ONE, static_cast<int64_t>(std::clamp<int32_t>(
                        _good_demand_ema_alpha_q16[continuation.good],
                        0, Q16_ONE)) * std::max(1, _epoch_days.get()));
                const int64_t addition = mul_div_sat(
                    daily, alpha, Q16_ONE, _saturation_count);
                _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
                    _market_signals.business_demand_ema[signal], addition,
                    _saturation_count), market_mutation_sink());
                _market_signals.realized_withdrawal_ema.write_scalar(signal, saturating_add(
                    _market_signals.realized_withdrawal_ema[signal], addition,
                    _saturation_count), market_mutation_sink());
            }
            continuation.market_applied = true;
        }
        while (continuation.merchant_cursor <
                continuation.living_merchants.size()) {
            const size_t index = continuation.merchant_cursor++;
            const int32_t merchant = continuation.living_merchants[index];
            const int64_t weight = index < continuation.merchant_weights.size()
                ? continuation.merchant_weights[index]
                : population_store().population[merchant];
            continuation.merchant_population_prefix = saturating_add(
                continuation.merchant_population_prefix, weight,
                _saturation_count);
            const int64_t next = mul_div_sat(
                continuation.cash, continuation.merchant_population_prefix,
                continuation.merchant_population, _saturation_count);
            const int64_t share = std::max<int64_t>(
                0, next - continuation.merchant_distributed);
            continuation.merchant_distributed = next;
            audit_touch_population_lane(merchant);
            touch_accounting_slot(merchant);
            population_store().funds.write_scalar(merchant, saturating_add(
                population_store().funds[merchant], share, _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(merchant, saturating_add(
                population_store().epoch_income[merchant], share, _saturation_count), market_mutation_sink());
            // Sync peer yields one merchant per slice; Host peer must finish
            // the whole credit in the same advance as Country commit.
            if (!continuation.host_peer)
                return true;
        }
        if (continuation.merchant_distributed != continuation.cash)
            return fail_fault("country_research_peer_apply_distribution_drift");
        continuation.phase = 5;
        if (!continuation.host_peer)
            return true;
        // Host peer: fall through to phase 5 completion below.
    }

    if (continuation.phase == 5) {
        if (!continuation.host_peer) {
            const godot::Dictionary applied =
                country_api::fiscal_return_port(*_country_runtime).applied(
                {continuation.transaction_id, continuation.session_epoch, continuation.country_generation, continuation.peer_generation},
                true, "");
            if (!static_cast<bool>(applied.get("ok", false)) ||
                String(applied.get("status_name", "")) != "completed")
                return fail_fault("country_research_peer_apply_ack_failed");
        }
        continuation.active = false;
        continuation.last_error.clear();
        return true;
    }
    return fail_fault("country_research_procurement_phase_invalid");
}
