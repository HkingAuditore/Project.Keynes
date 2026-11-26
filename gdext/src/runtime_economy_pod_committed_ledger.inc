uint64_t RuntimeEconomyPodAuthority::state_hash() const noexcept {
    EconomyCostProbe probe("pod_hash", _state.committed_day, _state.market.stock.size());
    uint64_t hash = FNV_OFFSET;
    auto mix = [&hash](uint64_t value) {
        hash = economy_hash_u64(hash, value);
    };
    mix(_state.state_generation);
    mix(static_cast<uint64_t>(_state.sample_day));
    mix(static_cast<uint64_t>(_state.committed_day));
    mix(static_cast<uint64_t>(_state.market.market_count));
    mix(static_cast<uint64_t>(_state.market.good_count));
    for (size_t i = 0; i < _state.population.active.size(); ++i) {
        mix(_state.population.active[i]);
        mix(_state.population.signature_id[i]);
        mix(_state.population.generation[i]);
        mix(static_cast<uint64_t>(_state.population.population[i]));
        mix(static_cast<uint64_t>(_state.population.funds[i]));
    }
    if (runtime_chunk_hash_enabled()) {
        mix(RuntimeChunkHash::VERSION);
        mix(_state.market_hash_pages[0].update(_state.market.stock, 1, 1));
        mix(_state.market_hash_pages[1].update(_state.market.price, 1, 2));
        mix(_state.market_hash_pages[2].update(_state.market.demand_ema, 1, 3));
        mix(_state.market_hash_pages[3].update(_state.market.last_shortage_q16, 1, 4));
    } else {
        for (size_t i = 0; i < _state.market.stock.size(); ++i) {
            mix(static_cast<uint64_t>(_state.market.stock[i]));
            mix(static_cast<uint64_t>(_state.market.price[i]));
            mix(static_cast<uint64_t>(_state.market.demand_ema[i]));
            mix(_state.market.last_shortage_q16[i]);
        }
    }
    return hash;
}

bool RuntimeEconomyPodAuthority::import_committed_ledger(
        const RuntimeEconomyLedgerState &ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    // Replacing the contents of a store a formula owner is bound to does not
    // disown it: the owner keeps the same object. Carry the ownership flag over
    // so a later protocol reset still knows not to zero the lanes.
    restored.formula_owner_bound = _state.formula_owner_bound;
    _state = std::move(restored);
    _market_export_warmup = 0;
    return true;
}

bool RuntimeEconomyPodAuthority::import_and_publish_committed_ledger(
        RuntimeEconomyLedgerState &&ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    // Validate all shapes and hashes once, before changing either publication.
    // No producer can mutate this local ledger between validation and move.
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    restored.formula_owner_bound = _state.formula_owner_bound;
    _state = std::move(restored);
    _committed_ledger_state = std::move(ledger);
    _market_export_warmup = 0;
    publish_mirror_features();
    return true;
}

bool RuntimeEconomyPodAuthority::import_and_publish_captured_ledger(
        RuntimeEconomyLedgerState &ledger, std::string &error) {
    error.clear();
    const int64_t probe_day = ledger.committed_day;
    auto probe_started = std::chrono::steady_clock::now();
    const auto probe_lap = [&](const char *name) {
        const auto now = std::chrono::steady_clock::now();
        EconomyCostProbe::record(name, probe_day,
            std::chrono::duration<double, std::milli>(now - probe_started).count());
        probe_started = now;
    };
    if (!validate_owned_ledger(ledger, false, error)) return false;
    RuntimeEconomyPopulationStore population;
    if (!restore_population_from_ledger(ledger, population, error)) return false;
    probe_lap("mirror.import.validate");
    // Nothing below can fail: the ledger is fully validated and the population
    // already restored, so `_state` is never left half written.
    const bool in_place = state_initialized() &&
        overwrite_market_from_ledger(ledger, _state.market);
    if (in_place) {
        _state.clear_except_market(ledger.market_count);
    } else {
        _state.clear(ledger.market_count, ledger.good_count);
        assign_market_from_ledger(ledger, _state.market);
    }
    _state.population = std::move(population);
    probe_lap(in_place ? "mirror.import.market_in_place" : "mirror.import.market_rebuild");
    assign_owned_blocks_from_ledger(ledger, _state);
    // The caller gets the previous publication back as its next capture buffer.
    std::swap(_committed_ledger_state, ledger);
    _market_export_warmup = 0;
    publish_mirror_features();
    probe_lap("mirror.import.blocks");
    static const bool verify = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MIRROR_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (verify) {
        RuntimeEconomyLedgerState roundtrip;
        std::string verify_error;
        const uint64_t published_hash = _committed_ledger_state.ledger_hash != 0
            ? _committed_ledger_state.ledger_hash
            : _committed_ledger_state.computed_hash();
        if (!export_committed_ledger(roundtrip, verify_error) ||
            roundtrip.ledger_hash != published_hash) {
            std::fprintf(stderr,
                "economy_mirror_import_mismatch day=%lld in_place=%d error=%s\n",
                static_cast<long long>(probe_day), in_place ? 1 : 0,
                verify_error.c_str());
            std::abort();
        }
    }
    return true;
}

