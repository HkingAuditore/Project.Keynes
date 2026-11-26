int64_t NativeEconomyRuntime::state_hash_internal(bool paged) const {
    EconomyCostProbe probe("native_hash", _current_day.get(), market_store().stock.size());
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u64 = [&](uint64_t value) {
        hash = economy_hash_u64(hash, value);
    };
    auto mix_string = [&](const std::string &value) {
        mix_u64(value.size());
        for (unsigned char byte : value) {
            hash ^= byte;
            hash *= 1099511628211ULL;
        }
    };
    mix_u64(static_cast<uint64_t>(_trade_runtime_mode.get() != 2 &&
        _catalog_compat_hash_v10.get() != 0 ? _catalog_compat_hash_v10.get() : _catalog_hash.get()));
    mix_u64(static_cast<uint64_t>(_building_catalog_hash.get()));
    mix_u64(static_cast<uint64_t>(_prosperity_profile_hash.get()));
    mix_u64(static_cast<uint64_t>(_startup_demand_runtime_mode.get()));
    mix_u64(_price_ceiling_confirm_days.get()); mix_u64(_price_ceiling_expand_bp.get()); mix_u64(_price_ceiling_recover_bp.get());
    for (size_t market = 0; market < market_store().price_ceilings.size(); ++market) {
        for (const auto &state : market_store().price_ceilings[market]) {
            mix_u64(market); mix_u64(state.good); mix_u64(state.limit); mix_u64(state.confirmation_days);
        }
    }
    mix_u64(price_ceiling_state_count());
    mix_u64(static_cast<uint64_t>(_cell_count.get()));
    mix_u64(static_cast<uint64_t>(_epoch_id.get()));
    mix_u64(static_cast<uint64_t>(_epoch_days.get()));
    mix_u64(static_cast<uint64_t>(_locked_market_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_market_cycle_start_day.get()));
    mix_u64(static_cast<uint64_t>(_locked_slow_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_slow_cycle_start_day.get()));
    mix_u64(static_cast<uint64_t>(_locked_investment_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_investment_cycle_start_day.get()));
    // Employment mobility is configuration, not persisted cohort state, but
    // it changes the next deterministic transition plan. Include it in the
    // authoritative hash so save/restore and worker/scalar comparisons cannot
    // silently continue under a different policy.
    mix_u64(0x454d504c4f594346ULL); // "EMPLOYCF"
    mix_u64(static_cast<uint32_t>(_employment_mobility_daily_q16.get()));
    mix_u64(static_cast<uint32_t>(
        _employment_understaffed_reallocation_hurdle_mult_q16.get()));
    mix_u64(static_cast<uint32_t>(_employment_choice_temperature_q16.get()));
    mix_u64(static_cast<uint64_t>(_last_committed_day.get()));
    mix_u64(static_cast<uint64_t>(_environment_day.get()));
    mix_u64(static_cast<uint64_t>(_environment_hash.get()));
    mix_u64(static_cast<uint64_t>(_country_runtime == nullptr ? 0 : country_reads().state_hash()));
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        mix_u64(static_cast<uint64_t>(_cell_last_settlement_day[cell]));
        mix_u64(_cell_settlement_generation[cell]);
        mix_u64(_cell_price_stock_gen[cell]);
        mix_u64(_cell_owner_cash_gen[cell]);
        mix_u64(_cell_population_gen[cell]);
        mix_u64(_cell_building_structure_gen[cell]);
        mix_u64(_cell_technology_gen[cell]);
        mix_u64(_cell_resource_gen[cell]);
        mix_u64(_cell_trade_gen[cell]);
        mix_u64(_settlements.tier[cell]);
        mix_u64(_settlements.prosperity_generation[cell]);
        mix_u64(_settlements.name_roll_generation[cell]);
        mix_u64(static_cast<uint64_t>(_settlements.name_active[cell]));
        mix_u64(static_cast<uint64_t>(_settlements.name_forced[cell]));
        if (_settlements.name_active[cell] != 0) {
            mix_string(_settlement_name_pack_id.get());
            if (_settlements.root[cell] < 0) {
                mix_string(_settlement_full_name_ids[
                    _settlements.prefix[cell]]);
            } else {
                mix_string(_settlement_prefix_ids[_settlements.prefix[cell]]);
                mix_string(_settlement_root_ids[_settlements.root[cell]]);
                mix_string(_settlement_suffix_ids[_settlements.suffix[cell]]);
            }
        }
        mix_u64(_settlements.disambiguator[cell]);
        mix_u64(cell < static_cast<int32_t>(
            _fiscal_previous_country_handles.size())
            ? _fiscal_previous_country_handles[cell] : 0);
        for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            mix_u64(static_cast<uint64_t>(
                lane < _fiscal_previous_requests.size()
                    ? _fiscal_previous_requests[lane] : 0));
        }
    }
    CountryReadView::Snapshot fiscal_country_snapshot;
    const size_t fiscal_hash_countries = _country_runtime != nullptr &&
        country_reads().copy_economy_snapshot(fiscal_country_snapshot)
        ? static_cast<size_t>(std::max(0,
            fiscal_country_snapshot.country_count))
        : _epoch_country_handles.size();
    const size_t fiscal_hash_lanes = fiscal_hash_countries *
        CountryApi::TAX_KIND_COUNT;
    const auto mix_fiscal_lanes = [&](const std::vector<int64_t> &values) {
        for (size_t lane = 0; lane < fiscal_hash_lanes; ++lane) {
            mix_u64(static_cast<uint64_t>(
                lane < values.size() ? values[lane] : 0));
        }
    };
    // PKEC persists one fixed tax-kind group per frozen country and fills
    // never-committed cumulative lanes with zero. Hash that same logical
    // shape so a cold bootstrap and its restore remain equivalent.
    mix_fiscal_lanes(_fiscal_cumulative_bases);
    mix_fiscal_lanes(_fiscal_cumulative_collected);
    mix_fiscal_lanes(_fiscal_cumulative_requests);
    mix_fiscal_lanes(_fiscal_cumulative_paid);
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        mix_u64(slot);
        mix_u64(population_store().generation[slot]);
        mix_u64(population_store().signature_id[slot]);
        mix_u64(static_cast<uint64_t>(population_store().population[slot]));
        mix_u64(static_cast<uint64_t>(population_store().funds[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_income[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_expense[slot]));
        mix_u64(static_cast<uint64_t>(population_store().income_ema[slot]));
        mix_u64(population_store().needs_satisfaction[slot]);
        mix_u64(population_store().worst_need_id[slot]);
        mix_u64(population_store().flags[slot]);
        mix_u64(static_cast<uint64_t>(population_store().demography_residual[slot]));
        mix_u64(static_cast<uint64_t>(population_store().owner_employed[slot]));
        mix_u64(static_cast<uint64_t>(population_store().employee_employed[slot]));
        mix_u64(population_store().composite_satisfaction[slot]);
        mix_u64(population_store().worst_dimension_id[slot]);
        const size_t dims_base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            mix_u64(population_store().satisfaction_dims[dims_base +
                                                  static_cast<size_t>(dim)]);
        mix_u64(static_cast<uint64_t>(population_store().income_baseline_ema[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_tax_paid[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_subsidy_received[slot]));
    }
    mix_u64(0x534f4350524553ULL); // "SOCPRES"
    hash = economy_hash_lanes<true>(hash, _cell_social_pressure_level);
    // Sparse stratum mobilization: hash every persisted field explicitly so
    // struct padding can never affect the saved-state hash.
    mix_u64(0x4d4f42494c495a45ULL); // "MOBILIZE"
    mix_u64(static_cast<uint64_t>(_stratum_mobilization.rows.size()));
    for (const StratumMobilizationRow &row : _stratum_mobilization.rows) {
        mix_u64(static_cast<uint64_t>(static_cast<uint32_t>(row.cell)));
        mix_u64(static_cast<uint64_t>(row.profession));
        mix_u64(static_cast<uint64_t>(static_cast<uint32_t>(row.owner_slot)));
        mix_u64(static_cast<uint64_t>(row.mobilization_q16));
        mix_u64(static_cast<uint64_t>(row.satisfaction_ema_q16));
        mix_u64(static_cast<uint64_t>(row.share_q16));
        mix_u64(static_cast<uint64_t>(row.local_sat_q16));
        mix_u64(static_cast<uint64_t>(row.stage));
        mix_u64(static_cast<uint64_t>(row.flags));
        mix_u64(static_cast<uint64_t>(static_cast<uint32_t>(row.next_check_day)));
        mix_u64(static_cast<uint64_t>(static_cast<uint32_t>(row.cooldown_until_day)));
        mix_u64(static_cast<uint64_t>(static_cast<uint32_t>(row.last_event_day)));
        mix_u64(static_cast<uint64_t>(row.trauma_q16));
    }
    mix_u64(0x4249525448524553ULL); // "BIRTHRES"
    hash = economy_hash_lanes<true>(hash, _birth_residual_q32);
    mix_u64(0x53555050454d41ULL); // "SUPPEMA"
    hash = economy_hash_lanes<true>(hash, _cell_support_ema_q16);
    mix_u64(0x583133415354524dULL); // "X13ASTRM"
    hash = economy_hash_lanes<true>(hash, _cell_dry_streak_days);
    hash = economy_hash_lanes<true>(hash, _cell_days_since_hazard);
    hash = economy_hash_lanes<true>(hash, _cell_previous_hazard_mask);
    mix_u64(0x464f4f44464c4f57ULL); // "FOODFLOW"
    mix_u64(static_cast<uint32_t>(_food_flow_previous_period_days.get()));
    hash = economy_hash_lanes<true>(hash, _cell_food_flow_valid);
    for (const EconomyOwnedColumn<int64_t> *lane : {
             &_cell_food_output_eq_previous,
             &_cell_food_input_eq_previous,
             &_cell_food_import_eq_previous,
             &_cell_food_export_eq_previous,
             &_cell_food_access_eq_previous})
        hash = economy_hash_lanes<true>(hash, *lane);
    for (int32_t i = 0; i < static_cast<int32_t>(families_store().active.size()); ++i) {
        if (families_store().active[i] == 0) continue;
        mix_u64(0x46414d494c59ULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(families_store().generation[i]);
        mix_u64(static_cast<uint64_t>(families_store().stable_id[i]));
        mix_u64(static_cast<uint32_t>(families_store().surname_id[i]));
        mix_u64(families_store().surname_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(families_store().founded_day[i]));
        mix_u64(static_cast<uint32_t>(families_store().home_cell[i]));
        mix_u64(static_cast<uint32_t>(families_store().origin_cell[i]));
        mix_u64(static_cast<uint32_t>(families_store().origin_ethnicity[i]));
        mix_u64(static_cast<uint32_t>(families_store().culture_group_id[i]));
        mix_u64(families_store().split_sequence[i]);
        mix_u64(families_store().decline_reviews[i]);
        mix_u64(families_store().flags[i]);
        const int32_t pending_population_reward = i < static_cast<int32_t>(
                _family_colonization_population_reward_pending.size())
            ? std::max(0, _family_colonization_population_reward_pending[
                static_cast<size_t>(i)])
            : 0;
        if (pending_population_reward > 0) {
            mix_u64(0x46414d5052455744ULL); // "FAMPREWD"
            mix_u64(static_cast<uint32_t>(pending_population_reward));
        }
    }
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        mix_u64(edge.family_handle); mix_u64(edge.cohort_handle);
        mix_u64(static_cast<uint64_t>(edge.people));
        mix_u64(static_cast<uint64_t>(edge.cash_claim));
        mix_u64(static_cast<uint64_t>(edge.population_basis));
        mix_u64(static_cast<uint64_t>(edge.funds_basis));
        mix_u64(static_cast<uint64_t>(edge.owner_employed));
        mix_u64(static_cast<uint64_t>(edge.employee_employed));
    }
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        mix_u64(edge.family_handle); mix_u64(edge.building_handle);
        mix_u64(static_cast<uint64_t>(edge.owned_count));
        mix_u64(static_cast<uint64_t>(edge.filled_owner));
    }
    mix_u64(0x46414d5452414954ULL); // "FAMTRAIT"
    mix_u64(static_cast<uint32_t>(_family_trait_catalog_version.get()));
    mix_u64(static_cast<uint64_t>(_family_trait_catalog_hash.get()));
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        mix_u64(roll.family_handle);
        mix_u64(static_cast<uint32_t>(roll.trait_id));
        mix_u64(static_cast<uint32_t>(roll.strength_q16));
        mix_u64(roll.core);
    }
    mix_u64(0x46414d4252414e43ULL); // "FAMBRANC"
    for (size_t i = 0; i < family_influences().active.size(); ++i) {
        mix_u64(i);
        mix_u64(family_influences().active[i]);
        mix_u64(family_influences().generation[i]);
        mix_u64(family_influences().family_handle[i]);
        mix_u64(static_cast<uint32_t>(family_influences().cell[i]));
        mix_u64(static_cast<uint64_t>(family_influences().stable_id[i]));
        mix_u64(static_cast<uint64_t>(family_influences().population[i]));
        mix_u64(static_cast<uint64_t>(family_influences().cash[i]));
        mix_u64(static_cast<uint64_t>(family_influences().building_asset[i]));
        mix_u64(static_cast<uint32_t>(
            family_influences().population_share_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().cash_share_q16[i]));
        mix_u64(static_cast<uint32_t>(
            family_influences().building_share_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().score_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().satisfaction_q16[i]));
        mix_u64(family_influences().prestige_level[i]);
        mix_u64(family_influences().pending_target_level[i]);
        mix_u64(family_influences().review_streak[i]);
        mix_u64(static_cast<uint64_t>(family_influences().last_review_day[i]));
    }
    mix_u64(0x46414d434f4d4d44ULL); // "FAMCOMMD"
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        mix_u64(static_cast<uint32_t>(command.operation));
        mix_u64(command.family_handle);
        mix_u64(static_cast<uint32_t>(command.trait_id));
        mix_u64(static_cast<uint32_t>(command.strength_q16));
        mix_u64(static_cast<uint64_t>(command.effective_day));
        mix_u64(static_cast<uint32_t>(command.priority));
        mix_u64(static_cast<uint64_t>(command.sequence));
        mix_u64(command.submit_order);
    }
    append_family_founding_hash(hash);
    mix_u64(0x455850454449544eULL); // "EXPEDITN"
    for (size_t i = 0; i < family_expeditions_store().active.size(); ++i) {
        mix_u64(i); mix_u64(family_expeditions_store().active[i]);
        mix_u64(family_expeditions_store().generation[i]);
        if (family_expeditions_store().active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(family_expeditions_store().stable_id[i]));
        mix_u64(family_expeditions_store().country_handle[i]);
        mix_u64(family_expeditions_store().family_handle[i]);
        mix_u64(static_cast<uint32_t>(family_expeditions_store().source_cell[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().target_cell[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().departure_day[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().due_day[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().route_cost[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().speed[i]));
        mix_u64(family_expeditions_store().state[i]);
        mix_u64(static_cast<uint64_t>(family_expeditions_store().population[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().anonymous[i]));
        mix_u64(static_cast<uint64_t>(
            family_expeditions_store().kit_bridge_required_units[i]));
        mix_u64(static_cast<uint64_t>(
            family_expeditions_store().kit_material_required_units[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().effect_transaction_id[i]));
        mix_u64(family_expeditions_store().idempotency_key[i]);
        const uint32_t route_begin = family_expeditions_store().route_begin[i];
        const uint32_t route_count = family_expeditions_store().route_count[i];
        for (uint32_t r = 0; r < route_count; ++r) {
            mix_u64(static_cast<uint32_t>(family_expedition_route_cells()[route_begin + r]));
            mix_u64(static_cast<uint32_t>(family_expedition_route_costs()[route_begin + r]));
        }
        const uint32_t payload_begin = family_expeditions_store().payload_begin[i];
        const uint32_t payload_count = family_expeditions_store().payload_count[i];
        for (uint32_t p = 0; p < payload_count; ++p) {
            const FamilyExpeditionPayload &payload =
                family_expedition_payloads()[payload_begin + p];
            mix_u64(payload.source_cohort_handle);
            mix_u64(static_cast<uint32_t>(payload.signature));
            mix_u64(static_cast<uint64_t>(payload.people));
            mix_u64(static_cast<uint64_t>(payload.funds));
            mix_u64(static_cast<uint64_t>(payload.epoch_income));
            mix_u64(static_cast<uint64_t>(payload.epoch_expense));
            mix_u64(static_cast<uint64_t>(payload.epoch_in_kind_income));
            mix_u64(static_cast<uint64_t>(payload.income_ema));
            mix_u64(static_cast<uint64_t>(payload.epoch_tax_paid));
            mix_u64(static_cast<uint64_t>(payload.epoch_subsidy_received));
            mix_u64(static_cast<uint64_t>(payload.income_baseline_ema));
            mix_u64(static_cast<uint64_t>(payload.demography_residual));
            mix_u64(static_cast<uint64_t>(payload.cash_claim));
            mix_u64(payload.anonymous);
            mix_u64(static_cast<uint64_t>(payload.owner_employed));
            mix_u64(static_cast<uint64_t>(payload.employee_employed));
            mix_u64(payload.needs_satisfaction); mix_u64(payload.worst_need_id);
            mix_u64(payload.composite_satisfaction);
            for (uint16_t dimension : payload.satisfaction_dims) mix_u64(dimension);
            mix_u64(payload.worst_dimension_id);
            for (uint32_t person = 0; person < payload.person_count; ++person)
                mix_u64(family_expedition_person_handles()[payload.person_begin + person]);
        }
        const uint32_t cargo_begin = family_expeditions_store().cargo_begin[i];
        const uint32_t cargo_count = family_expeditions_store().cargo_count[i];
        mix_u64(cargo_count);
        for (uint32_t c = 0; c < cargo_count; ++c) {
            const FamilyExpeditionCargoLine &line =
                family_expedition_cargo()[cargo_begin + c];
            mix_u64(static_cast<uint32_t>(line.good_id));
            mix_u64(static_cast<uint64_t>(line.quantity));
            mix_u64(line.flags);
        }
        const uint32_t kit_begin = family_expeditions_store().kit_building_begin[i];
        const uint32_t kit_count = family_expeditions_store().kit_building_count[i];
        mix_u64(kit_count);
        for (uint32_t k = 0; k < kit_count; ++k) {
            const FamilyExpeditionKitBuilding &row =
                family_expedition_kit_buildings()[kit_begin + k];
            mix_u64(static_cast<uint32_t>(row.type_id));
            mix_u64(static_cast<uint64_t>(row.count));
        }
        mix_u64(family_expeditions_store().kit_missing_stock_identity[i]);
        const uint32_t missing_begin =
            family_expeditions_store().missing_good_begin[i];
        const uint32_t missing_count =
            family_expeditions_store().missing_good_count[i];
        mix_u64(missing_count);
        for (uint32_t m = 0; m < missing_count; ++m) {
            mix_u64(static_cast<uint32_t>(
                family_expedition_missing_good_ids()[missing_begin + m]));
            mix_u64(static_cast<uint64_t>(
                family_expedition_missing_good_quantities()[missing_begin + m]));
        }
    }
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        mix_u64(0x504552534f4eULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(persons_store().generation[i]);
        mix_u64(persons_store().active[i]);
        if (persons_store().active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(persons_store().stable_id[i]));
        mix_u64(persons_store().family_handle[i]); mix_u64(persons_store().cohort_handle[i]);
        mix_u64(static_cast<uint32_t>(persons_store().given_name_id[i]));
        mix_u64(persons_store().name_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(persons_store().notable_since_day[i]));
        mix_u64(persons_store().flags[i]);
        mix_u64(static_cast<uint64_t>(persons_store().cash_claim[i]));
        mix_u64(static_cast<uint64_t>(persons_store().family_equity_share_q32[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_job_income[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_business_result[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_consumption_expense[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_tax[i]));
        mix_u64(static_cast<uint64_t>(persons_store().income_ema[i]));
        mix_u64(persons_store().needs_satisfaction[i]); mix_u64(persons_store().worst_need_id[i]);
        mix_u64(persons_store().building_handle[i]); mix_u64(persons_store().job_kind[i]);
        mix_u64(static_cast<uint32_t>(persons_store().employee_role_index[i]));
        mix_u64(static_cast<uint64_t>(persons_store().job_since_day[i]));
    }
    for (const PersonNeedState &state : person_needs()) {
        mix_u64(state.person_handle);
        mix_u64(static_cast<uint32_t>(state.stable_need_id));
        mix_u64(static_cast<uint64_t>(state.desired_period_units));
        mix_u64(state.satisfaction_q16);
        mix_u64(static_cast<uint64_t>(state.attributed_spend));
    }
    for (int32_t mapping : market_store().cell_to_market) mix_u64(static_cast<uint32_t>(mapping));
    if (paged) {
        auto &pages = _formula_owned != nullptr ? _formula_owned->market_hash_pages : _market_hash_pages;
        mix_u64(RuntimeChunkHash::VERSION);
        mix_u64(pages[0].update(market_store().stock, 1, 1));
        mix_u64(pages[1].update(market_store().price, 1, 2));
        mix_u64(pages[2].update(market_store().demand_ema, 1, 3));
        mix_u64(pages[3].update(market_store().last_shortage_q16, 1, 4));
    } else {
        hash = economy_hash_lanes<true>(hash, market_store().stock);
        for (int32_t value : market_store().price) mix_u64(static_cast<uint32_t>(value));
        hash = economy_hash_lanes<true>(hash, market_store().demand_ema);
        hash = economy_hash_lanes<true>(hash, market_store().last_shortage_q16);
    }
    for (const Command &cmd : _pending_commands) {
        mix_u64(static_cast<uint32_t>(cmd.opcode));
        mix_u64(static_cast<uint64_t>(cmd.effective_day));
        mix_u64(static_cast<uint64_t>(cmd.sequence));
        mix_u64(cmd.target_handle);
        mix_u64(static_cast<uint32_t>(cmd.i32_0));
        mix_u64(static_cast<uint32_t>(cmd.i32_1));
        mix_u64(static_cast<uint64_t>(cmd.i64_0));
        mix_u64(static_cast<uint64_t>(cmd.i64_1));
        mix_u64(static_cast<uint64_t>(cmd.effect_request_id));
        mix_u64(cmd.opcode == COMMAND_START_FAMILY_EXPEDITION
            ? cmd.expedition_route_hash : cmd.effect_idempotency_key);
    }
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        mix_u64(static_cast<uint32_t>(group.cell));
        mix_u64(static_cast<uint32_t>(group.type_id));
        mix_u64(static_cast<uint32_t>(group.owner_signature_id));
        mix_u64(static_cast<uint64_t>(group.count));
        mix_u64(static_cast<uint64_t>(group.filled_owner));
        mix_u64(static_cast<uint64_t>(group.last_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_temperature_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_water_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_lost_output));
        mix_u64(static_cast<uint64_t>(group.last_input));
        mix_u64(static_cast<uint64_t>(group.last_output));
        mix_u64(static_cast<uint64_t>(group.last_sold));
        mix_u64(static_cast<uint64_t>(group.last_discarded));
        mix_u64(static_cast<uint64_t>(group.last_resource));
        mix_u64(static_cast<uint64_t>(group.last_resource_generated));
        mix_u64(static_cast<uint64_t>(group.last_revenue));
        mix_u64(static_cast<uint64_t>(group.last_input_cost));
        mix_u64(static_cast<uint64_t>(group.last_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_expected_revenue));
        mix_u64(static_cast<uint64_t>(group.last_operating_cost));
        mix_u64(static_cast<uint32_t>(group.last_margin_gap_q16));
        mix_u64(static_cast<uint32_t>(group.planned_utilization_q16));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_bonus_paid));
        mix_u64(static_cast<uint64_t>(group.last_bonus_due));
        mix_u64(group.wage_suspended);
        mix_u64(static_cast<uint64_t>(group.purchase_intent_capacity_q16));
        mix_u64(static_cast<uint32_t>(group.realized_profit_margin_q16));
        mix_u64(group.severe_loss_cycles);
        mix_u64(group.recovery_cycles);
        mix_u64(group.recovery_failed_reviews);
        mix_u64(group.merchant_debt_term_cycles_left);
        mix_u64(group.merchant_debt_delinquent_cycles);
        mix_u64(std::min<uint8_t>(group.operating_state, 1));
        mix_u64(group.pending_operating_state <= 1
            ? group.pending_operating_state : uint8_t{255});
        mix_u64(0);
        mix_u64(static_cast<uint64_t>(group.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(group.merchant_debt_premium));
        mix_u64(static_cast<uint64_t>(group.last_in_kind_livelihood_value));
        mix_u64(static_cast<uint64_t>(group.last_market_receipt));
        mix_u64(static_cast<uint64_t>(group.last_bullion_mint_receipt));
        mix_u64(static_cast<uint64_t>(group.last_producer_support_receipt));
        mix_u64(static_cast<uint64_t>(group.last_business_tax_paid));
        mix_u64(static_cast<uint64_t>(group.last_business_subsidy_received));
        mix_u64(static_cast<uint64_t>(group.last_maintenance_due));
        mix_u64(static_cast<uint64_t>(group.last_observed_capacity_days_q16));
        mix_u64(static_cast<uint64_t>(group.last_quoted_market_receipt));
        mix_u64(static_cast<uint64_t>(group.last_quoted_operating_cost));
    }
    // CSR offsets are reconstructed from the stable signal records and are not
    // persistent authority. Hash only the records so bootstrap and restore do
    // not diverge on an equivalent transient cache shape.
    for (size_t i = 0; i < _market_signals.good_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_market_signals.good_ids[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.business_demand_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.offered_supply_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.realized_withdrawal_ema[i]));
        mix_u64(static_cast<uint32_t>(_market_signals.cost_anchor_price[i]));
        const auto mix_observation = [&](const std::vector<int64_t> &values) {
            mix_u64(static_cast<uint64_t>(i < values.size() ? values[i] : 0));
        };
        mix_observation(_epoch_producer_sellable_current);
        mix_observation(_epoch_producer_merchant_sold_current);
        mix_observation(_epoch_previous_producer_sellable);
        mix_observation(_epoch_previous_producer_merchant_sold);
    }
    auto hash_building_role_lanes = [&](const std::vector<int64_t> &lanes) {
        for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
            const auto group = building_view(pk_row);
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t role = 0; role < type.employee_count; ++role) {
                mix_u64(static_cast<uint64_t>(
                    lanes[group.employee_fill_begin + role]));
            }
        }
    };
    hash_building_role_lanes(_building_employee_filled);
    hash_building_role_lanes(_building_role_contract_wage);
    hash_building_role_lanes(_building_role_base_living_cost);
    hash_building_role_lanes(_building_role_living_cost);
    hash_building_role_lanes(_building_role_local_average_wage);
    hash_building_role_lanes(_building_role_base_wage_due);
    hash_building_role_lanes(_building_role_base_wage_paid);
    hash_building_role_lanes(_building_role_bonus_due);
    hash_building_role_lanes(_building_role_bonus_paid);
    // Labor cell offsets are likewise a derived lookup cache.
    for (size_t i = 0; i < _labor_signals.profession_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_labor_signals.profession_ids[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.base_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.role_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.contract_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.paid_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.job_days[i]));
        mix_u64(static_cast<uint32_t>(_labor_signals.pay_ratio_q16[i]));
    }
    for (const auto pending : pending_construction()) {
        mix_u64(static_cast<uint32_t>(pending.cell));
        mix_u64(static_cast<uint32_t>(pending.type_id));
        mix_u64(static_cast<uint32_t>(pending.owner_signature_id));
        mix_u64(static_cast<uint64_t>(pending.count));
        mix_u64(static_cast<uint64_t>(pending.ready_day));
        mix_u64(static_cast<uint64_t>(pending.sequence));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_premium));
        mix_u64(pending.merchant_debt_term_cycles_left);
        mix_u64(pending.sponsor_family_handle);
    }
    if (_trade_runtime_mode.get() == 2 || !trade_orders_store().ids.empty() ||
        !_trade_flows.cells.empty()) {
    mix_u64(0x5452414445524556ULL); // "TRADEREV"
    mix_u64(_country_trade_revision.get());
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        mix_u64(static_cast<uint64_t>(trade_orders_store().ids[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().sources[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().destinations[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().countries[order]));
        mix_u64(trade_orders_store().source_country_handles[order]);
        mix_u64(trade_orders_store().destination_country_handles[order]);
        mix_u64(static_cast<uint32_t>(trade_orders_store().source_country_slots[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().destination_country_slots[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().departure_days[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().arrival_days[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().cash_escrow[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().capacity_work[order]));
        mix_u64(trade_orders_store().states[order]);
        mix_u64(trade_orders_store().cargo_delivered[order]);
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_goods[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_quantities[line]));
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_unit_prices[line]));
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_destination_prices[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_base_values[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_retail_values[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_import_transfers[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_export_transfers[line]));
            mix_u64(static_cast<uint64_t>(
                trade_orders_store().line_transaction_transfers[line]));
            mix_u64(trade_orders_store().line_flags[line]);
        }
        for (int32_t seller = trade_orders_store().seller_offsets[order];
             seller < trade_orders_store().seller_offsets[order + 1]; ++seller) {
            mix_u64(trade_orders_store().seller_handles[seller]);
            mix_u64(static_cast<uint64_t>(trade_orders_store().seller_weights[seller]));
        }
    }
    mix_u64(static_cast<uint64_t>(trade_orders_store().next_id));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_trade_flows.cells[i]));
        mix_u64(static_cast<uint32_t>(_trade_flows.goods[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.import_ema[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.export_ema[i]));
    }
    }
    mix_u64(0x434f554e54525947ULL); // "COUNTRYG"
    for (size_t i = 0; i < _country_good_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_good_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_good_trade.goods[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_tariff[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_tariff[i]));
    }
    mix_u64(0x434f554e54525950ULL); // "COUNTRYP"
    for (size_t i = 0; i < _country_partner_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_partner_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_partner_trade.partners[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.order_count[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_order_count[i]));
    }
    mix_u64(0x5441524946464849ULL); // "TARIFFHI"
    for (size_t i = 0; i < _tariff_history.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_tariff_history.countries[i]));
        mix_u64(static_cast<uint32_t>(_tariff_history.kinds[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.assessed[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.reserved[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.paid[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_paid[i]));
    }
    mix_u64(0x46495343414c4556ULL); // "FISCALEV"
    // Restore materializes a dense zero-filled fiscal event group while a
    // never-committed bootstrap may still hold an empty vector. Hash the same
    // fixed logical country x tax-kind shape used by PKEC serialization.
    mix_fiscal_lanes(_fiscal_last_events);
    mix_u64(0x46495343455343ULL); // "FISCAESC"
    for (size_t country = 0; country < fiscal_hash_countries; ++country) {
        mix_u64(static_cast<uint64_t>(country <
            _fiscal_escrow_by_country.size()
                ? _fiscal_escrow_by_country[country] : 0));
    }
    mix_u64(0x46495343414c504aULL); // "FISCALPJ"
    if (paged) {
        if (_fiscal_digest_rebuild) {
            _fiscal_record_digests.clear();
            for (const auto &entry : _asset_peer_journal)
                _fiscal_record_digests.emplace(entry.first, fiscal_record_digest(entry.second));
            _fiscal_digest_rebuild = false;
            _fiscal_words_dirty = true;
        }
        if (_fiscal_words_dirty) {
            _fiscal_hash_words.clear();
            _fiscal_hash_words.reserve(_fiscal_record_digests.size() * 2);
            for (const auto &entry : _fiscal_record_digests) {
                _fiscal_hash_words.push_back(entry.first);
                _fiscal_hash_words.push_back(entry.second);
            }
            _fiscal_words_dirty = false;
            _fiscal_hash_dirty_from_word = 0;
        }
        const char *verify = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_HASH_VERIFY);
        if (verify && std::strcmp(verify, "1") == 0) {
            std::map<uint64_t, uint64_t> reference;
            for (const auto &entry : _asset_peer_journal)
                reference.emplace(entry.first, fiscal_record_digest(entry.second));
            if (reference != _fiscal_record_digests) {
                std::fprintf(stderr, "economy_fiscal_digest_mismatch day=%lld\n",
                    static_cast<long long>(_current_day.get()));
                std::abort();
            }
        }
        const size_t dirty_from = _fiscal_hash_dirty_from_word;
        _fiscal_hash_dirty_from_word = _fiscal_hash_words.size();
        mix_u64(_fiscal_hash_pages.update_tail(_fiscal_hash_words, 3, 1, dirty_from));
    } else {
    std::vector<uint64_t> fiscal_peer_ids;
    fiscal_peer_ids.reserve(_asset_peer_journal.size());
    for (const auto &entry : _asset_peer_journal)
        fiscal_peer_ids.push_back(entry.first);
    std::sort(fiscal_peer_ids.begin(), fiscal_peer_ids.end());
    for (const uint64_t request_id : fiscal_peer_ids) {
        const FiscalPeerJournalRecord &record =
            _asset_peer_journal.at(request_id);
        mix_u64(record.request_id);
        mix_u64(record.transaction_id);
        mix_u64(record.country_handle);
        mix_u64(record.country_generation);
        mix_u64(record.peer_generation);
        mix_u64(record.committed_peer_generation);
        mix_u64(static_cast<uint64_t>(record.day));
        mix_u64(record.operation_sequence);
        mix_u64(record.continuation_index);
        mix_u64(static_cast<uint64_t>(record.country_slot));
        mix_u64(static_cast<uint16_t>(record.operation));
        mix_u64(static_cast<uint8_t>(record.result_code));
        mix_u64(static_cast<uint8_t>(record.state));
        mix_u64(record.accepted);
        mix_u64(static_cast<uint64_t>(record.requested_quantity));
        mix_u64(static_cast<uint64_t>(record.requested_cash));
        mix_u64(static_cast<uint64_t>(record.committed_quantity));
        mix_u64(static_cast<uint64_t>(record.committed_cash));
        for (const char value : record.reason)
            mix_u64(static_cast<uint8_t>(value));
    }
    }
    // Canal quotes are read-side preview state and deliberately do not alter
    // the authoritative simulation hash.  Started projects do: they own paid
    // construction resources and the route that an Effect transaction will
    // atomically commit.
    if (!_canal_projects.empty()) {
        mix_u64(0x43414e414c50524aULL); // "CANALPRJ"
        mix_u64(static_cast<uint64_t>(_next_canal_project_id.get()));
        for (const CanalProject &project : _canal_projects) {
            mix_u64(project.handle);
            mix_u64(project.generation);
            mix_u64(project.country_handle);
            mix_u64(static_cast<uint64_t>(project.effective_day));
            mix_u64(static_cast<uint64_t>(project.sequence));
            mix_u64(static_cast<uint64_t>(project.ready_day));
            mix_u64(project.topology_hash);
            mix_u64(static_cast<uint64_t>(project.cash_paid));
            mix_u64(static_cast<uint64_t>(project.treasury_goods_used));
            mix_u64(static_cast<uint64_t>(project.market_goods_used));
            mix_u64(static_cast<uint64_t>(project.source_kind));
            mix_u64(static_cast<uint64_t>(project.state));
            mix_u64(static_cast<uint64_t>(project.effect_transaction_id));
            mix_u64(static_cast<uint64_t>(project.route_cells.size()));
            for (const int32_t cell : project.route_cells)
                mix_u64(static_cast<uint64_t>(cell));
            for (const int32_t direction : project.route_edge_dirs)
                mix_u64(static_cast<uint64_t>(direction));
        }
    }
    mix_u64(0x4d4f444946494552ULL); // "MODIFIER"
    if (_modifier_runtime != nullptr) {
        std::vector<uint8_t> modifier_bytes;
        std::string modifier_error;
        if (modifier_api::serialize_domain(*_modifier_runtime, ModifierApi::ECONOMY,
                                                modifier_bytes,
                                                modifier_error)) {
            // Modifier snapshot_version is a cache invalidation counter and
            // intentionally advances during restore; exclude that header lane
            // while retaining every persistent instance and identity byte.
            mix_u64(modifier_bytes.size());
            for (size_t byte_index = 0; byte_index < modifier_bytes.size();
                 ++byte_index) {
                if (byte_index >= 24 && byte_index < 32) continue;
                const uint8_t byte = modifier_bytes[byte_index];
                hash ^= byte;
                hash *= 1099511628211ULL;
            }
        } else {
            mix_u64(0xffffffffffffffffULL);
            mix_string(modifier_error);
        }
    } else {
        mix_u64(0);
    }
    return static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
}
