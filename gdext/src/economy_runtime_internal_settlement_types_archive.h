// Epoch event bundles, audit frames, and save and restore continuation.

    struct EventBatch {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int32_t period_days = 1;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
        std::vector<EventRecord> events;
        std::vector<EventLeg> legs;
        int32_t cashflow_cell = -1;
        bool cashflow_complete = false;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        int64_t bytes() const {
            int64_t welfare_bytes = 0;
            for (const CohortWelfareEntry &entry : welfare_entries) {
                welfare_bytes += static_cast<int64_t>(
                    entry.need_ids.capacity() * sizeof(int32_t) +
                    entry.need_satisfaction_q16.capacity() * sizeof(int32_t) +
                    entry.need_weight_q16.capacity() * sizeof(int32_t) +
                    entry.need_tiers.capacity() * sizeof(int32_t) +
                    entry.previous_demand_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.wealth_demand_delta_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.price_demand_delta_per_capita_daily.capacity() * sizeof(int64_t));
            }
            return static_cast<int64_t>(events.capacity() * sizeof(EventRecord) +
                                        legs.capacity() * sizeof(EventLeg) +
                                        cashflows.capacity() * sizeof(CashflowEntry) +
                                        welfare_entries.capacity() * sizeof(CohortWelfareEntry)) +
                   welfare_bytes;
        }
    };

    struct AuditFrame {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int64_t event_count = 0;
        int64_t leg_count = 0;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
    };

    struct SaveState {
        bool active = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        int32_t section = 0;
        int32_t page_cursor = 0;
        int32_t market_cursor = 0;
        int32_t cell_cursor = 0;
        int32_t command_cursor = 0;
        int32_t building_cursor = 0;
        int32_t construction_cursor = 0;
        int32_t audit_cursor = 0;
        int32_t signal_cursor = 0;
        int32_t labor_signal_cursor = 0;
        int32_t trade_order_cursor = 0;
        int32_t trade_flow_cursor = 0;
        int32_t fiscal_cursor = 0;
        int32_t fiscal_country_count = 0;
        int32_t fiscal_peer_cursor = 0;
        int32_t d7_peer_ext_cursor = 0;
        int32_t settlement_cursor = 0;
        int32_t family_cursor = 0;
        int32_t family_membership_cursor = 0;
        int32_t family_ownership_cursor = 0;
        int32_t person_cursor = 0;
        int32_t person_need_cursor = 0;
        int32_t family_trait_cursor = 0;
        int32_t family_influence_cursor = 0;
        int32_t family_trait_command_cursor = 0;
        int32_t family_expedition_cursor = 0;
        int32_t tariff_history_cursor = 0;
        int32_t country_good_cursor = 0;
        int32_t country_partner_cursor = 0;
        int32_t canal_quote_cursor = 0;
        int32_t canal_project_cursor = 0;
        int32_t ceiling_market_cursor = 0;
        int32_t ceiling_row_cursor = 0;
        int32_t resource_cursor = 0;
        int32_t cadence_cursor = 0;
        int32_t family_founding_cursor = 0;
        // BEGIN army personnel lane (contract §1.5): PKEC section 36 cursor.
        int32_t army_personnel_cursor = 0;
        // END army personnel lane
        // Schema 62: PKEC section 37 sparse mobilization row cursor.
        int32_t stratum_mobilization_cursor = 0;
        std::vector<int32_t> family_founding_cells;
        std::vector<uint8_t> modifier_bytes;
        size_t modifier_cursor = 0;
        bool end_emitted = false;
    };

    struct RestoreState {
        bool active = false;
        // Live lanes stay intact until prepare_restore_candidate_scratch() runs
        // (only from the ECP2 backup/rollback transaction). Streaming feed
        // rejects chunks while this is false so begin_restore alone cannot
        // wipe or partially overwrite a committed snapshot.
        bool scratch_prepared = false;
        // BEGIN army personnel lane (contract §1.5): section 36 scratch guard.
        bool army_personnel_seen = false;
        // END army personnel lane
        bool stratum_mobilization_seen = false;
        bool header_seen = false;
        bool end_seen = false;
        bool ceilings_seen = false;
        int64_t expected_ceilings = 0;
        int64_t restored_ceilings = 0;
        int64_t last_ceiling_key = -1;
        bool failed = false;
        std::string error;
        int32_t expected_pages = 0;
        int32_t expected_commands = 0;
        int32_t expected_buildings = 0;
        int32_t expected_construction = 0;
        int32_t restored_pages = 0;
        int32_t restored_markets = 0;
        int32_t restored_cells = 0;
        int32_t restored_commands = 0;
        int32_t schema_version = 0;
        int64_t environment_hash = 0;
        int32_t restored_buildings = 0;
        int32_t restored_construction = 0;
        int32_t expected_audits = 0;
        int32_t restored_audits = 0;
        int32_t expected_signals = 0;
        int32_t restored_signals = 0;
        int32_t expected_labor_signals = 0;
        int32_t restored_labor_signals = 0;
        int32_t expected_trade_orders = 0;
        int32_t restored_trade_orders = 0;
        int32_t expected_trade_flows = 0;
        int32_t restored_trade_flows = 0;
        int32_t expected_tariff_history = 0;
        int32_t restored_tariff_history = 0;
        int32_t expected_country_good = 0;
        int32_t restored_country_good = 0;
        int32_t expected_country_partner = 0;
        int32_t restored_country_partner = 0;
        int32_t expected_canal_quotes = 0;
        int32_t restored_canal_quotes = 0;
        int32_t expected_canal_projects = 0;
        int32_t restored_canal_projects = 0;
        int32_t expected_persons = 0;
        int32_t expected_person_needs = 0;
        int32_t expected_fiscal = -1;
        int32_t restored_fiscal = 0;
        int32_t expected_fiscal_peer = -1;
        int32_t restored_fiscal_peer = 0;
        int32_t expected_d7_peer_ext = -1;
        int32_t restored_d7_peer_ext = 0;
        int64_t expected_resource_rows = 0;
        int64_t restored_resource_rows = 0;
        int64_t last_resource_key = -1;
        int32_t last_signal_cell = -1;
        int32_t last_signal_good = -1;
        int32_t last_labor_cell = -1;
        int32_t last_labor_profession = -1;
        std::vector<uint8_t> modifier_bytes;
        bool modifier_seen = false;
        bool fiscal_seen = false;
        bool fiscal_peer_seen = false;
        bool d7_peer_ext_seen = false;
        bool family_founding_seen = false;
        int32_t expected_family_founding_records = -1;
        int32_t restored_family_founding_records = 0;
        bool resource_stock_seen = false;
        bool cadence_state_seen = false;
        int32_t restored_cadence_cells = 0;
        bool committed_generation_seen = false;
        uint64_t restored_committed_generation = 0;
        std::vector<int32_t> track_b_investment_cells_pending;
        int64_t track_b_derived_cell_cache_day = -1000000;
        std::vector<TrackBDerivedCellWork> track_b_derived_cell_cache;
        std::vector<int32_t> military_ration_cells;
        std::vector<int32_t> military_ration_q16;
        bool settlement_names_seen = false;
        int32_t restored_families = 0;
        int32_t restored_family_memberships = 0;
        int32_t restored_family_ownerships = 0;
        std::vector<int32_t> family_colonization_population_reward_pending;
        bool family_records_seen = false;
        bool family_membership_seen = false;
        bool family_ownership_seen = false;
        int32_t restored_persons = 0;
        int32_t restored_person_needs = 0;
        // Expedition payload person lanes whose handle no longer resolves. Only
        // pre-fix saves carry these; the payload's population, funds and
        // attribution stay authoritative, so the lane is dropped, not rejected.
        int32_t dropped_transit_persons = 0;
        bool person_records_seen = false;
        bool person_needs_seen = false;
        int32_t restored_family_traits = 0;
        int32_t restored_family_influences = 0;
        int32_t restored_family_trait_commands = 0;
        int32_t expected_family_traits = 0;
        int32_t expected_family_influences = 0;
        int32_t expected_family_trait_commands = 0;
        bool family_traits_seen = false;
        bool family_influences_seen = false;
        bool family_trait_commands_seen = false;
        int32_t expected_family_expedition_slots = 0;
        int32_t expected_family_expeditions = 0;
        int32_t restored_family_expedition_slots = 0;
        int32_t restored_family_expeditions = 0;
        bool family_expeditions_seen = false;
        bool tariff_history_seen = false;
        bool country_good_seen = false;
        bool country_partner_seen = false;
        bool canal_quotes_seen = false;
        bool canal_projects_seen = false;
    };

    struct EventArchiveState {
        bool active = false;
        bool header_emitted = false;
        bool end_emitted = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        size_t batch_limit = 0;
        size_t batch_cursor = 0;
        size_t event_cursor = 0;
    };

    bool _configured = false;
    bool _bootstrapped = false;
    bool _epoch_active = false;
    bool _fatal = false;
    std::string _fatal_reason;
    // Forensics captured at the instant fail() runs. Without it a fatal only