bool RuntimeEconomyPodAuthority::publish_owned_committed_mirror(
        uint64_t generation, int64_t committed_day, std::string &error) {
    error.clear();
    if (!state_initialized()) {
        error = "economy_pod_owned_mirror_state_uninitialized";
        return false;
    }
    EconomyCostProbe probe("ledger_export", committed_day, _state.market.stock.size());
    RuntimeEconomyLedgerState &ledger = _export_ledger_scratch;
    // Stamp identity before the export so `valid()` sees a nonzero generation
    // and a committed day even on the very first publish.
    _state.state_generation = std::max(generation, _state.state_generation);
    if (committed_day >= 0) _state.committed_day = committed_day;
    // Published undigested like the captured mirror; readers hash on demand.
    const char *full_market = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MARKET_PUBLISH_FULL);
    const bool incremental_market = !(full_market && std::strcmp(full_market, "1") == 0);
    if (!export_committed_ledger_internal(ledger, error, false, incremental_market)) return false;
    const char *verify = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MIRROR_VERIFY);
    if (verify && std::strcmp(verify, "1") == 0) {
        RuntimeEconomyLedgerState reference;
        if (!export_committed_ledger(reference, error, false) ||
            reference.computed_hash() != ledger.computed_hash()) {
            if (error.empty()) error = "economy_incremental_market_publish_mismatch";
            _market_export_warmup = 0;
            return false;
        }
    }
    // The caller refreshed the committed blocks; export_committed_ledger()
    // validated them. Keeping a second full copy in _state.committed here
    // only duplicated all population/market vectors before the move below;
    // export's fallback blocks are used only when a block is genuinely absent.
    // The complete validated ledger remains the single published copy.
    std::swap(_committed_ledger_state, ledger);
    publish_mirror_features();
    return true;
}

bool RuntimeEconomyPodAuthority::export_committed_ledger(
        RuntimeEconomyLedgerState &ledger, std::string &error,
        bool compute_hash) const {
    return export_committed_ledger_internal(ledger, error, compute_hash, false);
}

