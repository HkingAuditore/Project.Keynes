    aggregate_keys.reserve(_tariff_history.countries.size());
    for (size_t i = 0; i < _tariff_history.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(_tariff_history.countries[i],
                _tariff_history.kinds[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_tariff_history_duplicate";
            return out;
        }
    }
    const auto mix_environment_hash = [](uint64_t hash, uint32_t value) {
        for (int32_t byte = 0; byte < 4; ++byte) {
            hash ^= static_cast<uint8_t>(
                (value >> (byte * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
        return hash;
    };
    uint64_t restored_environment_hash = 1469598103934665603ULL;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const int32_t values[] = {
            _environment_temperature_q16[cell],
            _environment_temperature_30d_q16[cell],
            _environment_moisture_q16[cell],
            _environment_plant_available_water_q16[cell],
            _environment_precipitation_q16[cell],
            _environment_snow_q16[cell],
            _environment_weather_q16[cell],
        };
        for (int32_t value : values) {
            if (value < 0 || value > Q16_ONE) {
                out["ok"] = false;
                out["reason"] = "restore_environment_value_invalid";
                return out;
            }
            restored_environment_hash = mix_environment_hash(
                restored_environment_hash, static_cast<uint32_t>(value));
        }
    }
    const int64_t computed_environment_hash = static_cast<int64_t>(
        (restored_environment_hash & 0x7fffffffffffffffULL) | 1ULL);
    if (_restore.environment_hash != computed_environment_hash) {
        out["ok"] = false;
        out["reason"] = "restore_environment_hash_mismatch";
        out["expected_environment_hash"] = _restore.environment_hash;
        out["computed_environment_hash"] = computed_environment_hash;
        return out;
    }
    _environment_hash = _restore.environment_hash;
    // Rain is an edge (precipitation rose), not simply a wet day. Seed the
    // previous observation from the saved sample so unchanged rain after a
    // restore does not reset a persisted dry streak.
    _cell_previous_precipitation_q16.assign(
        _environment_precipitation_q16.values().begin(),
        _environment_precipitation_q16.values().end());

    const size_t expected_population_slots =
        population_store().page_next.size() * static_cast<size_t>(COHORT_PAGE_SIZE);
    if (population_store().active.size() != expected_population_slots ||
        population_store().reserved.size() != expected_population_slots ||
        population_store().reservation_owner.size() != expected_population_slots ||
        population_store().signature_id.size() != expected_population_slots ||
        population_store().generation.size() != expected_population_slots ||
        population_store().population.size() != expected_population_slots ||
        population_store().funds.size() != expected_population_slots) {
        out["ok"] = false;
        out["reason"] = "restore_population_lane_shape_invalid";
        return out;
    }
    std::vector<uint8_t> referenced(population_store().page_next.size(), 0);
    int64_t actual_active = 0;
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        const int32_t cell = population_store().page_cell[page];
        const int32_t next = population_store().page_next[page];
        if (cell < -1 || cell >= _cell_count.get() || next < -1 ||
            next >= static_cast<int32_t>(population_store().page_next.size()) ||
            (next >= 0 && population_store().page_cell[next] != cell)) {
            out["ok"] = false;
            out["reason"] = "restore_page_chain_invalid";
            return out;
        }
        if (next >= 0) referenced[next] = 1;
        if (cell < 0) population_store().free_pages.push_back(page);
        const int32_t base = page * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (population_store().active[slot] == 0) continue;
            // Active means an allocated stable handle, not necessarily a
            // living population. Structural/cash-peer work may retain a
            // drained lane at a committed boundary. Preserve it exactly;
            // the employment check below still requires zero jobs on it.
            if (cell < 0 || population_store().signature_id[slot] >= _signatures.size() ||
                population_store().generation[slot] == 0 || population_store().population[slot] < 0 ||
                population_store().funds[slot] < 0) {
                out["ok"] = false;
                out["reason"] = "restore_cohort_record_invalid";
                return out;
            }
            ++actual_active;
        }
    }
    population_store().cell_first_page.assign(_cell_count.get(), -1);
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        const int32_t cell = population_store().page_cell[page];
        if (cell < 0 || referenced[page] != 0) continue;
        if (population_store().cell_first_page[cell] >= 0) {
            out["ok"] = false;
            out["reason"] = "restore_multiple_page_chain_heads";
            return out;
        }
        population_store().cell_first_page.write_scalar(cell, page, market_mutation_sink());
    }
    std::vector<uint8_t> visited(population_store().page_next.size(), 0);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        int32_t steps = 0;
        for (int32_t page = population_store().cell_first_page[cell]; page >= 0;
             page = population_store().page_next[page]) {
            if (++steps > static_cast<int32_t>(population_store().page_next.size()) || visited[page] != 0) {
                out["ok"] = false;
                out["reason"] = "restore_page_chain_cycle";
                return out;
            }
            visited[page] = 1;
        }
    }
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        if (population_store().page_cell[page] >= 0 && visited[page] == 0) {
            out["ok"] = false;
            out["reason"] = "restore_unreachable_page";
            return out;
        }
    }
    if (actual_active != population_store().active_count) {
        out["ok"] = false;
        out["reason"] = "restore_active_count_mismatch";
        return out;
    }
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        if (market_store().cell_to_market[cell] < 0 || market_store().cell_to_market[cell] >= market_store().market_count.get()) {
            out["ok"] = false;
            out["reason"] = "restore_cell_market_invalid";
            return out;
        }
        std::vector<uint32_t> signatures;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            signatures.push_back(population_store().signature_id[slot]);
        });
        std::sort(signatures.begin(), signatures.end());
        if (std::adjacent_find(signatures.begin(), signatures.end()) != signatures.end()) {
            out["ok"] = false;
            out["reason"] = "restore_duplicate_cell_signature";
            return out;
        }
    }
    for (int32_t market = 0; market < market_store().market_count.get(); ++market) {
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t idx = market_store().index(market, good);
            if (market_store().stock[idx] < 0 || market_store().demand_ema[idx] < 0 ||
                market_store().price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                market_store().price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                out["ok"] = false;
                out["reason"] = "restore_market_value_invalid";
                return out;
            }
        }
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    int64_t restore_merchant_repairs = 0;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        if (!ensure_merchant_invariant(cell, restore_merchant_repairs, market_range_error)) {
            out["ok"] = false;
            out["reason"] = String(market_range_error.c_str());
            return out;
        }
    }
    if (!rebuild_merchant_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    for (const Command &cmd : _pending_commands) {
        int32_t slot = -1;
        const bool market_target = cmd.opcode == COMMAND_ADD_STOCK ||
            cmd.opcode == COMMAND_REMOVE_STOCK ||
            cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
            cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY;
        const bool family_reward = is_family_ledger_command(cmd.opcode);
        const bool split_policy = cmd.opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
        const bool treasury_build =
            cmd.opcode == COMMAND_TREASURY_SPONSORED_BUILD;
        const bool treasury_demolish =
            cmd.opcode == COMMAND_TREASURY_SPONSORED_DEMOLISH;
        const bool canal_build = cmd.opcode == COMMAND_BUILD_CANAL;
        const bool expedition_player =
            cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION;
        const bool target_ok = (cmd.opcode == COMMAND_MILITARY_PURCHASE_RECEIPT || cmd.opcode == COMMAND_MILITARY_PURCHASE || cmd.opcode == COMMAND_MILITARY_PURCHASE_ACK) ? (cmd.i64_0 >= 0 && cmd.i64_1 >= 0) : cmd.opcode == COMMAND_MILITARY_PROCUREMENT_DEMAND ? military_procurement_demand_valid(cmd)
            : family_reward ? family_ledger_command_preflight(cmd)
            : split_policy
            ? family_split_policy_command_preflight(cmd)
            : treasury_build
            ? (_country_runtime != nullptr && country_reads().valid_handle(
                   static_cast<int64_t>(cmd.target_handle)) &&
               cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count.get() &&
               cmd.i32_1 >= 0 && cmd.i32_1 < static_cast<int32_t>(
                   _building_types.size()) && cmd.i64_0 == 1 &&
               cmd.treasury_construction_policy_valid())
            : treasury_demolish
            ? (_country_runtime != nullptr && country_reads().valid_handle(
                   static_cast<int64_t>(cmd.target_handle)) &&
               cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count.get() &&
               cmd.i32_1 >= 0 && cmd.i32_1 < static_cast<int32_t>(
                   _building_types.size()) && cmd.i64_0 > 0 &&
               cmd.treasury_construction_policy_valid())
            : canal_build
            ? (_country_runtime != nullptr && country_reads().valid_handle(
                   static_cast<int64_t>(cmd.target_handle)) && cmd.i64_0 > 0)
            : expedition_player
            ? (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION
                ? (cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count.get() &&
                   cmd.i32_1 >= 0 && cmd.i32_1 < _cell_count.get() && cmd.i64_0 >= 1)
                : cmd.target_handle != 0)
            : market_target
            ? (cmd.i32_0 >= 0 && cmd.i32_0 < market_store().market_count.get() &&
               cmd.i32_1 >= 0 && cmd.i32_1 < market_store().good_count.get() &&
               ((cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                 cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) ||
                (_country_runtime != nullptr && country_reads().valid_handle(
                    static_cast<int64_t>(cmd.target_handle)))))
            : population_store().valid_handle(cmd.target_handle, slot);
        const bool opcode_ok =
            (cmd.opcode >= COMMAND_TRANSFER_TO_COHORT &&
             cmd.opcode <= COMMAND_BUILD_CANAL) ||
            family_reward || split_policy || cmd.opcode == COMMAND_MILITARY_PROCUREMENT_DEMAND ||
            cmd.opcode == COMMAND_MILITARY_PURCHASE || cmd.opcode == COMMAND_MILITARY_PURCHASE_RECEIPT || cmd.opcode == COMMAND_MILITARY_PURCHASE_ACK;
        if (!opcode_ok ||
            !target_ok || cmd.effective_day < 0 || cmd.sequence < 0 ||
            (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION &&
             cmd.opcode != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
             cmd.opcode != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
            out["ok"] = false;
            out["reason"] = "restore_command_invalid";
            return out;
        }
    }
    // Committed group fills describe the last employment allocation. A later
    // demolition/investment step may reduce lot counts before the next labor
    // period; reconciliation caps those fills by the remaining workforce, not
    // by the new lot count. Restore the same state, bounded by the persisted
    // cohort employment so historical fills cannot invent employees.
    std::unordered_map<uint64_t, int64_t> remaining_employee_jobs;
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int32_t profession = _signatures[population_store().signature_id[slot]].profession_id;
        const uint64_t key = trade_key(cell, profession);
        remaining_employee_jobs[key] = saturating_add(remaining_employee_jobs[key],
            std::max<int64_t>(0, population_store().employee_employed[slot]), _saturation_count);
    }
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
        if (_signatures[group.owner_signature_id].profession_id !=
                _building_types[group.type_id].owner_profession_id ||
            group.filled_owner < 0 || group.filled_owner >
                group.count * _building_types[group.type_id].owner_slots_per_building ||
            group.last_input_cost < 0 || group.last_wages_paid < 0 ||
            group.last_wages_due < 0 || group.last_expected_revenue < 0 ||
            group.last_operating_cost < 0 || group.planned_utilization_q16 < 0 ||
            group.planned_utilization_q16 > Q16_ONE ||
            group.last_resource_generated < 0 ||
            group.last_base_wages_paid < 0 || group.last_base_wages_due < 0 ||
            group.last_bonus_paid < 0 || group.last_bonus_due < 0 ||
            group.last_base_wages_paid > group.last_base_wages_due ||
            group.last_bonus_paid > group.last_bonus_due ||
            group.wage_suspended > 1 || group.operating_state > 1 ||
            (group.pending_operating_state > 1 && group.pending_operating_state != 255) ||
            group.merchant_debt_principal < 0 || group.merchant_debt_premium < 0 ||
            group.last_in_kind_livelihood_value < 0 ||
            group.last_temperature_fit_q16 < 0 ||
            group.last_temperature_fit_q16 > Q16_ONE ||
            group.last_water_fit_q16 < 0 ||
            group.last_water_fit_q16 > Q16_ONE ||
            group.last_climate_capacity_q16 < 0 ||
            group.last_climate_capacity_q16 > Q16_ONE ||
            group.last_climate_lost_output < 0 ||
            ((group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) &&
             group.merchant_debt_term_cycles_left == 0 &&
             group.merchant_debt_delinquent_cycles == 0) ||
            group.purchase_intent_capacity_q16 < 0 ||
            group.purchase_intent_capacity_q16 > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "restore_building_owner_or_job_invalid";
            return out;
        }
        const BuildingType &type = _building_types[group.type_id];
        if (group.last_input_selection_begin < 0 ||
            static_cast<size_t>(group.last_input_selection_begin) +
                    static_cast<size_t>(type.input_count) >
                _building_last_input_selected_goods.size()) {
            out["ok"] = false;
            out["reason"] = "restore_building_input_selection_span_invalid";
            return out;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            if (role_index < 0 ||
                role_index >= static_cast<int32_t>(_building_role_contract_wage.size()) ||
                _building_role_contract_wage[role_index] < 0 ||
                _building_role_base_living_cost[role_index] < 0 ||
                _building_role_living_cost[role_index] < 0 ||
                _building_role_local_average_wage[role_index] < 0 ||
                _building_role_base_wage_paid[role_index] < 0 ||
                _building_role_base_wage_due[role_index] <
                    _building_role_base_wage_paid[role_index] ||
                _building_role_bonus_paid[role_index] < 0 ||
                _building_role_bonus_due[role_index] <
                    _building_role_bonus_paid[role_index]) {
                out["ok"] = false;
                out["reason"] = "restore_building_role_wage_invalid";
                return out;
            }
            const int64_t filled = _building_employee_filled[role_index];
            const int32_t profession = _building_employee_roles[type.employee_begin + r].profession_id;
            int64_t &remaining = remaining_employee_jobs[trade_key(group.cell, profession)];
            if (filled < 0 || filled > remaining) {
                out["ok"] = false;
                out["reason"] = "restore_building_employee_job_invalid";
                return out;
            }
            remaining -= filled;
        }
    }
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        if (population_store().owner_employed[slot] < 0 || population_store().employee_employed[slot] < 0 ||
            population_store().owner_employed[slot] + population_store().employee_employed[slot] >
                population_store().population[slot]) {
            out["ok"] = false;
            out["reason"] = "restore_cohort_employment_invalid";
            return out;
        }
    }
    rebuild_building_cell_offsets();
    _pending_building_topology_rebuild = false;
    if (_auto_slice_by_scale)
        _cells_per_slice = std::clamp(market_store().market_count.get(), 1, 128);
