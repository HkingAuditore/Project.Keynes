    if (_auto_building_slice_by_scale)
        _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    refresh_cadence_estimates();
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell)
        _market_signals.cell_offsets.write_scalar(cell + 1, _market_signals.cell_offsets[cell + 1] + (_market_signals.cell_offsets[cell]), market_mutation_sink());
    // PKEC stores the committed signal rows, including zero-valued rows that
    // keep the stable CSR shape. Rebuild only derived lookups here; the
    // topology rebuild intentionally prunes rows and would change restored
    // authority before the next committed building-structure update.
    rebuild_market_signal_lookup();
    rebuild_production_input_reserves();
    _market_signal_force_full = false;
    _labor_signal_force_full = false;
    _input_reserve_force_full = false;
    _market_signal_full_rebuild_reason = "save_restore";
    _labor_signal_full_rebuild_reason = "save_restore";
    _input_reserve_full_rebuild_reason = "save_restore";
    if (_cell_count.get() > 0) {
        _market_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
        _labor_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
        _input_reserve_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
    }
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell)
        _labor_signals.cell_offsets.write_scalar(cell + 1, _labor_signals.cell_offsets[cell + 1] + (_labor_signals.cell_offsets[cell]), market_mutation_sink());
    std::string country_restore_error;
    if (!capture_country_epoch(country_restore_error)) {
        out["ok"] = false;
        out["reason"] = country_restore_error.c_str();
        return out;
    }
    for (const int32_t country : _tariff_history.countries) {
        if (country < 0 || country >= _epoch_country_count) {
            out["ok"] = false;
            out["reason"] = "restore_tariff_history_country_invalid";
            return out;
        }
    }
    for (const auto &entry : _asset_peer_journal) {
        if (entry.second.country_slot >= _epoch_country_count) {
            out["ok"] = false;
            out["reason"] = "restore_fiscal_peer_country_invalid";
            return out;
        }
    }
    for (const int32_t country : _country_good_trade.countries) {
        if (country < 0 || country >= _epoch_country_count) {
            out["ok"] = false;
            out["reason"] = "restore_country_good_country_invalid";
            return out;
        }
    }
    for (size_t row = 0; row < _country_partner_trade.countries.size(); ++row) {
        const int32_t country = _country_partner_trade.countries[row];
        const int32_t partner = _country_partner_trade.partners[row];
        if (country < 0 || country >= _epoch_country_count || partner < 0 ||
            partner >= _epoch_country_count || country == partner) {
            out["ok"] = false;
            out["reason"] = "restore_country_partner_country_invalid";
            return out;
        }
    }
    if ((!trade_orders_store().ids.empty() &&
         trade_orders_store().next_id <= trade_orders_store().ids.back()) ||
        trade_orders_store().line_offsets.size() != trade_orders_store().ids.size() + 1 ||
        trade_orders_store().seller_offsets.size() != trade_orders_store().ids.size() + 1) {
        out["ok"] = false;
        out["reason"] = "restore_trade_order_index_invalid";
        return out;
    }
    if (_restore.schema_version >= 20 && !_restore.modifier_bytes.empty()) {
        if (_modifier_runtime == nullptr) {
            out["ok"] = false;
            out["reason"] = "economy_restore_modifier_runtime_unavailable";
            return out;
        }
        std::string modifier_restore_error;
        if (!modifier_api::restore_domain(*_modifier_runtime, ModifierApi::ECONOMY,
                                               _restore.modifier_bytes,
                                               modifier_restore_error,
                                               _restore.schema_version == 22)) {
            out["ok"] = false;
            out["reason"] = String(("economy_restore_modifier_failed:" +
                                    modifier_restore_error).c_str());
            return out;
        }
    } else if (_modifier_runtime != nullptr) {
        modifier_api::clear_domain(*_modifier_runtime, ModifierApi::ECONOMY);
    }
    if (_modifier_runtime != nullptr) refresh_building_modifier_factors();
    {
        std::unordered_set<int64_t> stable_family_ids;
        std::unordered_set<uint64_t> visible_family_names;
        for (int32_t i = 0; i < static_cast<int32_t>(families_store().active.size()); ++i) {
            if (families_store().active[i] == 0) continue;
            const uint64_t visible_key =
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    families_store().surname_id[i])) << 32) |
                families_store().surname_disambiguator[i];
            if (!stable_family_ids.insert(families_store().stable_id[i]).second ||
                !visible_family_names.insert(visible_key).second) {
                out["ok"] = false;
                out["reason"] = "restore_family_identity_duplicate";
                return out;
            }
        }
        std::vector<int64_t> member_people(population_store().active.size(), 0);
        std::vector<int64_t> member_cash(population_store().active.size(), 0);
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            int32_t slot = -1;
            if (!population_store().valid_handle(edge.cohort_handle, slot)) {
                out["ok"] = false;
                out["reason"] = "restore_family_cohort_handle_invalid";
                return out;
            }
            if (edge.people > population_store().population[slot] -
                    member_people[slot] ||
                edge.cash_claim > population_store().funds[slot] -
                    member_cash[slot]) {
                out["ok"] = false;
                out["reason"] = "restore_family_claim_exceeds_cohort";
                return out;
            }
            member_people[slot] += edge.people;
            member_cash[slot] += edge.cash_claim;
        }
        // Saves written before ownership clamping could carry shares granted
        // ahead of a liquidation or owner-slot change. Repair them instead of
        // rejecting an otherwise loadable world; handles stay authoritative.
        sanitize_family_ownership_edges();
        std::vector<int64_t> owned(building_count(), 0);
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            const int32_t group = building_index_for_handle(edge.building_handle);
            if (group < 0) {
                out["ok"] = false;
                out["reason"] = "restore_family_building_handle_invalid";
                return out;
            }
            if (edge.owned_count > buildings_store().group_units[group] - owned[group]) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
            owned[group] += edge.owned_count;
            int64_t capacity_sat = 0;
            const int64_t owner_capacity = saturating_mul(edge.owned_count,
                _building_types[buildings_store().type_id[group]].owner_slots_per_building,
                capacity_sat);
            if (capacity_sat != 0 ||
                edge.filled_owner > owner_capacity) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
        }
        for (const auto pending : pending_construction()) {
            int32_t family = -1;
            if (pending.sponsor_family_handle != 0 &&
                !families_store().valid_handle(pending.sponsor_family_handle, family)) {
                out["ok"] = false;
                out["reason"] = "restore_construction_family_handle_invalid";
                return out;
            }
        }
        std::unordered_map<uint64_t, std::unordered_set<int32_t>> traits_by_family;
        std::unordered_map<uint64_t, int32_t> core_traits_by_family;
        uint64_t previous_trait_family = 0;
        int32_t previous_trait = -1;
        bool first_trait = true;
        for (const FamilyTraitRoll &roll : family_trait_rolls()) {
            if (!first_trait &&
                (roll.family_handle < previous_trait_family ||
                 (roll.family_handle == previous_trait_family &&
                  roll.trait_id <= previous_trait))) {
                out["ok"] = false;
                out["reason"] = "restore_family_trait_order_or_duplicate_invalid";
                return out;
            }
            first_trait = false;
            previous_trait_family = roll.family_handle;
            previous_trait = roll.trait_id;
            traits_by_family[roll.family_handle].insert(roll.trait_id);
            if (roll.core != 0) {
                if (_family_trait_core_eligible[roll.trait_id] == 0) {
                    out["ok"] = false;
                    out["reason"] = "restore_family_core_trait_ineligible";
                    return out;
                }
                ++core_traits_by_family[roll.family_handle];
            }
        }
        for (int32_t family = 0; family < static_cast<int32_t>(
                 families_store().active.size()); ++family) {
            if (families_store().active[family] == 0) continue;
            const uint64_t family_handle = families_store().handle_for_index(family);
            const int32_t core_count = core_traits_by_family[family_handle];
            // 初始抽取下限不适用于后代：分家可移除核心特性，新增项是附加特性。
            if (core_count > _family_core_trait_max) {
                out["ok"] = false;
                out["reason"] = "restore_family_core_trait_count_invalid";
                out["family_handle"] = static_cast<int64_t>(family_handle);
                out["core_trait_count"] = core_count;
                out["core_trait_max"] = _family_core_trait_max;
                return out;
            }
            const auto found_traits = traits_by_family.find(family_handle);
            if (found_traits == traits_by_family.end()) continue;
            const std::unordered_set<int32_t> &family_traits =
                found_traits->second;
            for (int32_t trait_id : family_traits) {
                for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                     p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_prerequisites[p]) ==
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] =
                            "restore_family_trait_prerequisite_missing";
                        return out;
                    }
                }
                for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                     p < _family_trait_exclusion_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_exclusions[p]) !=
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] = "restore_family_trait_conflict";
                        return out;
                    }
                }
            }
        }
        std::unordered_set<uint64_t> family_cells;
        std::unordered_set<int64_t> branch_stable_ids;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                 family_influences().active.size()); ++branch) {
            if (family_influences().active[branch] == 0) continue;
            int32_t family = -1;
            if (!families_store().valid_handle(
                    family_influences().family_handle[branch], family)) {
                out["ok"] = false;
                out["reason"] = "restore_family_influence_family_invalid";
                return out;
            }
            const uint64_t family_cell =
                (static_cast<uint64_t>(static_cast<uint32_t>(family)) << 32) |
                static_cast<uint32_t>(family_influences().cell[branch]);
            uint64_t expected_hash = 1469598103934665603ULL;
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint64_t>(
                families_store().stable_id[family]));
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint32_t>(
                family_influences().cell[branch]));
            const int64_t expected_stable_id = static_cast<int64_t>(
                (expected_hash & 0x7fffffffffffffffULL) | 1ULL);
            if (!family_cells.insert(family_cell).second ||
                !branch_stable_ids.insert(
                    family_influences().stable_id[branch]).second ||
                family_influences().stable_id[branch] != expected_stable_id) {
                out["ok"] = false;
                out["reason"] =
                    "restore_family_influence_identity_duplicate_or_invalid";
                return out;
            }
        }
    }
    if (_restore.schema_version >= 27) {
        std::unordered_set<int64_t> stable_person_ids;
        std::unordered_set<std::string> visible_person_names;
        std::unordered_set<uint64_t> transit_person_handles;
        for (const uint64_t handle : family_expedition_person_handles()) {
            if (!transit_person_handles.insert(handle).second) {
                out["ok"] = false;
                out["reason"] = "restore_expedition_person_duplicate";
                return out;
            }
        }
        std::vector<int64_t> claimed_by_membership(
            family_memberships().size(), 0);
        std::vector<int64_t> people_by_membership(
            family_memberships().size(), 0);
        for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
            if (persons_store().active[i] == 0) continue;
            int32_t family = -1, cohort = -1;
            const uint64_t person_handle = persons_store().handle_for_index(i);
            const bool in_transit = persons_store().cohort_handle[i] == 0;
            const int32_t membership = family_membership_index(
                persons_store().family_handle[i], persons_store().cohort_handle[i]);
            if (!families_store().valid_handle(persons_store().family_handle[i], family) ||
                (!in_transit &&
                 !population_store().valid_handle(persons_store().cohort_handle[i], cohort)) ||
                (!in_transit && membership < 0) ||
                (in_transit &&
                 transit_person_handles.find(person_handle) ==
                    transit_person_handles.end()) ||
                (in_transit && (persons_store().job_kind[i] != 0 ||
                    persons_store().building_handle[i] != 0)) ||
                !stable_person_ids.insert(persons_store().stable_id[i]).second) {
                out["ok"] = false;
                out["reason"] = "restore_person_identity_or_membership_invalid";
                return out;
            }
            const std::string family_name_key =
                std::to_string(persons_store().family_handle[i]) + ":" +
                std::to_string(persons_store().given_name_id[i]) + ":" +
                std::to_string(persons_store().name_disambiguator[i]);
            if (!visible_person_names.insert(family_name_key).second ||
                (!in_transit &&
                persons_store().cash_claim[i] >
                    family_memberships()[membership].cash_claim -
                    claimed_by_membership[membership]) ||
                (!in_transit &&
                people_by_membership[membership] >=
                    family_memberships()[membership].people)) {
                out["ok"] = false;
                out["reason"] = "restore_person_name_or_claim_invalid";
                return out;
            }
            if (!in_transit) {
                claimed_by_membership[membership] += persons_store().cash_claim[i];
                ++people_by_membership[membership];
            }
            if (persons_store().job_kind[i] != 0) {
                const int32_t group = building_index_for_handle(
                    persons_store().building_handle[i]);
                if (group < 0 || buildings_store().cell[group] !=
                        population_store().page_cell[cohort / COHORT_PAGE_SIZE]) {
                    out["ok"] = false;
                    out["reason"] = "restore_person_building_invalid";
                    return out;
                }
                if (persons_store().job_kind[i] == 2) {
                    const BuildingType &type =
                        _building_types[buildings_store().type_id[group]];
                    if (persons_store().employee_role_index[i] >= type.employee_count) {
                        out["ok"] = false;
                        out["reason"] = "restore_person_role_invalid";
                        return out;
                    }
                }
            }
        }
        // Canonical order is by person slot, matching how _person_need_offsets
        // is indexed. Handle order would be generation-major and would not
        // agree with the CSR once slots have been recycled.
        int32_t previous_person = -1;
        int32_t previous_need = -1;
        for (const PersonNeedState &state : person_needs()) {
            int32_t person = -1;
            if (!persons_store().valid_handle(state.person_handle, person)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_handle_invalid";
                return out;
            }
            if (person < previous_person ||
                (person == previous_person &&
                 state.stable_need_id <= previous_need)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_order_invalid";
                return out;
            }
            previous_person = person;
            previous_need = state.stable_need_id;
        }
    }
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
            continue;
        if (_effect_runtime == nullptr ||
            _effect_runtime->transaction_status_pod(
                family_expeditions_store().effect_transaction_id[expedition]) == 0) {
            out["ok"] = false;
            out["reason"] = "restore_expedition_effect_transaction_missing";
            return out;
        }
    }
    rebuild_family_expedition_indices();
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_PREPARING)
            continue;
        refresh_preparing_family_expedition_missing(expedition);
    }
    rebuild_family_indices();
    _family_effect_bindings.clear();
    _family_effect_binding_by_instance.clear();
    _family_effect_instances_by_branch.clear();
    _family_effect_instances_by_cell.clear();
    _family_modifier_bindings.clear();
    for (int32_t branch = 0; branch < static_cast<int32_t>(
             family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0) continue;
        reconcile_family_branch_effects(
            family_influences().handle_for_index(branch), false);
    }
    rebuild_family_owned_output_csr();
    rebuild_family_policy_scalars();
    rebuild_family_behavior_cache();
    rebuild_person_indices();
    rebuild_family_demography_weights();
    _bootstrapped = true;
    _track_b_investment_cells_pending.swap(_restore.track_b_investment_cells_pending);
    _track_b_derived_cell_cache.swap(_restore.track_b_derived_cell_cache);
    _track_b_derived_cell_cache_day = _restore.track_b_derived_cell_cache_day;
    _track_b_derived_cell_cache_cells =
        static_cast<int32_t>(_track_b_derived_cell_cache.size());
    _family_colonization_population_reward_pending.swap(
        _restore.family_colonization_population_reward_pending);
    set_military_ration_satisfaction(_restore.military_ration_cells, _restore.military_ration_q16);
    if (_restore.committed_generation_seen) {
        _committed_generation = _restore.restored_committed_generation;
    } else if (++_committed_generation == 0) {
        _committed_generation = 1;
    }
    _fatal = false;
    _fatal_reason.clear();
    _epoch_active = false;
    _stage = Stage::AGGREGATE_PUBLISH;
    _trade_topology.clear();
    _trade_plan.clear_transient();
    rebuild_country_trade_indices();
    rebuild_trade_arrival_buckets();
    rebuild_committed_summaries();
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const bool should_have_name =
            _settlements.tier[cell] >= _settlement_named_tier ||
            _settlements.name_forced[cell] != 0;
        if (should_have_name != (_settlements.name_active[cell] != 0)) {
            out["ok"] = false;
            out["reason"] = "restore_settlement_name_activity_mismatch";
            return out;
        }
    }
    _settlements.revision = 1;
    _closing_totals = audit_totals();
    std::atomic_store_explicit(&_committed_audit_view,
        std::shared_ptr<const CommittedAuditView>{}, std::memory_order_release);
    _opening_totals = _closing_totals;
    rebuild_incremental_audit_shadow();
    _closing_audit_force_full = true;
    _settlement_watermark = _last_committed_day.get();
    _settlement_newest_day = _last_committed_day.get();
    bool have_populated = false;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        if (_committed_cells[cell].population <= 0) continue;
        if (!have_populated) {
            _settlement_watermark = _cell_last_settlement_day[cell];
            _settlement_newest_day = _cell_last_settlement_day[cell];
            have_populated = true;
        } else {
            _settlement_watermark = std::min(
                _settlement_watermark, _cell_last_settlement_day[cell]);
            _settlement_newest_day = std::max(
                _settlement_newest_day, _cell_last_settlement_day[cell]);
        }
    }
    _settlement_max_age_days = have_populated
        ? std::max<int64_t>(0, _last_committed_day.get() - _settlement_watermark) : 0;
    const int32_t restored_pages = _restore.restored_pages;
    const int32_t restored_commands = _restore.restored_commands;
    const int32_t restored_buildings = _restore.restored_buildings;
    const int32_t restored_schema = _restore.schema_version;
    const int32_t dropped_transit_persons = _restore.dropped_transit_persons;
    _resource_stock_restored_pending_capture = _restore.resource_stock_seen;
    _restore = {};
    trace_begin_epoch();
    trace_append(EVENT_RESTORE_BOUNDARY,
                 static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id.get(), SCHEMA_VERSION, -1,
                 restored_pages, restored_commands, restored_buildings,
                 _last_committed_day.get(), nullptr);
    trace_commit_epoch(0, 0, 0);
    out["ok"] = true;
    out["restored_pages"] = restored_pages;
    out["restored_commands"] = restored_commands;
    out["restored_buildings"] = restored_buildings;
    out["restored_trade_orders"] = trade_orders_store().size();
    out["restored_trade_flows"] = static_cast<int64_t>(_trade_flows.cells.size());
    out["cohort_count"] = population_store().active_count.get();
    out["state_hash_catalog"] = _catalog_hash.get();
    out["restored_families"] = families_store().active_count.get();
    out["restored_persons"] = persons_store().active_count.get();
    out["restored_person_needs"] = static_cast<int64_t>(person_needs().size());
    out["dropped_transit_persons"] = dropped_transit_persons;
    out["migration"] = restored_schema == 27
        ? "v27_empty_birth_residual_bootstrap"
        : (restored_schema == 25
        ? "v25_empty_family_bootstrap"
        : (restored_schema == 26
        ? "v26_empty_notable_person_bootstrap"
        : (restored_schema == 55 || restored_schema == 56
        ? "v56_x13a_climate_columns"
        : (restored_schema == 22 || restored_schema == 23
        ? "legacy_settlement_bootstrap"
        : (restored_schema == 14
            ? "v14_rolling_phase_bootstrap" : "none")))));
    return out;
