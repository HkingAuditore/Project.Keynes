// Country ownership, territory, technology, treasury, and persistence state.

    bool _configured = false;
    bool _sync_store_writes_forbidden = false;
    CountryHostPort *_simulation_host = nullptr;
    bool _bootstrapped = false;
    RuntimeMode _mode = MODE_ACTIVE;
    int32_t _cell_count = 0;
    int64_t _seed = 0;
    int32_t _technology_words = 0;
    int32_t _research_signal_words = 0;
    int32_t _technology_points_good_id = -1;
    uint64_t _technology_catalog_identity_hash = 0;
    uint64_t _technology_content_binding_hash = 0;
    uint64_t _technology_trigger_definition_hash = 0;
    ModifierRuntime *_modifier_runtime = nullptr;
    NativeEconomyRuntime *_economy_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    EffectInstanceForwarder *_effect_forwarder = nullptr;
    bool _effect_runtime_enabled = false;
    int32_t _starting_country_slot = -1;
    uint64_t _generation = 0;
    // Visibility generations are diagnostic/publish watermarks, not separate
    // simulation authorities.  They deliberately stay out of save/state hashes.
    uint64_t _territory_generation = 0;
    uint64_t _research_generation = 0;
    bool _full_diagnostics = false;
    bool _light_report_enabled = true;
    bool _pending_queue_enabled = true;
    mutable bool _state_hash_cache_valid = false;
    mutable uint64_t _state_hash_cache = 0;
    mutable uint64_t _state_hash_cache_generation = 0;
    mutable int64_t _state_hash_cache_research_day = -1;
    mutable uint64_t _state_hash_cache_tax_policy_version = 0;
    mutable EraRewardReference _state_hash_cache_era_reward{};
    uint64_t _submit_order = 0;
    uint64_t _session_epoch = 1;
    uint64_t _next_boundary_id = 1;
    CountryBoundarySeal _boundary_seal;
    bool _boundary_seal_active = false;
    uint64_t _next_event_id = 1;
    int64_t _last_committed_day = -1;
    int32_t _max_commands_per_slice = 65536;

    std::vector<std::string> _good_ids;
    std::vector<std::string> _profession_ids;
    std::vector<std::string> _building_type_ids;
    std::vector<std::string> _technology_ids;
    std::vector<std::string> _technology_era_reward_pool_ids;
    std::vector<std::string> _research_signal_ids;
    std::vector<std::string> _political_regime_ids;
    std::vector<uint32_t> _political_regime_capability_bits;
    std::unordered_map<std::string, int32_t> _political_regime_index;
    uint64_t _political_regime_catalog_hash = 0;
    std::unordered_map<std::string, int32_t> _good_index;
    std::unordered_map<std::string, int32_t> _technology_index;
    std::vector<int32_t> _starting_technologies;
    std::vector<int32_t> _technology_domains;
    std::vector<int64_t> _technology_costs;
    std::vector<int32_t> _technology_prerequisite_offsets;
    std::vector<int32_t> _technology_prerequisites;
    std::vector<int32_t> _technology_milestone_offsets;
    std::vector<int32_t> _technology_milestone_candidates;
    std::vector<int32_t> _technology_milestone_required_counts;
    // Dense per-technology era gate. -1 denotes the first era. This is kept
    // separate from the authored prerequisite CSR so the graph contains only
    // real knowledge dependencies.
    std::vector<int32_t> _technology_entry_milestone_indices;
    std::vector<int32_t> _technology_era_milestone_indices;
    std::vector<int32_t> _technology_flags;
    std::vector<std::string> _technology_modifier_definition_keys;
    std::vector<uint8_t> _research_signal_requires_provenance;
    std::vector<int32_t> _technology_research_condition_offsets;
    std::vector<int32_t> _technology_research_condition_ops;
    std::vector<int32_t> _technology_research_condition_refs;
    std::vector<int64_t> _technology_research_condition_values;
    std::vector<int32_t> _technology_reveal_condition_offsets;
    std::vector<int32_t> _technology_reveal_condition_ops;
    std::vector<int32_t> _technology_reveal_condition_refs;
    std::vector<int64_t> _technology_reveal_condition_values;
    std::vector<int32_t> _technology_reveal_signal_offsets;
    std::vector<int32_t> _technology_reveal_signal_technologies;
    std::vector<int32_t> _technology_discovery_dependent_offsets;
    std::vector<int32_t> _technology_discovery_dependents;
    std::vector<uint8_t> _is_water;

    CountryStore _countries;
    std::vector<int32_t> _cell_country_slot;
    std::vector<int32_t> _country_cell_offsets;
    std::vector<int32_t> _country_cells;
    std::vector<uint64_t> _country_technologies;
    std::vector<int64_t> _country_goods;
    std::vector<uint64_t> _country_discovered;
    std::vector<uint64_t> _country_pending_technologies;
    std::vector<int32_t> _current_visual_era;
    std::vector<int32_t> _visual_era_dirty_slots;
    uint64_t _visual_era_generation = 0;
    mutable std::vector<std::vector<int32_t>> _pending_activation_indices;
    mutable bool _pending_activation_index_dirty = true;
    mutable int64_t _pending_activation_count = 0;
    mutable int64_t _research_queue_rebuilds = 0;
    int64_t _research_full_scan_fallbacks = 0;
    std::string _research_queue_fallback_reason;
    std::vector<int32_t> _research_active_country_slots;
    std::vector<int32_t> _research_active_country_scratch;
    std::vector<uint8_t> _research_active_country_membership;
    // A country has four research lanes with an eight-entry queue each. Keep
    // activation scratch at the runtime level so the daily hot loop reuses
    // capacity instead of allocating two vectors for every active country.
    std::vector<int32_t> _research_activated_pending_scratch;
    std::vector<int32_t> _research_activated_technologies_scratch;
    struct ResearchModifierCache {
        uint64_t country_handle = 0;
        uint64_t modifier_version = std::numeric_limits<uint64_t>::max();
        double cost_factor = 1.0;
        std::array<double, 4> efficiency{{1.0, 1.0, 1.0, 1.0}};
    };
    mutable std::vector<ResearchModifierCache> _research_modifier_cache;
    // Per-run diagnostics. They are reset at run_research_day() entry and are
    // excluded from persistence and authoritative hashes.
    mutable double _research_activation_ms = 0.0;
    mutable double _research_allocation_ms = 0.0;
    mutable double _research_effect_ack_ms = 0.0;
    mutable double _research_discovery_ms = 0.0;
    mutable double _research_modifier_ms = 0.0;
    mutable int64_t _research_countries_scanned = 0;
    mutable int64_t _research_active_countries = 0;
    mutable int64_t _research_pending_checks = 0;
    mutable int64_t _research_discovery_checks = 0;
    mutable int64_t _research_discovery_frontier_mismatches = 0;
    mutable int64_t _research_modifier_queries = 0;
    mutable int64_t _research_modifier_cache_hits = 0;
    mutable int64_t _research_remainder_iterations = 0;
    std::string _peer_protocol_fault_reason;
    std::vector<uint64_t> _country_research_signals;
    std::vector<std::vector<uint64_t>> _country_research_signal_cells;
    std::vector<std::vector<SignalEvidence>> _country_research_signal_evidence;
    std::vector<std::vector<std::pair<int32_t, int64_t>>> _country_research_progress;
    std::vector<int32_t> _country_research_queues;
    std::vector<uint8_t> _country_research_queue_lengths;
    std::vector<int32_t> _country_research_weights_bp;
    std::vector<uint8_t> _country_research_auto_purchase;
    std::vector<int64_t> _country_research_deferred_points;
    std::vector<int64_t> _country_research_purchased_total;
    std::vector<int64_t> _country_research_consumed_total;
    // Transient (not PKCN, not state hash): era-advancement treasury sink.
    std::vector<int64_t> _country_treasury_goods_consumed_total;
    std::vector<int64_t> _country_research_progress_total;
    std::vector<int64_t> _country_research_completed_total;
    // K2-A protocol diagnostics. These are not authority state and do not
    // participate in business/checkpoint hashes.
    uint64_t _peer_intents_emitted = 0;
    uint64_t _peer_results_consumed = 0;
    bool _peer_async_mode = false;
    std::unordered_map<uint64_t, CountryPeerIntent> _peer_pending_intents;
    std::deque<uint64_t> _peer_intent_queue;
    std::unordered_map<uint64_t, CountryPeerResult> _peer_result_cache;
    std::unordered_map<uint64_t, CountryPeerResult> _peer_rejected_results;
    std::unordered_set<uint64_t> _peer_rejection_reported;
    std::vector<int32_t> _country_tax_defaults;
    std::vector<int32_t> _country_tax_default_modes;
    std::vector<int32_t> _country_income_tax_overrides;
    std::vector<int32_t> _country_consumption_tax_overrides;
    std::vector<int32_t> _country_business_tax_overrides;
    std::vector<int32_t> _country_import_tax_overrides;
    std::vector<int32_t> _country_export_tax_overrides;
    std::vector<int32_t> _country_income_tax_mode_overrides;
    std::vector<int32_t> _country_consumption_tax_mode_overrides;
    std::vector<int32_t> _country_business_tax_mode_overrides;
    std::vector<int32_t> _country_import_tax_mode_overrides;
    std::vector<int32_t> _country_export_tax_mode_overrides;
    std::vector<uint32_t> _cell_tax_policy_ids;
    std::vector<CellTaxPolicy> _cell_tax_policies;
    std::vector<uint32_t> _cell_tax_policy_refcounts;
    std::vector<uint32_t> _cell_tax_policy_free_ids;
    std::unordered_map<uint64_t, std::vector<uint32_t>> _cell_tax_policy_intern;
    uint64_t _tax_policy_version = 0;
    int64_t _last_research_day = -1;
    std::vector<Command> _pending_commands;
    std::deque<CountryCommandReceipt> _typed_receipts;
    std::unordered_map<uint64_t, CountryCommandReceipt> _typed_request_state;
    std::unordered_map<int64_t, CountryEffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_command_idempotency;
    // Host request_id → Effect request_id while Country writes are worker-owned.
    std::unordered_map<uint64_t, int64_t> _effect_host_request_map;
    uint64_t _effect_host_receipt_cursor = 0;
    int64_t _next_effect_request_id = 1;
    EraRewardReference _era_reward_reference;
    std::deque<Event> _events;
    CommandBatchState _command_batch;
    godot::Dictionary _report;
    bool _reference_trace_enabled = false;
    size_t _reference_trace_capacity = 4096;
    uint64_t _next_reference_frame_id = 1;
    uint64_t _reference_boundary_id = 0;
    uint32_t _reference_continuation_index = 0;
    int64_t _reference_boundary_day = -1;
    int64_t _reference_boundary_first_event_id = 0;
    std::deque<ReferenceFrame> _reference_frames;
    // Suppresses the one legacy diagnostic write in run_research_day() while
    // the POD adapter is executing on a worker-owned runtime.
    bool _pod_execution = false;

    // Diagnostic transaction ledger for the K2-B compatibility bridge.  It is
    // deliberately excluded from the Country business hash and checkpoint;
    // authoritative Country balances remain the only mutable business state.
    uint64_t _next_economy_asset_transaction_id = 1;
    uint64_t _economy_asset_operation_sequence = 0;
    uint64_t _economy_asset_transactions_created = 0;
    uint64_t _economy_asset_transactions_completed = 0;
    uint64_t _economy_asset_transactions_rejected = 0;
    uint64_t _economy_asset_prepare_count = 0;
    uint64_t _economy_asset_commit_count = 0;
    uint64_t _economy_asset_complete_count = 0;
    int64_t _economy_asset_ledger_failures = 0;
    std::deque<EconomyAssetTransaction> _economy_asset_transaction_history;
    std::unordered_map<uint64_t, uint64_t> _economy_asset_request_index;
    std::unordered_map<uint64_t, EconomyAssetTransaction>
        _economy_asset_transactions_in_flight;
    std::vector<int64_t> _economy_asset_reserved_cash;
    std::vector<int64_t> _economy_asset_reserved_goods;
    // Research procurement credits technology_points, so reserve remaining
    // int64 capacity separately from debit-side goods reservations.
    std::vector<int64_t> _economy_asset_reserved_research_points;

    std::vector<uint8_t> _save_bytes;
    size_t _save_cursor = 0;
    int32_t _save_chunk_bytes = 4 * 1024 * 1024;
    bool _save_active = false;
    std::vector<uint8_t> _restore_bytes;
    bool _restore_active = false;
