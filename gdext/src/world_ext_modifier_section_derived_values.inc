Dictionary DCWorldExt::install_derived_cell_layer_for_test(const Dictionary &front) {
    Dictionary out;
    out["ok"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const PackedInt32Array stat_ids = front.get("stat_ids", PackedInt32Array());
    const PackedInt32Array cells = front.get("cells", PackedInt32Array());
    const PackedInt64Array sources = front.get("source_countries", PackedInt64Array());
    const PackedFloat64Array adds = front.get("adds", PackedFloat64Array());
    const PackedFloat64Array factors = front.get("factors", PackedFloat64Array());
    const int32_t count = stat_ids.size();
    if (cells.size() != count || sources.size() != count || adds.size() != count ||
            factors.size() != count) {
        out["reason"] = "derived_cell_layer_column_shape_invalid";
        return out;
    }

    DerivedCellFrontBuilder builder;
    builder.reset(static_cast<uint64_t>(front.get("world_identity", 1)),
                  static_cast<uint64_t>(front.get("map_generation", 1)),
                  static_cast<int64_t>(front.get("sample_day", 0)),
                  static_cast<uint64_t>(front.get("epoch_id", 0)),
                  static_cast<uint64_t>(front.get("execution_contract_hash", 0)));
    for (int32_t i = 0; i < count; ++i) {
        if (!builder.add(stat_ids[i], cells[i],
                static_cast<uint64_t>(sources[i]), adds[i], factors[i])) {
            out["reason"] = "derived_cell_layer_row_invalid";
            return out;
        }
    }
    // Bump every stat that received a row, so the layer version reflects real
    // content rather than "the builder ran" (plan §7.4).
    for (int32_t i = 0; i < count; ++i) builder.bump_stat_version(stat_ids[i]);

    DerivedCellFront built;
    const bool produced = builder.install(built);
    const uint64_t expected =
        static_cast<uint64_t>(front.get("expected_generation", 0));
    bool skipped = false;
    std::string error;
    const bool installed = runtime_from(_modifier_runtime)->install_derived_cell_layer(
        std::move(built), expected, skipped, error);
    out["ok"] = installed;
    out["installed"] = installed;
    out["skipped"] = skipped;
    out["produced"] = produced;
    out["reason"] = installed ? String("") : String(error.c_str());
    out["layer_generation"] = static_cast<int64_t>(
        runtime_from(_modifier_runtime)->derived_cell_layer_generation());
    return out;
}

int64_t DCWorldExt::modifier_stat_bucket_version(
        int domain, const PackedInt32Array &stat_ids) const {
    if (_modifier_runtime == nullptr) return 0;
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    return static_cast<int64_t>(
        runtime_from(_modifier_runtime)->stat_bucket_version(
            domain, wanted.data(), wanted.size()));
}

Dictionary DCWorldExt::collect_modifier_scope_ids(
        int domain, int scope, const PackedInt32Array &stat_ids) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    std::vector<uint64_t> scope_ids;
    runtime_from(_modifier_runtime)->collect_scope_ids(
        domain, scope, wanted.data(), wanted.size(), scope_ids);
    PackedInt64Array packed;
    packed.resize(static_cast<int32_t>(scope_ids.size()));
    for (size_t i = 0; i < scope_ids.size(); ++i)
        packed[static_cast<int32_t>(i)] = static_cast<int64_t>(scope_ids[i]);
    out["ok"] = true;
    out["scope_ids"] = packed;
    return out;
}

