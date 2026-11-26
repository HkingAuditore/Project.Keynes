Dictionary DCWorldExt::explain_ideology(int64_t country_handle, int32_t ideology_id) {
    if (const auto view = published_ideology(_runtime_host.get())) {
        const auto row = view->countries.find(static_cast<uint64_t>(country_handle));
        if (row == view->countries.end() || ideology_id < 0 ||
            static_cast<size_t>(ideology_id) >= row->second.explanations.size()) return unavailable();
        return row->second.explanations[ideology_id].duplicate(true);
    }
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->explain(country_handle, ideology_id);
}

Dictionary DCWorldExt::explain_ideologies(int64_t country_handle,
        const PackedInt32Array &ideology_ids) {
    if (const auto view = published_ideology(_runtime_host.get()))
        return view->explain_batch(static_cast<uint64_t>(country_handle), ideology_ids);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->explain_batch(
            country_handle, ideology_ids);
}

int64_t DCWorldExt::compute_idea_activation_signature_for_test(int64_t handle,
        int32_t ideology_id) {
    if (_ideology_runtime == nullptr) return 0;
    return static_cast<int64_t>(ideology_runtime_from(_ideology_runtime)
        ->activation_signature_for_test(static_cast<uint64_t>(handle),
                                        ideology_id));
}

Dictionary DCWorldExt::get_ideology_business_state() const {
    Dictionary out;
    out["ok"] = false;
    if (_ideology_runtime == nullptr) {
        out["code"] = "ideology_runtime_unavailable";
        return out;
    }
    RuntimeIdeologyPodSnapshot local;
    const auto view = published_ideology(_runtime_host.get());
    if ((!view && !ideology_runtime_from(_ideology_runtime)->export_pod_business_snapshot(local)) ||
        (view && !view->business)) {
        out["code"] = "ideology_business_snapshot_unavailable";
        return out;
    }
    const auto &snapshot = view ? *view->business : local;
    IdeologyBusinessSections sections;
    ideology_business_sections(snapshot, sections);
    out["ok"] = true;
    out["hash"] = static_cast<int64_t>(ideology_business_hash(snapshot));
    out["committed_day"] = snapshot.committed_day;
    out["catalog_hash"] = static_cast<int64_t>(snapshot.catalog_hash);
    out["countries"] = static_cast<int64_t>(snapshot.countries.size());
    // Per-section values, so a caller comparing two worlds (or a main thread
    // against a worker) can name the first diverging area instead of only
    // "the totals differ".
    out["points"] = static_cast<int64_t>(sections.points);
    out["baseline"] = static_cast<int64_t>(sections.baseline);
    out["history"] = static_cast<int64_t>(sections.history);
    out["draw"] = static_cast<int64_t>(sections.draw);
    out["bits"] = static_cast<int64_t>(sections.bits);
    out["offer"] = static_cast<int64_t>(sections.offer);
    out["ideas"] = static_cast<int64_t>(sections.ideas);
    // Diagnostic sub-hashes. They never participate in the total hash; they exist
    // so a failure can say WHICH part of a section moved without a debugger rerun.
    out["points_balance"] = static_cast<int64_t>(sections.points_balance);
    out["points_lifetime"] = static_cast<int64_t>(sections.points_lifetime);
    out["points_revision"] = static_cast<int64_t>(sections.points_revision);
    out["history_cursor"] = static_cast<int64_t>(sections.history_cursor);
    // Country rows in slot order, points only. Enough to bisect a points
    // divergence to one country without a debugger.
    PackedInt64Array handles;
    PackedInt64Array points_q16;
    PackedInt64Array lifetime_q16;
    PackedInt64Array revisions;
    for (const RuntimeIdeologyPodCountryState &country : snapshot.countries) {
        handles.append(static_cast<int64_t>(country.handle));
        points_q16.append(country.ideology_points_q16);
        lifetime_q16.append(country.lifetime_points_q16);
        revisions.append(static_cast<int64_t>(country.points_revision));
    }
    out["handles"] = handles;
    out["points_q16"] = points_q16;
    out["lifetime_q16"] = lifetime_q16;
    out["revisions"] = revisions;
    return out;
}

Dictionary DCWorldExt::get_ideology_report() const {
    if (const auto view = published_ideology(_runtime_host.get())) return view->report.duplicate(true);
    if (_ideology_runtime == nullptr) return unavailable();
    Dictionary out = ideology_runtime_from(_ideology_runtime)->report();
    // R-3: how often the refresh lost the economy input boundary lock, and the
    // longest run of consecutive losses. A high max-consecutive value means the
    // refresh is starved rather than merely deferred, which is invisible from the
    // per-call result alone (every call still answers ok=true).
    out["instance_refresh_lock_skips"] =
        static_cast<int64_t>(_instance_refresh_lock_skips);
    out["instance_refresh_max_consecutive_skips"] =
        static_cast<int64_t>(_instance_refresh_max_consecutive_skips);
    out["instance_refresh_consecutive_skips"] =
        static_cast<int64_t>(_instance_refresh_consecutive_skips);
    // Pointer identity, not a value: a parity failure whose reference side has
    // no country rows is almost always two different Economy instances, and the
    // numbers cannot show that on their own.
    out["economy_runtime_bound"] = _economy_runtime != nullptr;
    out["economy_runtime_matches_ideology"] =
        _economy_runtime != nullptr &&
        ideology_runtime_from(_ideology_runtime)->economy_runtime() ==
            static_cast<NativeEconomyRuntime *>(_economy_runtime);
    // The worker import behind a load under IDEOLOGY worker authority. `pending=1` means
    // the mirror is still holding the restored state because the POD has not adopted it
    // yet; `last_code` names the last attempt (`applied`, `economy_day_inflight`, or the
    // POD's own refusal reason).
    NativeIdeologyRuntime *runtime = ideology_runtime_from(_ideology_runtime);
    out["worker_import_pending"] = runtime->worker_import_pending();
    out["worker_import_attempts"] =
        static_cast<int64_t>(runtime->worker_import_attempts());
    out["worker_import_last_code"] =
        String(runtime->worker_import_last_code().c_str());
    out["pod_catalog_hash"] = static_cast<int64_t>(runtime->pod_catalog_hash());
    return out;
}
