// Economy bindings and committed projections.

    // ---- bindings: economy ----
    godot::Dictionary get_economy_checkpoint_format() const;
    // Diagnoses ONE `get_family_colonization_quotes` rejection (plan 22 M3-6/M3-7).
    //
    // The public quotes call collapses six distinct gates into
    // `colonization_target_invalid` (`economy_runtime_colonization.cpp:448-490`), so
    // a caller cannot tell "not visible" from "already owned" from
    // "topology not ready". Two rounds were spent guessing between them.
    //
    // This reports each gate separately for one cell. Read-only; no runtime state
    // is touched.
    godot::Dictionary diagnose_colonization_target(
        int64_t country_handle, int target_cell) const;
    godot::Dictionary apply_runtime_economy_resource_writeback();
    godot::Dictionary get_country_fiscal_snapshot(int64_t handle) const;
    godot::Dictionary get_country_trade_snapshot(
        int64_t handle, const godot::String &view = "summary",
        int offset = 0, int limit = 32) const;
    godot::Dictionary get_country_economy_overview(
        int64_t handle, const godot::String &view = "summary",
        int scope_cell = -1, int filter_id = -1, int offset = 0,
        int limit = 0) const;
    // ─── Native economy runtime / ECONOMY_GRAPH ────────────────────────
    // Economy owns dynamic PopulationCohort pages, local-market matrices,
    // deterministic formula execution and committed publication. It is
    // deliberately independent from the per-cell component slots above.
    godot::Dictionary configure_economy(const godot::Dictionary &catalog,
                                        const godot::Dictionary &profile,
                                        int cell_count,
                                        int64_t seed);
    // Hands ResourceProfileRegistry.build_pass_knobs() to the economy so a
    // worker-owned economy regenerates its own reserves.
    godot::Dictionary configure_economy_natural_resources(const godot::Dictionary &knobs);
    godot::Dictionary bootstrap_economy(const godot::Dictionary &population_packet,
                                        const godot::Dictionary &market_packet);
    godot::Dictionary submit_economy_commands(const godot::Dictionary &packed_batch);
    // Phase 4: Host POD command queue scaffolding (admission/receipt). Production
    // opcode apply remains submit_economy_commands → NativeEconomyRuntime.
    godot::Dictionary submit_economy_pod_commands(
        const godot::Dictionary &packed_batch);
    godot::Dictionary poll_economy_pod_receipts(int max_items = 128);
    godot::Dictionary run_economy_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_economy_slice_compact(const godot::Dictionary &ctx);
    // Phase-2.4.5: sync StageOps mutate day for dual-path soak parity tests.
    godot::Dictionary run_economy_stage_ops_day(int64_t day_index);
    void set_economy_stage_ops_soak_parity_ok(bool ok);
    bool get_economy_stage_ops_soak_parity_ok() const;
    // Main-thread Godot/MapData → NativeEconomyRuntime frozen input lanes.
    // Does not run economy mutation stages. Safe to call when ECONOMY is
    // worker-authoritative so compact slices can start_epoch without fatal.
    godot::Dictionary capture_economy_day_inputs(int64_t day_index);
    // Generation-aware input boundary. The day-only entry point above remains
    // available for existing callers and delegates with an empty generation.
    godot::Dictionary begin_or_reuse_economy_input_epoch(
        int64_t day_index, const godot::Dictionary &generation);
    bool economy_should_run(int64_t day_index) const;
    bool economy_deadline_critical(int64_t day_index) const;
    godot::PackedInt32Array get_economy_live_cells();
    // ---- end Economy military hooks ----
    godot::Dictionary get_economy_report() const;
    // R1-6: "which binary is this?" without requiring any runtime. A cold
    // `DCWorldExt.new()` (no economy bootstrapped, no worker) must still answer,
    // which is what the taxonomy test and a player bug report need.
    godot::String get_build_id() const;
    // The cold `get_economy_report()` shape, including build_id. Kept next to
    // get_build_id() so the two "no runtime yet" answers cannot drift apart.
    godot::Dictionary economy_unavailable_report() const;
    // Review §3: the effect-input digest buckets each metric by this quantum, so
    // sub-quantum drift stops re-signing every card. 0 keeps the old exact
    // behaviour, which is the default until the numbers are chosen.
    // The three-way split from review §3, as numbers: global (union), territory,
    // tag, and the per-metric array. A test can then assert that a metric no card
    // reads stays at 0, which is the whole point of splitting.
    godot::Dictionary get_effect_input_revisions() const;
    // Force one digest pass. Without this the gate tests can pass vacuously when
    // the fixture never commits a day.
    godot::Dictionary refresh_effect_input_digest_for_test();
    // Forces one metric to a chosen value for every cell; `has_value == false`
    // clears it. See the member comment: this exists so threshold crossings can be
    // tested exactly instead of approximated through the simulation.
    godot::Dictionary set_effect_metric_override_for_test(int32_t metric,
                                                          int64_t value,
                                                          bool has_value);
    // X9-b worker fixture: relax the authored family-target branch floor.
    godot::Dictionary set_family_target_min_branches_override_for_test(
        int32_t min_branches);
    // Force one catalog tag on or off for one cell while the economy samples
    // effect metrics. Test-only; add/remove semantics are immutable swaps.
    godot::Dictionary set_cell_tag_override_for_test(
        const godot::String &tag_key, int32_t cell, bool on);
    godot::Dictionary clear_cell_tag_overrides_for_test();
    // Test switch mirroring PK_TAG_FORCE_ALL: compute EVERY tag's bit instead of
    // narrowing to the tags some program consumes (M4-22). Lets a fixture query a tag
    // no program uses yet.
    void set_tag_force_all_for_test(bool force);
    // X14: the committed source revision/epoch and content hash the current
    // class-metric copy was taken from, plus the exact ids the copy used.
    godot::Dictionary get_class_metric_source_for_test() const;
    // Test-only: capture the current committed snapshot now, without waiting
    // for the next economy epoch boundary.
    godot::Dictionary capture_class_metric_source_for_test();
    godot::Dictionary set_class_opinion_source_override_for_test(
        godot::PackedInt64Array population,
        godot::PackedInt32Array satisfaction_q16,
        godot::PackedInt64Array satisfaction_weighted);
    godot::Dictionary clear_class_opinion_source_override_for_test();
    // X10 test-only bridge: replace the frozen country technology words with an
    // exact bitset, then run the same hash-gated metric refresh as epoch capture.
    godot::Dictionary set_country_technology_metric_input_for_test(
        int32_t country_slot, godot::PackedInt64Array words);
    godot::Dictionary clear_country_technology_metric_input_for_test();
    // R-4 X16: the frozen per-profession tax tolerance / satisfaction bias the
    // satisfaction loop will read, indexed by `profession_id`. Takes a COUNTRY SLOT
    // (from `get_country_cell_summary(...).country_slot`), not a handle.
    //
    // Modifier-side reads would answer a different question: a card can declare the
    // stat and still never reach a cohort if the epoch freeze does not pick it up.
    godot::Dictionary get_epoch_profession_report(int64_t country_slot) const;
    // R-4: sample ONE effect metric for ONE cell through the real sampling path,
    // without `set_effect_metric_override_for_test`. Used by the metric 68/69 tests,
    // which are about the live epoch accounting rather than about thresholds.
    godot::Dictionary sample_effect_metric_probe(int64_t metric, int64_t cell,
                                                 int64_t country_handle) const;
    godot::Dictionary get_economy_committed_audit_report() const;
    godot::Dictionary get_country_class_opinion_snapshot() const;
    godot::Dictionary get_population_cell_summary(int cell_idx) const;
    godot::Dictionary get_named_settlement_snapshot() const;
    godot::Dictionary get_settlement_delta(int64_t since_revision) const;
    godot::Dictionary get_population_cell_snapshot(
        int cell_idx, bool include_details = true) const;
    godot::Dictionary get_market_cell_snapshot(int cell_idx) const;
    godot::Dictionary explain_cohort_satisfaction(int64_t cohort_handle) const;
    godot::Dictionary get_cell_satisfaction_attractiveness(int cell_idx) const;
    godot::Dictionary get_trade_orders_for_cell(int cell_idx, int offset = 0,
                                                int limit = 64,
                                                int good_index = -1) const;
    godot::Dictionary capture_economy_trade_topology(
        const godot::PackedInt32Array &neighbor_indices,
        const godot::PackedByteArray &terrain,
        const godot::PackedByteArray &trade_passable_lut,
        const godot::PackedInt32Array &trade_move_cost_lut,
        int64_t generation = 0,
        const godot::PackedByteArray &landform = godot::PackedByteArray(),
        const godot::PackedByteArray &has_river = godot::PackedByteArray());
    godot::Dictionary get_trade_visual_snapshot(
        const godot::PackedInt32Array &cells,
        const godot::PackedByteArray &visible, int64_t vision_revision,
        int selected_cell = -1, bool enabled = true) const;
    godot::Dictionary capture_economy_trade_visibility(
        const godot::PackedByteArray &visible, bool fog_solved);
    godot::Dictionary get_building_cell_snapshot(int cell_idx) const;
    godot::Dictionary get_cell_situation_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    godot::Dictionary get_building_visual_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    godot::Dictionary consume_building_visual_dirty_cells();
    godot::Dictionary get_treasury_construction_quotes(
        int64_t country_handle, int cell_idx,
        const godot::PackedInt32Array &type_ids) const;
    godot::Dictionary get_construction_command_receipts(
        int64_t after_receipt_id, int limit = 64) const;
    // Formal player construction ingress. `submit_economy_commands` is
    // fail-closed while StageOps owns production, so the build request is
    // queued on the economy epoch boundary instead (canal lane contract).
    godot::Dictionary queue_treasury_sponsored_build(
        int64_t country_handle, int cell_idx, int type_id,
        int64_t effective_day, int64_t sequence);
    // Removal mirror of `queue_treasury_sponsored_build`: a state lot leaves the
    // economy ledger on the epoch boundary and the military bookkeeping command
    // is only forwarded afterwards (requirement 6.5).
    godot::Dictionary queue_treasury_sponsored_demolish(
        int64_t country_handle, int cell_idx, int type_id, int64_t count,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary get_canal_route_quote(
        int64_t country_handle, int start_cell, int end_cell,
        const godot::PackedInt32Array &waypoints);
    godot::Dictionary get_canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const;
    godot::Dictionary queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary get_canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int limit = 64) const;
    godot::Dictionary get_family_cell_snapshot(int cell_idx, int offset = 0,
                                                int limit = 64) const;
    godot::Dictionary get_family_snapshot(int64_t family_handle) const;
    godot::Dictionary get_family_traits(int64_t family_handle) const;
    godot::Dictionary get_family_branches(int64_t family_handle, int offset = 0,
                                           int limit = 64) const;
    godot::Dictionary get_family_colonization_quotes(
        int64_t country_handle, int target_cell, int64_t family_filter = 0,
        int source_filter = -1, int offset = 0, int limit = 64);
    godot::Dictionary get_family_colonization_quote_detail(
        int64_t quote_token, int64_t population = -1) const;
    godot::Dictionary start_family_colonization(
        int64_t country_handle, int64_t family_handle, int source_cell,
        int target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary cancel_family_colonization(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence);
    // Era advancement / national procurement budget (transient economy).
    godot::Dictionary set_country_procurement_policy(
        int64_t country_handle, bool enabled, int treasury_share_bp,
        int research_share_bp, int64_t effective_day, int64_t sequence,
        int era_share_bp = -1, int colonization_share_bp = -1);
    godot::Dictionary set_era_procurement_target(
        int64_t country_handle, bool active,
        const godot::PackedInt32Array &good_indices,
        const godot::PackedInt64Array &required_quantities,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary country_procurement_snapshot(int64_t country_handle) const;
    godot::Dictionary get_family_expeditions(
        int64_t country_handle, int offset = 0, int limit = 64) const;
    godot::Dictionary get_family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const;
    godot::Dictionary get_family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int limit = 64) const;
    godot::Dictionary get_family_branch_effects(int64_t family_handle,
                                                int cell_idx) const;
    godot::Dictionary submit_family_trait_commands(
        const godot::Dictionary &packed_batch);
    godot::Dictionary get_family_founding_offers(int offset = 0,
                                                 int limit = 16) const;
    godot::Dictionary submit_family_founding_choice(int64_t offer_id,
                                                    int64_t generation,
                                                    int choice_index,
                                                    int64_t effective_day,
                                                    int64_t sequence);
    godot::Dictionary get_family_industries(int64_t family_handle,
                                            int offset = 0,
                                            int limit = 64) const;
    godot::Dictionary get_family_notable_people(int64_t family_handle,
                                                int offset = 0,
                                                int limit = 64) const;
    godot::Dictionary get_notable_person_snapshot(int64_t person_handle) const;
    godot::Dictionary get_notable_person_needs(int64_t person_handle,
                                               int offset = 0,
                                               int limit = 32) const;
    godot::Dictionary get_building_notable_people(int64_t building_handle,
                                                  int offset = 0,
                                                  int limit = 64) const;
    godot::Dictionary get_economy_read_view_status() const;
    godot::Dictionary run_economy_production_climate_math_probe(
        const godot::Dictionary &vectors) const;
    int64_t get_economy_state_hash() const;
    godot::Dictionary inject_economy_cadence_timing(double market_cycle_ms,
                                                    double slow_cycle_ms,
                                                    double investment_cycle_ms = -1.0);
    godot::Dictionary reset_economy(const godot::String &reason);
    godot::Dictionary start_economy_csv_recording(const godot::Dictionary &config);
    godot::Dictionary request_stop_economy_csv_recording();
    godot::Dictionary get_economy_csv_recording_status() const;
    godot::Dictionary begin_economy_save(int chunk_bytes = 4 * 1024 * 1024);
    godot::Dictionary begin_economy_forensics_save(int chunk_bytes = 4 * 1024 * 1024);
    // R3: replay a `.pkinc` incident bundle offline. Owns an isolated runtime, so
    // it works without a loaded world and cannot touch the live economy.
    godot::Dictionary economy_replay_incident(const godot::Dictionary &incident);
    godot::PackedByteArray read_economy_save_chunk(int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_economy_save();
    godot::Dictionary capture_economy_ecp2(int flags = 0) const;
    godot::Dictionary restore_economy_ecp2(const godot::PackedByteArray &bytes);
    godot::Dictionary begin_economy_restore();
    godot::Dictionary feed_economy_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_economy_restore();
    godot::String get_economy_restore_rejected_reason() const;
    godot::Dictionary get_economy_event_schema() const;
    godot::Dictionary set_economy_trace_filter(const godot::Dictionary &filter);
    godot::Dictionary set_economy_inspector_trace_cell(int cell_idx);
    godot::Dictionary poll_economy_events(const godot::Dictionary &opts) const;
    godot::Dictionary ack_economy_events(godot::StringName consumer_id,
                                         int64_t up_to_event_id);
    godot::Dictionary get_economy_trace_report() const;
    godot::Dictionary begin_economy_event_archive(int chunk_bytes = 4 * 1024 * 1024);
    godot::PackedByteArray read_economy_event_archive_chunk(
        int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_economy_event_archive();
