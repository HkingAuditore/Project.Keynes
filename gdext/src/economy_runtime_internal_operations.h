// Included inside NativeEconomyRuntime; preserve declaration order and access.
    struct ReadSubscription {
        ReadKey key;
        uint64_t last_access_us = 0;
        bool pending = true;
    };
    std::shared_ptr<const ReadView> _read_view;
    std::shared_ptr<const BuildingVisualView> _building_visual_view;
    mutable std::mutex _read_subscription_mutex;
    std::vector<ReadSubscription> _read_subscriptions;
    std::atomic<uint32_t> _read_subscription_count{0};
    std::mutex _building_visual_outbox_mutex;
    std::vector<int32_t> _building_visual_outbox;
    uint64_t _read_view_serial = 0;
    uint64_t _read_view_last_refresh_us = 0;
    std::atomic<uint64_t> _read_view_serve_count{0};
    std::atomic<uint64_t> _read_view_eval_count{0};
    std::atomic<uint64_t> _read_view_serve_us_total{0};
    std::atomic<uint64_t> _read_view_serve_us_max{0};
    std::atomic<uint64_t> _read_view_evicted_count{0};
    // Transient CSR baked from stable building order. Recovery reviews touch
    // only the current cell-modulo-review bucket instead of scanning all groups.
    std::vector<int32_t> _building_review_phase_offsets;
    std::vector<int32_t> _building_review_group_indices;
    std::vector<int32_t> _building_special_reset_group_indices;
    ChangeRegistry _building_role_changes;
    EconomyTrackedColumn<int64_t> _building_employee_filled{_building_role_changes, {{10, 1}, "building_roles.building_employee_filled", EconomyFieldEncoding::I64, 8}};
    // Inspector-only last purchased good per (building group, input slot).
    // This diagnostic lane is intentionally excluded from save and state hash.
    std::vector<int32_t> _building_last_input_selected_goods;
    EconomyTrackedColumn<int64_t> _building_role_contract_wage{_building_role_changes, {{10, 2}, "building_roles.building_role_contract_wage", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_living_cost{_building_role_changes, {{10, 3}, "building_roles.building_role_base_living_cost", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_living_cost{_building_role_changes, {{10, 4}, "building_roles.building_role_living_cost", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_local_average_wage{_building_role_changes, {{10, 5}, "building_roles.building_role_local_average_wage", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_wage_due{_building_role_changes, {{10, 6}, "building_roles.building_role_base_wage_due", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_wage_paid{_building_role_changes, {{10, 7}, "building_roles.building_role_base_wage_paid", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_bonus_due{_building_role_changes, {{10, 8}, "building_roles.building_role_bonus_due", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_bonus_paid{_building_role_changes, {{10, 9}, "building_roles.building_role_bonus_paid", EconomyFieldEncoding::I64, 8}};
    // Epoch-derived cold-start funding ceiling. This is rebuilt before
    // employment from demand-backed absorption and is intentionally excluded
    // from PKEC and the authoritative state hash.
    std::vector<int32_t> _building_role_forecast_pay_ratio_q16;
    // A+Y N8: pending construction lives in buildings_store().pending_*; hot
    // paths reach it through pending_construction() / pending_construction_at().
    // Epoch-transient stable CSR over those pending columns. This removes the
    // previous all-pending scan from every active building cell.
    std::vector<int32_t> _pending_construction_cell_offsets;
    std::vector<int32_t> _pending_construction_cell_indices;
    EconomyTrackedScalar<int64_t> _building_catalog_hash{_metadata_changes, {{15, 1}, "metadata.building_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _building_catalog_compat_hash_v6 = 0;
    int64_t _building_catalog_compat_hash_v7 = 0;
    int64_t _building_catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v8 = 0;
    EconomyTrackedScalar<int64_t> _catalog_compat_hash_v10{_metadata_changes, {{15, 2}, "metadata.catalog_compat_hash_v10", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v39 = 0;
    EconomyTrackedScalar<int64_t> _family_catalog_hash{_metadata_changes, {{15, 40}, "config.family_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _family_catalog_compat_hash_v39 = 0;
    EconomyTrackedScalar<int32_t> _family_trait_catalog_version{_metadata_changes, {{15, 15}, "metadata.family_trait_catalog_version", EconomyFieldEncoding::I32, 4}, 0};
    EconomyTrackedScalar<int64_t> _family_trait_catalog_hash{_metadata_changes, {{15, 14}, "metadata.family_trait_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int32_t _family_core_trait_min = 0;
    int32_t _family_core_trait_max = 0;
    std::vector<std::string> _family_trait_ids;
    std::vector<std::string> _family_trait_display_names;
    std::vector<int32_t> _family_trait_weights;
    std::vector<uint8_t> _family_trait_core_eligible;
    std::vector<int32_t> _family_trait_strength_min_q16;
    std::vector<int32_t> _family_trait_strength_max_q16;
    std::vector<int32_t> _family_trait_strength_step_q16;
    std::vector<int32_t> _family_trait_prerequisite_offsets;
    std::vector<int32_t> _family_trait_prerequisites;
    std::vector<int32_t> _family_trait_exclusion_offsets;
    std::vector<int32_t> _family_trait_exclusions;
    std::vector<int32_t> _family_trait_technology_prerequisite_offsets;
    std::vector<int32_t> _family_trait_technology_prerequisites;
    std::vector<uint8_t> _family_trait_technology_match_any;
    std::vector<int32_t> _family_trait_behavior_offsets;
    std::vector<int32_t> _family_trait_behavior_axes;
    std::vector<int32_t> _family_trait_behavior_selector_kinds;
    std::vector<int32_t> _family_trait_behavior_selector_ids;
    std::vector<int32_t> _family_trait_behavior_factors_q16;
    std::vector<int32_t> _family_trait_behavior_score_terms;
    std::vector<int32_t> _family_trait_behavior_condition_offsets;
    std::vector<int32_t> _family_trait_behavior_condition_ops;
    std::vector<int32_t> _family_trait_behavior_condition_arg0;
    std::vector<int64_t> _family_trait_behavior_condition_values;
    // Catalog-derived union of metric operands; never persisted or hashed.
    std::vector<MetricMask> _family_trait_behavior_metric_masks;
    std::vector<int32_t> _family_trait_modifier_offsets;
    std::vector<std::string> _family_trait_modifier_definition_keys;
    std::vector<int32_t> _family_trait_modifier_targets;
    std::vector<int32_t> _family_trait_modifier_tier_magnitudes_q16;
    std::vector<int32_t> _family_trait_trigger_offsets;
    std::vector<std::string> _family_trait_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_trait_trigger_reward_targets;
    std::vector<int32_t> _family_trait_effect_offsets;
    std::vector<std::string> _family_trait_effect_keys;
    std::vector<int32_t> _family_trait_origin_landform_offsets;
    std::vector<uint8_t> _family_trait_origin_landforms;
    std::vector<uint8_t> _family_trait_origin_adjacent_water;
    std::vector<int32_t> _family_trait_origin_population_max;
    std::vector<int32_t> _family_trait_origin_temperature_max_q16;
    std::vector<int32_t> _family_trait_required_resource_offsets;
    std::vector<int32_t> _family_trait_required_resource_ids;
    std::vector<uint8_t> _family_trait_require_tax_or_subsidy;
    int32_t _family_effect_catalog_version = 0;
    int64_t _family_effect_catalog_hash = 0;
    std::vector<std::string> _family_effect_keys;
    std::vector<int32_t> _family_effect_source_kinds;
    std::vector<int32_t> _family_effect_weights;
    std::vector<uint8_t> _family_effect_random_pool_eligible;
    std::vector<int32_t> _family_effect_prerequisite_offsets;
    std::vector<int32_t> _family_effect_prerequisites;
    std::vector<uint8_t> _family_effect_technology_match_any;
    std::vector<int32_t> _family_effect_exclusion_offsets;
    std::vector<int32_t> _family_effect_exclusions;
    std::vector<int32_t> _family_effect_magnitude_by_prestige_q16;
    std::vector<std::string> _family_effect_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_effect_trigger_reward_targets;
    int32_t _family_corn_good_id = -1;
    int32_t _family_knowledge_class_index = -1;
    struct PendingFamilySplitGift {
        uint64_t family_handle = 0;
        int32_t cell = -1;
        uint16_t flags = 0;
        int32_t building_type_id = -1;
        int32_t building_count = 1;
        int64_t population = 0;
    };
    std::vector<PendingFamilySplitGift> _pending_family_split_gifts;
    std::string _family_surname_pack_id = "default_zh";
    std::vector<std::string> _family_surname_ids;
    std::vector<std::string> _family_surname_text;
    std::vector<int32_t> _family_surname_weights;
    std::vector<int32_t> _family_surname_culture_group_ids;
    std::vector<std::string> _family_culture_group_ids;
    std::vector<std::string> _family_culture_group_display_names;
    std::vector<std::string> _family_culture_group_naming_formats;
    std::vector<std::string> _family_culture_group_separators;
    std::vector<std::string> _family_culture_group_suffixes;
    EconomyTrackedScalar<int64_t> _person_catalog_hash{_metadata_changes, {{15, 73}, "config.person_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    std::string _person_given_name_pack_id = "default_zh";
    std::vector<std::string> _person_given_name_ids;
    std::vector<std::string> _person_given_name_text;
    std::vector<int32_t> _person_given_name_weights;

    // Notable-family policy. The anonymous majority remains implicit.
    EconomyTrackedScalar<int32_t> _family_runtime_mode{_metadata_changes, {{15, 45}, "config.family_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _family_review_days{_metadata_changes, {{15, 44}, "config.family_review_days", EconomyFieldEncoding::I32, 4}, 30};
    // Ascending committed-population thresholds; each one crossed by a cell
    // produces one founding offer. Starter capital founders do not count.
    std::vector<int64_t> _family_milestone_populations{
        100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    EconomyTrackedScalar<int64_t> _family_min_founder_people{_metadata_changes, {{15, 43}, "config.family_min_founder_people", EconomyFieldEncoding::I64, 8}, 30};
    int32_t _family_founding_choice_mode = 1; // 0=AUTO, 1=PLAYER.
    EconomyTrackedScalar<int64_t> _family_split_population_threshold{_metadata_changes, {{15, 46}, "config.family_split_population_threshold", EconomyFieldEncoding::I64, 8}, 100};
    EconomyTrackedScalar<int32_t> _family_max_per_cell{_metadata_changes, {{15, 42}, "config.family_max_per_cell", EconomyFieldEncoding::I32, 4}, 8};
    int32_t _family_cells_per_slice = 128;
    EconomyTrackedScalar<int32_t> _family_decline_reviews{_metadata_changes, {{15, 41}, "config.family_decline_reviews", EconomyFieldEncoding::I32, 4}, 3};
    // Notable households include dependents of the owned owner posts, not just
    // the two shopkeepers. Anonymous majority stays implicit.
    int32_t _family_household_people_per_owner_slot = 256;
    int32_t _family_household_max_people = 1024;
    EconomyTrackedScalar<int32_t> _person_runtime_mode{_metadata_changes, {{15, 78}, "config.person_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _person_max_per_family{_metadata_changes, {{15, 75}, "config.person_max_per_family", EconomyFieldEncoding::I32, 4}, 4};
    EconomyTrackedScalar<int32_t> _person_max_per_cell{_metadata_changes, {{15, 74}, "config.person_max_per_cell", EconomyFieldEncoding::I32, 4}, 128};
    EconomyTrackedScalar<int32_t> _person_max_total{_metadata_changes, {{15, 76}, "config.person_max_total", EconomyFieldEncoding::I32, 4}, 65536};
    EconomyTrackedScalar<int32_t> _person_records_per_slice{_metadata_changes, {{15, 77}, "config.person_records_per_slice", EconomyFieldEncoding::I32, 4}, 4096};

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    godot::Dictionary run_slice_internal(const godot::Dictionary &ctx, bool compact);
    godot::Dictionary compact_report() const;
    godot::Dictionary household_slice_breakdown_ms() const;
    godot::Dictionary household_slice_breakdown_work() const;
    bool start_epoch(int64_t day_index, std::string &error);
    bool finish_epoch_start_after_fiscal(int64_t day_index,
                                         std::string &error);
    bool trade_planner_should_run() const;
    bool run_trade_planner_slice(int64_t &work_done, std::string &error);
    bool begin_trade_plan_slice(int64_t &work_done, std::string &error);
    bool trade_vision_allows_pair(int32_t source, int32_t destination) const;
    bool route_trade_source(int32_t source_index, int32_t expansion_budget,
                            int32_t &expansions_done, bool &source_done,
                            std::string &error);
    int32_t cached_trade_route_cost(int32_t source, int32_t destination,
                                    int32_t country, int32_t &expansions);
    void collect_transport_successors(int32_t cell, uint8_t cap, bool reverse);
    void build_water_transport_graphs();
    void build_water_portal_graph(int32_t graph_index);
    void build_water_component_layers();
    bool reconstruct_water_corridor(int32_t from_portal, int32_t to_portal,
                                    uint8_t cap,
                                    std::vector<int32_t> &water_cells) const;
    void fill_trade_water_columns(const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *has_river, int32_t count,
                                  std::vector<uint8_t> &water_class,
                                  std::vector<uint8_t> &river) const;
    bool append_colonization_route_step(int32_t from_cell, int32_t to_cell,
                                        uint8_t cap, int64_t reverse_from,
                                        int64_t reverse_to,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int64_t &running) const;
    static uint64_t trade_route_cache_key(int32_t source, int32_t destination,
                                          int32_t layer);
    int32_t estimate_trade_price(int32_t market, int32_t good,
                                 int64_t stock_after, int64_t &sat) const;
    int64_t trade_relief_pressure_q16(int32_t market, int32_t good,
                                      int64_t &sat) const;
    int64_t trade_local_stock_target(int32_t market, int32_t good,
                                     int64_t &sat) const;
    int64_t trade_export_floor(int32_t market, int32_t good,
                               int64_t &sat) const;
    int64_t profitable_trade_quantity(int32_t source, int32_t destination,
                                      int32_t good, int64_t max_quantity,
                                      bool relief_route, int32_t &source_price,
                                      int32_t &destination_price,
                                      int64_t &profit, int64_t &margin_q16,
                                      int64_t &sat) const;
    TradeQuote make_trade_quote(int32_t source, int32_t destination,
                                int32_t good, int64_t quantity,
                                int32_t source_price,
                                int32_t destination_price,
                                bool relief_route,
                                int64_t &saturation_count) const;
    int64_t merchant_inventory_target(int32_t market, int32_t good,
                                      int32_t signal_index,
                                      int64_t realized_withdrawal,
                                      int64_t export_ema,
                                      int64_t cold_start_daily_supply,
                                      int64_t &sat) const;
    int64_t merchant_procurement_quota(int32_t market, int32_t good,
                                       int32_t signal_index,
                                       int64_t sellable,
                                       int64_t target,
                                       int64_t stock,
                                       int64_t realized_withdrawal,
                                       int64_t export_ema,
                                       int64_t &sat) const;
    int32_t effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const;
    bool settle_due_trade_orders(std::string &error);
    bool dispatch_trade_candidates(std::string &error);
    void update_trade_flow_ema();
    int32_t trade_flow_index(int32_t cell, int32_t good, bool create);
    int32_t trade_signal_clock_index(int32_t cell, int32_t good) const;
    int32_t ensure_trade_signal_clock_index(int32_t cell, int32_t good);
    void ensure_trade_signal_clock_keys_bulk(
        const std::vector<uint64_t> &sorted_unique_keys);
    void record_trade_signal_attempt(int32_t cell, int32_t good, int32_t reason);
    void refresh_trade_response_diagnostics();
    int64_t credit_trade_sellers(int32_t order_index, int64_t amount,
                                 int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS);
    int64_t debit_trade_sellers(int32_t order_index, int64_t amount,
                                int32_t cashflow_source);
    void rebuild_trade_arrival_buckets();
    void compact_trade_orders(const std::vector<uint8_t> &remove);
    void rebuild_country_trade_indices();
    void sort_dirty_country_trade_display_indices();
    int64_t trade_transit_goods() const;
    int64_t trade_escrow_cash() const;
    bool apply_command(const Command &cmd, std::string &error);
    Command command_from_pod(const RuntimeEconomyPodCommand &pod) const;
    bool validate_command_pod(const Command &cmd, std::string &error) const;
    bool family_ledger_command_preflight(const Command &cmd) const;
    bool family_split_policy_command_preflight(const Command &cmd) const;
    bool apply_family_free_building_reward(const Command &cmd,
                                           std::string &error);
    bool apply_family_population_reward(const Command &cmd,
                                        std::string &error);
    bool apply_family_absorb_anonymous(const Command &cmd,
                                       std::string &error);
    bool apply_family_purchase_discount(const Command &cmd,
                                        std::string &error);
    bool apply_family_set_split_policy(const Command &cmd,
                                       std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    // BEGIN army personnel lane (contract §1.2/§1.3).
    bool apply_army_lane_command(const Command &cmd, std::string &error,
                                 int64_t &settled);
    // Army pay's treasury debit when Country is worker-authoritative (army-pay
    // contract §1.1). The synchronous fiscal escrow (`military_collect_cash`) is
    // refused there, so this drives the same Country economy-asset peer the cohort
    // cash lane uses — prepare, service, finish — synchronously on the worker
    // thread inside one epoch. That is what keeps the treasury debit and the lane
    // credit in the SAME audit window; deferring to the enqueue-only route instead
    // splits them and closes the epoch with money_conservation_failed.
    // `moved` is what Country actually committed (<= requested).
    bool pay_army_lane_from_worker_country(uint64_t army_handle, int64_t country_handle,
                                           int64_t requested, int64_t &moved,
                                           std::string &error);
    // Cohort side of 30/31. Inside an epoch the record joins the structural
    // stage that still runs later in this same epoch; between epochs (the POD
    // drain at a committed day boundary) that day's structural stage has already
    // run, so the same record is committed through the same structural path
    // immediately — queueing there would delay a D+1 batch by a whole epoch and
    // the lane would not be visible to the D+1 read.
    bool queue_or_commit_army_lane(const StructuralCommand &record,
                                   std::string &error, int64_t &moved);
    // `moved_out` reports the heads that actually crossed (a no-op reports 0).
    bool commit_structural_army_lane(const StructuralCommand &cmd,
                                     std::string &error,
                                     int64_t *moved_out = nullptr);
    int64_t army_lane_country_handle(int32_t cell) const;
    void run_army_personnel_consumption(int32_t market, MarketResult &result);
    void sum_army_personnel_holdings(int64_t &population, int64_t &funds,
                                     int64_t &saturation_count) const;
    // END army personnel lane
    // Core cohort migration primitive extracted from commit_structural. Moves up
    // to `requested_pop` people from `source` into the (dest_cell, dest_signature)
    // cohort, carrying a proportional share of funds/income/expense/ema/residual,
    // population-weighting needs_satisfaction, and transferring any rounding
    // residue of a fully-drained source to the treasury (never burned). Pushes
    // both cells onto _structural_touched_cells and appends a structural trace.
    // Callers are responsible for command-level guards (profession_available,
    // same-cell/same-signature no-op) before invoking it. Returns false only on a
    // hard failure (allocation / treasury transfer); an empty move is a no-op true.
    //
    // `source_drained_out` (optional): set to true when the move emptied `source`
    // and released its slot, false otherwise. The employment pass (in-line layoff
    // / hiring) iterates a *snapshot* of a cell's slots -- it must never migrate
    // from inside for_each_in_cell -- and uses this flag to skip a snapshot slot
    // that a prior migration in the same loop already released, preventing
    // stale-slot reuse. When null it is ignored (commit_structural path).
    bool move_cohort_population(int32_t source, int32_t dest_cell,
                                int32_t dest_signature, int64_t requested_pop,
                                std::string &error,
                                bool *source_drained_out = nullptr,
                                uint64_t preferred_family_handle = 0,
                                bool preferred_family_strict = false);
    bool apply_start_family_expedition(const Command &cmd,
                                       std::string &error);
    bool apply_cancel_family_expedition(const Command &cmd,
                                        std::string &error);
    bool apply_settle_family_expedition(const Command &cmd,
                                        std::string &error);
    bool extract_family_expedition_payload(int32_t expedition,
                                           int64_t requested,
                                           std::string &error);
    void clip_cell_employment_and_defer_reconcile(int32_t cell);
    bool preparing_kit_launchable(const ColonizationKitPlan &kit,
                                  int64_t people) const;
    void unwind_family_expedition_payload_extract(int32_t expedition);
    bool extract_family_expedition_cargo(int32_t expedition,
                                         const ColonizationKitPlan &kit,
                                         std::string &error);
    bool restore_family_expedition_cargo(int32_t expedition,
                                         int32_t destination_cell,
                                         bool consume_construction,
                                         std::string &error);
    bool restore_family_expedition_payload(int32_t expedition,
                                            int32_t destination_cell,
                                            std::string &error);
    bool settle_family_expedition_kit(int32_t expedition,
                                      int32_t destination_cell,
                                      std::string &error);
    bool finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error);
    void release_family_expedition_reservations(int32_t expedition);
    bool process_due_family_expeditions(int64_t day, std::string &error);
    int64_t family_expedition_displayed_population(int32_t expedition) const;
    int64_t market_stock(int32_t cell, int32_t good_id) const;
    bool colonization_good_is_tools(int32_t good_id) const;
    uint64_t hash_preparing_missing_stock(int32_t source_cell,
                                          const int32_t *good_ids,
                                          uint32_t count) const;
    void store_preparing_missing_goods(int32_t expedition,
                                       const ColonizationKitPlan &kit);
    void refresh_preparing_family_expedition_missing(int32_t expedition);
    void abort_preparing_family_expedition(int32_t expedition, int64_t day,
                                           uint8_t kind, const char *code);
    bool launch_preparing_family_expedition(int32_t expedition, int64_t day,
                                            const ColonizationKitPlan &kit,
                                            std::string &error);
    bool advance_preparing_family_expedition(int32_t expedition, int64_t day,
                                             std::string &error);
    bool family_expedition_settle_inflight(uint64_t expedition_handle) const;
    void recover_lost_family_settlement_commands();
    bool stage_allows_in_epoch_family_settlement() const;
    void queue_family_settlement_command(const Command &command);
    void rebuild_family_expedition_indices();
    void push_family_expedition_due(int32_t expedition);
    void append_colonization_receipt(int32_t expedition, int64_t sequence,
                                     int64_t effective_day, int64_t settled_day,
                                     uint8_t kind, const char *code);
    void append_colonization_command_receipt(uint64_t country_handle,
                                             uint64_t expedition_handle,
                                             int32_t target_cell,
                                             int64_t sequence,
                                             int64_t effective_day,
                                             int64_t settled_day,
                                             uint8_t kind, const char *code);
    bool pending_family_expedition_target_taken(uint64_t country_handle,
                                                int32_t target_cell) const;
    bool pending_family_expedition_cancel_taken(uint64_t expedition_handle) const;
    bool has_pending_family_expedition_player_command() const;
    bool apply_family_expedition_player_command(const Command &cmd,
                                                std::string &error);
    int64_t family_population_in_cell(uint64_t family_handle,
                                      int32_t cell) const;
    int64_t family_dispatchable_population_in_cell(uint64_t family_handle,
        int32_t cell) const;
    bool colonization_target_owner_allowed(uint64_t country_handle,
                                           int32_t cell) const;
    bool colonization_destination_family_allowed(uint64_t family_handle,
                                                 int32_t cell) const;
    bool plan_family_colonization_route(uint64_t country_handle,
                                        int32_t source_cell,
                                        int32_t target_cell,
                                        const uint8_t *visible,
                                        int32_t visible_count,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int32_t &cost,
                                        std::string &error);
    uint64_t colonization_visibility_hash(const uint8_t *visible,
                                          int32_t count) const;
    uint64_t family_expedition_target_key(uint64_t country_handle,
                                          int32_t target_cell) const;
    bool cell_has_submitted_or_pending_buildings(int32_t cell) const;
    bool colonization_kit_type_eligible(int32_t source_cell, int32_t target_cell,
                                        int32_t type_id, bool frozen) const;
    int64_t colonization_kit_output_per_building(int32_t target_cell,
                                                 int32_t type_id,
                                                 int32_t good_id) const;
    int64_t colonization_kit_input_per_building(int32_t type_id,
                                                int32_t good_id) const;
    int64_t colonization_kit_daily_food_required(int32_t target_cell,
                                                 int64_t population) const;
    uint64_t hash_colonization_kit_plan(const ColonizationKitPlan &kit) const;
    void fill_colonization_kit_buffer(int32_t source_cell, int32_t target_cell,
                                      int64_t population, int32_t travel_days,
                                      ColonizationKitPlan &kit,
                                      const ColonizationReserveContext *reserve
                                          = nullptr,
                                      int32_t bridge_days_override = 0) const;
    void collect_family_expedition_reserved_stock(
        int32_t expedition, std::vector<int64_t> &reserved) const;
    bool reserve_preparing_family_expedition_cargo(
        int32_t expedition, ColonizationKitPlan &kit,
        std::string &error, int64_t day = -1);
    void note_family_expedition_procurement_rejection(
        int32_t expedition, int32_t good, uint8_t cargo_flags, int64_t day,
        const std::string &reason);
    bool advance_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &continuation,
        std::string &error);
    bool credit_family_expedition_procurement_merchants(
        FamilyExpeditionProcurementContinuation &continuation,
        std::string &error);
    bool settle_family_expedition_procurement_orphans(std::string &error);
    bool start_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &continuation,
        int32_t expedition, int32_t source_cell, int32_t market,
        int32_t good, uint8_t cargo_flags, int64_t quantity, int64_t cash,
        std::string &error);
    void add_colonization_kit_cargo(ColonizationKitPlan &kit, int32_t good_id,
                                    int64_t quantity, uint8_t flags,
                                    int64_t &sat) const;
    void sort_colonization_kit_cargo(ColonizationKitPlan &kit) const;
    bool plan_colonization_kit(int32_t source_cell, int32_t target_cell,
                               int64_t population, int32_t travel_days,
                               bool frozen, ColonizationKitPlan &kit,
                               bool ignore_existing = false,
                               const ColonizationReserveContext *reserve
                                   = nullptr) const;
    bool adjust_market_stock(int32_t cell, int32_t good_id, int64_t delta,
                             std::string &error);
    bool publish_epoch_slice(int64_t &work_done, std::string &error);
    void reset_publish_state();
    bool compile_building_catalog(const godot::Dictionary &catalog, std::string &error);
    bool compile_carrying_catalog(const godot::Dictionary &catalog, std::string &error);
    void refresh_epoch_carrying_yields();
    int64_t carrying_mix_q16(int64_t value_q16, int32_t elasticity_q16,
                             int64_t &sat) const;
    int64_t carrying_climate_habitability_q16(int32_t cell, int64_t &sat) const;
    int64_t carrying_resource_stock(int32_t resource_id, int32_t cell) const;
    int64_t cell_k_geo_persons(int32_t cell, int64_t &sat) const;
    int64_t cell_family_surplus_q16(int32_t market, int32_t cell, int32_t family,
                                    int64_t food_filled, int64_t food_desired,
                                    const int64_t *good_demand,
                                    const int64_t *good_sales,
                                    int64_t &sat) const;
    void append_carrying_capacity_fields(godot::Dictionary &out,
                                         int32_t cell_idx) const;
    void commit_food_flow_snapshot();
    // Returns the period food-supported population capacity using both net
    // flow and a bounded, reserve-aware local market stock buffer.
    int64_t food_flow_capacity_for_cell(int32_t cell, int64_t &k_geo,
                                        int64_t &sat) const;
    void accumulate_trade_food_flow(int32_t cell, int32_t good,
                                    int64_t import_qty, int64_t export_qty,
                                    int64_t &sat);
    bool evaluate_building_conditions(int32_t type_id, int32_t cell) const;
    bool cell_has_technology(int32_t cell, int32_t technology_id, bool frozen) const;
    bool cell_has_requirements(int32_t cell, int32_t begin, int32_t end,
                               const std::vector<int32_t> &requirements,
                               bool frozen) const;
    bool cell_has_all_requirements(int32_t cell, int32_t begin, int32_t end,
                                   const std::vector<int32_t> &requirements,
                                   bool frozen) const;
    bool good_production_available(int32_t cell, int32_t good_id,
                                   bool frozen = true) const;
    bool good_market_available(int32_t cell, int32_t good_id,
                               bool frozen = true) const;
    // Soft/production input discovery: physical stock is always usable;
    // empty shelves only admit locally producible (tech-unlocked) SKUs or
    // goods with positive offered supply. Trade-enabled-but-locked goods
    // must not absorb category demand via ghost ceiling prices.
    bool good_input_candidate_available(int32_t cell, int32_t good_id,
                                        bool frozen = true) const;
    // Compatibility name for callers that are explicitly asking for the
    // technology gate (UI/building unlock queries).
    bool good_available(int32_t cell, int32_t good_id, bool frozen = true) const;
    bool profession_available(int32_t cell, int32_t profession_id,
                              bool frozen = true) const;
    bool building_available(int32_t cell, int32_t type_id,
                            bool frozen = true) const;
    bool building_dependency_requirements_met(int32_t cell, int32_t type_id,
                                              bool frozen) const;
    bool building_dependency_group_required_for_operation(int32_t group) const;
    bool building_constructible(int32_t cell, int32_t type_id,
                                bool frozen = true) const;
    int64_t allocated_output_operating_cost(
        const BuildingType &type, int32_t output_index,
        int64_t operating_cost, int64_t &sat) const;
    // O(1) signature lookup helpers backed by _signature_by_profession_ethnicity.
    // Return -1 when no such signature exists (e.g. unemployed profession absent).
    inline int32_t signature_for_profession_ethnicity(int32_t profession_id,
                                                       int32_t ethnicity_id) const {
        if (profession_id < 0 || ethnicity_id < 0) return -1;
        const int32_t n_eth = static_cast<int32_t>(_ethnicity_ids.size());
        if (ethnicity_id >= n_eth) return -1;
        const size_t idx = static_cast<size_t>(profession_id) * static_cast<size_t>(n_eth) +
                           static_cast<size_t>(ethnicity_id);
        if (idx >= _signature_by_profession_ethnicity.size()) return -1;
        return _signature_by_profession_ethnicity[idx];
    }
    inline int32_t unemployed_signature_for_ethnicity(int32_t ethnicity_id) const {
        return signature_for_profession_ethnicity(_unemployed_profession_id, ethnicity_id);
    }
    // Military v1: a state-service (soldier) signature is locked to its own
    // profession. Every outward transfer lane (employee<->employee, owner moves,
    // unemployed reflux, family colonization draw, migration) asks this first.
    inline bool signature_is_state_service_only(int32_t signature_id) const {
        return signature_id >= 0 &&
            static_cast<size_t>(signature_id) < _signatures.size() &&
            profession_is_state_service_only(
                _signatures[static_cast<size_t>(signature_id)].profession_id);
    }
    // Allocation-free per-cell scan used by the outward-transfer guard: true when
    // `cell` still holds at least `people` members of any state-service cohort.
    bool cell_has_state_service_population(int32_t cell) const;
    void configure_satisfaction_profile(const godot::Dictionary &profile);
    bool satisfaction_need_available(const Need &need, int32_t cell) const;
    uint8_t satisfaction_applicable_mask(int32_t slot) const;
    std::array<int64_t, SAT_DIM_COUNT> satisfaction_effective_weights(
        const Signature &signature, uint8_t applicable_mask) const;
    int64_t satisfaction_bias_q16(int32_t cell, const Signature &signature) const;
    int64_t satisfaction_ceiling(const int64_t *dims, uint8_t applicable_mask,
                                const Signature &signature, int32_t &binding_dimension,
                                int64_t &sat) const;
    int32_t consumption_living_standard_level(int32_t slot) const;
    // `out_pending_city_factors` (optional) is set when the city-factor shard
    // yielded and needs another call. It is NOT an error: `start_epoch` must
    // park and resume rather than fail, because failing would abort the day.
    bool capture_country_epoch(std::string &error,
                               bool *out_pending_city_factors = nullptr);
    // Rebuilds _epoch_country_cell_offsets / _epoch_country_cells from
    // _epoch_cell_country. Counting sort in three linear passes, called once per
    // epoch capture rather than per selector query. Clears both columns when the
    // ownership column is absent or no country count is known, which is what
    // makes the consumers' linear-scan fallback kick in.
    void rebuild_country_territory_index();
    // Rebuilds X12's derived geography columns only when territory or canal
    // topology changed. `geo_flags_rebuilds` is the idle no-op evidence.
    void rebuild_epoch_geo_columns();
    // Rebuilds X9-a's per-cell family aggregates only when a tracked branch
    // column changes. Returns true when the cache was rebuilt.
    bool rebuild_epoch_family_cell_metrics();
    bool rebuild_epoch_family_country_metrics();
    // X13a persistent counters advance once per daily epoch, before the tag
    // snapshot is rebuilt. capture_environment only derives today's hazard.
    bool advance_climate_day_columns(std::string &error);
    // Refreshes X14's country scalars from the last committed class-opinion
    // snapshot at the start of the country epoch capture, reusing the previous
    // rows when the snapshot revision has not advanced.
    void refresh_class_opinion_metrics();
    // Rebuilds X10's per-country technology counts only when the frozen
    // technology bitset content changes. The four domain masks were compiled
    // once at configure.
    void refresh_technology_metrics();
    // R-3: builds BOTH per-epoch tag tables into a NEW immutable `TagSnapshot` and
    // publishes it with a single atomic store. The only writer.
    //
    // Callers must hold the economy input capture lock (`try_lock_economy_input_capture`)
    // or be the thread that owns the epoch columns: the snapshot is built from
    // `_target_tags`, `_cell_count` and `_epoch_cell_country`, so building it while
    // those move would publish a torn answer.
    //
    // R-3b: reentrancy is COUNTED and refused, not compiled away. `_tag_snapshot_building`
    // is the "only one thread may be in here" assertion: two concurrent builds would
    // race on `_published_tag_snapshot_generation` and could publish two snapshots
    // carrying the same generation, which a reader would then read as "unchanged".
    // The loser returns immediately and keeps the previously published snapshot --
    // stale at worst, never torn.
    void rebuild_epoch_tag_snapshot();
    // R-3b: does ANYTHING read the tag bits or metric 67 this epoch?
    //
    // The tables cost a full per-cell metric sample plus a per-country sweep. When
    // the catalog declares neither (an all-national-Modifier catalog, which is 55 of
    // the shipped 85 cards), paying it every epoch is pure waste -- and the caller
    // cannot tell, because the answer is invisible unless someone asks.
    //
    // Conservative on purpose: before any consumer set is published the answer is
    // YES, so a world that never configures ideology, and the selector fixtures that
    // drive `set_target_tags()` directly, keep working with no extra wiring. The
    // skip therefore applies only where something has explicitly declared a consumer
    // set and that set asked for neither.
    bool tag_snapshot_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->tags_needed || consumers->metric_mask.test(
            FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT);
    }
    // Whether the TAG BITS half is wanted (vs metric 67, which owns its own pass).
    bool tag_bits_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->tags_needed;
    }
    bool specialized_good_count_needed() const {
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        if (consumers == nullptr) return true;
        return consumers->metric_mask.test(
            FAMILY_METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT);
    }
    // Counters behind the lazy decision. `tag_snapshot_builds` is the evidence that
    // the skip works: an idle epoch whose catalog uses no tags must not increment it.
    uint64_t tag_snapshot_builds() const {
        return _tag_snapshot_builds.load(std::memory_order_relaxed);
    }
    uint64_t tag_snapshot_skips() const {
        return _tag_snapshot_skips.load(std::memory_order_relaxed);
    }
    uint64_t tag_snapshot_concurrent_writes() const {
        return _tag_snapshot_concurrent_writes.load(std::memory_order_relaxed);
    }
    // The published tables, or null before the first commit. ONE atomic load: the
    // returned pointer keeps the storage alive for the whole read even if a later
    // epoch swaps in a replacement, which is what makes readers safe without a lock.
    std::shared_ptr<const TagSnapshot> tag_snapshot() const {
        // R-3b: counts every load, so a per-cell loop that took the lock once per cell
        // is visible as a number instead of as a mysterious latency.
        _tag_snapshot_loads.fetch_add(1, std::memory_order_relaxed);
        auto snapshot = std::atomic_load_explicit(&_tag_snapshot,
                                                  std::memory_order_acquire);
        if (snapshot == nullptr)
            _last_tag_snapshot_miss_count.fetch_add(1, std::memory_order_relaxed);
        return snapshot;
    }
    // Total `tag_snapshot()` calls. Exported so the "load once outside the loop" rule
    // is checkable: a selector that scans N cells must cost O(1) loads, not O(N).
    int64_t tag_snapshot_loads() const {
        return _tag_snapshot_loads.load(std::memory_order_relaxed);
    }
    // R-3b: the per-CELL half of `cell_has_target_tag`, split out so a loop can do
    // the `atomic_load` ONCE and still ask per cell.
    //
    // `atomic_load(shared_ptr)` on MSVC takes a process-wide spin lock (the refcount
    // bump is not lock-free), so the old shape -- one load per cell, inside a
    // per-cell loop -- serialized every thread in the process against every tag scan.
    // Callers with a loop must load once and pass the snapshot in.
    static bool snapshot_has_tag(const TagSnapshot *snapshot, int32_t cell,
                                 int32_t tag) {
        if (snapshot == nullptr || tag < 0 || cell < 0) return false;
        if (snapshot->tag_words <= 0) return false;
        const size_t index = static_cast<size_t>(tag) *
            static_cast<size_t>(snapshot->tag_words) + static_cast<size_t>(cell / 64);
        if (index >= snapshot->tag_bits.size()) return false;
        return (snapshot->tag_bits[index] & (uint64_t{1} << (cell % 64))) != 0;
    }
    // Number of readers that found the tag snapshot unbuilt. Must be 0 on any world
    // that has completed one commit, so a caller that starts reading before commit
    // is visible instead of silently getting empty bits.
    // M4 observability: how long a tag-snapshot rebuild costs, and how many of
    // them happened. The M4 task list asks for "stamp / touched scratch, per-tag
    // changed words" -- a per-change incremental update -- and that is only worth
    // building if a FULL rebuild is actually expensive. These two numbers are what
    // decides it; without them the optimisation would be speculation.
    double last_tag_snapshot_build_ms() const {
        return _last_tag_snapshot_build_ms.load(std::memory_order_relaxed);
    }
    int64_t tag_snapshot_build_count() const {
        return _tag_snapshot_build_count.load(std::memory_order_relaxed);
    }
    int64_t last_tag_snapshot_miss_count() const {
        return _last_tag_snapshot_miss_count.load(std::memory_order_relaxed);
    }
    // X7: per-country counts live inside the same `TagSnapshot` (see
    // `tag_snapshot()`), because they are derived from the same tag bits and must
    // never be read from a different epoch than the bits they describe.
    // Counts, per country, how many distinct goods have at least one specialized
    // cell. Built into the epoch `TagSnapshot`; there is no lazy path any more.
    // True when the CSR is self-consistent with _epoch_country_count, i.e. its
    // slice table covers every slot and its last offset equals the cell list
    // length. Consumers use this to decide between O(1) index reads and the
    // linear-scan fallback, so a half-built index can never be read.
    bool country_territory_index_ready() const;
    void refresh_epoch_development();
    // Writes the authoritative composite/dimension columns for one cohort and
    // returns the composite. `tier_*_q16` point at the SAT_TIER_COUNT-wide slice
    // the household need reduction just produced for this cohort.
    int64_t update_cohort_satisfaction(int32_t slot, int32_t cell,
                                       int64_t subsistence_q16,
                                       const Signature &signature,
                                       const int64_t *tier_weighted_q16,
                                       const int64_t *tier_weight_q16,
                                       int64_t basic_min_fill_q16,
                                       int64_t &sat);
    int64_t normalize_band_q16(int64_t value, int64_t floor, int64_t ceiling,
                               int64_t &sat) const;
    int32_t living_standard_level_for(int64_t composite_q16) const;
    // Social-pressure level 0..4, ascending with satisfaction: 0 is the most
    // distressed band and 4 is contentment.
    int32_t social_pressure_level_for(int64_t composite_q16) const;
    void publish_social_pressure_facts();
    void rebuild_building_visual_social();
    // Returns true when a presentation band of `cell` changed.
    bool update_building_visual_social(int32_t cell, int64_t population,
                                       int64_t composite_q16, int64_t rich,
                                       int64_t poor);
    void mark_building_visual_cell(int32_t cell);
    void append_building_visual_social_rows(
        const std::vector<int32_t> &cells, godot::Dictionary &out) const;
    void publish_technology_practice_facts();
    void publish_country_development_facts();
    bool prepare_fiscal_budgets(int64_t day_index, std::string &error);
    int64_t prospective_business_subsidy_request(int32_t cell, int32_t country);
    struct TransactionQuote {
        int64_t base_value = 0;
        int64_t buyer_outlay = 0;
        int64_t seller_receipt = 0;
        int64_t fiscal_transfer = 0;
    };
    struct BuildingTaxQuote {
        int64_t business_transfer = 0;
        int64_t income_transfer = 0;
        int64_t after_tax_cash = 0;
    };
    TransactionQuote quote_transaction(int32_t cell, int32_t good,
                                        int64_t base_value,
                                        bool settle,
                                        bool subsidy_eligible,
                                        int64_t &saturation_count,
                                        int64_t filled_quantity);
    void settle_income_subsidies_for_cell(int32_t cell,
                                          int64_t &saturation_count);
    void settle_absolute_daily_taxes_for_cell(int32_t cell,
                                              int64_t &saturation_count);
    bool commit_fiscal(std::string &error);
    // Books one non-tax treasury outflow for the batch summary. `country_handle`
    // is the generation-safe payer handle; 0 is a no-op so callers may pass an
    // unresolved payer without inventing an attribution.
    void note_non_tax_outflow(uint64_t country_handle, int32_t kind, int64_t cash);
    int32_t epoch_country_index(uint64_t handle) const;
    bool advance_fiscal_reservation(std::string &error);
    bool advance_fiscal_settlement(std::string &error);
    int32_t frozen_tax_rate(int32_t cell, int32_t kind, int32_t item) const;
    int32_t frozen_tax_mode(int32_t cell, int32_t kind, int32_t item) const;
    int64_t apply_fiscal_tax(int32_t cell, int32_t kind, int64_t base,
                             int32_t rate, int64_t &saturation_count);
    int64_t apply_fiscal_tax(int32_t cell, int32_t kind, int64_t base,
                             int32_t rate, int32_t mode,
                             int64_t &saturation_count);
    struct FiscalLaneSnapshot {
        size_t lane = SIZE_MAX;
        int64_t bases = 0;
        int64_t assessed = 0;
        int64_t collected = 0;
        int64_t current_requests = 0;
        int64_t remaining = 0;
        int64_t paid = 0;
    };
    // apply_fiscal_tax settles immediately; callers that may abandon the
    // purchase afterwards must restore the lane so tax never outlives payment.
    FiscalLaneSnapshot snapshot_fiscal_lane(int32_t cell, int32_t kind) const;
    void restore_fiscal_lane(const FiscalLaneSnapshot &snapshot);
    int64_t expected_fiscal_transfer(int32_t cell, int32_t kind, int64_t base,
                                     int32_t rate,
                                     int64_t &saturation_count) const;
    int64_t expected_fiscal_transfer(int32_t cell, int32_t kind, int64_t base,
                                     int32_t rate, int32_t mode,
                                     int64_t &saturation_count) const;
    // Resolve frozen mode: percent uses money base, absolute uses unit count
    // (person-days, building-days, or goods quantity).
    int64_t expected_resolved_fiscal_transfer(
            int32_t cell, int32_t kind, int32_t item, int64_t percent_base,
            int64_t absolute_units, int64_t &saturation_count) const;
    int64_t producer_support_receipt_value(int32_t cell, int32_t good,
                                           int64_t quantity,
                                           int64_t &saturation_count) const;
    BuildingTaxQuote expected_building_tax_quote(
            int32_t cell, int32_t type_id, int32_t owner_profession,
            int64_t merchant_cash, int64_t producer_support_cash,
            int64_t business_eligible_cost, int64_t operating_cost,
            int64_t owner_living_cost, int64_t building_days,
            int64_t owner_days, int64_t &saturation_count) const;
    int32_t tariff_epoch_lane_index(int32_t cell, int32_t tariff_kind,
                                    bool create);
    int64_t expected_after_tax_income(int32_t cell, int32_t profession,
                                      int64_t gross_income,
                                      int64_t &saturation_count) const;
    int64_t fiscal_escrow_total() const;
    bool apply_build_command(const Command &cmd, int32_t owner_slot,
                             std::string &error, bool allow_obsolete_tier = false);
    bool investment_portfolio_funds_feasible(int32_t cell,
        const InvestmentCandidatePlan *const *plans,
        const ConstructionMaterialPlan *materials, int32_t count) const;
    bool commit_preflighted_build_command(
        const Command &cmd, int32_t owner_slot,
        const ConstructionMaterialPlan &material_plan,
        int32_t effective_construction_days,
        int64_t construction_debt_principal,
        int64_t construction_debt_premium,
        int64_t funding_gap,
        std::string &error);
    bool plan_construction_materials(int32_t cell, int32_t type_id,
                                     int64_t count, int32_t cost_factor_q16,
                                     ConstructionMaterialPlan &plan,
                                     const std::vector<int64_t> *additional_stock = nullptr,
                                     std::vector<int64_t> *stock_inout = nullptr,
        bool split_candidates = false, bool forecast_missing = false) const;
    bool apply_demolish_command(const Command &cmd, int32_t owner_slot, std::string &error);
    bool run_building_employment_cell(int32_t cell,
                                      bool allow_owner_job_reallocation,
                                      std::string &error);
    void replace_employment_metrics_for_cell(int32_t cell, int64_t owner_jobs,
                                             int64_t employee_jobs,
                                             int64_t unemployed_population);
    bool reconcile_building_employment_after_population_change(
        const std::vector<int32_t> &affected_cells, std::string &error);
    bool reconcile_building_employment_cells_range(
        const std::vector<int32_t> &stable_cells, int32_t begin, int32_t end,
        std::string &error);
    bool run_building_production_cell(int32_t cell, ProductionResult &result,
                                      std::string &error);
    void merge_building_production_result(ProductionResult &result);
    bool run_endogenous_building_investment(int32_t ordinal_begin,
                                            int32_t ordinal_end,
                                            bool initialize,
                                            bool &population_changed,
                                            std::string &error);
    void prepare_investment_review_cells();
    void begin_investment_scratch_generation();
    void ensure_investment_cell_finance_lane(int32_t cell);
    void ensure_investment_resource_commitment_lane(size_t index);
    int64_t investment_merchant_cash(int32_t cell) const;
    int64_t investment_outstanding_credit(int32_t cell) const;
    int64_t investment_resource_committed(size_t index) const;
    void record_investment_material_demand(int32_t cell, int32_t type_id,
        int64_t count, int32_t cost_factor_q16);
    void reserve_first_research_construction(int32_t cell);
    void prepare_startup_demand();
    void propagate_startup_demand_for_cell(int32_t cell);
    void begin_startup_demand_generation();
    void record_startup_demand(int32_t cell, int32_t good_id,
                               int64_t daily_quantity);
    int64_t startup_demand_for(int32_t cell, int32_t good_id) const;
    int64_t remote_startup_demand_for(int32_t cell, int32_t good_id) const;
    void consume_remote_startup_demand(int32_t cell, int32_t good_id,
                                       int64_t daily_capacity);
    // Sparse Leontief explosion of unmet deficits into intermediate-good
    // shadow demand for pricing and investment. Sample-boundary only.
    void refresh_derived_business_demand();
    // Credit non-selected co-candidates on the same input edge with shadow
    // substitute demand equal to the selected planned quantity.
    void credit_input_substitute_demand(int32_t cell, const ProductionInput &input,
                                        int32_t selected_candidate_index,
                                        int64_t planned);
    int64_t market_flow_deficit_daily(int32_t cell, int32_t good_id,
                                      bool include_derived,
                                      int64_t &sat) const;
    int64_t startup_producer_output_quantity(int32_t cell, int32_t type_id,
                                             int32_t good_id,
                                             int64_t &sat) const;
    int32_t select_startup_producer(int32_t cell, int32_t good_id) const;
    int32_t select_startup_producer(int32_t cell, int32_t good_id,
                                    InvestmentCandidatePlan *plan) const;
    // Cold-start ranking aid: how well the preferred producer of `good_id`
    // can cover its hard inputs from current local stock. Used when every
    // soft-input substitute is out of stock so ghost market prices alone
    // do not steer demand onto an unbuildable higher-tier good. Soft-only /
    // input-free recipes return 0 (not Q16_ONE) so they cannot beat a
    // hard-input cold-start lane that is merely empty this epoch.
    int64_t startup_producer_hard_input_cover_q16(int32_t cell, int32_t good_id,
                                                 int64_t &sat) const;
    bool startup_candidate_better(int64_t coverage, int64_t cold_cover,
                                  int64_t price, int32_t good_id,
                                  int64_t best_coverage, int64_t best_cold_cover,
                                  int64_t best_price, int32_t best_good) const;
    bool resolve_startup_construction_material(int32_t cell, int32_t bom,
                                               int32_t cost_factor_q16,
                                               int32_t &good,
                                               int64_t &physical) const;
    void initialize_investment_candidate_plan(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t payback_days, int64_t profit_per_day,
        int64_t return_on_capital_q16, int64_t owner_slots,
        int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const;
    // Final shared financial normalization for every investment trigger.
    // Startup, research, recovery and ordinary expansion may discover a
    // candidate differently, but they all publish the same plan economics.
    bool evaluate_investment_candidate(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t owner_slots, int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const;
    int32_t select_startup_input_candidate(int32_t cell,
                                           const ProductionInput &input,
                                           int64_t &physical_daily) const;
    int32_t select_startup_construction_candidate(int32_t cell,
                                                  int32_t group,
                                                  int64_t &physical_quantity) const;
    int32_t find_entrepreneur_source(int32_t cell, int32_t target_signature,
                                     int64_t required_capital,
                                     int64_t target_income_per_day,
                                     int64_t target_living_cost_per_day,
                                     int64_t owner_slots_per_building,
                                     int32_t building_type_id,
                                     bool &had_eligible_sponsor,
                                     int64_t &willing_population,
                                     int64_t &transferable_capital,
                                     int64_t &income_improvement_q16,
                                     uint64_t &sponsor_family_handle,
                                     const std::vector<int64_t> *living_cost_cache = nullptr) const;
    int64_t projected_owner_income_per_day(BuildingGroupConstRef group,
                                           int64_t &sat) const;
    OwnerOpportunityQuote owner_opportunity_quote(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const;
    OwnerOpportunityQuote owner_opportunity_quote_uncached(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const;
    int64_t projected_employee_tax_retention_q16(
        BuildingGroupConstRef group, int64_t &sat) const;
    int64_t effective_building_output_quantity(
        BuildingGroupConstRef group, int32_t good_id, int64_t base_quantity,
        int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const;
    // Same math for a synthetic target that has no row in the group lane.
    int64_t effective_building_output_quantity_at(
        int32_t cell, int32_t output_factor_q16, int32_t good_id,
        int64_t base_quantity, int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const;
    int64_t effective_building_output_quantity_for_target(
        int32_t cell, int32_t type_id, int32_t owner_signature_id,
        int32_t good_id, int64_t base_quantity, int64_t utilization_q16,
        int64_t building_days, int64_t &sat);
    int64_t effective_production_input_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_resource_use_quantity(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_managed_resource_generation(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const;
    int64_t effective_household_good_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const;
    void refresh_building_modifier_factors();
    // Returns true when the whole refresh finished, false when it yielded with a
    // resume cursor. Plan §14.3 requires "each derived native slice <= 1 ms";
    // M1-6 measured this reader at 0.465 ms (2400 cells) and 1.264 ms (6400
    // cells) while running to completion inside ONE
    // `run_economy_slice` (it is reached from `capture_country_epoch`, itself
    // inside `start_epoch`). With a derived layer adding work in the same
    // indivisible window there is no budget left, so the loop must be able to
    // stop between cells.
    //
    // The first call after `_city_factor_shard_cursor < 0` performs the
    // whole-matrix paint and the scope collection, then advances a cell cursor.
    // Subsequent calls resume at that cursor until the work set is exhausted.
    bool refresh_city_modifier_factors();
    // Returns true when the whole refresh finished, false when it yielded.
    //
    // Why the output reader needs its own cursor rather than waiting for the
    // city reader to finish: chaining the two made the output factors update
    // only on the LAST city shard, so on a multi-shard epoch the production
    // factors were half-refreshed for the intermediate slices. Two independent
    // cursors keep both readers' progress monotonic and keep the total work
    // unchanged.
    bool refresh_city_output_modifier_factors();
    int32_t city_good_output_factor_q16(int32_t cell, int32_t good_id) const;
    int64_t planned_owner_demand(BuildingGroupConstRef group,
                                 int64_t &sat) const;
    int64_t building_debt_due(BuildingGroupConstRef group, int64_t &sat) const;
    int64_t repay_building_debt(int32_t cell, int32_t owner_slot,
                                BuildingGroupRef group, int64_t payment_cap,
                                int64_t &premium_paid);
    int64_t available_resource_amount(const ResourceAmount &item, int32_t cell) const;
    void ensure_resource_lane(size_t index);
    void consume_resource_amount(const ResourceAmount &item, int32_t cell, int64_t quantity);
    void queue_bio_introduce_from_good(int32_t cell, int32_t good_id);
    void commit_bio_introduce(int32_t cell, int32_t bit);
    bool resource_is_renewable(int32_t resource_id) const;
    int32_t resource_stock_density_q16(int32_t resource_id, int32_t cell) const;
    int64_t renewable_safe_harvest(int32_t resource_id, int32_t cell) const;
    bool commit_ready_construction(std::vector<int32_t> &changed_cells,
                                   bool prune_empty_groups = true);
    void initialize_building_role_span(BuildingGroupRef group);
    void release_building_role_span(BuildingGroupConstRef group);
    void rebuild_building_role_storage();
    void rebuild_building_cell_offsets();
    void rebuild_building_visual_snapshot();
    void publish_building_visual_changes(
        const std::vector<int32_t> &changed_cells);
    void rebuild_building_review_buckets();
    void review_recovery_building_group(int32_t group_index);
    void finalize_household_building_cell(int32_t cell, int64_t &saturation,
                                          int64_t &restarted,
                                          int64_t &failed);
    int64_t production_reserve_shortfall_cell(int32_t cell,
                                              int64_t &saturation) const;
    void add_trade_active_key(int32_t market, int32_t good);
    void rebuild_market_signals();
    void rebuild_market_signal_lookup();
    bool flush_market_signal_overflow(std::string &error);
    int32_t ensure_market_signal_index(int32_t cell, int32_t good);
    void mark_market_signal_cell_dirty(int32_t cell);
    void mark_market_signal_full_rebuild(const char *reason);
    void mark_labor_signal_cell_dirty(int32_t cell);
    void mark_labor_signal_full_rebuild(const char *reason);
    void mark_input_reserve_cell_dirty(int32_t cell);
    void mark_input_reserve_full_rebuild(const char *reason);
    void rebuild_production_input_reserves(int32_t active_begin = 0,
                                           int32_t active_end = -1,
                                           bool initialize = true);
    int64_t rebuild_production_input_reserves_for_cell(int32_t cell);
    void recount_production_input_reserve_totals();
    void resolve_building_maintenance_csr();
    bool is_storable_nonmonetary_good(int32_t good) const;
    int32_t resolved_maintenance_horizon_days(const BuildingType &type) const;
    int64_t merchant_protected_reserve(int32_t signal) const;
    int64_t daily_maintenance_cost_for_type(
        int32_t cell, const BuildingType &type, int64_t &sat) const;
    int64_t maintenance_settlement_price(
        int32_t cell, int32_t good, int64_t &sat) const;
    void rebuild_labor_signals();
    int32_t labor_signal_index(int32_t cell, int32_t profession) const;
    int64_t living_cost_for_signature(int32_t cell, int32_t signature_id,
                                      int32_t plan_override, int64_t &sat) const;
    void compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat);
    bool prepare_cell_wages(int32_t cell, std::string &error);
    void update_cell_labor_signals(int32_t cell);
    int64_t production_climate_capacity_q16(
        const BuildingType &type, int32_t cell,
        int64_t *temperature_fit_q16, int64_t *water_fit_q16,
        int64_t &saturation_count) const;
    void prepare_group_climate_capacity(BuildingGroupRef group,
                                        const BuildingType &type);
    // SHADOW-only parity: publish graph stage hash/work to Host when the sync
    // ECONOMY_GRAPH stage completes and ECONOMY is not worker-authoritative.
    void publish_shadow_graph_stage_reference(RuntimeEconomyGraphStage stage);
    // Shared BUILDING_PLAN entry: routes through economy_kernel_prepare_building_plan
    // so sync and future worker probe worlds share one boundary (no second formula).
    bool evaluate_building_plan_range(int32_t active_begin, int32_t active_end, std::string &error);
    bool prepare_building_economic_plan(int32_t active_begin, int32_t active_end,
                                        const std::vector<int32_t> *cells_override,
                                        BuildingPlanResult &result,
                                        std::string &error);
    // Mutation body owned by NativeEconomyRuntime SoA; invoked only via the
    // EconomyBuildingPlanExecutor adapter registered with the shared kernel.
    bool prepare_building_economic_plan_body(int32_t active_begin, int32_t active_end,
                                             const std::vector<int32_t> *cells_override,
                                             BuildingPlanResult &result,
                                             std::string &error);
    int32_t market_signal_index(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_research_demand_daily_for_market(int32_t market,
                                                   int32_t good) const;
    void refresh_epoch_research_demand();
    void refresh_epoch_colonization_demand();
    bool military_procurement_demand_valid(const Command &cmd) const;
    bool retain_military_procurement_demand(const Command &cmd, std::string &error);
    void refresh_epoch_military_demand(int64_t day);
    int64_t epoch_military_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_military_demand_daily_for_market(int32_t market, int32_t good) const;
    int64_t epoch_colonization_demand(int32_t cell, int32_t good) const;
    int64_t epoch_colonization_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_procurement_demand_daily(int32_t cell, int32_t good) const;
    int64_t epoch_procurement_demand_daily_for_market(int32_t market,
                                                       int32_t good) const;
    void refresh_epoch_bullion_quota();
    int64_t bullion_cell_quota_remaining(int32_t cell) const;
    int64_t bullion_cell_quota_initial(int32_t cell) const;
    int64_t bullion_quota_remaining(int32_t cell, int32_t good) const;
    int64_t consume_bullion_quota(int32_t cell, int32_t good,
                                  int64_t requested, int64_t &sat);
    PricePressure price_pressure(int32_t market, int32_t good, int64_t household_demand,
                                 int64_t stock, int64_t shortage_q16,
                                 int32_t signal_index, int64_t &saturation_count) const;
    int64_t next_price_v6(int32_t good, int64_t current_price,
                          const PricePressure &pressure, int32_t days,
                          int64_t &saturation_count, bool &rate_clamped,
                          bool &rise_damped, bool *minimum_tick = nullptr) const;
    // Settlement / trade projection share this clamp. Economic prices are not
    // capped by catalog reference_max_price; only the i32 numeric guard applies.
    // The reference/default/cost arguments are retained for call-site ABI and
    // ignored by the current formula.
    static int32_t base_price_ceiling(int32_t reference, int32_t default_price,
                                       int64_t cost_anchor);
    static PriceCeilingState advance_price_ceiling(PriceCeilingState state,
        int32_t base, int32_t price, int64_t funded_shortage_q16, int32_t days,
        int32_t confirm_days, int32_t expand_bp, int32_t recover_bp);
    int32_t market_price_ceiling(int32_t market, int32_t good,
                                 int64_t cost_anchor) const;
    int64_t price_ceiling_state_count() const;
    void commit_price_ceilings();
    std::vector<PriceCeilingObservation> _epoch_price_ceiling_observations;
    std::vector<PriceCeilingState> _price_ceiling_merge_scratch;
    std::vector<int64_t> _epoch_ceiling_business_requested, _epoch_ceiling_business_unfilled;
    std::vector<int64_t> _epoch_ceiling_research_requested, _epoch_ceiling_research_delivered;
    std::vector<int32_t> _epoch_ceiling_research_touched;

    EconomyTrackedScalar<int32_t> _price_ceiling_confirm_days{_metadata_changes, {{15, 24}, "metadata.price_ceiling_confirm_days", EconomyFieldEncoding::I32, 4}, 30};
    EconomyTrackedScalar<int32_t> _price_ceiling_expand_bp{_metadata_changes, {{15, 25}, "metadata.price_ceiling_expand_bp", EconomyFieldEncoding::I32, 4}, 50};
    EconomyTrackedScalar<int32_t> _price_ceiling_recover_bp{_metadata_changes, {{15, 26}, "metadata.price_ceiling_recover_bp", EconomyFieldEncoding::I32, 4}, 10};
    int64_t _price_ceiling_expansions = 0;
    int64_t _price_ceiling_recoveries = 0;
    int64_t _price_ceiling_blocked_rises = 0;
    static int64_t shape_price(int32_t ceiling, int64_t current_price, int64_t next_price,
                        int64_t &saturation_count, bool *headroom_damped,
                        bool *catalog_bound, bool *minimum_tick = nullptr);
    int32_t find_building_group(int32_t cell, int32_t type_id,
                                int32_t owner_signature_id) const;
    int32_t find_cohort_slot(int32_t cell, int32_t signature_id) const;
    int64_t credit_local_merchants(int32_t cell, int64_t amount,
                                   int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS,
                                   int64_t *saturation_override = nullptr);
    // Same denominator as credit_local_merchants: false when every local
    // merchant cohort is empty, so a market purchase has no seller to pay.
    bool local_merchants_can_receive(int32_t cell) const;
    int64_t debit_local_merchants(int32_t cell, int64_t amount,
                                  int32_t cashflow_source = CASHFLOW_MERCHANT_PROCUREMENT,
                                  int64_t *saturation_override = nullptr);
    int64_t pay_building_wage_amount(int32_t cell, int32_t owner_slot,
                                     int32_t profession_id, int64_t filled_jobs,
                                     int64_t due, int64_t payment_cap,
                                     int64_t *saturation_override = nullptr);
    void fail(const std::string &reason);
    void capture_fatal_context(const std::string &reason);
    void park_on_country_asset_pending(const char *substage);
    void clear_epoch_metrics();
    void capture_completed_perf_snapshot();
    void rebuild_committed_summaries();
    CellSummary build_cell_summary(int32_t cell) const;
    void stage_cell_summary(int32_t cell, const CellSummary &summary);
    void finalize_market_result(int32_t market, MarketResult &result);
    void refresh_investment_active_goods_for_cell(int32_t cell,
                                                  int64_t &saturation_count);
    bool rebuild_market_cell_ranges(std::string &error);
    bool ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                   std::string &error);
    bool rebuild_merchant_ranges(std::string &error);
    bool refresh_merchant_ranges_if_dirty(std::string &error);
    bool repair_cell_merchant_and_rebuild(int32_t cell, std::string &error);
    bool run_government_research_procurement(std::string &error);
    bool advance_country_research_procurement(
        CountryResearchProcurementContinuation &continuation,
        std::string &error);
    CountryWorkerAssetRoute block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, int32_t good_id, std::string &error,
        uint64_t *request_id = nullptr);
    CountryWorkerAssetRoute block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &good_quantities, std::string &error,
        uint64_t *request_id = nullptr, int32_t target_slot = -1);
    bool coordinate_country_fiscal_transaction(
        int32_t country, int32_t operation, int64_t amount,
        int64_t &committed, std::string &error,
        uint64_t *transport_request_id = nullptr);
    // M1+ peer service. Economy consumes Country-authorized asset requests and
    // never writes the Country store. Fiscal ops mutate escrow; non-fiscal ops
    // (when the D7 gate is open) apply local cohort/market side effects then
    // journal COMPLETED using Country-prepared quantities.
    bool service_country_economy_asset_peer(uint32_t max_requests,
                                            std::string &error);
    bool fiscal_peer_journal_matches(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record, std::string &error) const;
    RuntimeEconomyAssetResult fiscal_peer_result_from_journal(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record) const;
    void record_fiscal_peer_terminal(
        const RuntimeEconomyAssetRequest &request,
        RuntimeEconomyAssetResultCode code,
        RuntimeEconomyAssetState state,
        int64_t committed_quantity, int64_t committed_cash,
        const char *reason);
    // Economy-side apply for M2–M5 after Country has already committed value.
    // RESEARCH_PURCHASE / TREASURY_SPEND complete without local mutation when
    // Country transferred treasury goods/cash on its path.
    bool apply_peer_asset_side_effects(const RuntimeEconomyAssetRequest &request,
                                       std::string &error);
    // Economy-owned peer coordinator for Country/cohort cash transfers. The
    // cohort is prepared before Country commit, then mutated exactly once and
    // acknowledged with the same transaction identity.
    bool coordinate_country_cohort_cash(
        int32_t cohort_slot, int64_t country_handle, int32_t operation,
        int64_t amount, int64_t &committed, std::string &error);
    // Economy-owned coordinator for Country/market inventory transfers. The
    // market lane is preflighted before Country commit and mutated once after
    // the commit decision.
    bool coordinate_country_market_goods(
        int32_t market, int32_t good, int64_t country_handle,
        int32_t operation, int64_t amount, int64_t &committed,
        std::string &error);
    bool coordinate_country_treasury_spend(
        int32_t merchant_cell, int32_t market, int64_t country_handle,
        const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &treasury_quantities,
        const std::vector<int64_t> &market_quantities, int64_t cash,
        int64_t &committed_cash, std::string &error);
    void refresh_country_research_goods_consumed();
    // Re-pin closing country goods/cash with research_consumed from one Country
    // snapshot immediately before VERIFY. Peer-wait previews / late-fold
    // research catch-up can otherwise advance consumed after closing goods were
    // frozen and trip goods_conservation_failed. Opening pins the same triple
    // atomically in begin_epoch (see economy_runtime_epoch.cpp).
    void resync_closing_country_goods_audit();
    bool compile_family_catalog(const godot::Dictionary &catalog,
                                std::string &error);
    bool compile_family_trait_catalog(const godot::Dictionary &catalog,
                                      std::string &error);
    bool compile_family_effect_catalog(const godot::Dictionary &catalog,
                                       std::string &error);
    bool run_family_commit_slice(int64_t &work_done, std::string &error);
    // Phase-2.4.3.3: StageOps mutate drains (compact keeps per-slice calls).
    bool run_family_commit_drain(int64_t &work_done, std::string &error);
    bool run_person_commit_drain(int64_t &work_done, std::string &error);
    bool run_aggregate_publish_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.3.1: shared BUILDING_COMMIT phase driver (no run_slice_compact).
    // ContinueFusing = stay in stage, outer loop may fuse; StopSlice = yield;
    // LeftStage = _stage moved past BUILDING_COMMIT; Fatal = fail() already called.
    enum class BuildingCommitChunkResult : uint8_t {
        ContinueFusing = 0,
        StopSlice = 1,
        LeftStage = 2,
        Fatal = 3,
    };
    BuildingCommitChunkResult advance_building_commit_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, std::string &error, bool yield_enabled,
        int32_t *chunks_completed, int32_t max_chunks_per_slice,
        int32_t *phase_fusions, const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms);
    // Phase-2.2/2.4.3.1: StageOps mutate entry for BUILDING_COMMIT. Drains the
    // shared phase driver until the runtime leaves BUILDING_COMMIT — never
    // re-enters run_slice_compact. Phase-2.4.3.2 then drains fiscal settlement
    // so FAMILY_COMMIT sees settled escrow (graph has no FISCAL stage).
    bool run_building_commit_slice(int64_t &work_done, std::string &error);
    // Phase-2.4.4.3: shared HOUSEHOLD_MARKET phase driver (no run_slice_compact).
    enum class HouseholdMarketChunkResult : uint8_t {
        ContinueFusing = 0,
        StopSlice = 1,
        LeftStage = 2,
        Fatal = 3,
    };
    HouseholdMarketChunkResult advance_household_market_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, bool &cell_range_used, std::string &error,
        bool yield_enabled, int32_t batch_multiplier, int32_t *chunks_completed,
        int32_t max_chunks_per_slice, int32_t *phase_fusions,
        const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms);
    bool run_household_market_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.3.2: StageOps-only fiscal bridge after BUILDING_COMMIT.
    // Fail-closed on country peer pending (compact yields; StageOps cannot).
    bool run_fiscal_settlement_drain(std::string &error);
    void diag_stage_money_probe(const char *where, bool force = false);
    // Phase-2.4.4.3: StageOps bounded mid-graph drains (cursor + slice caps).
    // Compact keeps its own slice loops; these drains never re-enter
    // run_slice_compact.
    bool run_building_employment_drain(int64_t &work_done, std::string &error);
    bool run_building_production_drain(int64_t &work_done, std::string &error);
    struct BuildingInvestmentCellContext;
    enum class InvestmentPreflightResult : uint8_t {
        Skip = 0,
        Ready = 1,
        Fatal = 2,
    };
    bool investment_prepare_cell(BuildingInvestmentCellContext &ctx);
    bool investment_evaluate_cell_types(BuildingInvestmentCellContext &ctx);
    void investment_mark_rejection(const InvestmentExistingType *existing,
                                   int32_t reason);
    void investment_allocate_portfolio(BuildingInvestmentCellContext &ctx);
    InvestmentPreflightResult investment_preflight_portfolio(
        BuildingInvestmentCellContext &ctx, std::string &error);
    bool investment_commit_portfolio(BuildingInvestmentCellContext &ctx,
                                     bool &population_changed,
                                     std::string &error);
    // Phase-2.4.4.4: StageOps drains for early/late graph stages that were still
    // single-slice in dispatch (Host advances stage_index once per pulse).
    bool run_ledger_apply_drain(int64_t &work_done, std::string &error);
    bool run_government_research_drain(int64_t &work_done, std::string &error);
    bool run_structural_commit_drain(int64_t &work_done, std::string &error);
    // Phase-2.4.5: BUILDING_PLAN evaluate+reserve drain (matches compact).
    bool run_building_plan_drain(int64_t &work_done, std::string &error);
    void rebuild_family_indices(bool rebuild_derived = true);
    void rebuild_family_industry_metrics();
    void rebuild_family_owned_output_csr();
    bool rebuild_family_behavior_cache();
    void mark_family_behavior_cache_dirty(uint32_t reason);
    // Track B cadenced AGGREGATE_PUBLISH state hash carry (per runtime).
public:
    bool track_b_aggregate_hash_reuse(int64_t day, uint64_t &cached_hash);
    void track_b_aggregate_hash_store(int64_t day, uint64_t hash);
private:
    void rebuild_family_policy_scalars();
    void grant_random_pool_family_effect(int32_t family_index,
                                         bool submit_changes);
    void grant_family_effect_to_branches(int32_t family_index,
                                         int32_t effect_id);
    void grant_ancestral_precept_for_country(uint64_t country_handle);
    int32_t family_effect_id_for_key(const std::string &program_key) const;
    int32_t family_effect_prestige_magnitude_q16(int32_t effect_id,
                                                 int32_t prestige_level) const;
    int32_t family_owned_output_factor_q16(int32_t family_index, int32_t cell,
                                           int32_t sector,
                                           int32_t upgrade_family) const;
    int32_t family_scoped_output_factor_q16(uint64_t family_handle) const;
    int32_t family_group_owned_output_factor_q16(int32_t group_index) const;
    const FamilyIndustryStats *family_industry_stats_for(
        int32_t family_index, int32_t cell) const;
    void apply_family_split_policy_flags(int32_t family_index, uint16_t policy,
                                         uint8_t weight_q8);
    void split_family_branches();
    bool build_family_split_offer(int32_t parent, int32_t cell,
                                  FamilyFoundingOffer &offer) const;
    bool resolve_family_split_offer(const FamilyFoundingOffer &offer,
                                    int32_t choice_index);
    void transfer_family_branch(int32_t parent, int32_t child, int32_t cell);
    // commit_ledger is set only at FAMILY_COMMIT: it settles the claim ledger
    // against each cohort's opening basis. Mid-epoch callers only enforce
    // the subset caps.
    void normalize_family_memberships(bool rebuild_derived = true,
                                      bool commit_ledger = false);
    void collect_family_edges_for_cohort(int32_t slot,
                                         std::vector<int32_t> &out) const;
    int64_t family_ledger_basis_for_slot(int32_t slot) const;
    // Structural funds moves (migration, colonization, capital transfers)
    // shift the cohort's ledger opening so they are not read as flows.
    void shift_family_ledger_basis(int32_t slot, int64_t delta);
    // A funds change in `slot` that belongs to one family (0 = anonymous):
    // the claim moves with it and the basis shifts so it is not re-split.
    void attribute_family_funds_delta(int32_t slot, uint64_t family_handle,
                                      int64_t delta);
    void rebuild_family_demography_weights();
    const FamilyDemographyRow *family_demography_row(uint64_t family_handle,
                                                     int32_t cell) const;
    void apply_family_death_attribution(int32_t slot, int64_t population_before,
                                        int64_t deaths);
    void apply_family_birth_attribution(int32_t slot, int64_t births);
    void settle_family_claim_ledger();
    void recruit_family_dependents();
    void rebuild_family_owner_seats();
    int64_t family_owner_seats(uint64_t cohort_handle, uint64_t family_handle) const;
    // Owning family of group `group_index` with idle members in `pool_slot`,
    // or 0. Only used when the hire lands in the group's owner signature.
    uint64_t owning_family_for_owner_hire(int32_t group_index,
                                          int32_t pool_slot) const;
    void release_unstaffable_family_ownership(int32_t family_index);
    void record_person_deaths_for_family(int32_t cohort_slot,
                                         uint64_t family_handle,
                                         int64_t people_before,
                                         int64_t deaths);
    // Clamp derived employment/basis fields so membership edges always satisfy
    // the PKEC restore invariants even if attribution briefly overshoots.
    static void sanitize_family_membership_edge(FamilyMembershipEdge &edge);
    // Clamp ownership shares to the surviving building count and owner-slot
    // capacity. Liquidation and demolition shrink a group after the shares were
    // granted, so without this the PKEC restore invariants can reject a save.
    void sanitize_family_ownership_edges();
    void absorb_family_households();
    int64_t family_household_target_people(int64_t owner_slots) const;
    int64_t family_household_people_for_slot(int32_t slot,
                                             int64_t owner_slots) const;
    int64_t family_owned_owner_slots_in_cell(int32_t family_index,
                                             int32_t cell) const;
    void add_family_household_people(uint64_t family_handle, int32_t slot,
                                     int64_t take);
    int64_t family_people_on_slot(int32_t slot) const;
    void update_family_employment_attribution();
    void attribute_family_owner_employment_for_cell(int32_t cell);
    int32_t create_family_for_building(
        int32_t cell, int32_t building_index, int64_t founders,
        int64_t filled_owner, bool allow_small_starter = false,
        const FamilyFoundingIdentity *identity = nullptr);
    void review_family_milestone(int32_t cell);
    int64_t family_milestone_hash() const;
    int64_t family_founding_founders_for_group(int32_t cell,
                                               int32_t group_index) const;
    int32_t build_family_founding_candidates(
        int32_t cell, int32_t milestone_index,
        std::vector<FamilyFoundingCandidate> &out) const;
    bool resolve_family_founding_offer(FamilyFoundingOffer &offer,
                                       int32_t choice_index);
    bool family_founding_player_choice(int32_t cell) const;
    int32_t family_founding_auto_choice(const FamilyFoundingOffer &offer) const;
    void apply_due_family_founding_choices();
    void rebuild_family_founding_offer_index();
    int32_t family_founding_offer_for_cell(int32_t cell);
    void prune_family_founding_effects();
    void clear_family_founding_state();
    bool write_family_founding_save_records(int32_t budget,
                                            std::vector<uint8_t> &payload);
    bool read_family_founding_save_records(const std::vector<uint8_t> &bytes,
                                           size_t &cursor, uint32_t records,
                                           std::string &error);
    bool validate_restored_family_founding(std::string &error) const;
    void append_family_founding_hash(uint64_t &hash) const;
    int32_t family_founding_effect_for(int64_t stable_id) const;
    int32_t roll_core_family_traits(uint64_t stable_id, int32_t tech_cell,
                                    int32_t origin_cell,
                                    std::vector<int32_t> &trait_ids,
                                    std::vector<int32_t> &strengths) const;
    int32_t roll_random_pool_family_effect(
        uint64_t stable_id, int32_t tech_cell,
        const std::vector<int32_t> &owned_sorted,
        const std::vector<int32_t> &avoid) const;
    void review_family_lifecycle();
    void assign_core_family_traits(int32_t family_index);
    void apply_due_family_trait_commands();
    void rebuild_family_influences(bool rebuild_derived = true);
    void reconcile_family_branch_effects(uint64_t branch_handle,
                                         bool submit_changes);
    void clear_family_branch_effects(uint64_t branch_handle);
    void rebuild_family_effect_binding_index();
    void add_family_effect_binding(FamilyEffectBinding binding);
    void remove_family_effect_binding(size_t index);
    int64_t family_effect_metric_revision(int32_t phase) const;
    bool publish_family_effect_metrics(const FamilyEffectBinding &binding,
                                       int64_t revision,
                                       const MetricMask &requested_mask);
    void refresh_family_effect_metrics_for_branch(uint64_t branch_handle,
                                                  int64_t revision,
                                                  const MetricMask &requested_mask);
    void refresh_family_effect_metrics_for_cell(int32_t cell,
                                                int64_t revision,
                                                const MetricMask &requested_mask);
    int32_t family_trait_behavior_factor_q16(uint64_t family_handle,
                                             int32_t axis,
                                             int32_t selector_kind,
                                             int32_t selector_id,
                                             int32_t cell = -1) const;
    int32_t family_behavior_score_term_q16(uint64_t family_handle,
                                           int32_t cell,
                                           int32_t score_term) const;
    int32_t family_purchase_pay_factor_q16(int32_t cohort_slot) const;
    int32_t family_free_building_type_id(const Command &cmd) const;
    void fill_family_behavior_metrics(int32_t family_index, int32_t branch,
                                      int32_t cell, int64_t *metrics,
                                      int32_t metric_count,
                                      const MetricMask &metric_mask =
                                          MetricMask::all()) const;
    bool evaluate_family_behavior_conditions(int32_t edge,
                                             const int64_t *metrics,
                                             int32_t metric_count) const;
    int32_t building_local_resource_abundance_q16(int32_t cell,
                                                  int32_t type_id) const;
    int32_t cell_profession_share_q16(int32_t cell,
                                      int32_t profession_id) const;
    bool family_trait_technology_unlocked(int32_t trait_id, int32_t cell) const;
    bool family_effect_technology_unlocked(int32_t effect_id, int32_t cell) const;
    bool family_trait_origin_gates_allow(int32_t trait_id, int32_t origin_cell) const;
    bool family_trait_context_allows(int32_t trait_id, int32_t family_index) const;
    void collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells,
        const std::string &definition_key = std::string(),
        int32_t prestige_level = 1) const;
