// Applied program provenance, derived projection caches, and refresh diagnostics.

    // ── plan §9.3: when the current basis became confirmable, and when it may be used ──
    //
    // `confirmed_day` is the business day on which every required ACK for the newest
    // projection had been observed; `eligible_from_day` is the day AFTER it, which is the
    // first day the derived layer is allowed to adopt that projection. Both are -1 until
    // something settles.
    int64_t _derived_basis_confirmed_day = -1;
    int64_t _derived_basis_eligible_day = -1;
    // ── plan §18.2: the FULL applied-program basis ──────────────────────────
    //
    // The basis the LAST projection was built from, kept for diagnostics and
    // assigned at the same commit point as the two dates above (so a failed restore
    // puts it back). The PAYLOAD's rows are re-derived at capture time rather than
    // read from here on purpose: this member goes stale the moment a card is
    // equipped, unequipped or levelled between two rebuilds, and a payload that
    // recorded a stale basis would refuse to reload its own world. Re-deriving at
    // capture makes the payload describe the state it was captured from, which is
    // the only thing a reload can verify.
    std::vector<AppliedProgramBasis> _applied_program_basis;
    // §18.5: the local scalar basis the LAST RESTORE installed, kept for diagnostics
    // and put back by `rollback` at the same commit point as the rows above. The
    // PAYLOAD's rows are re-derived at capture from `_countries`, never read from
    // here, for exactly the reason the applied basis is: this member describes the
    // last completed restore, not the current state, and a payload built from it
    // would refuse its own world after the first equip.
    std::vector<LocalScalarValue> _local_scalar_basis;
    // WHY the last restore refused with `ideology_save_scalar_basis_mismatch`, in one
    // line: row counts on both sides and the first differing (country, metric, value).
    // A named refusal that does not say WHAT disagreed costs a debugging round every
    // time it fires -- this one fired first on a cross-domain input and the reason string
    // alone could not tell the two possible causes apart. Empty when nothing refused.
    std::string _last_scalar_basis_mismatch_detail;
    // ── plan §18.5: the sample day the installed projection was built from ────
    //
    // Mirrors `DerivedCellFront::sample_day` of the front that is serving readers, read
    // back right after `install_derived_cell_layer` -- not from the job argument, so a
    // skipped install (§I13), a refused one, or a build still folding cannot make this
    // disagree with the front. `-1` means "no projection is installed".
    //
    // Assigned at the restore commit point like the rows above, and put back by
    // `rollback`, so a refused restore cannot leave an identity describing state that
    // was itself rolled back.
    //
    // WHY CAPTURE READS THIS MEMBER INSTEAD OF THE LIVE FRONT, unlike the applied basis
    // and the scalar rows: it is an identity, not a function of current state. Reading
    // the live front looks equivalent and is not -- PKID does not restore the Modifier
    // domain (PKCM owns it), so a world that rebuilt its front after the save would
    // stamp its OWN day into a re-capture and the payload would stop round-tripping.
    // The two §9.3 dates above are the same kind of value and are read the same way.
    int64_t _derived_basis_sample_day = -1;
    // How many rebuild attempts were refused because the basis was not eligible yet.
    // Distinguishes "the gate held" from "nothing ever tried to rebuild".
    int64_t _derived_rebuild_gated_by_eligibility = 0;
    int64_t _derived_rebuild_steps = 0;
    // The LAST collect of the current day (see `step_derived_rebuild`), written at
    // the collect site itself. They were declared and exported but never assigned
    // until 2026-11-16, so all three read 0 on every run and "the collect never ran"
    // was the conclusion drawn from a permanently-zero diagnostic.
    //   count = target-cell rows handed to the fold
    //   rows  = distinct (country, card, level, program) rows
    //   ideas = cards that emitted at least one row
    int64_t _derived_collect_count = 0;
    int64_t _derived_collect_rows = 0;
    int64_t _derived_collect_ideas = 0;
    int64_t _derived_first_country_delta = 0;
    int64_t _derived_second_country_delta = 0;
    bool _derived_last_collect_ok = true;
    int64_t _derived_contribs_passed = 0;
    double _derived_rebuild_total_ms = 0.0;
    std::vector<DerivedProgramContribution> _derived_rebuild_contributions;
    // The contributions that built the SERVING front, swapped in when a rebuild
    // installs (or is skipped as identical). `effect_target_report` reads them only
    // while the front still carries `_derived_installed_generation`.
    std::vector<DerivedProgramContribution> _derived_installed_contributions;
    uint64_t _derived_installed_generation = 0;
    // The resumable fold. Held across slice boundaries -- the state IS the job.
    std::unique_ptr<DerivedCellMaterializeJob> _derived_rebuild_job;
    // Ramp sampling state for the SHARDED rebuild.
    //
    // The single-shot path builds a lambda that captures these as LOCALS by
    // reference, which cannot outlive the call. The job spans slice boundaries, so the
    // state has to be a member: without it the job was constructed with an empty
    // `DerivedMaterializeOptions` and every ramp term was DEFERRED instead of
    // evaluated -- a silent behaviour regression for the 24 ramp programs.
    std::unordered_map<uint64_t, double> _derived_ramp_country_cache;
    std::vector<int64_t> _derived_ramp_metric_scratch;
    int32_t _derived_ramp_samples_taken = 0;
    // Why a ramp card may contribute nothing. `ramp_candidates` counts commands whose
    // `value_mode` is not CONSTANT; `ramp_metric_ok` counts those that ALSO declare a
    // metric. A gap between them means the program's metadata never saw its
    // READ_METRIC instruction.
    mutable int64_t _ramp_candidates = 0;
    mutable int64_t _ramp_metric_ok = 0;
    // Why the economy may see `consumed = 0`: no publisher ran, or it found no named
    // tags. `_consumer_levels_with_tags` counts levels that declare tag use at all.
    mutable int64_t _consumer_publish_calls = 0;
    // Programs the old plane skipped because `decide_cell_program_backend` said the
    // derived layer owns them (I01). Non-zero proves the gate fires.
    mutable int64_t _cell_plane_derived_elsewhere = 0;
    // How many source fan-outs ran, and under which ownership scope. Counts, not time:
    // "the filter is applied" and "the filter drops nothing" look identical in the
    // output otherwise.
    mutable int64_t _ownership_filtered_resolves = 0;
    mutable int64_t _ownership_own_resolves = 0;
    mutable int64_t _ownership_foreign_resolves = 0;
    mutable int64_t _consumer_tag_ids_last = 0;
    mutable int64_t _consumer_levels_with_tags = 0;
    int32_t _derived_ramp_samples_memoised = 0;
    DerivedRampSampler _derived_ramp_sampler;
    // Runs the program's own instruction stream per cell (M5-13).
    //
    // The metric sampler below returns a RAW metric; the cards' magnitudes are programs
    // (`CONST -> READ_METRIC -> CONST -> MIN -> MUL -> EMIT`), so scaling the raw metric
    // dropped both the clamp and the constant and saturated the stat.
    // Stable storage for program keys, so `Term` can hold a pointer.
    //
    // `std::unordered_set` nodes do not move on insert, so a pointer to an element stays
    // valid for the runtime's lifetime. Interning also collapses the per-cell key
    // construction the collector would otherwise repeat.
    mutable std::unordered_set<std::string> _program_key_pool;
    const std::string *intern_program_key(const std::string &key) const;

    DerivedProgramMagnitudeSampler _derived_program_sampler;
    std::vector<int64_t> _derived_program_metric_scratch;
    mutable int64_t _derived_program_evaluations = 0;
    mutable int64_t _derived_program_failures = 0;
    void ensure_derived_program_sampler();
    // Builds `_derived_ramp_sampler` against the members above. Idempotent.
    void ensure_derived_ramp_sampler();
    // Identity of the world the derived front was built against. Passed to the
    // materializer so `install_derived_cell_layer` can reject a candidate built
    // against a different world/map (plan §9.6).
    uint64_t _derived_world_identity = 0;
    uint64_t _derived_map_generation = 0;
    uint64_t _derived_epoch_id = 0;
    // Diagnostics for the derived rebuild (plan §12.4). Named with the
    // `_cell_layer_` prefix because `_derived_rebuild_visits` was ALREADY taken by
    // an unrelated idea-iteration counter (`ideology_runtime.h:979`); reusing that
    // name made both counters silently share one field.
    // M3 ramp sampling observability. `memoised` > 0 proves the country-scope
    // cache is doing work; a large `taken` with zero `memoised` on a country metric
    // would mean the cache never hits, which is the failure this pair exists to
    // make visible.
    int64_t _ramp_samples_taken = 0;
    int64_t _ramp_samples_memoised = 0;
    int64_t _ramp_terms_evaluated = 0;
    int64_t _ramp_terms_deferred = 0;
    // M4 diagnosis: where `collect_effect_activations` gives up. `seen=0` with an
    // ACTIVE idea and a valid territory plane can only mean one of the early exits
    // fired, and they are indistinguishable from the outside. Each counter is one
    // such exit; `collect_stage_*` names them in the report.
    mutable int64_t _collect_entries = 0;          // ideas that passed location/level
    mutable int64_t _collect_templates = 0;        // active_templates seen
    mutable int64_t _collect_program_empty = 0;    // program key came back empty
    mutable int64_t _collect_pod_fail = 0;
    // The first few program keys whose POD lookup failed. Bounded so a broken catalog
    // cannot grow this without limit; enough to identify the offending program.
    mutable std::vector<std::string> _collect_pod_fail_keys;
    // ... and the ones that RESOLVED. Without both halves a non-empty failure list cannot
    // be interpreted: a cost entry is EXPECTED to fail, so "failures exist" says nothing
    // about whether the card's real effect was found.
    mutable std::vector<std::string> _collect_pod_ok_keys;         // family_effect_metadata_pod returned false
    mutable int64_t _collect_targets_fail = 0;
    // Where `resolve_effect_targets` bails. Each is a distinct early return and
    // they all surface as the same `targets_fail`, which is why the empty front was
    // not diagnosable from outside.
    mutable int64_t _targets_country_zero = 0;
    mutable int64_t _targets_domain_gate = 0;
    mutable int64_t _targets_economy_null = 0;
    mutable int64_t _targets_anchor_neg = 0;
    mutable int64_t _targets_collected_empty = 0;
    // kind 14/15 bail out when the card carries no tag id. Counted separately: without it
    // "no targets" cannot be told apart from "the tag never made it into param[1]".
    mutable int64_t _targets_fanout_no_tag = 0;
    // The kind 14/15 branch also bails when the tag scan finds no source cell -- the one
    // exit that had NO counter, which is why four rounds could not tell "the tag matched
    // nothing" apart from "the branch never ran".
    mutable int64_t _targets_fanout_no_source = 0;

    // Peak memory across rebuilds (§18.3). "retained" is the front still serving readers
    // while "candidate" is being built; they coexist during `finish()`, so the peak is
    // their sum. Kept as MAX over rebuilds -- a per-rebuild value would miss the worst.
    mutable int64_t _derived_peak_retained_bytes = 0;
    mutable int64_t _derived_peak_candidate_bytes = 0;
    mutable int64_t _derived_peak_total_bytes = 0;
    // kine 14/15 have their OWN `sources.empty()` check (line ~2129), separate from
    // kind 16's. The first patch landed on kind 16 because both lines had identical
    // indentation and text -- so this one is named for the branch it belongs to.
    mutable int64_t _targets_fanout_ring_empty = 0;     // resolve_effect_targets returned false
    mutable int64_t _collect_derived_emitted = 0;  // derived contributions pushed
    int64_t _cell_layer_rebuild_visits = 0;
    int64_t _cell_layer_rebuild_skips = 0;
    double _cell_layer_rebuild_ms = 0.0;
    // ── P1-A sliced instance refresh ────────────────────────────────────────
    // Budget in COUNTRIES, never milliseconds: a time-based slice would make
    // which cards get refreshed depend on machine speed and break replay.
    // Zero means "scan every country", which is what the callers use: the scan
    // itself is a cheap per-card comparison, and slicing it by country would
    // stretch one pass over a 512-country map across eight days.
    static constexpr int32_t INSTANCE_REFRESH_COUNTRY_BUDGET = 0;
    // Real work happens only for cards whose signature moved, so the slice cap
    // belongs here. A pass with more than this many changed cards continues on
    // the next call with the cursor preserved.
    static constexpr int32_t INSTANCE_REFRESH_VISIT_BUDGET = 64;
    mutable std::vector<LevelManagedInfo> _level_managed;
    mutable bool _level_managed_built = false;
    int32_t _managed_active_total = 0;
    uint64_t _effect_input_revision_seen = 0;
    uint64_t _effect_input_revision_target = 0;
    bool _instance_refresh_pending = false;
    bool _instance_refresh_dirty = false;
    int32_t _instance_refresh_country_cursor = 0;
    uint64_t _instance_refresh_visits = 0;
    // Reconcile attempts that FAILED (submit refused / rejected / authority
    // unavailable). Both entry points that reconcile increment it --
    // `step_effect_instance_refresh` and `reconcile_country_effect_activations` --
    // and both record the reason in `_last_error`.
    //
    // WHY A COUNTER AND NOT ONLY `last_error`: `last_error` is sticky and shared, so
    // the next unrelated rejection overwrites it, and a report read after a
    // successful later pass cannot tell "never failed" from "failed and recovered".
    // A visit that fails is also invisible in `instance_refresh_visits`, which counts
    // attempts, not successes.
    uint64_t _effect_reconcile_failures = 0;
    // Doc 03 §6.2 wants this at 0 on an idle day. It counts builds, not publishes:
    // a build with no publisher still costs the per-card string lookups, which is
    // exactly the idle overhead the threshold is about.
    mutable uint64_t _cell_plane_builds = 0;
    uint64_t _instance_refresh_skips = 0;
    uint64_t _instance_refresh_passes = 0;
    uint64_t _instance_refresh_lag_revisions = 0;
    double _instance_refresh_ms = 0.0;
    double _transition_poll_ms = 0.0;
    double _command_apply_ms = 0.0;
    double _active_progress_ms = 0.0;
    double _last_slice_ms = 0.0;
    double _max_slice_ms = 0.0;
    std::string _last_error;
    NativeCountryRuntime *_country_runtime = nullptr;
    NativeEconomyRuntime *_economy_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    EffectInstanceForwarder *_effect_forwarder = nullptr;
    // Last EFFECT authority epoch observed by the reconcile entry point.
    // AUTHORITY_EPOCH_UNSET means "never observed": adopt the current value
    // without wiping held refs, so a fresh runtime does not force a resubmit.
    static constexpr uint64_t AUTHORITY_EPOCH_UNSET =
        std::numeric_limits<uint64_t>::max();
    uint64_t _effect_authority_epoch = AUTHORITY_EPOCH_UNSET;
    ModifierRuntime *_modifier_runtime = nullptr;