Dictionary DCWorldExt::collect_modifier_scope_stat_entries(
        int domain, int scope, const PackedInt32Array &stat_ids) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    std::vector<uint64_t> scope_ids;
    std::vector<int32_t> out_stats;
    runtime_from(_modifier_runtime)->collect_scope_stat_entries(
        domain, scope, wanted.data(), wanted.size(), scope_ids, out_stats);
    PackedInt64Array packed_scopes;
    packed_scopes.resize(static_cast<int32_t>(scope_ids.size()));
    for (size_t i = 0; i < scope_ids.size(); ++i)
        packed_scopes[static_cast<int32_t>(i)] = static_cast<int64_t>(scope_ids[i]);
    PackedInt32Array packed_stats;
    packed_stats.resize(static_cast<int32_t>(out_stats.size()));
    for (size_t i = 0; i < out_stats.size(); ++i)
        packed_stats[static_cast<int32_t>(i)] = out_stats[i];
    out["ok"] = true;
    out["scope_ids"] = packed_scopes;
    out["stat_ids"] = packed_stats;
    return out;
}

Dictionary DCWorldExt::resolve_modifier_stat(const String &stat_key) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const std::string key(stat_key.utf8().get_data());
    const int32_t sid =
        runtime_from(_modifier_runtime)->stat_id_for_key(key);
    out["ok"] = sid >= 0;
    out["stat_id"] = static_cast<int64_t>(sid);
    out["clamp_max"] = sid >= 0
        ? runtime_from(_modifier_runtime)->stat_clamp_max(key.c_str(), 0.0) : 0.0;
    return out;
}

Dictionary DCWorldExt::get_cell_program_rollout() const {
    Dictionary out;
    out["ok"] = true;
    // The selector kinds enabled at the CURRENT milestone. `enabled_any` is what a
    // test asks when it only needs "is the derived path driving production yet".
    PackedInt32Array kinds;
    bool any = false;
    for (int32_t kind = 0; kind <= 17; ++kind) {
        if (cell_program_rollout_enabled(kind)) {
            kinds.append(kind);
            any = true;
        }
    }
    out["enabled_kinds"] = kinds;
    out["enabled_any"] = any;
    // `rollout` used to echo the staged enum. The switch is gone (§15.7), so the
    // honest answer is a boolean: is the derived backend expressing every selector it
    // can, with no milestone gate left in between? Kept as a field because fixtures ask
    // for it, and "1" now means "no gate", not "stage 3".
    out["rollout"] = static_cast<int64_t>(1);
    out["rollout_stage_removed"] = true;
    return out;
}

