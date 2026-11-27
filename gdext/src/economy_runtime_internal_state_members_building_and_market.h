// Building factor caches, market processing work, and market signals.

    // Phase-1 BuildingOutputFactorKey: shared identity for country/type/terrain/
    // landform/sector composite factors. Per-group cache still also keys owner
    // and family-owned mix; this struct documents the Plan key and is used when
    // comparing the geography/policy half of a cache entry.
    struct BuildingOutputFactorKey {
        int32_t country = -1;
        int32_t building_type = -1;
        int32_t terrain = -1;
        int32_t landform = -1;
        int32_t sector = -1;

        bool operator==(const BuildingOutputFactorKey &other) const noexcept {
            return country == other.country &&
                   building_type == other.building_type &&
                   terrain == other.terrain &&
                   landform == other.landform &&
                   sector == other.sector;
        }
    };
    // Per-group cache for refresh_building_modifier_factors, keyed on every
    // input of group.output_factor_q16 / modifier_handle: every frozen
    // country factor value, country handle, ECONOMY store snapshot_version,
    // and the (type, owner) identity. During a frozen epoch the group lane is
    // append-only; topology rebuilds permute the compact lane only at
    // BUILDING_COMMIT / idle boundaries and remap this cache with them.
    // Cache hits skip both ensure_building_identity and the ECONOMY
    // effective_value query. Transient; never saved or hashed.
    struct BuildingFactorCacheEntry {
        BuildingOutputFactorKey output_key{};
        int64_t country_factor_q16 = std::numeric_limits<int64_t>::min();
        int64_t sector_factor_q16 = 0;
        int64_t research_factor_q16 = 0;
        int64_t family_factor_q16 = 0;
        int64_t building_type_factor_q16 = 0;
        int64_t terrain_sector_factor_q16 = 0;
        int64_t landform_sector_factor_q16 = 0;
        uint64_t country_handle = 0;
        uint64_t mod_version = 0;
        uint64_t exact_building_mod_version = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int32_t family_owned_factor_q16 = Q16_ONE;
        int32_t cell_sector_factor_q16 = Q16_ONE;
        // 空组（count==0，含拆除后留下的墓碑槽）的 family-owned 混合因子恒为
        // Q16_ONE，与家族持股无关。把「当时是否为空」纳入身份判据后，空组可以
        // 完全跳过重算而不会在 count 变正时错误命中旧值。
        uint8_t count_positive = 0;
    };
    std::vector<BuildingFactorCacheEntry> _building_factor_cache;
    std::vector<BuildingFactorCacheEntry> _building_factor_cache_rebuild_scratch;
    // Persons whose cohort changed since the last CSR rebuild, keyed by the
    // cohort they landed in. Lets move_notable_people read the cohort CSR
    // instead of the whole person table without losing candidates the stale
    // CSR no longer lists.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_cohort_migrations;
    // Same idea for the person-family CSR, which promotion reads before the
    // next PERSON_COMMIT rebuild.
    std::unordered_map<uint64_t, std::vector<int32_t>> _person_family_migrations;
    // Live notable-person stable ids, so identity assignment can test for a
    // collision without walking the person table once per hash probe.
    std::unordered_set<int64_t> _person_stable_ids;
    std::unordered_set<int64_t> _family_stable_ids;
    // Live family indices grouped by surname, compacted lazily on read.
    std::vector<std::vector<int32_t>> _family_surname_members;
    std::vector<uint32_t> _person_candidate_stamp;
    uint32_t _person_candidate_generation = 0;
    int64_t _building_factor_cache_hits = 0;
    int64_t _building_factor_cache_misses = 0;
    std::vector<int64_t> _building_investment_score_q16;
    std::vector<int64_t> _building_investment_payback_days;
    std::vector<int32_t> _building_investment_rejection;
    // Review-only watermark: which economy epoch last rebuilt the transient
    // investment incumbent index. The Track-B spread path can carry review
    // cells into a later epoch without running the phase-4 prepare.
    int64_t _investment_prepared_epoch = -1;
    // Bounded cold-path diagnostics for the one inspector-selected cell. These
    // are transient, excluded from save/hash, and include absent building types.
    int32_t _investment_diagnostic_cell = -1;
    int64_t _investment_diagnostic_day = -1;
    std::vector<InvestmentDiagnostic> _investment_diagnostics;
    // Same cold-path contract as the investment diagnostics above: one
    // inspector-selected cell, transient, excluded from save/hash.
    int32_t _employment_diagnostic_cell = -1;
    int64_t _employment_diagnostic_day = -1;
    std::vector<EmploymentDiagnostic> _employment_diagnostics;
    static constexpr size_t EMPLOYMENT_DIAGNOSTIC_LIMIT = 512;
    // Scratch for the current cell only; consumed by the employment pass in the
    // same call that fills it.
    std::vector<FamilyOwnerClampTrace> _family_clamp_traces;
    std::unordered_map<uint64_t, int64_t> _investment_pending_by_cell_type;
    std::unordered_map<uint64_t, InvestmentExistingType>
        _investment_existing_by_cell_type;
    // Peak daily extraction already committed by installed and pending groups,
    // indexed as resource * cell_count + cell for the investment review only.
    std::vector<int64_t> _investment_resource_committed_by_cell;
    std::vector<int64_t> _investment_merchant_cash_by_cell;
    std::vector<int64_t> _investment_outstanding_credit_by_cell;
    std::vector<uint32_t> _investment_resource_commitment_stamp;
    std::vector<uint32_t> _investment_cell_finance_stamp;
    uint32_t _investment_scratch_generation = 0;
    std::vector<OutputInvestmentSignal> _investment_output_signals_scratch;
    std::vector<InvestmentIncumbentLane> _investment_incumbent_lanes_scratch;
    // Persistent settled incumbents keyed by (cell, output_good, type_id).
    // Updated only after a successful aggregate publish.
    std::vector<InvestmentIncumbentRecord> _investment_incumbent_records;
    std::vector<OwnerMobilityCooldown> _owner_mobility_cooldowns;
    std::vector<int32_t> _investment_employment_cells;
    std::vector<int32_t> _investment_review_cell_indices;
    // Catalog-derived output-good -> building-type CSR plus the current review
    // cell's sparse active-good set. These lanes are rebuildable scheduling
    // data and are excluded from PKEC and the authoritative state hash.
    std::vector<int32_t> _investment_good_type_offsets;
    std::vector<int32_t> _investment_good_type_indices;
    std::vector<uint64_t> _investment_active_good_words;
    std::vector<int32_t> _investment_active_goods_scratch;
    std::vector<uint32_t> _investment_type_stamp;
    std::vector<uint32_t> _investment_good_stamp;
    uint32_t _investment_review_stamp_generation = 0;
    std::vector<int32_t> _investment_review_types_scratch;
    std::vector<int32_t> _investment_good_queue_scratch;
    // Per-cell active plus pending monetary capacity, prepared once per
    // investment batch so candidate evaluation does not rescan building groups.
    std::vector<int64_t> _investment_monetary_units_by_cell;
    // v44 transient startup-demand graph. The dense value/stamp pair is the
    // fixed 12-byte (cell, good) budget; only stamped/touched lanes are read.
    // Remote/inbound lanes are sparse, rebuilt once per investment batch, and
    // excluded from PKEC and the authoritative state hash.
    std::vector<int64_t> _startup_demand_values;
    std::vector<uint32_t> _startup_demand_stamps;
    uint32_t _startup_demand_generation = 0;
    std::vector<uint64_t> _startup_demand_touched_keys;
    std::vector<int32_t> _startup_monetary_good_indices;
    std::vector<StartupRemoteLane> _startup_remote_lanes;
    std::vector<StartupRemoteGroup> _startup_remote_groups;
    std::vector<StartupInboundLane> _startup_inbound_lanes;
    std::vector<StartupRemoteAccumulator> _startup_remote_accumulator_scratch;
    // Epoch-transient worker outputs. Keeping the nested vector capacities
    // avoids rebuilding thousands of small buffers every household slice.
    std::vector<MarketResult> _market_results_scratch;
    std::vector<ProductionResult> _production_results_scratch;
    // Production uses stable contiguous weighted ranges. These transient
    // buffers are diagnostics/scheduling scratch only and never enter PKEC or
    // the authoritative state hash.
    std::vector<int64_t> _production_cell_weights_scratch;
    std::vector<int32_t> _production_task_offsets_scratch;
    std::vector<int64_t> _production_task_weights_scratch;
    std::vector<double> _production_task_ms_scratch;
    std::vector<AuditTotals> _audit_task_totals_scratch;
    std::vector<int64_t> _audit_task_saturation_scratch;
    std::vector<double> _audit_task_ms_scratch;
    std::vector<BuildingPlanResult> _building_plan_results_scratch;
    CompletedEpochPerf _last_completed_perf;
    std::vector<uint64_t> _trade_active_keys;
    std::vector<uint8_t> _trade_active_key_present;
    std::unordered_map<uint64_t, uint8_t> _trade_active_key_idle_cycles;
    // Diagnostic-only sparse clocks keyed independently from authoritative EMA state.
    std::vector<uint64_t> _trade_signal_clock_keys;
    std::vector<uint64_t> _trade_signal_bulk_keys_scratch;
    std::vector<int64_t> _trade_signal_first_seen_day;
    std::vector<int64_t> _trade_signal_first_dispatch_day;
    std::vector<int64_t> _trade_signal_last_attempt_day;
    std::vector<int32_t> _trade_signal_last_rejection_reason;
    std::vector<uint8_t> _trade_signal_deadline_reported;
    // Investment-only append lanes. Entries are immediately visible through
    // dense_index, then stably merged into the authoritative CSR before publish.
    std::vector<int32_t> _market_signal_overflow_cells;
    std::vector<OwnerRetainedOutput> _owner_retained_outputs;
    TradeTopologyStore _trade_topology;
    TradePlanStore _trade_plan;
    // A+Y N3/N4: unbound fallback only; see trade_orders_store().
    TradeOrderStore _trade_orders_local;
    TradeFlowSignalStore _trade_flows;
    CountryGoodTradeAggregateStore _country_good_trade;
    CountryPartnerTradeAggregateStore _country_partner_trade;
    TariffHistoryStore _tariff_history;
    // Rebuildable sparse lookup/display indices.  The authoritative aggregate
    // columns above remain the only persisted/hashed state; these maps remove
    // the former O(total aggregates) rebuild from every dispatch, while the
    // per-country sorted row lists make paged UI queries O(limit).
    std::unordered_map<uint64_t, int32_t> _country_good_trade_index;
    std::unordered_map<uint64_t, int32_t> _country_partner_trade_index;
    std::unordered_map<uint64_t, int32_t> _tariff_history_index;
    std::vector<std::vector<int32_t>> _country_good_display_rows;
    std::vector<std::vector<int32_t>> _country_partner_display_rows;
    std::vector<uint8_t> _country_good_display_dirty;
    std::vector<uint8_t> _country_partner_display_dirty;
    EconomyTrackedScalar<uint64_t> _country_trade_revision{_metadata_changes, {{15, 5}, "metadata.country_trade_revision", EconomyFieldEncoding::U64, 8}, 0};
    LaborMarketStore _labor_signals;
    LaborMarketStore _labor_signals_rebuild_scratch;
