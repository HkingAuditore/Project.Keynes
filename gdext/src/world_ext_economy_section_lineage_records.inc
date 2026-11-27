Dictionary DCWorldExt::get_family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_EXPEDITION_SNAPSHOT, {country_handle, expedition_handle}),
        [&] { return runtime->family_expedition_snapshot(country_handle, expedition_handle); });
}

Dictionary DCWorldExt::get_family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_COLONIZATION_RECEIPTS,
                 {country_handle, after_receipt_id, limit}),
        [&] {
            return runtime->family_colonization_receipts(
                country_handle, after_receipt_id, limit);
        });
}

Dictionary DCWorldExt::get_family_branch_effects(
        int64_t family_handle, int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_BRANCH_EFFECTS, {family_handle, cell_idx}),
        [&] { return runtime->family_branch_effects(family_handle, cell_idx); });
}

Dictionary DCWorldExt::submit_family_trait_commands(
        const Dictionary &packed_batch) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->submit_family_trait_commands(
        packed_batch);
}

Dictionary DCWorldExt::get_family_founding_offers(int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_FOUNDING_OFFERS, {offset, limit}),
        [&] { return runtime->family_founding_offers(offset, limit); });
}

Dictionary DCWorldExt::submit_family_founding_choice(
        int64_t offer_id, int64_t generation, int choice_index,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.kind = RuntimeEconomyBoundaryRequest::Kind::FOUNDING_CHOICE;
        request.subject_id = offer_id;
        request.offer_generation = generation;
        request.choice = choice_index;
        request.effective_day = effective_day;
        request.sequence = sequence;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    auto admission = _runtime_host ? _runtime_host->admit_command(effective_day)
                                    : RuntimeCommandAdmission();
    if (_runtime_host && !admission.accepted()) return unavailable();
    Dictionary result = runtime_from(_economy_runtime)->submit_family_founding_choice(
        offer_id, generation, choice_index, effective_day, sequence);
    if (bool(result.get("ok", false))) result["effective_day"] = effective_day;
    return result;
}

Dictionary DCWorldExt::get_family_industries(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_INDUSTRIES, {family_handle, offset, limit}),
        [&] { return runtime->family_industries(family_handle, offset, limit); });
}

Dictionary DCWorldExt::get_family_notable_people(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_NOTABLE_PEOPLE, {family_handle, offset, limit}),
        [&] { return runtime->family_notable_people(family_handle, offset, limit); });
}

Dictionary DCWorldExt::get_notable_person_snapshot(
        int64_t person_handle) const {
    if (_economy_runtime == nullptr) return Dictionary();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::NOTABLE_PERSON_SNAPSHOT, {person_handle}),
        [&] { return runtime->notable_person_snapshot(person_handle); });
}

Dictionary DCWorldExt::get_notable_person_needs(
        int64_t person_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::NOTABLE_PERSON_NEEDS, {person_handle, offset, limit}),
        [&] { return runtime->notable_person_needs(person_handle, offset, limit); });
}

Dictionary DCWorldExt::get_building_notable_people(
        int64_t building_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::BUILDING_NOTABLE_PEOPLE, {building_handle, offset, limit}),
        [&] { return runtime->building_notable_people(building_handle, offset, limit); });
}