Dictionary DCWorldExt::get_effective_stat_value(const String &stat_key,
                                                 int64_t cell,
                                                 int64_t entity_handle,
                                                 double base_value) const {
    Dictionary out;
    out["ok"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    // Inspect the actual Economy reader. A UI mirror can have a correct value
    // while the simulation still consumes a different published generation.
    std::optional<std::unique_lock<std::mutex>> boundary;
    const auto *runtime = static_cast<const ModifierRuntime *>(_modifier_runtime);
    const auto ideology_view = _runtime_host && _runtime_host->effect_adapter_owned()
        ? _runtime_host->latest_ideology_read_view() : nullptr;
    if (ideology_view) {
        out["read_source"] = "committed_ideology_projection";
    } else if (_economy_modifier_view_attached && _economy_modifier_view != nullptr) {
        if (_runtime_host != nullptr) {
            auto acquired = _runtime_host->try_lock_economy_input_capture();
            if (!acquired.owns_lock()) {
                out["pending"] = true;
                out["reason"] = "economy_day_inflight";
                return out;
            }
            boundary.emplace(std::move(acquired));
        }
        runtime = static_cast<const ModifierRuntime *>(_economy_modifier_view);
        out["read_source"] = "economy_worker_view";
    } else {
        out["read_source"] = "main_runtime";
    }
    const int32_t stat_id = runtime->stat_id_for_key(std::string(stat_key.utf8().get_data()));
    if (stat_id < 0) {
        out["reason"] = "stat_unknown";
        return out;
    }
    out["ok"] = true;
    out["stat_id"] = stat_id;
    // The production call, so this reports the number the game would see.
    const DerivedCellFront *front = ideology_view ? ideology_view->derived.get()
        : runtime->derived_cell_front();
    out["value"] = runtime->effective_value_with_front(ModifierRuntime::ECONOMY, stat_id,
        static_cast<uint64_t>(entity_handle), static_cast<uint64_t>(cell), base_value, front);

    // The derived layer's own slice of it, when the cell has one. Reported separately so
    // a test can tell "the derived row contributed" from "the legacy bucket did".
    bool derived_found = false;
    if (cell >= 0) {
        if (front != nullptr) {
            const DerivedCellStatRow *row = front->row_for_stat(stat_id);
            if (row != nullptr) {
                const DerivedCellContribution *slot =
                    row->find(static_cast<int32_t>(cell));
                if (slot != nullptr) {
                    derived_found = true;
                    out["derived_add"] = slot->sum_add;
                    out["derived_factor"] = slot->product_nonzero;
                    out["derived_zero_factor_count"] =
                        static_cast<int64_t>(slot->zero_factor_count);
                    out["derived_contributors"] =
                        static_cast<int64_t>(slot->contributor_count);
                    out["derived_source_country"] =
                        static_cast<int64_t>(slot->source_country);
                }
            }
        }
    }
    out["derived_present"] = derived_found;
    return out;
}

Dictionary DCWorldExt::probe_fan_out_ownership(
        int64_t country_handle, int64_t source_cell, int64_t selector_kind,
        int64_t param0, int64_t param1, int64_t dilate_depth) const {
    Dictionary out;
    out["ok"] = false;
    if (_economy_runtime == nullptr || _ideology_runtime == nullptr) {
        out["reason"] = "runtime_unavailable";
        return out;
    }
    auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    auto *ideology = static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
    const int32_t cell = static_cast<int32_t>(source_cell);
    if (cell < 0 || cell >= economy->cell_count()) {
        out["reason"] = "source_cell_out_of_range";
        return out;
    }
    const int32_t p0 = static_cast<int32_t>(param0);
    const int32_t scope = pk::decode_ownership_scope(p0);
    // `resolve_selector_cell_cap`, NOT an ad-hoc `authored > 0 ? authored : 32`.
    //
    // The old fallback meant `param0 = 0` was measured as "32 sources", i.e. the probe
    // could not exercise the UNCAPPED case at all and would have reported
    // "removing the cap costs nothing" from a comparison of 32 against 32. The
    // production OWN_TERRITORY branch resolves the cap the same way
    // (`economy_runtime_family_buff.cpp:2500`), so this also stops the probe from
    // describing behaviour the runtime does not have.
    const int32_t cap = pk::resolve_selector_cell_cap(
        static_cast<int32_t>(selector_kind), pk::ownership_stripped_cap(p0),
        economy->cell_count());

    // Collect the UNFILTERED fan-out exactly as the production path does, then run the
    // shared filter. Doing both halves here is the point: a probe that re-implemented
    // the predicate would prove nothing about the shipped code.
    std::vector<int32_t> raw;
    economy->collect_effect_target_cells(cell,
        static_cast<int32_t>(selector_kind), cap, static_cast<int32_t>(param1), raw,
        param0);
    std::vector<int32_t> kept = raw;
    ideology->apply_fan_out_ownership_filter(cell, scope, kept);

    PackedInt32Array raw_packed;
    for (const int32_t v : raw) raw_packed.append(v);
    PackedInt32Array kept_packed;
    for (const int32_t v : kept) kept_packed.append(v);

    out["ok"] = true;
    out["scope"] = pk::ownership_scope_name(scope);
    out["scope_value"] = scope;
    out["source_cell"] = cell;
    out["source_country"] = economy->cell_country_slot(cell);
    out["raw_cells"] = raw_packed;
    out["kept_cells"] = kept_packed;
    out["raw_count"] = static_cast<int64_t>(raw.size());
    out["kept_count"] = static_cast<int64_t>(kept.size());
    // Optional: run the BATCH dilation over the collected sources. This is the path the
    // kind 14/15 fan-out now takes, so a fixture can time it instead of the per-source
    // loop it replaced.
    if (dilate_depth > 0) {
        std::vector<int32_t> dilated;
        economy->dilate_cell_set(raw, static_cast<int32_t>(dilate_depth), dilated);
        PackedInt32Array dilated_packed;
        for (const int32_t v : dilated) dilated_packed.append(v);
        out["dilated_cells"] = dilated_packed;
        out["dilated_count"] = static_cast<int64_t>(dilated.size());
    }
    out["country_handle"] = country_handle;
    // Why the ring may be empty: the radial kinds bail unless all four columns are
    // sized, and that guard is invisible from outside.
    out["building_context"] = economy->building_context_ready_for_test();
    return out;
}

Dictionary DCWorldExt::probe_cell_program_backend(
        const Dictionary &facts) const {
    CellProgramFacts parsed;
    parsed.target_domain =
        static_cast<int32_t>(facts.get("target_domain", 0));
    parsed.selector_kind =
        static_cast<int32_t>(facts.get("target_selector_kind", -1));
    parsed.lifecycle = static_cast<int32_t>(facts.get("lifecycle", 0));
    parsed.duration_days =
        static_cast<int32_t>(facts.get("duration_days", -1));
    parsed.stack_policy = static_cast<int32_t>(facts.get("stack_policy", 0));
    parsed.max_stacks = static_cast<int32_t>(facts.get("max_stacks", 1));

    // An unknown selector kind is refused outright rather than defaulted into a
    // backend: a card whose selector was renamed must fail visibly (plan §4.4).
    if (!cell_program_selector_supported(parsed.selector_kind)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "selector_kind_not_supported";
        out["selector_kind"] = parsed.selector_kind;
        return out;
    }

    // Optional single command, so a test can exercise the per-command conditions
    // without constructing a whole ProgramSet.
    if (facts.has("command_value_mode")) {
        CellProgramCommandFacts command;
        command.value_mode =
            static_cast<int32_t>(facts.get("command_value_mode", 1));
        command.stack_top_is_constant =
            bool(facts.get("command_stack_top_is_constant", false));
        command.definition_resolved =
            bool(facts.get("command_definition_resolved", false));
        command.all_terms_sum =
            bool(facts.get("command_all_terms_sum", false));
        command.stacks = static_cast<int32_t>(facts.get("command_stacks", 1));
        command.duration_days =
            static_cast<int32_t>(facts.get("command_duration_days", -1));
        // `has_metric_ramp` was MISSING here. It is what separates "the derived
        // layer can express this magnitude" from "it cannot", and leaving it at its
        // default `false` made every ramp probe report
        // `non_constant_value_mode` -- i.e. the probe said "rejected" no matter what
        // the real runtime would decide. Caught while trying to explain why an
        // ACTIVE ramp card produced `seen=0`; the answer was that this bridge, not
        // the runtime, was wrong.
        command.has_metric_ramp =
            bool(facts.get("command_has_metric_ramp", false));
        parsed.commands.push_back(command);
    }

    const CellProgramDecision decision = decide_cell_program_backend(parsed);
    Dictionary out;
    out["ok"] = true;
    out["backend"] = decision.backend == CellProgramBackend::DerivedCell
        ? String("DerivedCell") : String("EffectInstance");
    out["reason"] =
        String(cell_program_legacy_reason_name(decision.reason));
    out["detail"] = String(decision.detail.c_str());
    // Capability and rollout are separate answers; report both so a test can prove
    // they do not collapse into one another.
    out["rollout_enabled"] = cell_program_rollout_enabled(parsed.selector_kind);
    return out;
}

Dictionary DCWorldExt::drain_derived_cell_layer(int64_t day_index) {
    Dictionary out;
    if (_ideology_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    if (_runtime_host && _runtime_host->effect_adapter_owned()) {
        out["ok"] = false;
        out["reason"] = "ideology_executor_owned";
        return out;
    }
    // NON-const: draining advances the rebuild.
    auto *ideology = static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
    // A drain for a day the in-flight job does not belong to DESTROYS that job:
    // `step_derived_rebuild` reads "different day" as "the epoch's inputs moved" and
    // resets the accumulator and the fold. Reporting `{ok:true, complete:true}` for
    // that made a caller's wrong argument look like an empty layer -- measured in
    // `ideology_tag_snapshot_stress_test`, where `drain(0)` threw away a day-30 fold
    // and the resulting `layer_installed=false` read as "the layer is broken".
    // Capture what is about to be discarded, then report it as `reset`.
    const bool had_job = ideology->derived_rebuild_pending();
    const int64_t job_day = ideology->derived_rebuild_day();
    std::string first_error;
    // Bounded: a rebuild needs at most (contributions / min_batch) steps, and a
    // runaway loop here would hang a day rather than fail it.
    int32_t steps = 0;
    while (ideology->derived_rebuild_pending() && steps < 4096) {
        // A local, not `*new std::string()`: that leaked one string per step.
        std::string step_error;
        ideology->step_derived_rebuild(day_index, step_error);
        // Keep the FIRST error: the loop keeps stepping, and the last one is often a
        // follow-on (`derived_cell_layer_finish_failed` after the real refusal).
        if (first_error.empty() && !step_error.empty())
            first_error = step_error;
        ++steps;
        if (!step_error.empty()) break;
    }
    out["ok"] = true;
    out["steps"] = steps;
    out["complete"] = !ideology->derived_rebuild_pending();
    // `reset` is the honest answer to "did this call throw work away?". A caller
    // that asked for the wrong day gets `reset: true` plus the day it discarded,
    // instead of a green `complete` over a layer nobody built.
    const bool reset = had_job && job_day != day_index;
    out["reset"] = reset;
    if (reset) {
        out["reason"] = "day_changed";
        out["discarded_day"] = job_day;
        out["requested_day"] = day_index;
    }
    // The step error used to be dropped here while `complete` was still computed
    // from the leftover state, so a refused install looked like success. Named, not
    // swallowed.
    if (!first_error.empty())
        out["error"] = String(first_error.c_str());
    return out;
}

Dictionary DCWorldExt::get_derived_multi_country_report() const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    auto *runtime = static_cast<const ModifierRuntime *>(_modifier_runtime);
    const auto ideology_view = _runtime_host && _runtime_host->effect_adapter_owned()
        ? _runtime_host->latest_ideology_read_view() : nullptr;
    const DerivedCellFront *front = ideology_view ? ideology_view->derived.get()
        : runtime->derived_cell_front();
    if (front == nullptr) {
        out["ok"] = true;
        out["rows"] = 0;
        out["cells"] = 0;
        out["multi_country_cells"] = 0;
        out["max_contributors"] = 0;
        out["countries"] = PackedInt64Array();
        return out;
    }
    int64_t cells = 0;
    int64_t multi = 0;
    int32_t max_contributors = 0;
    // Distinct handles across the whole front, so a caller can see WHICH countries
    // reached the layer, not only how many cells they touched.
    std::vector<uint64_t> handles;
    for (const DerivedCellStatRow &row : front->rows) {
        cells += static_cast<int64_t>(row.cells.size());
        for (const DerivedCellContribution &slot : row.contributions) {
            const int32_t contributors = static_cast<int32_t>(slot.contributor_count);
            if (contributors > max_contributors) max_contributors = contributors;
            if (contributors > 1) ++multi;
            if (slot.source_country != 0)
                handles.push_back(slot.source_country);
        }
    }
    std::sort(handles.begin(), handles.end());
    handles.erase(std::unique(handles.begin(), handles.end()), handles.end());
    PackedInt64Array packed;
    for (const uint64_t handle : handles)
        packed.append(static_cast<int64_t>(handle));

    out["ok"] = true;
    out["rows"] = static_cast<int64_t>(front->rows.size());
    out["cells"] = cells;
    // The number B10 needs: cells reached by MORE than one country.
    out["multi_country_cells"] = multi;
    out["max_contributors"] = max_contributors;
    out["countries"] = packed;
    out["generation"] = static_cast<int64_t>(front->generation);
    return out;
}

Dictionary DCWorldExt::get_derived_materialize_report() const {
    Dictionary out;
    if (_ideology_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    // `runtime_from()` is specialised per runtime type, so it cannot be reused
    // here; `_ideology_runtime` is stored as `void *` (world_ext.h:3416) and
    // the concrete type is known from the include.
    const auto *ideology = static_cast<const NativeIdeologyRuntime *>(
        _ideology_runtime);
    if (ideology == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    const DerivedMaterializeReport &report = ideology->derived_materialize_report();
    out["ok"] = true;
    out["programs_seen"] = report.programs_seen;
    out["programs_derived"] = report.programs_derived;
    out["programs_skipped_legacy"] = report.programs_skipped_legacy;
    out["cells_visited"] = report.cells_visited;
    out["commands_folded"] = report.commands_folded;
    out["rows_emitted"] = report.rows_emitted;
    // See the comment on `report_rows["rebuild_backlog_cells"]`: this is the fold's
    // remaining work, not a synonym for `cells_visited`.
    out["rebuild_backlog_cells"] = report.rebuild_backlog_cells;
    out["rebuild_backlog_peak_cells"] = report.rebuild_backlog_peak_cells;
    out["allocations"] = report.allocations;
    out["scratch_bytes"] = static_cast<int64_t>(report.scratch_bytes);
    out["scratch_nodes"] = static_cast<int64_t>(report.scratch_nodes);
    // Hard §12.4 condition: the derived path must never truncate. Surfaced
    // explicitly so a regression fails a test rather than silently dropping
    // targets.
    out["truncated"] = report.truncated;
    out["missing_stat"] = report.missing_stat;
    return out;
}

Dictionary DCWorldExt::get_derived_cell_layer_report() const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const auto ideology_view = _runtime_host && _runtime_host->effect_adapter_owned()
        ? _runtime_host->latest_ideology_read_view() : nullptr;
    const DerivedCellFront *layer = ideology_view ? ideology_view->derived.get()
        : runtime_from(_modifier_runtime)->derived_cell_front();
    out["ok"] = true;
    out["installed"] = layer != nullptr;
    out["layer_generation"] = static_cast<int64_t>(
        ideology_view ? (layer ? layer->generation : 0)
                      : runtime_from(_modifier_runtime)->derived_cell_layer_generation());
    if (layer == nullptr) {
        out["stat_count"] = int64_t{0};
        out["cell_count"] = int64_t{0};
        out["stat_ids"] = PackedInt32Array();
        return out;
    }
    // STRUCTURAL MEMORY (§18.3 "front/candidate/retained/scratch peak").
    //
    // The front is the dominant resident term: one `DerivedCellContribution` plus one
    // cell id per (stat, cell). Reporting the size from the structure rather than from a
    // heap sample keeps it deterministic -- a heap counter would make the number depend
    // on allocator behaviour, which is not what the gate is about.
    //
    // These are BYTES OF THE FRONT, not process RSS. Said plainly so nobody reads 57 KB
    // as "the whole migration costs 57 KB".
    int64_t front_bytes = 0;
    int64_t contribution_count = 0;
    int64_t row_overhead_bytes = 0;
    {
        const DerivedCellFront *front = layer;
        if (front != nullptr) {
            // ONE formula for both the report and the peak tracker:
            // `pk::derived_cell_front_bytes` in `derived_cell_layer.h`. It also counts
            // `stat_versions`, which this inline copy used to miss -- two size formulas
            // for one structure is the same drift pattern as the kind-16 cap.
            front_bytes = pk::derived_cell_front_bytes(*front);
            for (const DerivedCellStatRow &row : front->rows)
                contribution_count += static_cast<int64_t>(row.contributions.size());
            row_overhead_bytes =
                static_cast<int64_t>(front->rows.size()) *
                static_cast<int64_t>(sizeof(DerivedCellStatRow));
        }
    }
    out["front_bytes"] = front_bytes;
    out["front_row_overhead_bytes"] = row_overhead_bytes;
    out["contribution_count"] = contribution_count;
    out["contribution_bytes"] = static_cast<int64_t>(sizeof(DerivedCellContribution));
    // `stat_versions` is sized by the STAT-ID SPACE, not by the number of rows, so it is
    // reported separately: without this term the identity "front_bytes == cells + contribs
    // + row overhead" no longer closes. Exported so a fixture can verify the whole sum
    // instead of hard-coding the difference.
    out["stat_versions_bytes"] = layer != nullptr
        ? static_cast<int64_t>(layer->stat_versions.size()) *
              static_cast<int64_t>(sizeof(uint64_t))
        : int64_t{0};
    out["bytes_per_contribution"] =
        static_cast<int64_t>(sizeof(int32_t)) +
        static_cast<int64_t>(sizeof(DerivedCellContribution));

    PackedInt32Array stat_ids;
    int64_t cell_count = 0;
    for (const DerivedCellStatRow &row : layer->rows) {
        stat_ids.append(row.stat_id);
        cell_count += static_cast<int64_t>(row.cells.size());
    }
    out["stat_count"] = static_cast<int64_t>(layer->rows.size());
    out["cell_count"] = cell_count;
    out["stat_ids"] = stat_ids;
    out["sample_day"] = layer->sample_day;
    out["epoch_id"] = static_cast<int64_t>(layer->epoch_id);
    return out;
}

Dictionary DCWorldExt::apply_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    out["applied"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER)) {
        out["ok"] = true;
        out["reason"] = "modifier_not_worker_authoritative";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    RuntimeCommit display = _runtime_display_commit;
    if (!display.day_tail) _runtime_host->poll_commit(0, display);
    const auto committed = display.day_tail ? display.day_tail->modifier : nullptr;
    RuntimeModifierPodSnapshot legacy;
    if (!committed) {
        // A partial executor still publishes this view before its other
        // domains have settled. Copy it only at a day boundary.
        auto boundary = _runtime_host->try_lock_economy_read_boundary();
        if (!boundary.owns_lock()) {
            out["ok"] = true;
            out["reason"] = "economy_day_inflight";
            return out;
        }
        uint32_t slot = 0;
        if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
            out["ok"] = true;
            return out;
        }
        legacy = _runtime_host->modifier_snapshot_buffer(slot);
        _runtime_host->release_modifier_snapshot(slot);
    }
    const auto &snapshot = committed ? *committed : legacy;
    if (snapshot.generation <= cursor) {
        out["ok"] = true;
        return out;
    }
    const int64_t generation = static_cast<int64_t>(snapshot.generation);
    const int64_t committed_day = snapshot.committed_day;
    const int64_t state_hash = static_cast<int64_t>(snapshot.state_hash);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    std::string apply_error;
    const bool applied =
        runtime_from(_modifier_runtime)->apply_pod_snapshot(snapshot, apply_error);
    out["ok"] = applied;
    out["available"] = true;
    out["applied"] = applied;
    out["generation"] = generation;
    out["committed_day"] = committed_day;
    out["state_hash"] = state_hash;
    out["reason"] = applied ? "" : String(apply_error.c_str());
    return out;
}

Dictionary DCWorldExt::runtime_modifier_pod_self_test() const {
    std::string error;
    const bool authority_ok = RuntimeModifierPodAuthority::self_test(error);
    NativeSimulationHost protocol_host;
    const bool protocol_ok = authority_ok && protocol_host.modifier_pod_self_test(&error);
    const bool ok = authority_ok && protocol_ok;
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = ok ? "" : String(error.c_str());
    out["implemented_domain_mask"] = static_cast<int64_t>(
        NativeSimulationHost::implemented_domain_mask());
    return out;
}
