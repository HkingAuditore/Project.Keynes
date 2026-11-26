bool RuntimeCountryPodAuthority::plan_day(
        int64_t day, uint64_t input_generation, RuntimeCountryPodPlan &plan,
        std::string &error, const std::vector<RuntimeCountryCommand> *observations) {
    error.clear();
    plan = RuntimeCountryPodPlan{};
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (_plan_active) {
        error = "country_plan_already_active";
        return false;
    }
    if (day != _state.committed_day + 1) {
        error = "country_day_not_contiguous";
        return false;
    }
    if (input_generation == 0) {
        error = "country_input_generation_invalid";
        return false;
    }
    plan.next_state = _state;
    plan.header.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    plan.header.abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    plan.header.day = day;
    plan.header.input_generation = input_generation;
    plan.header.base_generation = _state.generation;
    plan.header.preflight_ok = 1;
    plan.commands.reserve(_pending.size() + (observations ? observations->size() : 0));
    for (const RuntimeCountryCommand &command : _pending)
        if (command.effective_day <= day) plan.commands.push_back(command);
    if (observations) plan.commands.insert(plan.commands.end(), observations->begin(), observations->end());
    std::sort(plan.commands.begin(), plan.commands.end(),
        [](const RuntimeCountryCommand &lhs, const RuntimeCountryCommand &rhs) {
            return ResolveOrder{lhs.effective_day, lhs.sequence, lhs.submit_order, lhs.request_id} <
                ResolveOrder{rhs.effective_day, rhs.sequence, rhs.submit_order, rhs.request_id};
        });
    plan.header.work_units = plan.commands.size();
    for (auto it = plan.commands.begin(); it != plan.commands.end();) {
        const RuntimeCountryCommand &command = *it;
        if (command.observed_generation != 0 &&
            command.observed_generation != _state.generation) {
            error = "stale_command_generation";
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
            return false;
        }
        if (!apply_command(plan.next_state, command, plan, error)) {
            auto *rejected = error == "country_cell_tax_territory_invalid"
                ? &plan.rejected_cell_taxes : nullptr;
            // Direct transfers are independent; military peace batches are atomic.
            if (command.producer_id == 0u && command.opcode == CountryApi::COMMAND_TRANSFER_TERRITORY &&
                    error == "country_transfer_cell_invalid")
                rejected = &plan.rejected_territory_transfers;
            if (rejected) {
                rejected->push_back(command);
                it = plan.commands.erase(it);
                error.clear();
                continue;
            }
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
            return false;
        }
        ++it;
    }
    // Both research passes use the same day stamp, so points are allocated once.
    if (!run_research_day(plan.next_state, day, plan, error) ||
        !run_research_day(plan.next_state, day, plan, error)) {
        plan.header.preflight_ok = 0;
        copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
        return false;
    }
    if ((plan.header.dirty_families & RUNTIME_DIRTY_COUNTRY_TERRITORY) != 0)
        rebuild_territory_csr(plan.next_state);
    plan.header.intent_count = static_cast<uint32_t>(plan.intents.size());
    plan.header.ack_count = 0;
    plan.header.state_hash = hash_business_state(plan.next_state);
    plan.preflight_ok = 1;
    _plan_active = true;
    return true;
}

bool RuntimeCountryPodAuthority::apply_economy_asset_result(
        const RuntimeEconomyAssetRequest &request,
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (!_bootstrapped || _plan_active) {
        error = "country_economy_asset_apply_invalid";
        return false;
    }
    const int32_t slot = request.country_slot;
    const size_t c = (slot >= 0 && slot < static_cast<int32_t>(_state.country_count))
        ? static_cast<size_t>(slot) : 0;
    const uint32_t ver_before = c < _state.country_state_version.size()
        ? _state.country_state_version[c] : 0;
    const int64_t cash_before = c < _state.country_cash.size()
        ? _state.country_cash[c] : 0;
    const int64_t research_before = c < _state.research_purchased_total.size()
        ? _state.research_purchased_total[c] : 0;
    if (!country_core_apply_economy_asset_commit(
            _state, _catalog, request, result, error)) {
        return false;
    }
    const uint32_t ver_after = c < _state.country_state_version.size()
        ? _state.country_state_version[c] : 0;
    const int64_t cash_after = c < _state.country_cash.size()
        ? _state.country_cash[c] : 0;
    const int64_t research_after = c < _state.research_purchased_total.size()
        ? _state.research_purchased_total[c] : 0;
    bool goods_changed = false;
    for (uint32_t i = 0; i < request.good_count &&
         i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
        if (request.good_quantities[i] != 0) {
            goods_changed = true;
            break;
        }
    }
    const bool mutated = (ver_after != ver_before) &&
        (cash_after != cash_before || research_after != research_before || goods_changed);
    if (mutated) {
        _state.generation = _next_generation++;
        _state.state_hash = hash_business_state(_state);
    }
    return true;
}

bool RuntimeCountryPodAuthority::apply_economy_asset_commit_to_authority_state(
        const RuntimeEconomyAssetRequest &request,
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (!_bootstrapped) {
        error = "country_economy_asset_apply_invalid";
        return false;
    }
    // Keep generation stable while a plan is open so commit_day's
    // base_generation check still passes. state_hash is refreshed on commit.
    return country_core_apply_economy_asset_commit(
        _state, _catalog, request, result, error);
}
