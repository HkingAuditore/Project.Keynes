// Worker command inbox, country metrics, read projections, and effect tag publication.

    // Player commands submitted from the main thread while a worker owns this
    // runtime. Tracked command records and submit order may only be written
    // by the owning thread, so the worker folds these in at epoch start.
    struct WorkerCommandInbox {
        std::mutex mutex;
        std::vector<Command> commands;
    };
    std::unique_ptr<WorkerCommandInbox> _worker_command_inbox =
        std::make_unique<WorkerCommandInbox>();
    void enqueue_worker_command(const Command &command);
    void drain_worker_command_inbox();
    std::unordered_map<int64_t, EffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_idempotency_requests;
    int64_t _next_effect_request_id = 1;
    EconomyTrackedRecords<StructuralCommand> _structural_commands{{{14, 3}, "commands.structural_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<CellSummary> _committed_cells;
    std::vector<CellSummary> _staging_cells;
    std::vector<int32_t> _staging_touched_cells;
    // Per-task landing buffers for the market worker fan-out. Cells are
    // partitioned one-per-market, so summary/generation writes never alias
    // across tasks, but the touched list is a shared vector and must not be
    // grown concurrently. Merged back into _staging_touched_cells after join.
    std::vector<std::vector<int32_t>> _staging_touched_task_scratch;
    std::vector<uint32_t> _staging_cell_generation;
    uint32_t _staging_current_generation = 0;
    std::vector<int32_t> _structural_touched_cells;
    // BEGIN army personnel lane state (contract §1.1).
    // One row per army that currently holds embarked people. Authoritative,
    // persisted in PKEC schema 59 (SAVE_SECTION_ARMY_PERSONNEL); the handle ->
    // row index inside the store is derived and never saved.
    ArmyPersonnelStore _army_personnel;
    // END army personnel lane state
    std::vector<int32_t> _population_changed_cells;
    // Number of _structural_touched_cells entries already covered by this
    // epoch's structural_commit employment reconcile. building_commit.finalize
    // re-reconciles only the tail appended after that point (investment
    // profession transitions), instead of double-reconciling the full set.
    int64_t _structural_reconciled_upto = 0;
    // Cells whose cohorts were moved at the idle boundary between epochs
    // (colonization launch/landing/return). Epoch begin clears the touched
    // list, so these are handed to the next structural employment reconcile.
    std::vector<int32_t> _deferred_population_reconcile_cells;
    std::vector<int64_t> _prosperity_thresholds;
    std::vector<std::string> _prosperity_ids;
    std::vector<std::string> _prosperity_names;
    EconomyKeyedVariableRecords<std::string> _settlement_prefix_ids{{{26, 2}, "name_catalog.settlement_prefix_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_prefix_text;
    std::vector<int32_t> _settlement_prefix_weights;
    std::vector<std::string> _settlement_prefix_alias_ids;
    std::vector<std::string> _settlement_prefix_alias_targets;
    EconomyKeyedVariableRecords<std::string> _settlement_root_ids{{{26, 3}, "name_catalog.settlement_root_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_root_text;
    std::vector<int32_t> _settlement_root_weights;
    std::vector<std::string> _settlement_root_alias_ids;
    std::vector<std::string> _settlement_root_alias_targets;
    EconomyKeyedVariableRecords<std::string> _settlement_suffix_ids{{{26, 4}, "name_catalog.settlement_suffix_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_suffix_text;
    std::vector<int32_t> _settlement_suffix_weights;
    std::vector<std::string> _settlement_suffix_alias_ids;
    std::vector<std::string> _settlement_suffix_alias_targets;
    EconomyOwnedRecordValue<std::string> _settlement_name_pack_id{
        {{26, 5}, "name_catalog.pack_id", EconomyFieldEncoding::CanonicalRecord, 1}, "default_zh"};
    EconomyKeyedVariableRecords<std::string> _settlement_full_name_ids{{{26, 1}, "name_catalog.settlement_full_name_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<std::string> _settlement_full_name_text;
    std::vector<int32_t> _settlement_full_name_weights;
    std::vector<std::string> _settlement_full_name_alias_ids;
    std::vector<std::string> _settlement_full_name_alias_targets;
    int32_t _settlement_full_name_share_q16 = 32768;
    int32_t _settlement_named_tier = 2;
    int32_t _settlement_downgrade_bp = 9000;
    EconomyTrackedScalar<int64_t> _prosperity_profile_hash{_metadata_changes, {{15, 27}, "metadata.prosperity_profile_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _settlement_catalog_hash = 0;
    int64_t _prosperity_changed_cells = 0;
    int64_t _prosperity_promotions = 0;
    int64_t _prosperity_demotions = 0;
    int64_t _settlement_names_assigned = 0;
    int64_t _settlement_names_released = 0;
    int64_t _settlement_name_collision_probes = 0;
    double _prosperity_update_ms = 0.0;
    int64_t _structural_funds_to_treasury = 0;

    std::vector<std::string> _building_type_ids;
	std::vector<int32_t> _building_kinds;
    std::vector<int32_t> _building_economic_sectors;
	std::vector<std::string> _building_upgrade_family_ids;
	std::vector<int32_t> _building_upgrade_family_indices;
	std::vector<int32_t> _building_upgrade_tiers;
    // Immutable derived catalog, shared by every cell's chain metric. It is
    // rebuilt at configure, not while sampling a cell or switching OwnedState.
    std::vector<uint32_t> _building_upgrade_required_tiers;
    uint64_t _building_upgrade_catalog_builds = 0;
    uint64_t _building_upgrade_catalog_rows = 0;
	std::vector<int32_t> _building_technology_tag_offsets;
	std::vector<std::string> _building_technology_tags;
	std::vector<int32_t> _building_required_technology_tag_offsets;
	std::vector<std::string> _building_required_technology_tags;
    std::vector<uint32_t> _building_technology_practice_masks;
    std::array<int32_t, 28> _breakthrough_signal_ids{};
    int32_t _bio_maize_signal_id = -1;
    std::array<int32_t, 8> _metal_resource_signal_ids{
        -1, -1, -1, -1, -1, -1, -1, -1};
    std::vector<uint64_t> _research_signal_prefix_masks;
    int32_t _research_signal_prefix_words = 0;
    int32_t _abundant_mountain_landform_id = -1;
    int32_t _abundant_forest_terrain_id = -1;
    bool _catalog_geography_lookup_warning_emitted = false;
    std::vector<int32_t> _building_technology_offsets;
    std::vector<int32_t> _building_required_technologies;
    std::vector<int32_t> _building_all_technology_offsets;
    std::vector<int32_t> _building_all_required_technologies;
    // Material/resource dependency gates compiled from Good/Resource technology
    // tags. Operating availability requires every input/output/resource group
    // to have at least one completed technology tag. Construction-good groups
    // (kind 1) gate new builds via good_market_available / material planning,
    // not already-standing lots.
    std::vector<int32_t> _building_dependency_branch_offsets;
    std::vector<int32_t> _building_dependency_branch_technologies;
    std::vector<int32_t> _building_dependency_branch_technology_offsets;
    std::vector<int32_t> _building_dependency_branch_group_offsets;
    std::vector<uint8_t> _building_dependency_kinds;
    std::vector<int32_t> _building_dependency_ids;
    std::vector<int32_t> _building_dependency_tag_offsets;
    std::vector<int32_t> _building_dependency_tags;
    std::vector<std::string> _technology_ids;
    int32_t _water_tech_river = -1;
    int32_t _water_tech_shallow = -1;
    int32_t _water_tech_far = -1;
    int32_t _water_tech_deep = -1;
    std::vector<int32_t> _development_metric_signal_indices;
    std::vector<int32_t> _development_metric_era_indices;
    std::vector<int32_t> _development_metric_types;
    std::vector<int32_t> _development_metric_subject_kinds;
    std::vector<int32_t> _development_metric_subject_offsets;
    std::vector<int32_t> _development_metric_subject_indices;
    std::vector<int64_t> _development_metric_qualifier_thresholds;
    std::vector<int32_t> _development_metric_duration_days;
    // Per country x metric publication state: below-qualifier samples only feed
    // the progress display, so they are throttled; qualified samples and the
    // drop below the qualifier are always published.
    static constexpr int64_t DEVELOPMENT_IDLE_FACT_INTERVAL_DAYS = 30;
    std::vector<uint64_t> _development_fact_country_handles;
    std::vector<int64_t> _development_fact_last_day;
    std::vector<uint8_t> _development_fact_qualified;
    int32_t _technology_words = 0;
    NativeCountryRuntime *_country_runtime = nullptr;
    EconomyHostPort *_simulation_host = nullptr;
    std::array<int64_t, ANNUAL_METRIC_COUNT> _annual_epoch_events{};
    std::vector<AnnualBreakdown> _annual_epoch_industries;
    EconomyCsvRecorder *_csv_recorder = nullptr; // facade-owned; destroyed after worker joins
    bool _sync_writes_forbidden = false;
    uint32_t _d7_operation_gate_mask = RUNTIME_ECONOMY_D7_FISCAL_GATE_MASK;
    ModifierRuntime *_modifier_runtime = nullptr;
    int32_t _family_scoped_output_stat_id = -1;
    int32_t _family_target_min_branches_override_for_test = 0;
    EffectRuntime *_effect_runtime = nullptr;
    EffectInstanceForwarder *_effect_forwarder = nullptr;
    TriggerRuntime *_trigger_runtime = nullptr;
    std::vector<int32_t> _epoch_cell_country;
#include "economy_runtime_internal_country_cache.h"
    // Country territory CSR, refreshed at the ownership capture boundary;
    // unchanged exact inputs reuse it. Derived: never persisted, never hashed.
    //
    // Why a copy on this side instead of reading the country pod's own CSR: the
    // pod rebuilds on its own schedule, and a target set that disagrees with the
    // ownership column the economy already trusts is worse than no target set at
    // all. Building from _epoch_cell_country makes "anchor cell" and "territory"
    // true statements about the same bytes by construction.
    //
    // When _epoch_country_cell_offsets is empty the consumers fall back to a
    // linear scan of _epoch_cell_country, so hand-built fixtures and the pre-index
    // path keep the old semantics.
    std::vector<int32_t> _epoch_country_cell_offsets;
    std::vector<int32_t> _epoch_country_cells;
    // Tag predicate table, copied from EffectRuntime at attach time.
    TargetTagTable _target_tags;
    // Per-epoch tag tables (tag bitset + X7 per-country counts), published as ONE
    // immutable snapshot.
    //
    // R-3: these used to be plain `std::vector` members. `capture_country_epoch`
    // cleared and refilled them on the owning thread while
    // `step_ideology_instance_refresh` -> `reconcile` iterated them on the main
    // thread without holding anything, so a reader could walk a buffer that had just
    // been freed. "Build it eagerly at commit" (R-3 first pass) did not fix that: it
    // still wrote the same vectors the reader was walking.
    //
    // Now the writer builds a `TagSnapshot` and `atomic_store`s it; every reader does
    // ONE `atomic_load` into a local shared_ptr and uses that for the whole read.
    // Swapping is therefore safe against a concurrent read by construction. Derived,
    // never persisted, never hashed.
    std::shared_ptr<const TagSnapshot> _tag_snapshot;
    // Test switch mirroring PK_TAG_FORCE_ALL: the epoch bitset normally narrows to the
    // tags some program consumes (M4-22), which makes a tag nobody consumes
    // unqueryable (`x13a` asserts exactly such a tag).
    bool _tag_force_all_for_test = false;
public:
    void set_tag_force_all_for_test(bool force) {
        if (_tag_force_all_for_test == force) return;
        _tag_force_all_for_test = force;
        rebuild_epoch_tag_snapshot();
    }

private:
    // Monotone publish counter, so a snapshot can say which epoch it describes.
    //
    // R-3b: SINGLE WRITER. Assigned only inside `rebuild_epoch_tag_snapshot`, which
    // runs either from `capture_country_epoch` (the economy commit thread) or from
    // `set_target_tags` (config time, or a caller holding the boundary lock -- see
    // the assertion there). Two concurrent writers would not corrupt the swapped
    // pointer (that store is atomic) but they WOULD race on this counter and can
    // publish two snapshots with the same generation.
    uint64_t _published_tag_snapshot_generation = 0;
    // R-3b: evidence that an epoch which nobody reads costs nothing. One increment
    // per snapshot actually built, one per epoch where both halves were skipped.
    std::atomic<uint64_t> _tag_snapshot_builds{0};
    std::atomic<uint64_t> _tag_snapshot_skips{0};
    // R-3b: "only one builder at a time" assertion (see rebuild_epoch_tag_snapshot).
    // Atomic so a second caller can see it without holding a lock; `exchange(false)`
    // in the guard's destructor is what makes the early-outs below leak-free.
    std::atomic<bool> _tag_snapshot_building{false};
    // `set_target_tags` calls that arrived while a rebuild was in flight. Must stay 0:
    // it is the only observable form of "someone called outside the config phase
    // without holding the boundary lock".
    std::atomic<uint64_t> _tag_snapshot_concurrent_writes{0};
    // Readers that arrived before the first publish. Must be 0 after the first
    // commit; exported as `tag_snapshot_miss_count`.
    mutable std::atomic<int64_t> _last_tag_snapshot_miss_count{0};
    // M4: see `last_tag_snapshot_build_ms`. Relaxed is enough -- these are
    // diagnostics, never control flow.
    mutable std::atomic<double> _last_tag_snapshot_build_ms{0.0};
    mutable std::atomic<int64_t> _tag_snapshot_build_count{0};
    // How many tags the table DECLARES versus how many have rows and can match. The
    // gap is pure waste in the `cells x tags` sweep.
    mutable std::atomic<int64_t> _tag_declared_tag_count{0};
    mutable std::atomic<int64_t> _tag_active_tag_count{0};
    // How many tag ids the CONSUMER set named. 0 means "all tags" (the conservative
    // fallback), so this is the number that explains why the sweep did or did not
    // narrow.
    mutable std::atomic<int64_t> _tag_consumed_tag_count{0};
    // Last tag-bit build's deterministic work, excluding the separate
    // specialized-good count pass. Requested metrics differ from catalog
    // metrics when the consumer set names only part of the tag table.
    std::atomic<int64_t> _tag_snapshot_sampled_cells{0};
    std::atomic<int64_t> _tag_snapshot_requested_metrics{0};
    std::atomic<int64_t> _tag_catalog_metrics{0};
    int64_t tag_declared_tag_count() const {
        return _tag_declared_tag_count.load(std::memory_order_relaxed);
    }
    int64_t tag_active_tag_count() const {
        return _tag_active_tag_count.load(std::memory_order_relaxed);
    }
    int64_t tag_consumed_tag_count() const {
        return _tag_consumed_tag_count.load(std::memory_order_relaxed);
    }
    // R-3b: how many `tag_snapshot()` loads happened, so "one load per scan" is a
    // measured property rather than a code-review claim.
    mutable std::atomic<int64_t> _tag_snapshot_loads{0};
