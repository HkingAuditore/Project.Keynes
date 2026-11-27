Dictionary DCWorldExt::get_economy_territory_plane() const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    const auto *economy = static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    out["ok"] = true;
    out["cell_count"] = static_cast<int64_t>(economy->cell_count());
    out["plane_size"] = static_cast<int64_t>(economy->epoch_cell_country_size_for_test());
    out["country_count"] = static_cast<int64_t>(economy->epoch_country_count_for_test());
    // `country_territory_index_ready()` is private. What actually matters is
    // whether a territory query returns cells, so ask the same accessor the
    // selector uses.
    out["slot0_cell_count"] =
        static_cast<int64_t>(economy->country_cell_count(0));
    // THE decision the own-territory selector makes first:
    //   const int32_t country = cell_country_slot(source_cell);  // = the anchor
    //   if (country < 0) { out.push_back(source_cell); return; }
    // If the anchor cell reports no owner, the branch returns exactly ONE cell --
    // and an empty result means `owned` was 0 for whatever slot it found.
    out["cell0_country"] = static_cast<int64_t>(economy->cell_country_slot(0));
    out["cell0_country_cell_count"] =
        static_cast<int64_t>(economy->country_cell_count(
            economy->cell_country_slot(0)));
    out["anchor0"] = static_cast<int64_t>(economy->country_anchor_cell(0));
    out["own_territory_branch"] =
        static_cast<int64_t>(economy->own_territory_branch_count());
    out["own_territory_owned"] =
        static_cast<int64_t>(economy->own_territory_owned_total());
    out["own_territory_emitted"] =
        static_cast<int64_t>(economy->own_territory_emitted_total());
    out["own_last_source_cell"] = economy->own_last_source_cell_debug();
    out["own_last_country"] = economy->own_last_country_debug();
    out["own_last_cap"] = economy->own_last_cap_debug();
    out["own_first_cell_ok"] = economy->own_first_cell_ok_debug();
    out["own_last_tag"] = economy->own_last_tag_debug();
    out["own_pushed_raw"] = economy->own_pushed_raw_debug();
    out["own_cell_neg"] = economy->own_cell_neg_debug();
    out["own_tag_rejected"] = economy->own_tag_rejected_debug();
    // The exact predicate `country_cell_count` uses (economy_runtime_family_buff
    // .cpp:970); when false every territory query yields zero cells.
    out["plane_matches_cell_count"] =
        economy->epoch_cell_country_size_for_test() ==
        static_cast<size_t>(economy->cell_count());
    return out;
}

Dictionary DCWorldExt::get_country_territory_counts() const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    // `runtime_from()` is not visible in this translation unit, so cast the stored
    // void pointer directly.
    const auto *economy = static_cast<const NativeEconomyRuntime *>(_economy_runtime);
    // Country slots are dense in the epoch snapshot; walking them and asking the
    // runtime for each count keeps the ownership question in one place instead of
    // re-deriving it from a cell->country table here.
    // `epoch_country_count_for_test()` is the only accessor for the epoch's
    // country slot count. It is named "for_test" but is const and side-effect free,
    // which is why it is usable here; there is no non-test twin.
    const int32_t country_count = economy->epoch_country_count_for_test();
    PackedInt64Array handles;
    PackedInt32Array counts;
    int32_t widest = 0;
    int32_t widest_slot = -1;
    int64_t total = 0;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const int32_t owned = economy->country_cell_count(slot);
        handles.append(static_cast<int64_t>(slot));
        counts.append(owned);
        total += owned;
        if (owned > widest) {
            widest = owned;
            widest_slot = slot;
        }
    }
    out["ok"] = true;
    out["country_count"] = country_count;
    out["slots"] = handles;
    out["counts"] = counts;
    out["widest"] = widest;
    out["widest_slot"] = widest_slot;
    out["total_cells"] = total;
    // Explicit count of territories above the OLD 32-cell cap: the migration's
    // premise in one number.
    int32_t above_cap = 0;
    for (int32_t i = 0; i < counts.size(); ++i)
        if (counts[i] > 32) ++above_cap;
    out["above_old_cap"] = above_cap;
    return out;
}

