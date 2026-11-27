Dictionary NativeEconomyRuntime::family_notable_people(
        int64_t family_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t family = -1;
    if (!families_store().valid_handle(handle, family)) {
        out["ok"] = false; out["reason"] = "family_handle_invalid"; return out;
    }
    std::vector<int32_t> rows;
    if (_person_family_offsets.size() == families_store().active.size() + 1)
        for (int32_t p = _person_family_offsets[family];
             p < _person_family_offsets[family + 1]; ++p)
            rows.push_back(_person_family_indices[p]);
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt64Array handles, stable_ids, cash_claims, job_incomes,
        consumption_expenses, building_handles;
    PackedInt32Array given_names, disambiguators, cells, professions, role_indices;
    PackedByteArray job_kinds;
    for (int32_t pos = offset; pos < end; ++pos) {
        const int32_t person = rows[pos];
        int32_t slot = -1;
        const bool cohort_ok = population_store().valid_handle(
            persons_store().cohort_handle[person], slot);
        const int32_t signature = cohort_ok
            ? static_cast<int32_t>(population_store().signature_id[slot]) : -1;
        handles.push_back(static_cast<int64_t>(persons_store().handle_for_index(person)));
        stable_ids.push_back(persons_store().stable_id[person]);
        given_names.push_back(persons_store().given_name_id[person]);
        disambiguators.push_back(static_cast<int32_t>(
            persons_store().name_disambiguator[person]));
        cells.push_back(cohort_ok ? population_store().page_cell[slot / COHORT_PAGE_SIZE] : -1);
        professions.push_back(signature >= 0 && signature < static_cast<int32_t>(
            _signatures.size()) ? _signatures[signature].profession_id : -1);
        cash_claims.push_back(persons_store().cash_claim[person]);
        job_incomes.push_back(persons_store().epoch_job_income[person]);
        consumption_expenses.push_back(
            persons_store().epoch_consumption_expense[person]);
        building_handles.push_back(static_cast<int64_t>(
            persons_store().building_handle[person]));
        job_kinds.push_back(persons_store().job_kind[person]);
        role_indices.push_back(persons_store().employee_role_index[person]);
    }
    out["ok"] = true; out["family_handle"] = family_handle_value;
    out["total"] = static_cast<int32_t>(rows.size()); out["offset"] = offset;
    out["limit"] = limit; out["has_more"] = end < static_cast<int32_t>(rows.size());
    out["person_handles"] = handles; out["stable_ids"] = stable_ids;
    out["given_name_indices"] = given_names;
    out["name_disambiguators"] = disambiguators; out["cell_indices"] = cells;
    out["profession_ids"] = professions; out["cash_claims"] = cash_claims;
    out["epoch_job_income"] = job_incomes;
    out["epoch_consumption_expense"] = consumption_expenses;
    out["building_handles"] = building_handles; out["job_kinds"] = job_kinds;
    out["employee_role_indices"] = role_indices;
    return out;
}

Dictionary NativeEconomyRuntime::notable_person_snapshot(
        int64_t person_handle_value) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(person_handle_value);
    int32_t person = -1;
    if (!persons_store().valid_handle(handle, person)) {
        out["ok"] = false; out["reason"] = "person_handle_invalid"; return out;
    }
    int32_t family = -1, slot = -1;
    if (!families_store().valid_handle(persons_store().family_handle[person], family)) {
        out["ok"] = false; out["reason"] = "person_relation_invalid"; return out;
    }
    // A notable person travelling with a family expedition keeps no cohort lane
    // until it lands (the payload owns the population unit). Report it as
    // in-transit instead of failing the whole row, so the family dossier can
    // still list the person while they are on the road.
    const bool in_transit = !population_store().valid_handle(
        persons_store().cohort_handle[person], slot);
    if (in_transit && (persons_store().cohort_handle[person] != 0 ||
        !person_in_expedition_transit(handle))) {
        out["ok"] = false; out["reason"] = "person_relation_invalid"; return out;
    }
    const int32_t signature = in_transit ? -1
        : static_cast<int32_t>(population_store().signature_id[slot]);
    const int32_t profession = signature >= 0 && signature < static_cast<int32_t>(
        _signatures.size()) ? _signatures[signature].profession_id : -1;
    const int32_t surname = families_store().surname_id[family];
    const int32_t given = persons_store().given_name_id[person];
    const int32_t building = building_index_for_handle(
        persons_store().building_handle[person]);
    int64_t family_assets = 0, asset_sat = 0;
    if (_family_owned_offsets.size() == families_store().active.size() + 1)
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p) {
            const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
                _family_owned_edge_indices[p], __FILE__, __LINE__);
            const int32_t group = building_index_for_handle(ownership.building_handle);
            if (group < 0 || buildings_store().group_units[group] <= 0) continue;
            family_assets = saturating_add(family_assets, mul_div_sat(
                std::max(buildings_store().last_expected_revenue[group],
                         buildings_store().last_operating_cost[group]),
                ownership.owned_count, buildings_store().group_units[group], asset_sat), asset_sat);
        }
    const int64_t attributed_asset = mul_div_sat(family_assets,
        persons_store().family_equity_share_q32[person], Q32_ONE, asset_sat);
    out["ok"] = true; out["person_handle"] = person_handle_value;
    out["stable_id"] = persons_store().stable_id[person];
    out["family_handle"] = static_cast<int64_t>(persons_store().family_handle[person]);
    out["cohort_handle"] = static_cast<int64_t>(persons_store().cohort_handle[person]);
    out["surname_id"] = surname >= 0 ? from_utf8(_family_surname_ids[surname]) : String();
    out["surname"] = surname >= 0 ? from_utf8(_family_surname_text[surname]) : String();
    out["given_name_id"] = given >= 0 ? from_utf8(_person_given_name_ids[given]) : String();
    out["given_name"] = given >= 0 ? from_utf8(_person_given_name_text[given]) : String();
    out["name_disambiguator"] = static_cast<int32_t>(
        persons_store().name_disambiguator[person]);
    out["notable_since_day"] = persons_store().notable_since_day[person];
    out["cell_idx"] = in_transit ? -1
        : population_store().page_cell[slot / COHORT_PAGE_SIZE];
    out["in_transit"] = in_transit;
    out["profession_id"] = profession; out["cash_claim"] = persons_store().cash_claim[person];
    out["family_equity_share_q32"] = persons_store().family_equity_share_q32[person];
    out["attributed_asset_value"] = attributed_asset;
    out["estimated_net_worth"] = persons_store().cash_claim[person] + attributed_asset;
    out["epoch_job_income"] = persons_store().epoch_job_income[person];
    out["epoch_business_result"] = persons_store().epoch_business_result[person];
    out["epoch_consumption_expense"] = persons_store().epoch_consumption_expense[person];
    out["epoch_tax"] = persons_store().epoch_tax[person];
    out["income_ema"] = persons_store().income_ema[person];
    out["needs_satisfaction_q16"] = persons_store().needs_satisfaction[person];
    out["worst_need_id"] = persons_store().worst_need_id[person];
    out["building_handle"] = static_cast<int64_t>(persons_store().building_handle[person]);
    out["building_type_id"] = building >= 0 ? buildings_store().type_id[building] : -1;
    out["job_kind"] = persons_store().job_kind[person];
    out["employee_role_index"] = persons_store().employee_role_index[person];
    out["job_since_day"] = persons_store().job_since_day[person];
    out["attribution_model"] = "cohort_realized_attribution_v1";
    out["market_cycle_days"] = locked_market_cycle_days();
    return out;
}

