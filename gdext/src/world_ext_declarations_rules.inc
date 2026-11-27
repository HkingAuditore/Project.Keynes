// Effect, Modifier, Ideology, Trigger, and event bindings.

    // ---- bindings: effect ----
    godot::Dictionary apply_runtime_effect_snapshot(int64_t after_generation);
    // Generic Effect Runtime. It owns immutable effect programs, active
    // instances, plans and cross-domain ACK state; domain runtimes own all
    // authoritative mutations.
    godot::Dictionary configure_effects(const godot::Dictionary &catalog);
    godot::Dictionary submit_effect_instances(const godot::Dictionary &batch);
    godot::Dictionary retire_effect_instance(int64_t instance_id, int64_t generation,
                                             int64_t effective_day);
    // Test seam for the M2a effect-authority split. mode: -1 = live host
    // authority (production), 0 = force legacy EffectRuntime writes,
    // 1 = force the worker transport. See EffectInstanceForwarder's declaration
    // for why the real grant cannot be produced by a headless fixture.
    godot::Dictionary set_effect_forwarder_authority_for_test(int32_t mode);
    godot::Dictionary queue_effect_pod_instance(const godot::Dictionary &input);
    godot::Dictionary queue_effect_pod_metric(const godot::Dictionary &input);
    godot::Dictionary queue_effect_pod_remove(int64_t instance_id, int64_t generation);
    godot::Dictionary poll_effect_worker_intent();
    godot::Dictionary submit_effect_worker_ack(const godot::Dictionary &ack);
    bool effect_instance_fire_acked(int64_t instance_id, int64_t generation) const;
    // `{ok, value, present}` for one published Effect metric. Presence is
    // reported separately from the value so "published 0" and "never published"
    // stay distinguishable -- the whole point of the ideology metric publisher.
    godot::Dictionary query_effect_instance_metric(int64_t instance_id,
                                                   int32_t metric_id) const;
    godot::Dictionary submit_effect_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_effect_daily(int64_t day_index);
    godot::Dictionary dispatch_effect_native_modifier();
    godot::Dictionary ack_effect_native_modifier();
    godot::Dictionary dispatch_effect_native_country();
    godot::Dictionary ack_effect_native_country();
    godot::Dictionary settle_orphaned_effect_native_country_acks();
    godot::Dictionary dispatch_effect_native_economy();
    godot::Dictionary ack_effect_native_economy();
    godot::Dictionary dispatch_effect_native_gameplay();
    godot::Dictionary ack_effect_native_gameplay();
    // Read-only state of native Effect ingress queues.  Save coordination
    // uses this to reject a cross-section snapshot before a domain ACK.
    godot::Dictionary get_effect_native_adapter_report() const;
    bool effect_should_run(int64_t day_index) const;
    godot::Dictionary poll_effect_transactions(int64_t after_transaction_id,
                                               int limit = 128) const;
    godot::Dictionary preflight_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary commit_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary ack_effect_transactions(const godot::Dictionary &batch);
    godot::Dictionary explain_effect(int64_t instance_id) const;
    godot::Dictionary get_effect_report() const;
    godot::PackedByteArray capture_effect_state() const;
    godot::Dictionary restore_effect_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_effect_state();
    godot::Dictionary bind_era_reward_player_country(int64_t country_handle);
    godot::Dictionary get_era_reward_offer();
    godot::Dictionary submit_era_advancement(const godot::String &action,
        int64_t country, int64_t day, int64_t sequence, const godot::Dictionary &data);
    godot::Dictionary get_era_advancement_view() const;
    godot::Dictionary choose_era_reward(int64_t offer_generation,
                                        int choice_index,
                                        int64_t effective_day, int64_t sequence = 0);

    // ---- bindings: modifier ----
    // Shared data-oriented Modifier runtime. Four domain stores are isolated;
    // this facade is the only GDScript mutation boundary.
    godot::Dictionary configure_modifiers(const godot::Dictionary &catalog,
                                          int cell_count);
    godot::Dictionary submit_modifier_commands(const godot::Dictionary &packed_batch);
    godot::Dictionary run_modifier_daily(int64_t day_index);
    bool modifier_should_run(int64_t day_index) const;
    godot::Dictionary get_modifier_command_result(int64_t request_id) const;
    godot::Dictionary list_modifiers(int domain, int64_t entity_handle,
                                     const godot::String &stat_key) const;
    godot::Dictionary explain_modifier_stat(int domain, int64_t entity_handle,
                                            int64_t group_handle,
                                            const godot::String &stat_key,
                                            double base_value) const;
    godot::Dictionary get_modifier_report() const;
    // P3 step 1: what one authored modifier definition does, as
    // [{stat_id, operation, value}]. Read-only; the coefficient plane uses it to
    // turn "card -> definition" into a per-cell stat delta.
    godot::Dictionary resolve_modifier_definition_terms(
        const godot::String &definition_key) const;
    // Evaluates one effect program against caller-supplied metric samples
    // (plan §15.5, M3). Exposed so a test can prove a Ramp produces DIFFERENT
    // magnitudes for different metric inputs -- the exit condition
    // "same country, different cells, different ramp values".
    //
    // `metric_values` is indexed by metric id; ids past its end read 0.
    godot::Dictionary evaluate_effect_program_magnitude(
        const godot::String &program_key,
        const godot::PackedInt64Array &metric_values) const;
    // Builds a derived cell front from an explicit term list, with an optional
    // synthetic ramp sampler (plan §15.5, M3).
    //
    // Exists because the production path needs a live economy epoch to produce
    // metric samples, and that fixture gap has blocked end-to-end verification
    // five times. This lets a test drive the MATERIALIZER's per-cell ramp branch
    // directly, which is what M3's exit condition is actually about.
    //
    // `sampler_scale` < 0 means "supply no sampler", so the caller can assert the
    // deferred-without-sampler behaviour.
    godot::Dictionary build_derived_cell_front_for_test(
        const godot::Dictionary &terms) const;
    godot::Dictionary poll_modifier_events(int64_t after_event_id,
                                           int limit = 128) const;
    double evaluate_modifier_stat(int domain, int64_t entity_handle,
                                  int64_t group_handle,
                                  const godot::String &stat_key,
                                  double base_value) const;
    int64_t register_gameplay_modifier_object(const godot::String &archetype);
    godot::Dictionary unregister_gameplay_modifier_object(int64_t handle,
                                                          int64_t day_index);
    godot::Dictionary set_gameplay_modifier_base(int64_t handle,
                                                 const godot::String &stat_key,
                                                 double value);
    godot::Dictionary get_gameplay_modifier_effective(int64_t handle,
                                                      int64_t group_handle,
                                                      const godot::String &stat_key) const;
    godot::PackedByteArray capture_modifier_domain(int domain) const;
    godot::Dictionary restore_modifier_domain(int domain,
                                              const godot::PackedByteArray &bytes);
    godot::Dictionary clear_modifier_domain(int domain);
    godot::Dictionary get_runtime_modifier_snapshot(int64_t after_generation);
    godot::Dictionary apply_runtime_modifier_snapshot(int64_t after_generation);
    // Derived cell layer (plan 22 ADR01/ADR02). These are the ONLY Godot-facing
    // entry points for the layer, and they exist so a test can prove ADR02:
    // that a `apply_runtime_modifier_snapshot` rebuild does not clear it.
    //
    // Production callers are the Economy freeze coordinator, not GDScript; see
    // plan §4.2 ("the install entry is defined by Modifier and accepts only an
    // already-frozen, identity-bearing immutable result").
    godot::Dictionary install_derived_cell_layer_for_test(
        const godot::Dictionary &front);
    godot::Dictionary get_derived_cell_layer_report() const;
    // Last materializer report (plan §12.4). Exposed so a test can assert
    // `truncated == 0` directly instead of inferring it from row counts --
    // "no truncation" is the whole point of the migration, so it deserves an
    // observable rather than an assumption.
    godot::Dictionary get_derived_materialize_report() const;
    // Provenance report for the INSTALLED derived front: how many distinct source
    // countries contributed to each (stat, cell), and how many cells were covered by
    // more than one.
    //
    // Why this exists: a border cell can be covered by two countries' cards, and the
    // RESOLVED VALUE cannot tell them apart -- two sources contributing 0.5 + 0.5
    // resolve identically to one contributing 1.0. Plan §15.6/B10 asks for
    // "multi-country sources affecting the same border target" and for source
    // revocation, and neither is answerable without this count.
    godot::Dictionary get_derived_multi_country_report() const;
    // Drives the REAL fan-out ownership filter and returns the surviving cells.
    //
    // Why a bridge: proving "OWN and FOREIGN differ across a border" needs a card whose
    // `target_selector_param[0]` carries the scope bits, and rewriting a compiled
    // catalog card from GDScript is not possible. Rather than fabricate a card, this
    // calls the same `apply_fan_out_ownership_filter` the production path calls, on a
    // real two-country world.
    //
    // `dilate_depth > 0` additionally runs the BATCH dilation over the collected
    // sources and returns those cells, so a fixture can time the fan-out path
    // (one pass) rather than the per-source loop it replaced.
    //
    // Returns { ok, scope, sources, raw_cells, kept_cells, cells[, dilated_cells] }.
    // The MERGED value of one modifier stat on one cell, plus the derived layer's own
    // contribution to it.
    //
    // WHY THIS EXISTS
    //
    // The derived front is keyed by (stat, cell) but exposed only as COUNTS
    // (`get_derived_cell_layer_report` -> cell_count / stat_count). That made the
    // layer's actual numbers unobservable, which is why the old v1 plane could not be
    // deleted: its test coverage (ADD vs MULTIPLY, and the SUBTRACT sign coming from the
    // definition rather than the magnitude) had no derived-layer equivalent to move to.
    //
    // `value` comes from `ModifierRuntime::effective_value`, i.e. the same call the
    // production hot path makes, so this reports what the game would really see rather
    // than a re-derivation.
    godot::Dictionary get_effective_stat_value(const godot::String &stat_key,
                                               int64_t cell, int64_t entity_handle,
                                               double base_value) const;
    godot::Dictionary probe_fan_out_ownership(int64_t country_handle, int64_t source_cell,
                                              int64_t selector_kind, int64_t param0,
                                              int64_t param1,
                                              int64_t dilate_depth = 0) const;
    // Drains the sharded derived rebuild for `day`.
    //
    // The rebuild became a slice stage (plan §14.3: a 6400-cell materialise costs
    // 1.28 ms against a 1 ms gate), so ONE `run_ideology_daily` call no longer
    // publishes it. A caller that needs the layer immediately -- a fixture, or the UI
    // right after a day -- has to drain. Without this every consumer had to guess a
    // call count, and the guesses that existed silently read an empty front.
    //
    // Returns { ok, steps, complete }.
    godot::Dictionary drain_derived_cell_layer(int64_t day_index);
    // ── I01 probes (plan 22 §4.5 / §13.4 `catalog` row) ────────────────────
    //
    // NOTE: a `describe_cell_program_backends` bridge (walking the compiled catalog
    // and counting DerivedCell vs EffectInstance) was designed but NOT built: it
    // needs three EffectRuntime accessors that do not exist yet
    // (`program_count_for_backend_report`, `program_key_at`,
    // `program_describe_backend_probe`). The static coverage tool remains the
    // authority on the catalogue-wide split; the two probes below cover the
    // per-facts assertions. Both are read-only and touch no runtime state.
    godot::Dictionary probe_cell_program_backend(
        const godot::Dictionary &facts) const;
    // The staged rollout state (plan §15). Separate from capability on purpose: a
    // milestone flip must not change what the backend can express.
    godot::Dictionary get_cell_program_rollout() const;
    // Resolve a stat key to its dense id and clamp ceiling. Needed by the merge
    // contract test: the ceiling depends on the catalog, so hardcoding it would
    // make the test pass today and lie tomorrow.
    godot::Dictionary resolve_modifier_stat(const godot::String &stat_key) const;
    // Read-only scope enumeration, exposed so a test can prove the derived-layer
    // union (plan §8.5). Pure read: no state, no versions, no side effects.
    // Combined revision of a stat subset, INCLUDING the derived layer (plan
    // §8.6). Exposed so a test can prove that a derived install invalidates the
    // readers' caches while an idle day does not.
    int64_t modifier_stat_bucket_version(int domain,
                                         const godot::PackedInt32Array &stat_ids) const;
    godot::Dictionary collect_modifier_scope_ids(int domain, int scope,
                                                 const godot::PackedInt32Array &stat_ids) const;
    godot::Dictionary collect_modifier_scope_stat_entries(
        int domain, int scope, const godot::PackedInt32Array &stat_ids) const;
    godot::Dictionary runtime_modifier_pod_self_test() const;
    int64_t ensure_modifier_building_handle(int cell, int type_id,
                                            int owner_signature_id);

    // ---- bindings: ideology ----
    // Native ideology authority.  It owns only country-scoped ideology
    // collection/progression state and delegates domain effects elsewhere.
    godot::Dictionary configure_ideologies(const godot::Dictionary &catalog);
    godot::Dictionary submit_ideology_commands(const godot::Dictionary &batch);
    godot::Dictionary poll_ideology_receipts(int64_t after_receipt_id,
                                             int32_t limit) const;
    godot::Dictionary run_ideology_daily(int64_t day_index);
    bool ideology_should_run(int64_t day_index) const;
    bool ideology_needs_daily_continuation(int64_t day_index) const;
    godot::Dictionary step_ideology_instance_refresh(int64_t day_index);
    // Worker-authority pump for the DERIVED half, symmetric to the instance refresh.
    // Needed because `run_ideology_daily` is suppressed when the worker owns IDEOLOGY.
    // Throttling is the CALLER's job -- see the comment on the definition.
    godot::Dictionary step_ideology_derived_rebuild(int64_t day_index);
    godot::Dictionary apply_runtime_ideology_snapshot(int64_t after_generation);
    godot::Dictionary get_ideology_snapshot(int64_t country_handle) const;
    // Diagnostic: reconciled Effect instances owned by each held idea, with a
    // `present` flag proving the EffectRuntime still holds them. Read-only.
    godot::Dictionary get_ideology_effect_instance_report(int64_t country_handle) const;
    // Where each held card acts, instance and derived backends alike.
    godot::Dictionary get_ideology_effect_target_report(int64_t country_handle) const;
    // Per-cell output factor after the Modifier rows AND the Ideology plane have
    // been folded in. Test/diagnostic seam for the coefficient plane.
    godot::Dictionary get_city_output_factor_q16(int32_t cell, int32_t good_id) const;
    godot::Dictionary resolve_effect_program_modifier_commands(
        const godot::String &program_key) const;
    godot::Dictionary reconcile_ideology_effects_for_test(int64_t country_handle);
    godot::Dictionary apply_ideology_self_snapshot_for_test(int64_t generation);
    // Read-only query over the shared target-cell resolver. Content tooling and
    // tests use it to prove a selector is deterministic and bounded before a
    // card is authored against it. Never mutates state.
    godot::PackedInt32Array query_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0,
        int32_t param1) const;
    // Lowest cell owned by `country_slot`, or -1. Anchors cell-scoped ideology
    // effects until a capital/city concept exists.
    int32_t query_country_anchor_cell(int32_t country_slot) const;
    // True when the compiled Effect catalog declares `program_key` as a managed
    // program. Lets tests and tooling assert that a card row is routed through
    // the reconciliation path instead of the legacy Modifier batch.
    bool effect_program_is_managed(const godot::String &program_key) const;
    godot::Dictionary preview_ideology_offer_eligibility(int64_t country_handle) const;
    godot::Dictionary explain_ideology(int64_t country_handle, int32_t ideology_id);
    godot::Dictionary explain_ideologies(
        int64_t country_handle,
        const godot::PackedInt32Array &ideology_ids);
    godot::Dictionary get_ideology_report() const;
    // Business-only state (no transport fields), for comparing two worlds or a
    // main thread against a worker. Same sections and hash the parity report uses.
    godot::Dictionary get_ideology_business_state() const;
    int64_t compute_idea_activation_signature_for_test(int64_t handle,
                                                      int32_t ideology_id);
    godot::PackedByteArray capture_ideology_state() const;
    godot::Dictionary restore_ideology_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_ideology_state();
    godot::Dictionary publish_ideology_worker_inputs();
    godot::Dictionary poll_ideology_worker_intent();
    godot::Dictionary submit_ideology_worker_ack(
        const godot::Dictionary &ack);

    // ---- bindings: trigger ----
    // Generic trigger runtime. It only ingests committed facts/snapshots and
    // emits typed effects; domain stores apply those effects at their own
    // safe boundary.
    godot::Dictionary configure_triggers(const godot::Dictionary &catalog);
    godot::Dictionary submit_trigger_events(const godot::Dictionary &batch);
    godot::Dictionary submit_trigger_snapshots(const godot::Dictionary &batch);
    godot::Dictionary run_trigger_daily(int64_t day_index);
    bool trigger_should_run(int64_t day_index) const;
    // H8 ACTIVE Trigger authority. When the worker owns TRIGGER_INPUT the
    // main thread stops running the daily kernel and instead writes the worker
    // snapshot back into the facade, plus relays the Trigger->Effect ACK
    // barrier when the in-worker bridge is not used.
    bool trigger_worker_authoritative() const;
    godot::Dictionary apply_runtime_trigger_snapshot(int64_t after_generation = -1);
    godot::Dictionary poll_trigger_worker_intent();
    godot::Dictionary submit_trigger_worker_ack(const godot::Dictionary &source);
    godot::Dictionary poll_trigger_effects(int64_t after_effect_id,
                                            int limit = 128) const;
    godot::Dictionary ack_trigger_effects(int64_t up_to_effect_id);
    // Delivery ACK by explicit effect id. Effect ids are allocated at ingress
    // while delivery order is canonical (effective_day/source_priority/...), so
    // a numeric high-water cursor can delete an effect that was never handed
    // off. Callers must ack exactly the id set returned by handoff_effects().
    godot::Dictionary ack_trigger_effect_ids(const godot::PackedInt64Array &effect_ids);
    godot::Dictionary reconcile_completed_research_signals(int limit = 64);
    godot::Dictionary handoff_trigger_effects(int limit = 128);
    godot::Dictionary set_trigger_enabled(const godot::Dictionary &batch);
    godot::Dictionary reconcile_trigger_branch_bindings(const godot::Dictionary &batch);
    godot::Dictionary get_trigger_branch_progress(int64_t branch_handle) const;
    godot::Dictionary get_development_progress(int64_t country_handle,
                                               int32_t era_index) const;
    godot::Dictionary resync_trigger_source(const godot::Dictionary &snapshot);
    godot::Dictionary get_trigger_report() const;
    godot::PackedByteArray capture_trigger_state() const;
    godot::Dictionary restore_trigger_state(const godot::PackedByteArray &bytes);
    godot::Dictionary clear_trigger_state();
    // Recovery backfill for ONE_SHOT development achievements whose completed
    // record survived a load but whose permanent Country research signal did
    // not. Re-enqueues the single COUNTRY_COMMAND signal effect at day-1 so it
    // delivers at `day`; the Country DISCOVER_SIGNAL command dedupes by
    // (signal, cell), which makes repeated replay idempotent.
    godot::Dictionary replay_completed_research_signal(int64_t trigger_id,
        int64_t target, int64_t cell, int64_t day);

    // ---- bindings: events ----
    bool gameplay_effect_should_run(int64_t day_index) const;
    godot::Dictionary run_gameplay_effects(int64_t day_index);
    godot::PackedInt32Array consume_canal_visual_dirty_cells();
    // ─── Gameplay event bus（2026-06-26）────────────────────────────────
    // 通用、可持久化/可回放的 gameplay event log。C++ pass 和 GDScript 都通过
    // 同一 columnar schema 发布事件；消费者用独立 cursor poll/ack，避免视觉、
    // UI、debug 互相抢事件。事件日志只保存 POD/packed payload，不持有 Godot
    // Object 引用，方便 save/replay。
    godot::Dictionary get_gameplay_event_schema() const;
    godot::Dictionary publish_gameplay_events(godot::Dictionary batch);
    godot::Dictionary poll_gameplay_events(godot::Dictionary opts);
    godot::Dictionary ack_gameplay_events(godot::StringName consumer_id, int64_t up_to_event_id);
    godot::Dictionary replay_gameplay_events(godot::Dictionary opts) const;
    godot::Dictionary snapshot_gameplay_event_journal(godot::Dictionary opts) const;
    godot::Dictionary restore_gameplay_event_journal(godot::Dictionary snapshot);
    godot::Dictionary clear_gameplay_events(godot::Dictionary opts);
    godot::Dictionary get_gameplay_event_bus_report() const;
    bool configure_gameplay_narrative(godot::Dictionary packet, godot::Dictionary state);
    godot::Dictionary get_gameplay_narrative_view() const;
    godot::Dictionary capture_gameplay_narrative() const;
    godot::Dictionary submit_gameplay_narrative(godot::StringName kind, godot::Dictionary args);
    godot::Dictionary poll_runtime_events_snapshot(int64_t after_generation = 0);