bool RuntimeEconomyPodAuthority::export_committed_ledger_internal(
        RuntimeEconomyLedgerState &ledger, std::string &error,
        bool compute_hash, bool incremental_market) const {
    error.clear();
    const bool reuse_market = incremental_market && _market_export_warmup >= 2 &&
        ledger.market_count == _state.market.market_count.get() &&
        ledger.good_count == _state.market.good_count.get();
    if (!incremental_market) ledger.clear();
    // 以下字段全部重新赋值；增量路径只保留私有缓冲中的市场列容量和数值。
    ledger.source_state_hash = 0;
    ledger.ledger_hash = 0;
    const auto copy_started = std::chrono::steady_clock::now();
    ledger.generation = _state.state_generation;
    ledger.committed_day = _state.committed_day;
    ledger.market_count = _state.market.market_count;
    ledger.good_count = _state.market.good_count;
    ledger.cohort_active = _state.population.active;
    ledger.cohort_cell.assign(_state.population.active.size(), -1);
    ledger.cohort_slot.resize(_state.population.active.size());
    for (size_t i = 0; i < ledger.cohort_slot.size(); ++i) ledger.cohort_slot[i] = static_cast<int32_t>(i);
    for (size_t page = 0; page < _state.population.page_cell.size(); ++page) {
        const size_t base = page * RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE && base + static_cast<size_t>(lane) < ledger.cohort_cell.size(); ++lane) ledger.cohort_cell[base + static_cast<size_t>(lane)] = _state.population.page_cell[page];
    }
    ledger.cohort_signature_id = _state.population.signature_id;
    ledger.cohort_generation = _state.population.generation;
    ledger.cohort_reserved = _state.population.reserved;
    ledger.cohort_reservation_owner = _state.population.reservation_owner;
    ledger.cohort_population = _state.population.population;
    ledger.cohort_funds = _state.population.funds;
    ledger.cohort_epoch_income = _state.population.epoch_income;
    ledger.cohort_epoch_expense = _state.population.epoch_expense;
    ledger.cohort_needs_satisfaction = _state.population.needs_satisfaction;
    ledger.cohort_composite_satisfaction =
        _state.population.composite_satisfaction;
    ledger.cohort_owner_employed = _state.population.owner_employed;
    ledger.cohort_employee_employed = _state.population.employee_employed;
    const auto population_finished = std::chrono::steady_clock::now();
    uint64_t market_copied_bytes = 0;
    uint64_t market_dense_bytes = 0;
    const auto copy_market_column = [&](auto &target, const auto &column, size_t index) {
        using Value = typename std::decay_t<decltype(column)>::value_type;
        market_dense_bytes += column.size() * sizeof(Value);
        std::vector<uint64_t> changed;
        if (incremental_market)
            changed = column.take_change_pages(EconomyChangeConsumer::Publish);
        if (!reuse_market || target.size() != column.size()) {
            target = column.values();
            market_copied_bytes += column.size() * sizeof(Value);
        } else {
            // scratch 比当前发布落后两代，必须合并前一代与本代脏页。
            const auto &previous = _market_export_previous_pages[index];
            std::vector<uint64_t> pages;
            pages.reserve(previous.size() + changed.size());
            std::set_union(previous.begin(), previous.end(), changed.begin(), changed.end(),
                std::back_inserter(pages));
            constexpr size_t lanes_per_page = 4096 / sizeof(Value);
            for (uint64_t page : pages) {
                const size_t first = static_cast<size_t>(page) * lanes_per_page;
                if (first >= column.size()) continue;
                const size_t count = std::min(lanes_per_page, column.size() - first);
                std::copy_n(column.data() + first, count, target.data() + first);
                market_copied_bytes += count * sizeof(Value);
            }
        }
        if (incremental_market) _market_export_previous_pages[index] = std::move(changed);
    };
    copy_market_column(ledger.market_stock, _state.market.stock, 0);
    copy_market_column(ledger.market_price, _state.market.price, 1);
    copy_market_column(ledger.market_demand_ema, _state.market.demand_ema, 2);
    copy_market_column(ledger.market_last_shortage_q16, _state.market.last_shortage_q16, 3);
    copy_market_column(ledger.market_cell_to_market, _state.market.cell_to_market, 4);
    const auto market_finished = std::chrono::steady_clock::now();
    ledger.building = _state.building;
    ledger.trade_escrow = _state.trade_escrow;
    ledger.family = _state.family;
    ledger.resource = _state.resource;
    ledger.epoch_cursor = _state.epoch_cursor;
    if (!ledger.building.captured && _state.committed.building.captured)
        ledger.building = _state.committed.building;
    if (!ledger.trade_escrow.captured && _state.committed.trade_escrow.captured)
        ledger.trade_escrow = _state.committed.trade_escrow;
    if (!ledger.family.captured && _state.committed.family.captured)
        ledger.family = _state.committed.family;
    if (!ledger.resource.captured && _state.committed.resource.captured)
        ledger.resource = _state.committed.resource;
    if (!ledger.epoch_cursor.captured && _state.committed.epoch_cursor.captured)
        ledger.epoch_cursor = _state.committed.epoch_cursor;
    const auto blocks_finished = std::chrono::steady_clock::now();
    const auto validation_started = std::chrono::steady_clock::now();
    const char *validation_reason = nullptr;
    if (!ledger.validate_shape_and_values(&validation_reason)) {
        if (incremental_market) _market_export_warmup = 0;
        error = std::string("economy_pod_ledger_export_invalid:") +
            (validation_reason != nullptr ? validation_reason : "unknown");
        return false;
    }
    const auto hash_started = std::chrono::steady_clock::now();
    if (compute_hash) ledger.recompute_hash();
    if (incremental_market) _market_export_warmup = std::min<uint32_t>(2u, _market_export_warmup + 1u);
    EconomyCostProbe::record("ledger_export.market_copied_bytes", ledger.committed_day,
        0.0, market_copied_bytes);
    EconomyCostProbe::record("ledger_export.market_dense_bytes", ledger.committed_day,
        0.0, market_dense_bytes);
    EconomyCostProbe::record("ledger_export.population", ledger.committed_day,
        std::chrono::duration<double, std::milli>(population_finished - copy_started).count());
    EconomyCostProbe::record("ledger_export.market", ledger.committed_day,
        std::chrono::duration<double, std::milli>(market_finished - population_finished).count());
    EconomyCostProbe::record("ledger_export.blocks", ledger.committed_day,
        std::chrono::duration<double, std::milli>(blocks_finished - market_finished).count());
    EconomyCostProbe::record("ledger_export.validate", ledger.committed_day,
        std::chrono::duration<double, std::milli>(hash_started - validation_started).count());
    EconomyCostProbe::record("ledger_export.hash", ledger.committed_day,
        elapsed_ms(hash_started));
    if (ledger.committed_day > 0 && ledger.committed_day % 100 == 0) {
        std::fprintf(stderr, "[economy-ledger-cost] day=%lld copy_ms=%.3f validate_ms=%.3f hash_ms=%.3f cohorts=%zu markets=%zu\n",
            static_cast<long long>(ledger.committed_day),
            std::chrono::duration<double, std::milli>(validation_started - copy_started).count(),
            std::chrono::duration<double, std::milli>(hash_started - validation_started).count(),
            elapsed_ms(hash_started), ledger.cohort_active.size(), ledger.market_stock.size());
    }
    return true;
}
