    if (_save.section == SAVE_SECTION_FAMILY_RECORDS) {
        constexpr int32_t record_bytes = 61;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(families_store().active.size(),
            _save.family_cursor + max_records);
        const int32_t begin = _save.family_cursor;
        for (; _save.family_cursor < end; ++_save.family_cursor) {
            const int32_t i = _save.family_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, families_store().active[i]);
            append_le<uint32_t>(payload, families_store().generation[i]);
            append_le<int64_t>(payload, families_store().stable_id[i]);
            append_le<int32_t>(payload, families_store().surname_id[i]);
            append_le<uint32_t>(payload, families_store().surname_disambiguator[i]);
            append_le<int64_t>(payload, families_store().founded_day[i]);
            append_le<int32_t>(payload, families_store().home_cell[i]);
            append_le<int32_t>(payload, families_store().origin_cell[i]);
            append_le<int32_t>(payload, families_store().origin_ethnicity[i]);
            append_le<int32_t>(payload, families_store().culture_group_id[i]);
            append_le<uint32_t>(payload, families_store().split_sequence[i]);
            append_le<uint16_t>(payload, families_store().decline_reviews[i]);
            append_le<uint16_t>(payload, families_store().flags[i]);
            append_le<int32_t>(payload,
                families_store().active[i] != 0 &&
                        static_cast<size_t>(i) <
                            _family_colonization_population_reward_pending.size()
                    ? std::max(0, _family_colonization_population_reward_pending[
                        static_cast<size_t>(i)])
                    : 0);
        }
        if (_save.family_cursor >= static_cast<int32_t>(families_store().active.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_RECORDS,
            static_cast<uint32_t>(_save.family_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_MEMBERSHIP) {
        constexpr int32_t record_bytes = 64;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(family_memberships().size(),
            _save.family_membership_cursor + max_records);
        const int32_t begin = _save.family_membership_cursor;
        for (; _save.family_membership_cursor < end;
             ++_save.family_membership_cursor) {
            const FamilyMembershipEdge &raw =
                family_memberships()[_save.family_membership_cursor];
            FamilyMembershipEdge edge = raw;
            sanitize_family_membership_edge(edge);
            append_le<uint64_t>(payload, edge.family_handle);
            append_le<uint64_t>(payload, edge.cohort_handle);
            append_le<int64_t>(payload, edge.people);
            append_le<int64_t>(payload, edge.cash_claim);
            append_le<int64_t>(payload, edge.population_basis);
            append_le<int64_t>(payload, edge.funds_basis);
            append_le<int64_t>(payload, edge.owner_employed);
            append_le<int64_t>(payload, edge.employee_employed);
        }
        if (_save.family_membership_cursor >= static_cast<int32_t>(
                family_memberships().size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_MEMBERSHIP,
            static_cast<uint32_t>(_save.family_membership_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_OWNERSHIP) {
        constexpr int32_t record_bytes = 32;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(family_ownerships().size(),
            _save.family_ownership_cursor + max_records);
        const int32_t begin = _save.family_ownership_cursor;
        for (; _save.family_ownership_cursor < end;
             ++_save.family_ownership_cursor) {
            const FamilyBuildingOwnership &edge =
                family_ownerships().read_at(_save.family_ownership_cursor, __FILE__, __LINE__);
            append_le<uint64_t>(payload, edge.family_handle);
            append_le<uint64_t>(payload, edge.building_handle);
            append_le<int64_t>(payload, edge.owned_count);
            append_le<int64_t>(payload, edge.filled_owner);
        }
        if (_save.family_ownership_cursor >= static_cast<int32_t>(
                family_ownerships().size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_OWNERSHIP,
            static_cast<uint32_t>(_save.family_ownership_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_PERSON_RECORDS) {
        constexpr int32_t record_bytes = 124;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(persons_store().active.size(),
            _save.person_cursor + max_records);
        const int32_t begin = _save.person_cursor;
        for (; _save.person_cursor < end; ++_save.person_cursor) {
            const int32_t i = _save.person_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, persons_store().active[i]);
            append_le<uint32_t>(payload, persons_store().generation[i]);
            append_le<int64_t>(payload, persons_store().stable_id[i]);
            append_le<uint64_t>(payload, persons_store().family_handle[i]);
            append_le<uint64_t>(payload, persons_store().cohort_handle[i]);
            append_le<int32_t>(payload, persons_store().given_name_id[i]);
            append_le<uint32_t>(payload, persons_store().name_disambiguator[i]);
            append_le<int64_t>(payload, persons_store().notable_since_day[i]);
            append_le<uint16_t>(payload, persons_store().flags[i]);
            append_le<int64_t>(payload, persons_store().cash_claim[i]);
            append_le<int64_t>(payload, persons_store().family_equity_share_q32[i]);
            append_le<int64_t>(payload, persons_store().epoch_job_income[i]);
            append_le<int64_t>(payload, persons_store().epoch_business_result[i]);
            append_le<int64_t>(payload, persons_store().epoch_consumption_expense[i]);
            append_le<int64_t>(payload, persons_store().epoch_tax[i]);
            append_le<int64_t>(payload, persons_store().income_ema[i]);
            append_le<uint16_t>(payload, persons_store().needs_satisfaction[i]);
            append_le<uint16_t>(payload, persons_store().worst_need_id[i]);
            append_le<uint64_t>(payload, persons_store().building_handle[i]);
            append_le<uint8_t>(payload, persons_store().job_kind[i]);
            append_le<int32_t>(payload, persons_store().employee_role_index[i]);
            append_le<int64_t>(payload, persons_store().job_since_day[i]);
        }
        if (_save.person_cursor >= static_cast<int32_t>(persons_store().active.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_PERSON_RECORDS,
            static_cast<uint32_t>(_save.person_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_PERSON_NEEDS) {
        constexpr int32_t record_bytes = 30;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(person_needs().size(),
            _save.person_need_cursor + max_records);
        const int32_t begin = _save.person_need_cursor;
        for (; _save.person_need_cursor < end; ++_save.person_need_cursor) {
            const PersonNeedState &state =
                person_needs()[_save.person_need_cursor];
            append_le<uint64_t>(payload, state.person_handle);
            append_le<int32_t>(payload, state.stable_need_id);
            append_le<int64_t>(payload, state.desired_period_units);
            append_le<uint16_t>(payload, state.satisfaction_q16);
            append_le<int64_t>(payload, state.attributed_spend);
        }
        if (_save.person_need_cursor >= static_cast<int32_t>(person_needs().size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_PERSON_NEEDS,
            static_cast<uint32_t>(_save.person_need_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_TRAITS) {
        constexpr int32_t record_bytes = 17;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(family_trait_rolls().size(),
            _save.family_trait_cursor + max_records);
        const int32_t begin = _save.family_trait_cursor;
        for (; _save.family_trait_cursor < end; ++_save.family_trait_cursor) {
            const FamilyTraitRoll &roll =
                family_trait_rolls()[_save.family_trait_cursor];
            append_le<uint64_t>(payload, roll.family_handle);
            append_le<int32_t>(payload, roll.trait_id);
            append_le<int32_t>(payload, roll.strength_q16);
            append_le<uint8_t>(payload, roll.core);
        }
        if (_save.family_trait_cursor >= static_cast<int32_t>(
                family_trait_rolls().size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_TRAITS,
            static_cast<uint32_t>(_save.family_trait_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_INFLUENCES) {
        constexpr int32_t record_bytes = 84;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(family_influences().active.size(),
            _save.family_influence_cursor + max_records);
        const int32_t begin = _save.family_influence_cursor;
        for (; _save.family_influence_cursor < end;
             ++_save.family_influence_cursor) {
            const int32_t i = _save.family_influence_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, family_influences().active[i]);
            append_le<uint32_t>(payload, family_influences().generation[i]);
            append_le<uint64_t>(payload, family_influences().family_handle[i]);
            append_le<int32_t>(payload, family_influences().cell[i]);
            append_le<int64_t>(payload, family_influences().stable_id[i]);
            append_le<int64_t>(payload, family_influences().population[i]);
            append_le<int64_t>(payload, family_influences().cash[i]);
            append_le<int64_t>(payload, family_influences().building_asset[i]);
            append_le<int32_t>(payload,
                family_influences().population_share_q16[i]);
            append_le<int32_t>(payload,
                family_influences().cash_share_q16[i]);
            append_le<int32_t>(payload,
                family_influences().building_share_q16[i]);
            append_le<int32_t>(payload, family_influences().score_q16[i]);
            append_le<int32_t>(payload, family_influences().satisfaction_q16[i]);
            append_le<uint8_t>(payload, family_influences().prestige_level[i]);
            append_le<uint8_t>(payload,
                family_influences().pending_target_level[i]);
            append_le<uint8_t>(payload, family_influences().review_streak[i]);
            append_le<int64_t>(payload, family_influences().last_review_day[i]);
        }
        if (_save.family_influence_cursor >= static_cast<int32_t>(
                family_influences().active.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_INFLUENCES,
            static_cast<uint32_t>(_save.family_influence_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_TRAIT_COMMANDS) {
        constexpr int32_t record_bytes = 48;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_trait_commands.size(),
            _save.family_trait_command_cursor + max_records);
        const int32_t begin = _save.family_trait_command_cursor;
        for (; _save.family_trait_command_cursor < end;
             ++_save.family_trait_command_cursor) {
            const FamilyTraitCommand &command =
                _family_trait_commands[_save.family_trait_command_cursor];
            append_le<int32_t>(payload, command.operation);
            append_le<uint64_t>(payload, command.family_handle);
            append_le<int32_t>(payload, command.trait_id);
            append_le<int32_t>(payload, command.strength_q16);
            append_le<int64_t>(payload, command.effective_day);
            append_le<int32_t>(payload, command.priority);
            append_le<int64_t>(payload, command.sequence);
            append_le<uint64_t>(payload, command.submit_order);
        }
        if (_save.family_trait_command_cursor >= static_cast<int32_t>(
                _family_trait_commands.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_TRAIT_COMMANDS,
            static_cast<uint32_t>(_save.family_trait_command_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_EXPEDITIONS) {
        const int32_t begin = _save.family_expedition_cursor;
        while (_save.family_expedition_cursor < static_cast<int32_t>(
                family_expeditions_store().active.size())) {
            const int32_t i = _save.family_expedition_cursor;
            std::vector<uint8_t> record;
            append_le<int32_t>(record, i);
            append_le<uint8_t>(record, family_expeditions_store().active[i]);
            append_le<uint32_t>(record, family_expeditions_store().generation[i]);
            append_le<int64_t>(record, family_expeditions_store().stable_id[i]);
            append_le<uint64_t>(record, family_expeditions_store().country_handle[i]);
            append_le<uint64_t>(record, family_expeditions_store().family_handle[i]);
            append_le<int32_t>(record, family_expeditions_store().source_cell[i]);
            append_le<int32_t>(record, family_expeditions_store().target_cell[i]);
            append_le<int64_t>(record, family_expeditions_store().departure_day[i]);
            append_le<int64_t>(record, family_expeditions_store().due_day[i]);
            append_le<int32_t>(record, family_expeditions_store().route_cost[i]);
            append_le<int32_t>(record, family_expeditions_store().speed[i]);
            append_le<uint8_t>(record, family_expeditions_store().state[i]);
            append_le<int64_t>(record, family_expeditions_store().population[i]);
            append_le<int64_t>(record,
                family_expeditions_store().anonymous[i]);
            append_le<int64_t>(record,
                family_expeditions_store().kit_bridge_required_units[i]);
            append_le<int64_t>(record,
                family_expeditions_store().kit_material_required_units[i]);
            append_le<int64_t>(record,
                family_expeditions_store().effect_transaction_id[i]);
            append_le<uint64_t>(record, family_expeditions_store().idempotency_key[i]);
            const uint32_t route_count = family_expeditions_store().active[i] != 0
                ? family_expeditions_store().route_count[i] : 0;
            const uint32_t payload_count = family_expeditions_store().active[i] != 0
                ? family_expeditions_store().payload_count[i] : 0;
            append_le<uint32_t>(record, route_count);
            append_le<uint32_t>(record, payload_count);
            const uint32_t route_begin = family_expeditions_store().route_begin[i];
            for (uint32_t r = 0; r < route_count; ++r) {
                append_le<int32_t>(record,
                    family_expedition_route_cells()[route_begin + r]);
                append_le<int32_t>(record,
                    family_expedition_route_costs()[route_begin + r]);
            }
            const uint32_t payload_begin =
                family_expeditions_store().payload_begin[i];
            for (uint32_t p = 0; p < payload_count; ++p) {
                const FamilyExpeditionPayload &lane =
                    family_expedition_payloads()[payload_begin + p];
                append_le<uint64_t>(record, lane.source_cohort_handle);
                append_le<int32_t>(record, lane.signature);
                append_le<int64_t>(record, lane.people);
                append_le<int64_t>(record, lane.funds);
                append_le<int64_t>(record, lane.epoch_income);
                append_le<int64_t>(record, lane.epoch_expense);
                append_le<int64_t>(record, lane.epoch_in_kind_income);
                append_le<int64_t>(record, lane.income_ema);
                append_le<int64_t>(record, lane.epoch_tax_paid);
                append_le<int64_t>(record, lane.epoch_subsidy_received);
                append_le<int64_t>(record, lane.income_baseline_ema);
                append_le<int64_t>(record, lane.demography_residual);
                append_le<int64_t>(record, lane.cash_claim);
                append_le<int64_t>(record, lane.owner_employed);
                append_le<int64_t>(record, lane.employee_employed);
                append_le<uint16_t>(record, lane.needs_satisfaction);
                append_le<uint16_t>(record, lane.worst_need_id);
                append_le<uint16_t>(record, lane.composite_satisfaction);
                append_le<uint8_t>(record, lane.worst_dimension_id);
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    append_le<uint16_t>(record, lane.satisfaction_dims[dim]);
                append_le<uint8_t>(record, lane.anonymous);
                // The flat handle lane can shrink while the party is on the
                // map (a retirement drops its reference). Never trust the
                // cached payload count for the wire record: clamp it to the
                // lane we actually hold, or the save reads past the vector.
                const uint32_t handle_begin = lane.person_begin;
                const uint32_t handle_total = static_cast<uint32_t>(
                    family_expedition_person_handles().size());
                const uint32_t person_count = handle_begin >= handle_total
                    ? 0U
                    : std::min<uint32_t>(lane.person_count,
                        handle_total - handle_begin);
                append_le<uint32_t>(record, person_count);
                for (uint32_t person = 0; person < person_count; ++person)
                    append_le<uint64_t>(record,
                        family_expedition_person_handles()[
                            handle_begin + person]);
            }
            const uint32_t cargo_count = family_expeditions_store().active[i] != 0
                ? family_expeditions_store().cargo_count[i] : 0;
            const uint32_t kit_count = family_expeditions_store().active[i] != 0
                ? family_expeditions_store().kit_building_count[i] : 0;
            append_le<uint32_t>(record, cargo_count);
            const uint32_t cargo_begin = family_expeditions_store().cargo_begin[i];
            for (uint32_t c = 0; c < cargo_count; ++c) {
                const FamilyExpeditionCargoLine &line =
                    family_expedition_cargo()[cargo_begin + c];
                append_le<int32_t>(record, line.good_id);
                append_le<int64_t>(record, line.quantity);
                append_le<uint8_t>(record, line.flags);
            }
            append_le<uint32_t>(record, kit_count);
            const uint32_t kit_begin =
                family_expeditions_store().kit_building_begin[i];
            for (uint32_t k = 0; k < kit_count; ++k) {
                const FamilyExpeditionKitBuilding &row =
                    family_expedition_kit_buildings()[kit_begin + k];
                append_le<int32_t>(record, row.type_id);
                append_le<int64_t>(record, row.count);
            }
            uint64_t missing_identity = 0;
            uint32_t missing_count = 0;
            uint32_t missing_begin = 0;
            if (family_expeditions_store().active[i] != 0) {
                missing_identity =
                    family_expeditions_store().kit_missing_stock_identity[i];
                missing_count = family_expeditions_store().missing_good_count[i];
                missing_begin = family_expeditions_store().missing_good_begin[i];
            }
            append_le<uint64_t>(record, missing_identity);
            append_le<uint32_t>(record, missing_count);
            for (uint32_t m = 0; m < missing_count; ++m) {
                append_le<int32_t>(record,
                    family_expedition_missing_good_ids()[missing_begin + m]);
                append_le<int64_t>(record,
                    family_expedition_missing_good_quantities()[missing_begin + m]);
            }
            if (!payload.empty() && payload.size() + record.size() + 16U >
                    static_cast<size_t>(budget)) break;
            payload.insert(payload.end(), record.begin(), record.end());
            ++_save.family_expedition_cursor;
        }
        if (_save.family_expedition_cursor >= static_cast<int32_t>(
                family_expeditions_store().active.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_EXPEDITIONS,
            static_cast<uint32_t>(_save.family_expedition_cursor - begin), payload);
    }