Dictionary NativeEconomyRuntime::notable_person_needs(
        int64_t person_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(person_handle_value);
    int32_t person = -1;
    if (!persons_store().valid_handle(handle, person)) {
        out["ok"] = false; out["reason"] = "person_handle_invalid"; return out;
    }
    const int32_t begin = _person_need_offsets.size() == persons_store().active.size() + 1
        ? _person_need_offsets[person] : 0;
    const int32_t finish = _person_need_offsets.size() == persons_store().active.size() + 1
        ? _person_need_offsets[person + 1] : 0;
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 64);
    const int32_t end = std::min(finish, begin + offset + limit);
    PackedInt32Array need_ids, satisfaction;
    PackedInt64Array desired, spending;
    for (int32_t i = begin + offset; i < end; ++i) {
        need_ids.push_back(person_needs()[i].stable_need_id);
        desired.push_back(person_needs()[i].desired_period_units);
        satisfaction.push_back(person_needs()[i].satisfaction_q16);
        spending.push_back(person_needs()[i].attributed_spend);
    }
    out["ok"] = true; out["person_handle"] = person_handle_value;
    out["total"] = finish - begin; out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < finish; out["need_ids"] = need_ids;
    out["desired_period_units"] = desired; out["satisfaction_q16"] = satisfaction;
    out["attributed_spend"] = spending;
    out["attribution_model"] = "cohort_realized_attribution_v1";
    return out;
}

Dictionary NativeEconomyRuntime::building_notable_people(
        int64_t building_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const int32_t building = building_index_for_handle(
        static_cast<uint64_t>(building_handle_value));
    if (building < 0) {
        out["ok"] = false; out["reason"] = "building_handle_invalid"; return out;
    }
    const int32_t begin = _person_building_offsets.size() == building_count() + 1
        ? _person_building_offsets[building] : 0;
    const int32_t finish = _person_building_offsets.size() == building_count() + 1
        ? _person_building_offsets[building + 1] : 0;
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min(finish, begin + offset + limit);
    PackedInt64Array handles;
    PackedInt64Array family_handles;
    PackedInt32Array given_name_indices;
    PackedInt32Array name_disambiguators;
    PackedByteArray job_kinds;
    PackedInt32Array role_indices;
    for (int32_t p = begin + offset; p < end; ++p) {
        const int32_t person = _person_building_indices[p];
        handles.push_back(static_cast<int64_t>(persons_store().handle_for_index(person)));
        family_handles.push_back(static_cast<int64_t>(
            persons_store().family_handle[person]));
        given_name_indices.push_back(persons_store().given_name_id[person]);
        name_disambiguators.push_back(static_cast<int32_t>(
            persons_store().name_disambiguator[person]));
        job_kinds.push_back(persons_store().job_kind[person]);
        role_indices.push_back(persons_store().employee_role_index[person]);
    }
    out["ok"] = true; out["building_handle"] = building_handle_value;
    out["total"] = finish - begin; out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < finish; out["person_handles"] = handles;
    out["family_handles"] = family_handles;
    out["given_name_indices"] = given_name_indices;
    out["name_disambiguators"] = name_disambiguators;
    out["job_kinds"] = job_kinds; out["employee_role_indices"] = role_indices;
    return out;
}
