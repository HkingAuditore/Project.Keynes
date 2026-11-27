bool RuntimeCountryPodAuthority::commit_rejected_day(
        RuntimeCountryPodPlan &plan, std::string &error,
        bool advance_generation) {
    error.clear();
    if (!_bootstrapped || !_plan_active || plan.preflight_ok == 0 ||
        plan.header.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
        plan.header.base_generation != _state.generation ||
        plan.header.day != _state.committed_day + 1) {
        error = "country_rejected_plan_commit_invalid";
        return false;
    }

    // Country work before the peer barrier is already a semantic commit in
    // the production ordering: commands, research consumption and the
    // pending activation survive the peer rejection. The calendar boundary
    // closes, but the generation does not advance and the pending technology
    // remains blocked until a later-day retry gets a new request identity.
    RuntimeCountryPodSnapshot next = plan.next_state;
    next.committed_day = plan.header.day;
    if (advance_generation &&
        (plan.header.dirty_families != 0 || !plan.commands.empty())) {
        next.generation = _next_generation++;
    }
    next.state_hash = hash_business_state(next);
    _state = std::move(next);
    // The plan took every due queued command. Internal observations never
    // occupy that queue, so removing them must not scan it once per signal.
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
        [&](const RuntimeCountryCommand &queued) {
            return queued.effective_day <= plan.header.day;
        }), _pending.end());
    for (const RuntimeCountryCommand &command : plan.commands) {
        RuntimeCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = _state.generation;
        // Generic runtime receipts only describe successful application;
        // the typed Country terminal projection reports COMMITTED separately.
        receipt.code = RuntimeReceiptCode::OK;
        plan.receipts.push_back(receipt);
    }
    plan.header.base_generation = _state.generation;
    plan.header.state_hash = _state.state_hash;
    plan.header.preflight_ok = 1;
    plan.committed = 1;
    _plan_active = false;
    return true;
}

bool RuntimeCountryPodAuthority::snapshot(
        RuntimeCountryPodSnapshot &out, std::string &error) const {
    error.clear();
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    out = _state;
    return true;
}