Dictionary DCWorldExt::capture_country_runtime_snapshot() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodSnapshot snapshot;
    std::string error;
    std::shared_ptr<const RuntimeCountryPodSnapshot> committed;
    if (_runtime_host && _runtime_host->execution_has_stopped()) {
        const auto previous = _runtime_host->report();
        const auto country = runtime_domain_mask(RuntimeDomainId::COUNTRY);
        if (_runtime_host->country_authority_owner_is_worker() ||
            (previous.mode == RuntimeSimulationMode::ACTIVE && _runtime_host->has_started_once() &&
             (previous.requested_authority_mask & country) != 0u))
            committed = _runtime_host->country_economy_audit_snapshot();
    }
    if (committed) snapshot = *committed;
    else if (!country_runtime_from(_country_runtime)->export_pod_snapshot(snapshot, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_snapshot_capture_failed" : error.c_str();
        return out;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (!committed && !_runtime_host->publish_country_snapshot(snapshot)) {
        out["ok"] = false;
        out["code"] = "country_snapshot_validation_failed";
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["committed_day"] = snapshot.committed_day;
    out["country_count"] = static_cast<int>(snapshot.country_count);
    out["cell_count"] = static_cast<int>(snapshot.cell_count);
    out["technology_count"] = static_cast<int>(snapshot.technology_count);
    return out;
}

Dictionary DCWorldExt::capture_country_pod_catalog() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodCatalog catalog;
    std::string error;
    if (!country_runtime_from(_country_runtime)->export_pod_catalog(catalog, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_catalog_capture_failed" : error.c_str();
        return out;
    }
    PackedInt64Array costs;
    costs.resize(static_cast<int64_t>(catalog.technology_costs.size()));
    for (int64_t i = 0; i < costs.size(); ++i) costs.set(i, catalog.technology_costs[static_cast<size_t>(i)]);
    PackedInt32Array domains, flags, prereq_offsets, prerequisites;
    PackedByteArray effect_required;
    domains.resize(static_cast<int64_t>(catalog.technology_domains.size()));
    flags.resize(static_cast<int64_t>(catalog.technology_flags.size()));
    effect_required.resize(static_cast<int64_t>(catalog.technology_effect_required.size()));
    prereq_offsets.resize(static_cast<int64_t>(catalog.prerequisite_offsets.size()));
    prerequisites.resize(static_cast<int64_t>(catalog.prerequisites.size()));
    for (int64_t i = 0; i < domains.size(); ++i) domains.set(i, catalog.technology_domains[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < flags.size(); ++i) flags.set(i, catalog.technology_flags[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < effect_required.size(); ++i) effect_required.set(i, catalog.technology_effect_required[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prereq_offsets.size(); ++i) prereq_offsets.set(i, catalog.prerequisite_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prerequisites.size(); ++i) prerequisites.set(i, catalog.prerequisites[static_cast<size_t>(i)]);
    PackedInt32Array condition_offsets, condition_ops, condition_refs;
    PackedInt64Array condition_values;
    condition_offsets.resize(static_cast<int64_t>(catalog.research_condition_offsets.size()));
    condition_ops.resize(static_cast<int64_t>(catalog.research_condition_ops.size()));
    condition_refs.resize(static_cast<int64_t>(catalog.research_condition_refs.size()));
    condition_values.resize(static_cast<int64_t>(catalog.research_condition_values.size()));
    for (int64_t i = 0; i < condition_offsets.size(); ++i) condition_offsets.set(i, catalog.research_condition_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_ops.size(); ++i) condition_ops.set(i, catalog.research_condition_ops[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_refs.size(); ++i) condition_refs.set(i, catalog.research_condition_refs[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_values.size(); ++i) condition_values.set(i, catalog.research_condition_values[static_cast<size_t>(i)]);
    PackedInt32Array reveal_offsets, reveal_ops, reveal_refs;
    PackedInt64Array reveal_values;
    reveal_offsets.resize(static_cast<int64_t>(catalog.reveal_condition_offsets.size()));
    reveal_ops.resize(static_cast<int64_t>(catalog.reveal_condition_ops.size()));
    reveal_refs.resize(static_cast<int64_t>(catalog.reveal_condition_refs.size()));
    reveal_values.resize(static_cast<int64_t>(catalog.reveal_condition_values.size()));
    for (int64_t i = 0; i < reveal_offsets.size(); ++i) reveal_offsets.set(i, catalog.reveal_condition_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_ops.size(); ++i) reveal_ops.set(i, catalog.reveal_condition_ops[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_refs.size(); ++i) reveal_refs.set(i, catalog.reveal_condition_refs[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < reveal_values.size(); ++i) reveal_values.set(i, catalog.reveal_condition_values[static_cast<size_t>(i)]);
    PackedInt32Array milestone_offsets, milestone_candidates, milestone_required, entry_milestones;
    milestone_offsets.resize(static_cast<int64_t>(catalog.milestone_offsets.size()));
    milestone_candidates.resize(static_cast<int64_t>(catalog.milestone_candidates.size()));
    milestone_required.resize(static_cast<int64_t>(catalog.milestone_required_counts.size()));
    entry_milestones.resize(static_cast<int64_t>(catalog.entry_milestone_indices.size()));
    for (int64_t i = 0; i < milestone_offsets.size(); ++i) milestone_offsets.set(i, catalog.milestone_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_candidates.size(); ++i) milestone_candidates.set(i, catalog.milestone_candidates[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_required.size(); ++i) milestone_required.set(i, catalog.milestone_required_counts[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < entry_milestones.size(); ++i) entry_milestones.set(i, catalog.entry_milestone_indices[static_cast<size_t>(i)]);
    out["ok"] = true;
    out["catalog_hash"] = static_cast<int64_t>(catalog.catalog_hash);
    out["technology_count"] = static_cast<int>(catalog.technology_count);
    out["technology_words"] = static_cast<int>(catalog.technology_words);
    out["technology_points_good_id"] = catalog.technology_points_good_id;
    out["research_conditions_complete"] = catalog.research_conditions_complete;
    out["technology_costs"] = costs;
    out["technology_domains"] = domains;
    out["technology_flags"] = flags;
    out["technology_effect_required"] = effect_required;
    out["prerequisite_offsets"] = prereq_offsets;
    out["prerequisites"] = prerequisites;
    out["milestone_offsets"] = milestone_offsets;
    out["milestone_candidates"] = milestone_candidates;
    out["milestone_required_counts"] = milestone_required;
    out["entry_milestone_indices"] = entry_milestones;
    out["research_condition_offsets"] = condition_offsets;
    out["research_condition_ops"] = condition_ops;
    out["research_condition_refs"] = condition_refs;
    out["research_condition_values"] = condition_values;
    out["reveal_condition_offsets"] = reveal_offsets;
    out["reveal_condition_ops"] = reveal_ops;
    out["reveal_condition_refs"] = reveal_refs;
    out["reveal_condition_values"] = reveal_values;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    std::string publish_error;
    if (!_runtime_host->publish_country_catalog(catalog, publish_error)) {
        out["ok"] = false;
        out["code"] = publish_error.empty()
            ? "country_catalog_publish_failed" : publish_error.c_str();
        return out;
    }
    if (_ideology_runtime != nullptr && _economy_runtime != nullptr)
        publish_ideology_worker_inputs();
    return out;
}

Dictionary DCWorldExt::get_country_worker_protocol_status() const {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const NativeSimulationHost::CountryWorkerProtocolStatus status =
        _runtime_host->country_worker_protocol_status();
    Dictionary out;
    out["ok"] = true;
    out["code"] = "ok";
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["configured"] = status.configured;
    out["plan_active"] = status.plan_active;
    out["waiting_for_peer"] = status.waiting_for_peer;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["result_count"] = static_cast<int64_t>(status.result_count);
    out["rejected_results"] = static_cast<int64_t>(status.rejected_results);
    out["rejected_intents"] = static_cast<int64_t>(status.rejected_intents);
    out["has_unreported_rejection"] = status.has_unreported_rejection;
    out["retry_day"] = status.retry_day;
    out["rejected_request_id"] = static_cast<int64_t>(
        status.rejected_request_id);
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["country_generation"] = static_cast<int64_t>(status.country_generation);
    out["day"] = status.day;
    out["continuation_index"] = static_cast<int64_t>(status.continuation_index);
    out["boundary_id"] = static_cast<int64_t>(status.boundary_id);
    out["last_admitted_submit_order"] = static_cast<int64_t>(
        status.last_admitted_submit_order);
    out["expected_base_generation"] = static_cast<int64_t>(
        status.expected_base_generation);
    out["catalog_hash"] = static_cast<int64_t>(status.catalog_hash);
    out["last_reason"] = String(status.last_reason);
    out["has_save_barrier"] = status.plan_active || status.pending_intents != 0 ||
        status.result_count != 0 || status.rejected_intents != 0 ||
        status.has_unreported_rejection;
    return out;
}

Dictionary DCWorldExt::get_country_worker_read_view(
        int64_t after_generation) const {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? 0u : static_cast<uint64_t>(after_generation);
    const auto &tail = _runtime_display_commit.day_tail;
    RuntimeCountryReadView view = tail && tail->country.snapshot
        ? tail->country : _runtime_host->country_worker_read_view(cursor);
    if (tail && tail->country.snapshot) {
        view.available = view.generation > cursor;
        view.full_snapshot_required = view.available &&
            cursor != view.patch_base_generation && cursor < view.territory_watermark;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["available"] = view.available;
    out["full_snapshot_required"] = view.full_snapshot_required;
    out["generation"] = static_cast<int64_t>(view.generation);
    out["patch_base_generation"] = static_cast<int64_t>(
        view.patch_base_generation);
    out["committed_day"] = view.committed_day;
    out["state_hash"] = static_cast<int64_t>(view.state_hash);
    out["dirty_families"] = static_cast<int64_t>(view.dirty_families);
    out["territory_watermark"] = static_cast<int64_t>(view.territory_watermark);
    out["research_watermark"] = static_cast<int64_t>(view.research_watermark);
    out["tax_watermark"] = static_cast<int64_t>(view.tax_watermark);
    out["visual_watermark"] = static_cast<int64_t>(view.visual_watermark);
    out["country_count"] = static_cast<int>(view.country_count);
    out["cell_count"] = static_cast<int>(view.cell_count);
    PackedInt32Array changed_cells;
    PackedInt32Array changed_owners;
    changed_cells.resize(static_cast<int64_t>(view.changed_cells.size()));
    changed_owners.resize(static_cast<int64_t>(view.changed_owners.size()));
    for (int64_t i = 0; i < changed_cells.size(); ++i) {
        changed_cells.set(i, view.changed_cells[static_cast<size_t>(i)]);
        changed_owners.set(i, view.changed_owners[static_cast<size_t>(i)]);
    }
    out["changed_cells"] = changed_cells;
    out["changed_owners"] = changed_owners;
    if (view.snapshot != nullptr && view.full_snapshot_required) {
        const int64_t owner_count = static_cast<int64_t>(
            view.snapshot->cell_country_slot.size());
        PackedInt32Array owners;
        owners.resize(owner_count);
        if (owner_count > 0) {
            std::memcpy(owners.ptrw(), view.snapshot->cell_country_slot.data(),
                static_cast<size_t>(owner_count) * sizeof(int32_t));
        }
        out["full_cell_owners"] = owners;
    } else {
        out["full_cell_owners"] = PackedInt32Array();
    }
    PackedInt64Array country_cash;
    PackedInt64Array country_state_versions;
    if (view.snapshot != nullptr) {
        country_cash.resize(static_cast<int64_t>(view.snapshot->country_cash.size()));
        country_state_versions.resize(static_cast<int64_t>(
            view.snapshot->country_state_version.size()));
        for (int64_t i = 0; i < country_cash.size(); ++i) {
            country_cash.set(i, view.snapshot->country_cash[
                static_cast<size_t>(i)]);
        }
        for (int64_t i = 0; i < country_state_versions.size(); ++i) {
            country_state_versions.set(i, static_cast<int64_t>(
                view.snapshot->country_state_version[static_cast<size_t>(i)]));
        }
    }
    // Country ACTIVE consumers read these immutable snapshot fields instead
    // of consulting the synchronous Country store, which is deliberately not
    // mutated by the worker.
    out["country_cash"] = country_cash;
    out["country_state_versions"] = country_state_versions;
    return out;
}

Dictionary DCWorldExt::poll_country_worker_intent() {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    CountryPeerIntent intent;
    if (!_runtime_host->poll_country_worker_intent(intent)) {
        Dictionary out = get_country_worker_protocol_status();
        out["available"] = false;
        out["code"] = "country_worker_intent_empty";
        return out;
    }
    Dictionary out = country_peer_intent_dictionary(intent);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}
