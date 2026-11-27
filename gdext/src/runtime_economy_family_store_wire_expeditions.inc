    expedition_slot.reserve(expedition_count);
    for (uint32_t i = 0; i < expedition_count; ++i) {
        int32_t v_i32 = 0;
        uint8_t v_u8 = 0;
        uint32_t v_u32 = 0;
        int64_t v_i64 = 0;
        uint64_t v_u64 = 0;
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_slot.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        expedition_active.push_back(v_u8);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        expedition_generation.push_back(v_u32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_stable_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_country_handle.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_family_handle.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_source_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_target_cell.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_departure_day.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_due_day.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_route_cost.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        expedition_speed.push_back(v_i32);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        expedition_state.push_back(v_u8);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_population.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        expedition_effect_transaction_id.push_back(v_i64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_idempotency_key.push_back(v_u64);
        uint32_t route_count = 0;
        uint32_t payload_count = 0;
        if (!read_pod(p, end, route_count) || !read_pod(p, end, payload_count)) {
            clear();
            return false;
        }
        expedition_route_count.push_back(route_count);
        expedition_route_begin.push_back(static_cast<uint32_t>(route_cell.size()));
        expedition_payload_count.push_back(payload_count);
        expedition_payload_begin.push_back(
            static_cast<uint32_t>(payload_source_cohort_handle.size()));
        for (uint32_t r = 0; r < route_count; ++r) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            route_cell.push_back(v_i32);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            route_cost.push_back(v_i32);
        }
        for (uint32_t lane = 0; lane < payload_count; ++lane) {
            if (!read_pod(p, end, v_u64)) {
                clear();
                return false;
            }
            payload_source_cohort_handle.push_back(v_u64);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            payload_signature.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_people.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_funds.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_income.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_expense.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_in_kind_income.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_income_ema.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_tax_paid.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_epoch_subsidy_received.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_income_baseline_ema.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_demography_residual.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_cash_claim.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_owner_employed.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            payload_employee_employed.push_back(v_i64);
            uint16_t v_u16 = 0;
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_needs_satisfaction.push_back(v_u16);
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_worst_need_id.push_back(v_u16);
            if (!read_pod(p, end, v_u16)) {
                clear();
                return false;
            }
            payload_composite_satisfaction.push_back(v_u16);
            if (!read_pod(p, end, v_u8)) {
                clear();
                return false;
            }
            payload_worst_dimension_id.push_back(v_u8);
            const size_t dim_base =
                payload_satisfaction_dims.size();
            payload_satisfaction_dims.resize(dim_base +
                                             static_cast<size_t>(kSatDimCount));
            for (int32_t dim = 0; dim < kSatDimCount; ++dim) {
                if (!read_pod(p, end, v_u16)) {
                    clear();
                    return false;
                }
                payload_satisfaction_dims[dim_base + dim] = v_u16;
            }
            if (!read_pod(p, end, v_u32)) {
                clear();
                return false;
            }
            payload_person_count.push_back(v_u32);
            payload_person_begin.push_back(
                static_cast<uint32_t>(payload_person_handle.size()));
            for (uint32_t person = 0; person < v_u32; ++person) {
                if (!read_pod(p, end, v_u64)) {
                    clear();
                    return false;
                }
                payload_person_handle.push_back(v_u64);
            }
        }
        uint32_t cargo_count = 0;
        if (!read_pod(p, end, cargo_count)) {
            clear();
            return false;
        }
        expedition_cargo_count.push_back(cargo_count);
        expedition_cargo_begin.push_back(static_cast<uint32_t>(cargo_good_id.size()));
        for (uint32_t c = 0; c < cargo_count; ++c) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            cargo_good_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            cargo_quantity.push_back(v_i64);
            if (!read_pod(p, end, v_u8)) {
                clear();
                return false;
            }
            cargo_flags.push_back(v_u8);
        }
        uint32_t kit_count_wire = 0;
        if (!read_pod(p, end, kit_count_wire)) {
            clear();
            return false;
        }
        expedition_kit_count.push_back(kit_count_wire);
        expedition_kit_begin.push_back(static_cast<uint32_t>(kit_type_id.size()));
        for (uint32_t k = 0; k < kit_count_wire; ++k) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            kit_type_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            kit_count.push_back(v_i64);
        }
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        expedition_missing_identity.push_back(v_u64);
        if (!read_pod(p, end, v_u32)) {
            clear();
            return false;
        }
        expedition_missing_count.push_back(v_u32);
        expedition_missing_begin.push_back(
            static_cast<uint32_t>(missing_good_id.size()));
        for (uint32_t m = 0; m < v_u32; ++m) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            missing_good_id.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            missing_quantity.push_back(v_i64);
        }
    }
